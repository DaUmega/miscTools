#!/usr/bin/env python3
"""
Image Compressor Script
-----------------------
Recursively compresses image files in a given directory to ensure they fall within a defined size range.
Tries to preserve original quality as much as possible. Removes originals after compression.

Features:
- Adaptive compression using binary search on quality
- Optional image downscaling when compression alone isn't enough
- Parallel processing for faster batch operations
- Auto-installs missing dependencies (Pillow)

Usage:
    python3 compress_images.py /path/to/directory
"""

import os
import io
import sys
import subprocess
import importlib
import concurrent.futures

# === SETTINGS ===
MAX_SIZE_MB = 1.5         # Target maximum file size(MB) after compression
MIN_SIZE_MB = 1.0         # Skip images smaller than this threshold
TARGET_RATIO = 0.25       # Try to compress images to ~25% of original size
# SUPPORTED_FORMATS unchanged...
SUPPORTED_FORMATS = (
    '.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tiff'
)
# =================


# === DEPENDENCY CHECK ===
DEPENDENCIES = [
    ("Pillow", "PIL"),
]

def ensure_dependencies():
    """Ensure required packages are importable; check distribution metadata before installing.
    Avoids false 'missing' reports on Windows when the distribution name differs from the import name.
    """
    import platform
    try:
        import importlib.metadata as importlib_metadata  # Python 3.8+
    except ImportError:
        try:
            import importlib_metadata  # type: ignore  # backport
        except Exception:
            importlib_metadata = None

    for dist_name, module_name in DEPENDENCIES:
        try:
            importlib.import_module(module_name)
            continue
        except Exception:
            # If we can inspect installed distributions, check whether the package is installed under a different name
            has_dist = False
            if importlib_metadata:
                try:
                    importlib_metadata.version(dist_name)
                    has_dist = True
                except Exception:
                    has_dist = False

            if has_dist:
                # Distribution is installed but import failed (name mismatch or broken env) — assume ok and skip install
                continue

            # Not installed: avoid auto-install on Windows to prevent unexpected behavior
            if platform.system() == "Windows":
                print(f"⚠️ Dependency not found: {dist_name}. Skipping auto-install on Windows.")
                continue

            print(f"⚠️ Missing dependency: {dist_name}. Installing...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", dist_name])

ensure_dependencies()

from PIL import Image, ImageOps  # imported after ensuring Pillow is available


# === HELPER FUNCTIONS ===
def get_size_mb(buf: bytes) -> float:
    """Return the size of a byte buffer in megabytes."""
    return len(buf) / (1024 * 1024)


def _save_image_bytes(img: Image.Image, img_format: str, q: int = None, exif_bytes: bytes = None) -> bytes:
    """Save image to bytes with appropriate parameters (handles JPEG mode conversions and EXIF)."""
    temp = io.BytesIO()
    fmt = img_format.upper()
    save_params = {}

    if fmt in ('JPEG', 'JPG'):
        # Ensure mode is compatible with JPEG
        if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
            # Remove alpha by compositing onto white background
            background = Image.new("RGB", img.size, (255, 255, 255))
            background.paste(img.convert("RGBA"), mask=img.convert("RGBA").split()[-1])
            img_to_save = background
        else:
            img_to_save = img.convert("RGB")
        save_params.update({"format": "JPEG", "optimize": True})
        if q is not None:
            save_params["quality"] = q
        if exif_bytes:
            save_params["exif"] = exif_bytes

    elif fmt == 'PNG':
        img_to_save = img
        save_params.update({"format": "PNG", "optimize": True})
        if q is not None:
            # Map quality-ish value to PNG compress_level (0-9)
            save_params["compress_level"] = max(0, min(9, int((100 - q) / 10)))
    else:
        img_to_save = img
        save_params.update({"format": fmt})

    img_to_save.save(temp, **save_params)
    return temp.getvalue()


def compress_to_target_size(img: Image.Image, img_format: str, target_mb: float, exif_bytes: bytes = None) -> bytes:
    """
    Compress image adaptively to reach a target file size (MB).
    """
    # widen bounds so search can hit lower qualities when needed
    low, high = 30, 95  # quality search bounds
    best_bytes = None
    best_quality = 85   # reasonable default if search fails
    width, height = img.size

    # Binary search: try to find the HIGHEST quality that still fits under target_mb
    while low <= high:
        q = (low + high) // 2
        data = _save_image_bytes(img, img_format, q=q, exif_bytes=exif_bytes)
        size_mb = get_size_mb(data)

        if size_mb <= target_mb:
            # Keep best (highest) quality found so far
            best_bytes = data
            best_quality = q
            low = q + 1  # try higher quality
        else:
            high = q - 1  # too large — reduce quality

    # If binary search couldn't produce a small-enough file, progressively scale down
    if best_bytes is None:
        scale = 0.95  # gentler initial scaling to preserve quality
        current_img = img
        while True:
            new_w = max(1, int(width * scale))
            new_h = max(1, int(height * scale))
            if new_w < 2 or new_h < 2:
                # fallback: force save at best_quality even if huge
                best_bytes = _save_image_bytes(current_img, img_format, q=best_quality, exif_bytes=exif_bytes)
                break

            resized = current_img.resize((new_w, new_h), Image.LANCZOS)
            data = _save_image_bytes(resized, img_format, q=best_quality, exif_bytes=exif_bytes)
            size_mb = get_size_mb(data)
            if size_mb <= target_mb or new_w < 200 or new_h < 200:
                best_bytes = data
                break
            # continue scaling down gradually
            current_img = resized
            scale *= 0.95

    return best_bytes


def compress_image(path: str):
    """Compress a single image file if it's larger than MIN_SIZE_MB."""
    try:
        original_size = os.path.getsize(path) / (1024 * 1024)
        if original_size < MIN_SIZE_MB:
            print(f"⏭️  Skipping small file ({original_size:.2f} MB): {path}")
            return

        # compute a target size based on a fraction of the original, but never exceed MAX_SIZE_MB
        target_mb = min(MAX_SIZE_MB, original_size * TARGET_RATIO)

        print(f"🔧 Compressing ({original_size:.2f} MB) -> target {target_mb:.2f} MB: {path}")
        with Image.open(path) as img:
            # Preserve and normalize EXIF orientation: apply transform then clear orientation tag
            try:
                exif = img.getexif()
                if exif:
                    # Set orientation tag to '1' (normal) so saved image is not auto-rotated again by viewers
                    ORIENTATION_TAG = 274
                    if ORIENTATION_TAG in exif:
                        exif[ORIENTATION_TAG] = 1
                    exif_bytes = exif.tobytes()
                else:
                    exif_bytes = None
            except Exception:
                exif_bytes = None

            # Apply EXIF-based transpose to get correct visual orientation for processing
            img = ImageOps.exif_transpose(img)

            img_format = img.format or 'JPEG'
            result = compress_to_target_size(img, img_format, target_mb, exif_bytes=exif_bytes)

            # Write temporary compressed file then replace original
            temp_path = path + ".tmp"
            with open(temp_path, "wb") as f:
                f.write(result)
            os.replace(temp_path, path)

            final_size = os.path.getsize(path) / (1024 * 1024)
            print(f"✅ Compressed to {final_size:.2f} MB ({path})")

    except Exception as e:
        print(f"❌ Failed to process {path}: {e}")


def compress_directory(directory: str):
    """Recursively find and compress all supported image files in a directory."""
    all_images = []
    for root, _, files in os.walk(directory):
        for fname in files:
            if fname.lower().endswith(SUPPORTED_FORMATS):
                all_images.append(os.path.join(root, fname))

    if not all_images:
        print("No supported images found.")
        return

    print(f"Found {len(all_images)} images. Starting compression...\n")

    # Parallel compression for better performance
    with concurrent.futures.ProcessPoolExecutor() as executor:
        list(executor.map(compress_image, all_images))


# === MAIN ENTRY POINT ===
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} /path/to/directory")
        sys.exit(1)

    target_dir = sys.argv[1]
    if not os.path.isdir(target_dir):
        print(f"❌ Invalid directory: {target_dir}")
        sys.exit(1)

    compress_directory(target_dir)
    print("\n🎉 All done!")
