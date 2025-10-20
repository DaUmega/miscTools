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
SUPPORTED_FORMATS = (     # File extensions eligible for compression
    '.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tiff'
)
# =================


# === DEPENDENCY CHECK ===
REQUIRED_PACKAGES = ["Pillow"]

def ensure_dependencies():
    """Automatically installs any missing dependencies."""
    for pkg in REQUIRED_PACKAGES:
        try:
            importlib.import_module(pkg)
        except ImportError:
            print(f"⚠️ Missing dependency: {pkg}. Installing...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", pkg])

ensure_dependencies()

from PIL import Image  # imported after ensuring Pillow is available


# === HELPER FUNCTIONS ===
def get_size_mb(buf: bytes) -> float:
    """Return the size of a byte buffer in megabytes."""
    return len(buf) / (1024 * 1024)


def compress_to_target_size(img: Image.Image, img_format: str, target_mb: float) -> bytes:
    """
    Compress image adaptively to reach a target file size (MB).
    - Uses binary search on compression quality (JPEG/PNG).
    - Falls back to gradual image downscaling if compression isn’t enough.
    """
    low, high = 10, 95  # quality search bounds
    best_bytes = None
    best_quality = high
    width, height = img.size

    while low <= high:
        q = (low + high) // 2
        temp_bytes = io.BytesIO()

        # Compression settings depend on format
        if img_format.upper() in ('JPEG', 'JPG'):
            save_params = {"format": "JPEG", "optimize": True, "quality": q}
        elif img_format.upper() == 'PNG':
            save_params = {"format": "PNG", "optimize": True, "compress_level": int((100 - q) / 10)}
        else:
            save_params = {"format": img_format}

        # Save compressed version to memory buffer
        resized = img.copy()
        resized.save(temp_bytes, **save_params)
        size_mb = get_size_mb(temp_bytes.getvalue())

        if size_mb <= target_mb:
            # Keep best smaller version so far
            best_bytes = temp_bytes.getvalue()
            best_quality = q
            high = q - 1  # try slightly higher quality (less compression)
        else:
            low = q + 1  # too large — increase compression

    # If still too large, progressively scale down
    if best_bytes is None:
        scale = 0.9  # start scaling down by 10%
        while True:
            new_w, new_h = int(width * scale), int(height * scale)
            resized = img.resize((new_w, new_h), Image.LANCZOS)
            temp_bytes = io.BytesIO()
            resized.save(temp_bytes, format=img_format, optimize=True, quality=best_quality)
            size_mb = get_size_mb(temp_bytes.getvalue())
            if size_mb <= target_mb or new_w < 200 or new_h < 200:
                best_bytes = temp_bytes.getvalue()
                break
            scale *= 0.9  # reduce size further if still too large

    return best_bytes


def compress_image(path: str):
    """Compress a single image file if it's larger than MIN_SIZE_MB."""
    try:
        original_size = os.path.getsize(path) / (1024 * 1024)
        if original_size < MIN_SIZE_MB:
            print(f"⏭️  Skipping small file ({original_size:.2f} MB): {path}")
            return

        print(f"🔧 Compressing ({original_size:.2f} MB): {path}")
        with Image.open(path) as img:
            img_format = img.format or 'JPEG'
            result = compress_to_target_size(img, img_format, MAX_SIZE_MB)

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
