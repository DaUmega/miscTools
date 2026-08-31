#!/usr/bin/env python3
"""
find_duplicate_songs.py

Recursively scans a directory for audio files and groups filenames that
look like duplicates - even if they differ in case, use underscores vs
spaces, have "Artist - Title" vs "Title - Artist" order, or have extra
junk like "(Official Video)" or "[Lyrics]" tacked on.

Usage:
    python3 find_duplicate_songs.py /path/to/music
    python3 find_duplicate_songs.py /path/to/music --threshold 0.85
    python3 find_duplicate_songs.py /path/to/music --all-files
    python3 find_duplicate_songs.py /path/to/music --csv report.csv

Run with -h for all options.
"""

import argparse
import csv
import os
import re
import sys
from difflib import SequenceMatcher
from itertools import combinations

DEFAULT_AUDIO_EXTS = {
    ".mp3", ".flac", ".wav", ".m4a", ".aac", ".ogg", ".wma",
    ".opus", ".alac", ".aiff", ".ape",
}

# Words that commonly show up in downloaded song filenames but carry no
# information about the actual song identity. Stripped before comparing.
NOISE_WORDS = {
    "official", "video", "audio", "lyrics", "lyric", "hd", "hq",
    "remix", "remastered", "remaster", "explicit", "clean", "mv",
    "feat", "ft", "featuring", "prod", "by", "the", "a", "an",
    "extended", "version", "edit", "radio", "original", "mix",
    "live", "acoustic", "cover", "full", "album", "track",
}


def strip_extension(filename: str) -> str:
    return os.path.splitext(filename)[0]


def normalize(name: str) -> str:
    """Lowercase, unify separators, strip bracketed junk and punctuation noise."""
    name = name.lower()

    # underscores <-> spaces: just treat underscores as spaces
    name = name.replace("_", " ")

    # drop bracketed/parenthesized annotations, e.g. (Official Video), [HD]
    name = re.sub(r"\(.*?\)", " ", name)
    name = re.sub(r"\[.*?\]", " ", name)

    # unify dash variants
    name = re.sub(r"[–—―]", "-", name)

    # remove track numbers at the start, e.g. "01 - Song" or "01. Song"
    name = re.sub(r"^\s*\d{1,3}[\.\-\)]?\s+", "", name)

    # remove any character that isn't a letter, number, space, dash, or apostrophe
    name = re.sub(r"[^a-z0-9\-\s']", " ", name)

    name = re.sub(r"\s+", " ", name).strip()
    return name


def token_signature(normalized_name: str) -> str:
    """
    Build an order-independent signature so "Artist - Title" and
    "Title - Artist" (or any word order) compare equal/close.
    Noise words are dropped.
    """
    parts = re.split(r"[-]", normalized_name)
    words = []
    for part in parts:
        words.extend(part.strip().split())

    words = [w for w in words if w and w not in NOISE_WORDS]
    words.sort()
    return " ".join(words)


def collect_files(root: str, extensions):
    results = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fname in filenames:
            ext = os.path.splitext(fname)[1].lower()
            if extensions is None or ext in extensions:
                results.append(os.path.join(dirpath, fname))
    return results


def similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, a, b).ratio()


def build_records(paths):
    records = []
    for path in paths:
        base = strip_extension(os.path.basename(path))
        norm = normalize(base)
        sig = token_signature(norm)
        records.append({
            "path": path,
            "normalized": norm,
            "signature": sig,
        })
    return records


def find_groups(records, threshold):
    """
    Compare every pair and union files whose signatures (or normalized
    strings) are similar enough. Returns a list of groups, each a list
    of record dicts, plus the similarity score that triggered the match.
    """
    n = len(records)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x, y):
        rx, ry = find(x), find(y)
        if rx != ry:
            parent[ry] = rx

    pair_scores = {}

    for i, j in combinations(range(n), 2):
        sig_a, sig_b = records[i]["signature"], records[j]["signature"]
        norm_a, norm_b = records[i]["normalized"], records[j]["normalized"]

        # exact signature match (handles reordering + case + underscores) = instant match
        if sig_a and sig_a == sig_b:
            score = 1.0
        else:
            score = max(similarity(sig_a, sig_b), similarity(norm_a, norm_b))

        if score >= threshold:
            union(i, j)
            pair_scores[(i, j)] = score

    groups_map = {}
    for idx in range(n):
        root = find(idx)
        groups_map.setdefault(root, []).append(idx)

    groups = []
    for indices in groups_map.values():
        if len(indices) > 1:
            # best score within this group, for display
            best_score = 0.0
            for i, j in combinations(indices, 2):
                s = pair_scores.get((i, j)) or pair_scores.get((j, i))
                if s:
                    best_score = max(best_score, s)
            groups.append({
                "records": [records[i] for i in indices],
                "score": best_score,
            })

    groups.sort(key=lambda g: g["score"], reverse=True)
    return groups


def main():
    parser = argparse.ArgumentParser(
        description="Find likely duplicate song files by filename, across subdirectories."
    )
    parser.add_argument("directory", help="Root directory to scan")
    parser.add_argument(
        "--threshold", type=float, default=0.82,
        help="Similarity threshold 0-1 (default 0.82). Lower = more matches, more false positives."
    )
    parser.add_argument(
        "--all-files", action="store_true",
        help="Include all files, not just common audio extensions."
    )
    parser.add_argument(
        "--csv", metavar="PATH",
        help="Also write results to a CSV file at this path."
    )
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print(f"Error: '{args.directory}' is not a directory.", file=sys.stderr)
        sys.exit(1)

    extensions = None if args.all_files else DEFAULT_AUDIO_EXTS

    print(f"Scanning '{args.directory}' ...")
    paths = collect_files(args.directory, extensions)
    print(f"Found {len(paths)} files. Comparing filenames...")

    if len(paths) > 6000:
        print(
            f"Warning: {len(paths)} files means ~{len(paths)*(len(paths)-1)//2:,} "
            "comparisons - this may take a while.", file=sys.stderr
        )

    records = build_records(paths)
    groups = find_groups(records, args.threshold)

    if not groups:
        print("No likely duplicates found.")
        return

    print(f"\nFound {len(groups)} group(s) of likely duplicate songs:\n")

    csv_rows = []
    for gi, group in enumerate(groups, 1):
        print(f"--- Group {gi} (similarity ~{group['score']:.2f}) ---")
        for rec in group["records"]:
            print(f"  {rec['path']}")
            csv_rows.append({
                "group": gi,
                "similarity": f"{group['score']:.2f}",
                "path": rec["path"],
            })
        print()

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["group", "similarity", "path"])
            writer.writeheader()
            writer.writerows(csv_rows)
        print(f"CSV report written to: {args.csv}")


if __name__ == "__main__":
    main()
