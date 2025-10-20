#!/usr/bin/env python3
"""
CRF-based Video Compressor with Early Size Estimation
-----------------------------------------------------
Recursively compresses videos using libx265 (HEVC) with CRF encoding.
Predicts final size during compression and cancels early if not worth it.
Outputs .mkv files, removes originals if compression is successful.
"""

import os
import sys
import shutil
import subprocess
import concurrent.futures
import re

# === SETTINGS ===
CRF = 28
PRESET = "medium"
MIN_SIZE_MB = 5.0
MIN_COMPRESSION_RATIO = 0.98
SUPPORTED_FORMATS = ('.mp4', '.mkv', '.mov', '.avi', '.flv', '.wmv')
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")

if not FFMPEG or not FFPROBE:
    print("❌ ffmpeg or ffprobe not found. Please install ffmpeg first.")
    sys.exit(1)


def get_video_info(path: str):
    """Return duration (s) and size (MB)."""
    try:
        import json
        cmd = [FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "json", path]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        info = json.loads(result.stdout)
        duration = float(info["format"]["duration"])
        size_mb = os.path.getsize(path) / (1024 * 1024)
        return duration, size_mb
    except Exception:
        return None, None


def prepare_paths(path: str):
    """Return temp and final paths for output .mkv."""
    base_dir = os.path.dirname(path)
    base_name = os.path.splitext(os.path.basename(path))[0]
    temp_path = os.path.join(base_dir, base_name + ".tmp.mkv")
    final_path = os.path.join(base_dir, base_name + ".mkv")
    return temp_path, final_path


def run_ffmpeg_crf(input_path, output_path, duration, original_size_mb):
    """Run FFmpeg CRF compression with early size estimation."""
    cmd = [
        FFMPEG, "-y", "-i", input_path,
        "-c:v", "libx265", "-vtag", "hvc1",
        "-crf", str(CRF),
        "-preset", PRESET,
        "-c:a", "copy",
        output_path
    ]

    time_pattern = re.compile(r'time=(\d+):(\d+):([\d.]+)')
    size_pattern = re.compile(r'size=(\d+)kB')

    proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True)

    while True:
        line = proc.stderr.readline()
        if not line:
            break

        t_match = time_pattern.search(line)
        s_match = size_pattern.search(line)
        if t_match and s_match:
            h, m, s = int(t_match.group(1)), int(t_match.group(2)), float(t_match.group(3))
            elapsed_sec = h*3600 + m*60 + s
            current_size_mb = int(s_match.group(1)) / 1024
            est_final_mb = (current_size_mb / max(elapsed_sec, 0.1)) * duration

            if est_final_mb > original_size_mb * MIN_COMPRESSION_RATIO:
                print(f"⚠️ Estimated final size {est_final_mb:.1f} MB too large, cancelling")
                proc.terminate()
                return False

    proc.wait()
    return os.path.exists(output_path)


def should_replace_original(original_path, temp_path):
    """Return True if compressed file is significantly smaller."""
    original_size = os.path.getsize(original_path)
    final_size = os.path.getsize(temp_path)
    return final_size < original_size * MIN_COMPRESSION_RATIO


def compress_video(path: str):
    """High-level compression wrapper."""
    try:
        duration, size_mb = get_video_info(path)
        if not duration or duration <= 0:
            print(f"❌ Skipping invalid video: {path}")
            return
        if size_mb < MIN_SIZE_MB:
            print(f"⏭️  Skipping small file ({size_mb:.2f} MB): {path}")
            return

        temp_path, final_path = prepare_paths(path)

        print(f"🔧 Compressing {os.path.basename(path)} ({size_mb:.1f} MB, {duration/60:.1f} min)")

        success = run_ffmpeg_crf(path, temp_path, duration, size_mb)
        if not success:
            if os.path.exists(temp_path):
                os.remove(temp_path)
            return

        if should_replace_original(path, temp_path):
            os.replace(temp_path, final_path)
            os.remove(path)
            print(f"✅ Compressed to {os.path.getsize(final_path)/(1024*1024):.1f} MB → {final_path}")
        else:
            os.remove(temp_path)
            print(f"⚠️ Minimal reduction, original kept ({path})")

    except Exception as e:
        print(f"❌ Failed to process {path}: {e}")
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

    print(f"Found {len(all_videos)} videos. Starting compression...\n")

    with concurrent.futures.ProcessPoolExecutor(max_workers=2) as executor:
        list(executor.map(compress_video, all_videos))


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
