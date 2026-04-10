#!/usr/bin/env python3
"""
Video Compressor Script
-----------------------
Re-encodes videos with libx265 (HEVC) for significant size reduction.
Always previews files and asks for confirmation before making any changes.
Replaces the original only if the compressed file is meaningfully smaller.

Usage:
    python3 compressVids.py /path/to/directory [options]

Options:
    -r, --recursive         Also process subdirectories (opt-in)
    -y, --yes               Skip confirmation prompt
    --backup                Copy originals to .backup/ before replacing
    --min-size MB           Skip files smaller than this (default: 5.0 MB)
    --ratio RATIO           Only keep compressed file if smaller than this
                            fraction of the original (default: 0.5 = 50%)

Examples:
    python3 compressVids.py ~/Videos
    python3 compressVids.py ~/Videos -r --backup
    python3 compressVids.py ~/Videos --min-size 10 --ratio 0.6 -y
"""

import os
import sys
import re
import json
import shutil
import signal
import subprocess
import threading
import time
import argparse

# === DEFAULTS ===
DEFAULT_MIN_SIZE_MB        = 5.0
DEFAULT_MIN_COMPRESS_RATIO = 0.5   # keep new file only if < 50% of original
SAMPLE_SECONDS             = 20    # seconds of encoding used to estimate final size
SUPPORTED_FORMATS          = ('.mp4', '.mkv', '.mov', '.avi', '.flv', '.wmv')

FFMPEG  = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")

if not FFMPEG or not FFPROBE:
    print("❌  ffmpeg / ffprobe not found. Please install ffmpeg first.")
    sys.exit(1)


# === HELPERS ===

def get_video_info(path: str) -> tuple[float | None, float]:
    """Return (duration_seconds, size_mb). duration is None on error."""
    try:
        cmd = [FFPROBE, "-v", "error", "-show_entries", "format=duration",
               "-of", "json", path]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        info = json.loads(result.stdout)
        duration = float(info["format"]["duration"])
        size_mb  = os.path.getsize(path) / (1024 * 1024)
        return duration, size_mb
    except Exception:
        return None, os.path.getsize(path) / (1024 * 1024)


def fmt_duration(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    return f"{m}m {s:02d}s" if m else f"{s}s"


def hms_to_seconds(hms: str) -> float:
    try:
        hh, mm, ss = hms.split(":")
        return int(hh) * 3600 + int(mm) * 60 + float(ss)
    except Exception:
        return 0.0


def collect_videos(directory: str, recursive: bool) -> list[str]:
    videos = []
    if recursive:
        for root, dirs, files in os.walk(directory):
            dirs[:] = [d for d in dirs if d != ".backup"]
            for f in files:
                if f.lower().endswith(SUPPORTED_FORMATS):
                    videos.append(os.path.join(root, f))
    else:
        for f in os.listdir(directory):
            p = os.path.join(directory, f)
            if os.path.isfile(p) and f.lower().endswith(SUPPORTED_FORMATS):
                videos.append(p)
    return sorted(videos)


# === COMPRESSION ===

def compress_video(path: str, args) -> None:
    duration, size_mb = get_video_info(path)

    base_dir  = os.path.dirname(path)
    base_name = os.path.splitext(os.path.basename(path))[0]
    temp_path  = os.path.join(base_dir, base_name + ".tmp.mkv")
    final_path = os.path.join(base_dir, base_name + ".mkv")

    accept_threshold_mb = size_mb * args.ratio

    print(f"\n{'─'*60}")
    print(f"🔧  {os.path.relpath(path, args.directory)}")
    print(f"    Size     : {size_mb:.2f} MB")
    if duration:
        print(f"    Duration : {fmt_duration(duration)}")
    print(f"    Keep if  : < {accept_threshold_mb:.2f} MB  ({args.ratio*100:.0f}% of original)")

    cmd = [FFMPEG, "-y", "-i", path, "-c:v", "libx265", "-vtag", "hvc1", "-c:a", "copy", temp_path]
    print(f"    Command  : {' '.join(cmd)}\n")

    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                             text=True, bufsize=1)

    last_time_str: dict[str, str | None] = {"val": None}
    time_re = re.compile(r"time=(\d+:\d+:\d+\.\d+)")

    def stderr_reader(stream, outdict):
        try:
            while True:
                chunk = stream.read(1024)
                if not chunk:
                    break
                sys.stderr.write(chunk)
                sys.stderr.flush()
                for m in time_re.finditer(chunk):
                    outdict["val"] = m.group(1)
        except Exception:
            pass

    reader = threading.Thread(target=stderr_reader, args=(proc.stderr, last_time_str), daemon=True)
    reader.start()

    start   = time.monotonic()
    sampled = False

    while True:
        elapsed = time.monotonic() - start
        if proc.poll() is not None:
            break

        if not sampled and elapsed >= SAMPLE_SECONDS:
            sampled = True
            try:
                if os.path.exists(temp_path) and duration:
                    bytes_written  = os.path.getsize(temp_path)
                    parsed         = last_time_str.get("val")
                    enc_seconds    = hms_to_seconds(parsed) if parsed else elapsed
                    kbps           = (bytes_written * 8) / enc_seconds / 1000.0 if enc_seconds > 0 else 0.0
                    est_mb         = (kbps * 1000.0 / 8.0) * duration / (1024 * 1024)

                    print(f"\n🔎  Sample ({int(enc_seconds)}s encoded): "
                          f"{bytes_written/(1024*1024):.2f} MB written, ~{kbps:.0f} kbit/s")
                    print(f"🔮  Estimated final size: {est_mb:.2f} MB "
                          f"({est_mb/size_mb*100:.0f}% of original)")

                    if est_mb >= accept_threshold_mb:
                        print("⚠️   Estimate won't meet threshold. Aborting early.")
                        try:
                            proc.send_signal(signal.SIGINT)
                            proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                            proc.wait()
                        except Exception:
                            proc.kill()
                        if os.path.exists(temp_path):
                            os.remove(temp_path)
                        reader.join(timeout=1)
                        return
                    else:
                        print("✅  Estimate looks good. Continuing to completion.")
            except Exception as e:
                print(f"⚠️   Sample failed ({e}). Continuing.")

        time.sleep(0.5)

    rc = proc.poll()
    if rc is None:
        rc = proc.wait()
    reader.join(timeout=1)

    if rc != 0:
        print(f"\n❌  ffmpeg exited with code {rc}.")
        if os.path.exists(temp_path):
            os.remove(temp_path)
        return

    if not os.path.exists(temp_path):
        print(f"\n❌  Output not found: {temp_path}")
        return

    final_mb = os.path.getsize(temp_path) / (1024 * 1024)
    ratio    = final_mb / size_mb if size_mb > 0 else 1.0
    print(f"\n✅  Encoded: {final_mb:.2f} MB  ({ratio*100:.0f}% of original)")

    if final_mb < accept_threshold_mb:
        if args.backup:
            backup_dir = os.path.join(base_dir, ".backup")
            os.makedirs(backup_dir, exist_ok=True)
            shutil.copy2(path, os.path.join(backup_dir, os.path.basename(path)))
        os.replace(temp_path, final_path)
        if os.path.abspath(path) != os.path.abspath(final_path):
            try:
                os.remove(path)
            except Exception:
                pass
        saved = size_mb - final_mb
        print(f"🗑️   Replaced original. Saved {saved:.2f} MB → {os.path.relpath(final_path, args.directory)}")
    else:
        os.remove(temp_path)
        print(f"⚠️   Not worth it. Original kept: {os.path.relpath(path, args.directory)}")


# === MAIN ===

def main():
    parser = argparse.ArgumentParser(
        description="Safely re-encode videos to HEVC (libx265).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("directory", help="Directory containing videos")
    parser.add_argument("-r", "--recursive", action="store_true",
                        help="Also process subdirectories")
    parser.add_argument("-y", "--yes", action="store_true",
                        help="Skip confirmation prompt")
    parser.add_argument("--backup", action="store_true",
                        help="Copy originals to .backup/ before replacing")
    parser.add_argument("--min-size", type=float, default=DEFAULT_MIN_SIZE_MB,
                        metavar="MB", help=f"Skip files smaller than this (default: {DEFAULT_MIN_SIZE_MB})")
    parser.add_argument("--ratio", type=float, default=DEFAULT_MIN_COMPRESS_RATIO,
                        metavar="RATIO",
                        help=f"Keep compressed file only if smaller than RATIO × original (default: {DEFAULT_MIN_COMPRESS_RATIO})")
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print(f"❌  Not a directory: {args.directory}")
        sys.exit(1)

    videos = collect_videos(args.directory, args.recursive)

    if not videos:
        print("No supported videos found.")
        sys.exit(0)

    # ── Preview table ────────────────────────────────────────────────────────
    will_compress, will_skip = [], []
    print("\nScanning files…")
    for p in videos:
        duration, size_mb = get_video_info(p)
        if size_mb < args.min_size:
            will_skip.append((p, size_mb, duration))
        else:
            will_compress.append((p, size_mb, duration))

    if will_skip:
        print(f"\n⏭️   Skipping {len(will_skip)} file(s) smaller than {args.min_size} MB:")
        for p, mb, dur in will_skip:
            dur_str = fmt_duration(dur) if dur else "?"
            print(f"   {mb:6.2f} MB  {dur_str:>10}  {os.path.relpath(p, args.directory)}")

    if not will_compress:
        print("\nNothing to compress.")
        sys.exit(0)

    total_mb  = sum(mb for _, mb, _ in will_compress)
    total_dur = sum(d for _, _, d in will_compress if d)

    print(f"\nFiles to compress ({len(will_compress)}):")
    print(f"  {'Size':>8}   {'Duration':>10}   Path")
    print(f"  {'----':>8}   {'--------':>10}   ----")
    for p, mb, dur in will_compress:
        dur_str = fmt_duration(dur) if dur else "unknown"
        print(f"  {mb:>7.2f}MB   {dur_str:>10}   {os.path.relpath(p, args.directory)}")
    print(f"\n  Total : {total_mb:.2f} MB  /  {fmt_duration(total_dur)}")
    print(f"  Keep new file only if < {args.ratio*100:.0f}% of original size")
    if args.backup:
        print("  Originals will be backed up to .backup/ before replacing.")
    if not args.recursive:
        print("  Subdirectories are NOT included (use -r to include them).")

    # ── Confirmation ─────────────────────────────────────────────────────────
    if not args.yes:
        try:
            answer = input(f"\nCompress {len(will_compress)} file(s)? [y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            sys.exit(0)
        if answer not in ("y", "yes"):
            print("Aborted.")
            sys.exit(0)

    # ── Compress (sequential — video encoding is CPU-bound) ──────────────────
    print()
    for p, _, _ in will_compress:
        compress_video(p, args)

    print(f"\n{'─'*60}")
    print("🎬  All done!")


if __name__ == "__main__":
    main()
