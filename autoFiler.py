#!/usr/bin/env python3
"""
autoFiler.py - Organize photos or videos into year/month folders based on filename.
Example: destination/2025/202503 for files from March 2025.

Usage:
    python autoFileFiles.py /path/to/source /path/to/destination --mode photos
    python autoFileFiles.py /path/to/source /path/to/destination --mode videos
"""

import sys
import re
import shutil
from pathlib import Path

# Supported extensions
PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".heic", ".webp"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".flv", ".webm"}

# Define separate regex patterns for maintainability
FILENAME_PATTERNS = [
    # Pattern 1: YYYY-MM-DD_HHMMSS or YYYY-MM-DD HH.MM.SS
    re.compile(r"^(\d{4})-(\d{2})-(\d{2})[_\s](\d{2})[._](\d{2})[._](\d{2})"),
    
    # Pattern 2: Screenshot_YYYY-MM-DD_HHMMSS
    re.compile(r"^Screenshot_(\d{4})-(\d{2})-(\d{2})[_\s](\d{2})[._](\d{2})[._](\d{2})"),
    
    # Pattern 3: IMG_YYYYMMDD_HHMMSS_xxx
    re.compile(r"^IMG_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_\d+")
]

def match_filename(file_name: str):
    """
    Try to match the filename against known patterns.
    Returns (year, month, day) if matched, else None.
    """
    for pattern in FILENAME_PATTERNS:
        match = pattern.match(file_name)
        if match:
            year, month, day = match.group(1), match.group(2), match.group(3)
            return year, month, day
    return None

def organize_files(source_dir: Path, dest_dir: Path, mode: str):
    if not source_dir.is_dir():
        print(f"Source directory does not exist: {source_dir}")
        sys.exit(1)
    
    dest_dir.mkdir(parents=True, exist_ok=True)

    extensions = PHOTO_EXTENSIONS if mode == "photos" else VIDEO_EXTENSIONS

    for file_path in source_dir.rglob("*"):
        if not file_path.is_file():
            continue
        if file_path.suffix.lower() not in extensions:
            continue
        
        result = match_filename(file_path.name)
        if result:
            year, month, day = result
            target_dir = dest_dir / year / f"{year}{month}"
            target_dir.mkdir(parents=True, exist_ok=True)

            dest_file = target_dir / file_path.name
            counter = 1
            while dest_file.exists():
                dest_file = target_dir / f"{file_path.stem}_{counter}{file_path.suffix}"
                counter += 1

            print(f"Moving {file_path} -> {dest_file}")
            shutil.move(str(file_path), str(dest_file))
        else:
            print(f"Skipping unrecognized filename format: {file_path.name}")


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <source_directory> <destination_directory> --mode [photos|videos]")
        sys.exit(1)
    
    source_dir = Path(sys.argv[1]).resolve()
    dest_dir = Path(sys.argv[2]).resolve()
    mode_arg = sys.argv[3].lower()

    if mode_arg not in ("photos", "videos"):
        print("Mode must be 'photos' or 'videos'")
        sys.exit(1)

    organize_files(source_dir, dest_dir, mode_arg)


if __name__ == "__main__":
    main()
