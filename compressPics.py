#!/usr/bin/env python3
"""
Image Compressor Script
-----------------------
Compresses image files in a directory to fall within a defined size range.
Preserves original quality as much as possible.
Always previews files and asks for confirmation before making any changes.

Usage:
    python3 compressPics.py /path/to/directory [options]

Options:
    -r, --recursive         Also process subdirectories (opt-in)
    -y, --yes               Skip confirmation prompt
    --backup                Copy originals to .backup/ before overwriting
    --strip-exif            Remove EXIF metadata (saves space, zero pixel loss)
    --min-size MB           Skip files smaller than this (default: 1.0 MB)
    --max-size MB           Target ceiling after compression (default: 1.5 MB)

Examples:
    python3 compressPics.py ~/Photos
    python3 compressPics.py ~/Photos -r --backup
    python3 compressPics.py ~/Photos --strip-exif --min-size 0.5
"""

import os
import io
import sys
import shutil
import argparse
import subprocess
import importlib
import concurrent.futures

# === DEFAULTS ===
DEFAULT_MAX_SIZE_MB = 1.5
DEFAULT_MIN_SIZE_MB = 1.0
TARGET_RATIO        = 0.25     # aim for ~25% of original size as a starting target
SUPPORTED_FORMATS   = ('.jpg', '.jpeg', '.png', '.bmp', '.tiff')


# === DEPENDENCY CHECK ===
def ensure_dependencies():
    try:
        importlib.import_module("PIL")
        return
    except ImportError:
        pass
    if sys.platform == "win32":
        print("⚠️  Pillow not found. Install it with:  pip install Pillow")
        sys.exit(1)
    print("⚠️  Installing Pillow...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "Pillow"])

ensure_dependencies()
from PIL import Image  # noqa: E402 — imported after dependency check


# === IMAGE HELPERS ===

def get_size_mb(data: bytes) -> float:
    return len(data) / (1024 * 1024)


def _save_jpeg(img: Image.Image, quality: int, exif_bytes: bytes | None) -> bytes:
    buf = io.BytesIO()
    out = img
    if img.mode in ("RGBA", "LA", "P"):
        bg = Image.new("RGB", img.size, (255, 255, 255))
        bg.paste(img.convert("RGBA"), mask=img.convert("RGBA").split()[-1])
        out = bg
    elif img.mode != "RGB":
        out = img.convert("RGB")

    params = {"format": "JPEG", "optimize": True, "quality": quality}
    if exif_bytes:
        params["exif"] = exif_bytes
    out.save(buf, **params)
    return buf.getvalue()


def _save_png(img: Image.Image, compress_level: int = 9) -> bytes:
    """Lossless PNG save — no quality degradation, only zlib compression level."""
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True, compress_level=compress_level)
    return buf.getvalue()


def compress_image_data(
    img: Image.Image,
    img_format: str,
    target_mb: float,
    max_mb: float,
    exif_bytes: bytes | None,
    strip_exif: bool,
) -> bytes:
    """
    Return compressed image bytes, trying to stay under target_mb.
    Strategy:
      PNG  → lossless zlib max compression; quantize only if still > max_mb.
      JPEG → binary-search quality between 20–92; downscale only as last resort.
    """
    fmt = (img_format or "JPEG").upper()
    kept_exif = None if strip_exif else exif_bytes

    # ── PNG: lossless first ──────────────────────────────────────────────────
    if fmt == "PNG":
        data = _save_png(img, compress_level=9)
        if get_size_mb(data) <= max_mb:
            return data
        # Lossy fallback: convert to JPEG
        data = _save_jpeg(img, quality=85, exif_bytes=kept_exif)
        if get_size_mb(data) <= max_mb:
            return data
        fmt = "JPEG"   # fall through to JPEG binary search below

    # ── JPEG: binary search on quality ──────────────────────────────────────
    low, high = 20, 92
    best_under: bytes | None = None       # highest quality that fits
    smallest: bytes | None  = None        # absolute smallest produced
    smallest_mb = float("inf")

    while low <= high:
        q = (low + high) // 2
        data = _save_jpeg(img, quality=q, exif_bytes=kept_exif)
        mb = get_size_mb(data)

        if mb < smallest_mb:
            smallest_mb = mb
            smallest = data

        if mb <= target_mb:
            best_under = data
            low = q + 1           # try to keep higher quality
        else:
            high = q - 1

    if best_under is not None:
        return best_under

    # Quality-only result is still under the hard ceiling — accept it
    if smallest is not None and smallest_mb <= max_mb:
        return smallest

    # ── Last resort: limited downscale (max 3 steps, never below 73% of original) ──
    w, h = img.size
    scale = 0.90
    current = img
    for _ in range(3):
        nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
        resized = current.resize((nw, nh), Image.LANCZOS)
        q = max(20, (low + high) // 2) if low <= high else 55
        data = _save_jpeg(resized, quality=q, exif_bytes=kept_exif)
        if get_size_mb(data) <= max_mb:
            return data
        current = resized
        scale *= 0.90

    return smallest or _save_jpeg(img, quality=55, exif_bytes=kept_exif)


# === SINGLE FILE ===

def compress_file(path: str, args) -> tuple[str, float, float | None, str]:
    """
    Compress one file.  Returns (path, original_mb, final_mb_or_None, status).
    status: 'skipped' | 'compressed' | 'error:<msg>'
    """
    original_mb = os.path.getsize(path) / (1024 * 1024)

    if original_mb < args.min_size:
        return path, original_mb, None, "skipped"

    target_mb = min(args.max_size, original_mb * TARGET_RATIO)

    try:
        with Image.open(path) as img:
            try:
                exif = img.getexif()
                exif_bytes = exif.tobytes() if exif else None
            except Exception:
                exif_bytes = None

            img_format = img.format or "JPEG"
            img.load()   # load fully before closing the file handle
            result = compress_image_data(
                img, img_format, target_mb, args.max_size,
                exif_bytes, args.strip_exif
            )

        if args.backup:
            backup_dir = os.path.join(os.path.dirname(path), ".backup")
            os.makedirs(backup_dir, exist_ok=True)
            shutil.copy2(path, os.path.join(backup_dir, os.path.basename(path)))

        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(result)
        os.replace(tmp, path)

        final_mb = os.path.getsize(path) / (1024 * 1024)
        return path, original_mb, final_mb, "compressed"

    except Exception as e:
        return path, original_mb, None, f"error:{e}"


# === SCAN ===

def collect_images(directory: str, recursive: bool) -> list[str]:
    images = []
    if recursive:
        for root, dirs, files in os.walk(directory):
            # Skip backup folders we created
            dirs[:] = [d for d in dirs if d != ".backup"]
            for f in files:
                if f.lower().endswith(SUPPORTED_FORMATS):
                    images.append(os.path.join(root, f))
    else:
        for f in os.listdir(directory):
            p = os.path.join(directory, f)
            if os.path.isfile(p) and f.lower().endswith(SUPPORTED_FORMATS):
                images.append(p)
    return sorted(images)


# === MAIN ===

def main():
    parser = argparse.ArgumentParser(
        description="Safely compress images in a directory.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("directory", help="Directory containing images")
    parser.add_argument("-r", "--recursive", action="store_true",
                        help="Also process subdirectories")
    parser.add_argument("-y", "--yes", action="store_true",
                        help="Skip confirmation prompt")
    parser.add_argument("--backup", action="store_true",
                        help="Copy originals to .backup/ before overwriting")
    parser.add_argument("--strip-exif", action="store_true",
                        help="Remove EXIF metadata (saves space, no pixel loss)")
    parser.add_argument("--min-size", type=float, default=DEFAULT_MIN_SIZE_MB,
                        metavar="MB", help=f"Skip files smaller than this (default: {DEFAULT_MIN_SIZE_MB})")
    parser.add_argument("--max-size", type=float, default=DEFAULT_MAX_SIZE_MB,
                        metavar="MB", help=f"Target maximum size (default: {DEFAULT_MAX_SIZE_MB})")
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print(f"❌  Not a directory: {args.directory}")
        sys.exit(1)

    images = collect_images(args.directory, args.recursive)

    if not images:
        print("No supported images found.")
        sys.exit(0)

    # ── Preview table ────────────────────────────────────────────────────────
    will_compress, will_skip = [], []
    for p in images:
        mb = os.path.getsize(p) / (1024 * 1024)
        if mb < args.min_size:
            will_skip.append((p, mb))
        else:
            will_compress.append((p, mb))

    if will_skip:
        print(f"\n⏭️  Skipping {len(will_skip)} file(s) smaller than {args.min_size} MB:")
        for p, mb in will_skip:
            print(f"   {mb:6.2f} MB  {os.path.relpath(p, args.directory)}")

    if not will_compress:
        print("\nNothing to compress.")
        sys.exit(0)

    print(f"\nFiles to compress ({len(will_compress)}):")
    print(f"  {'Size':>8}   Path")
    print(f"  {'----':>8}   ----")
    total_mb = 0.0
    for p, mb in will_compress:
        print(f"  {mb:>7.2f}MB   {os.path.relpath(p, args.directory)}")
        total_mb += mb
    print(f"\n  Total: {total_mb:.2f} MB across {len(will_compress)} file(s)")
    if args.backup:
        print("  Originals will be backed up to .backup/ in each folder.")
    if args.strip_exif:
        print("  EXIF metadata will be stripped.")
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

    # ── Compress ─────────────────────────────────────────────────────────────
    print()
    paths_only = [p for p, _ in will_compress]

    with concurrent.futures.ProcessPoolExecutor() as executor:
        futures = {executor.submit(compress_file, p, args): p for p in paths_only}
        for future in concurrent.futures.as_completed(futures):
            path, orig_mb, final_mb, status = future.result()
            rel = os.path.relpath(path, args.directory)
            if status == "skipped":
                print(f"⏭️   skipped (too small)          {rel}")
            elif status == "compressed":
                saved = orig_mb - final_mb
                pct   = (saved / orig_mb) * 100 if orig_mb else 0
                print(f"✅  {orig_mb:.2f} MB → {final_mb:.2f} MB  (-{pct:.0f}%)  {rel}")
            else:
                msg = status.replace("error:", "", 1)
                print(f"❌  failed: {msg:<30} {rel}")

    print("\n🎉  Done!")


if __name__ == "__main__":
    main()
