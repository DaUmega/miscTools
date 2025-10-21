#!/usr/bin/env python3
"""
Simple wrapper to re-encode videos with libx265 (HEVC) and show useful info.
This script intentionally keeps behavior identical to running:
  ffmpeg -i input.mp4 -c:v libx265 -vtag hvc1 -c:a copy output.mkv

It prints original size/duration, an acceptance threshold, the ffmpeg command,
and final compressed size + decision (replace original or keep it).
"""

import os
import sys
import shutil
import subprocess
import json
import time
import signal
import threading
import re

# === SETTINGS ===
MIN_SIZE_MB = 5.0
MIN_COMPRESSION_RATIO = 0.5  # only keep compressed file if it's less than this fraction of original
SAMPLE_SECONDS = 20          # how long to sample encoding to estimate final size
SUPPORTED_FORMATS = ('.mp4', '.mkv', '.mov', '.avi', '.flv', '.wmv')
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")

if not FFMPEG or not FFPROBE:
    print("❌ ffmpeg or ffprobe not found. Please install ffmpeg first.")
    sys.exit(1)


def get_video_info(path: str):
    """Return (duration_seconds, size_mb) or (None, None) on error."""
    try:
        cmd = [FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "json", path]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        info = json.loads(result.stdout)
        duration = float(info["format"]["duration"])
        size_mb = os.path.getsize(path) / (1024 * 1024)
        return duration, size_mb
    except Exception:
        return None, None


def prepare_paths(path: str):
    base_dir = os.path.dirname(path)
    base_name = os.path.splitext(os.path.basename(path))[0]
    temp_path = os.path.join(base_dir, base_name + ".tmp.mkv")
    final_path = os.path.join(base_dir, base_name + ".mkv")
    return temp_path, final_path


def compress_video(path: str):
    try:
        duration, size_mb = get_video_info(path)
        if not duration or duration <= 0:
            print(f"❌ Skipping invalid video: {path}")
            return

        if size_mb < MIN_SIZE_MB:
            print(f"⏭️  Skipping small file ({size_mb:.2f} MB): {path}")
            return

        temp_path, final_path = prepare_paths(path)
        accept_threshold_mb = size_mb * MIN_COMPRESSION_RATIO

        print("------------------------------------------------------------")
        print(f"🔧 Processing: {path}")
        print(f"   Duration : {duration/60:.2f} minutes")
        print(f"   Original : {size_mb:.2f} MB")
        print(f"   Keep new file only if < {accept_threshold_mb:.2f} MB ({MIN_COMPRESSION_RATIO*100:.0f}% of original)")

        cmd = [FFMPEG, "-y", "-i", path, "-c:v", "libx265", "-vtag", "hvc1", "-c:a", "copy", temp_path]
        print("▶️  Running ffmpeg:")
        print("   " + " ".join(cmd))
        print(f"ℹ️  Sampling {SAMPLE_SECONDS}s to estimate final size... (will print live ffmpeg output below)")

        # Start ffmpeg but capture stderr so we can parse the "time=" progress value
        # while still streaming ffmpeg output live to the terminal.
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, bufsize=1)

        # shared state to hold the latest parsed encoded time (as "HH:MM:SS.xx")
        last_time_str = {"val": None}
        time_re = re.compile(r"time=(\d+:\d+:\d+\.\d+)")

        def stderr_reader(stream, outdict):
            try:
                while True:
                    chunk = stream.read(1024)
                    if not chunk:
                        break
                    # stream ffmpeg output to the terminal exactly as received
                    try:
                        sys.stderr.write(chunk)
                        sys.stderr.flush()
                    except Exception:
                        pass
                    # parse any time=... occurrences and keep the last one
                    for m in time_re.finditer(chunk):
                        outdict["val"] = m.group(1)
            except Exception:
                pass

        reader_thr = threading.Thread(target=stderr_reader, args=(proc.stderr, last_time_str), daemon=True)
        reader_thr.start()

        def hms_to_seconds(hms: str) -> float:
            try:
                hh, mm, ss = hms.split(":")
                return int(hh) * 3600 + int(mm) * 60 + float(ss)
            except Exception:
                return 0.0

        start = time.monotonic()
        sampled = False
        # Wait SAMPLE_SECONDS or until process finishes
        while True:
            now = time.monotonic()
            elapsed = now - start
            if proc.poll() is not None:
                # ffmpeg finished before/while sampling
                break
            if not sampled and elapsed >= SAMPLE_SECONDS:
                # gather sample info, prefer encoded time from ffmpeg output (time=HH:MM:SS.xx)
                try:
                    if os.path.exists(temp_path):
                        bytes_written = os.path.getsize(temp_path)
                        # prefer parsing the time= value reported by ffmpeg
                        parsed = last_time_str.get("val")
                        encoded_seconds = hms_to_seconds(parsed) if parsed else 0.0
                        if encoded_seconds <= 0.0:
                            # fallback to wall-clock elapsed if ffmpeg time not available
                            encoded_seconds = elapsed
                        # avg bitrate in kbits/s based on actual encoded seconds
                        kbps = (bytes_written * 8) / encoded_seconds / 1000.0 if encoded_seconds > 0 else 0.0
                        est_final_bytes = (kbps * 1000.0 / 8.0) * duration
                        est_final_mb = est_final_bytes / (1024 * 1024)
                        print()
                        sample_time_display = int(encoded_seconds) if parsed else int(elapsed)
                        print(f"🔎 Sample after {sample_time_display}s (ffmpeg time{' available' if parsed else ' unavailable'}): written {bytes_written/(1024*1024):.2f} MB -> avg {kbps:.1f} kbit/s")
                        print(f"🔮 Estimated final size: {est_final_mb:.2f} MB ({(est_final_mb/size_mb)*100:.1f}% of original)")
                        if est_final_mb >= accept_threshold_mb:
                            print("⚠️  Estimated size not good enough. Aborting encoding to save time/disk.")
                            # try graceful shutdown then kill if needed
                            try:
                                proc.send_signal(signal.SIGINT)
                                # give ffmpeg a moment to write trailer and exit
                                try:
                                    proc.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    proc.kill()
                                    proc.wait(timeout=5)
                            except Exception:
                                try:
                                    proc.kill()
                                except Exception:
                                    pass
                            # remove partial file if present
                            try:
                                if os.path.exists(temp_path):
                                    os.remove(temp_path)
                            except Exception:
                                pass
                            # ensure reader thread finishes
                            try:
                                reader_thr.join(timeout=1)
                            except Exception:
                                pass
                            return
                        else:
                            print("✅ Estimated size looks promising. Letting ffmpeg continue to completion.")
                    else:
                        print(f"⚠️  No output file yet at sample time ({temp_path}), cannot estimate reliably. Continuing encoding.")
                except Exception as e:
                    print(f"⚠️  Failed to sample file size: {e}. Continuing encoding.")
                sampled = True
            time.sleep(0.5)

        # wait for process to finish if it hasn't already
        rc = proc.poll()
        if rc is None:
            rc = proc.wait()
        # ensure reader thread finishes
        try:
            reader_thr.join(timeout=1)
        except Exception:
            pass

        if rc != 0:
            print(f"❌ ffmpeg failed for {path} (exit code {rc}). Removing partial output if any.")
            try:
                if os.path.exists(temp_path):
                    os.remove(temp_path)
            except Exception:
                pass
            return

        if not os.path.exists(temp_path):
            print(f"❌ Expected output not found: {temp_path}")
            return

        final_size_mb = os.path.getsize(temp_path) / (1024 * 1024)
        ratio = final_size_mb / size_mb if size_mb > 0 else 1.0

        print()
        print(f"✅ Finished: {os.path.basename(temp_path)}")
        print(f"   Compressed : {final_size_mb:.2f} MB ({ratio*100:.1f}% of original)")

        if final_size_mb < accept_threshold_mb:
            # keep compressed file, remove original
            os.replace(temp_path, final_path)
            try:
                os.remove(path)
            except Exception:
                pass
            print(f"🗑️  Original replaced. New file: {final_path}")
        else:
            # not worth it, remove compressed and keep original
            try:
                os.remove(temp_path)
            except Exception:
                pass
            print(f"⚠️  Compression not significant. Original kept: {path}")

    except Exception as e:
        print(f"❌ Error processing {path}: {e}")
        try:
            if os.path.exists(temp_path):
                os.remove(temp_path)
        except Exception:
            pass


def compress_directory(directory: str):
    all_videos = []
    for root, _, files in os.walk(directory):
        for fname in files:
            if fname.lower().endswith(SUPPORTED_FORMATS):
                all_videos.append(os.path.join(root, fname))

    if not all_videos:
        print("No supported videos found.")
        return

    print(f"Found {len(all_videos)} videos. Starting sequential compression...\n")

    for v in all_videos:
        compress_video(v)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} /path/to/directory")
        sys.exit(1)

    target_dir = sys.argv[1]
    if not os.path.isdir(target_dir):
        print(f"❌ Invalid directory: {target_dir}")
        sys.exit(1)

    compress_directory(target_dir)
    print("\n🎬 All done!")
