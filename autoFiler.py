#!/usr/bin/env python3
"""
autoFiler.py - Organize photos or videos into year/month folders based on filename.
Example: destination/2025/202503 for files from March 2025.

Usage:
    python autoFiler.py --source "C:\My Photos\Phone" --dest "D:\Sorted" --mode photos
    python autoFiler.py /path/to/source /path/to/destination photos
"""
import sys
import re
import shutil
from pathlib import Path
import argparse

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

def reconstruct_from_tokens(tokens):
    """
    Heuristic to reconstruct source, dest and mode when Windows or other shells
    split paths with spaces. We locate the last token that equals 'photos' or 'videos'
    (case-insensitive) as the mode and then try to split the preceding tokens into
    source and destination. This is best-effort; using flags (--source/--dest) is recommended.
    """
    if not tokens:
        return None

    # find last occurrence of mode token
    mode_idx = None
    mode = None
    for i in range(len(tokens)-1, -1, -1):
        t = tokens[i].lower()
        if t in ("photos", "videos"):
            mode_idx = i
            mode = t
            break
    if mode_idx is None:
        return None

    before = tokens[:mode_idx]
    if len(before) == 0:
        return None

    # If exactly two tokens before mode, easy case
    if len(before) == 2:
        source = before[0]
        dest = before[1]
        return source, dest, mode

    # If more than 2 tokens, try heuristics:
    # - If tokens contain a drive letter (Windows style) or absolute path markers, try to split
    #   by finding a token that looks like the start of dest (has ":" for drive or starts with "/" or "~")
    # - Fallback: treat last token before mode as dest (maybe without spaces) and join the rest as source.
    for split_idx in range(len(before)-1, 0, -1):
        candidate_dest = " ".join(before[split_idx:])
        candidate_source = " ".join(before[:split_idx])
        # simple checks: both should form valid-ish paths (existence not required)
        # check for drive-letter or root path hints in dest or source
        if (candidate_dest.startswith(("/", "~")) or (len(candidate_dest) >= 2 and candidate_dest[1] == ":")):
            return candidate_source, candidate_dest, mode
        if (candidate_source.startswith(("/", "~")) or (len(candidate_source) >= 2 and candidate_source[1] == ":")):
            return candidate_source, candidate_dest, mode

    # fallback: last token before mode = dest, rest joined = source
    dest = before[-1]
    source = " ".join(before[:-1])
    return source, dest, mode

def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Organize photos or videos into year/month folders based on filename."
    )
    parser.add_argument("-s", "--source", help="Source directory (path).")
    parser.add_argument("-d", "--dest", "--destination", help="Destination directory (path).")
    parser.add_argument("-m", "--mode", choices=["photos", "videos"], help="Mode: photos or videos.")
    parser.add_argument("positional", nargs="*", help="Positional: source dest mode (alternative).")

    args = parser.parse_args(argv)

    # If flags provided, prefer them
    if args.source and args.dest and args.mode:
        return args.source, args.dest, args.mode

    # Try positional or mixed parsing
    tokens = args.positional.copy()

    # If any of the flags were provided together with positional tokens, include them
    if args.source:
        tokens.insert(0, args.source)
    if args.dest:
        # dest should come after source; put before mode if mode present in positional
        tokens.insert(1 if len(tokens) == 0 else len(tokens), args.dest)
    if args.mode:
        tokens.append(args.mode)

    # If we have exactly 3 tokens now, accept them as source, dest, mode
    if len(tokens) == 3 and tokens[2].lower() in ("photos", "videos"):
        return tokens[0], tokens[1], tokens[2].lower()

    # Otherwise attempt heuristic reconstruction
    rec = reconstruct_from_tokens(tokens)
    if rec:
        source, dest, mode = rec
        return source, dest, mode

    parser.error("Unable to parse arguments. Recommended usage:\n"
                 "  --source \"C:\\My Photos\" --dest \"D:\\Sorted\" --mode photos\n"
                 "or\n"
                 "  python autoFiler.py /path/to/source /path/to/dest photos")

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
    source_arg, dest_arg, mode_arg = parse_args(sys.argv[1:])

    source_dir = Path(source_arg).expanduser().resolve()
    dest_dir = Path(dest_arg).expanduser().resolve()
    mode = mode_arg.lower()

    if mode not in ("photos", "videos"):
        print("Mode must be 'photos' or 'videos'")
        sys.exit(1)

    organize_files(source_dir, dest_dir, mode)


if __name__ == "__main__":
    main()
