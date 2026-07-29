#!/usr/bin/env bash
#
# print_all.sh — Print every .txt, .pdf, and image file in a directory
# using CUPS (lp), forcing US Letter paper size.
#
# Usage:
#   ./print_all.sh                      # print everything in current dir
#   ./print_all.sh -d /path/to/folder   # print everything in another dir
#   ./print_all.sh -p PrinterName       # use a specific printer
#   ./print_all.sh -n                   # dry run — show what would print
#   ./print_all.sh -y                   # skip confirmation prompt
#
# Requires: CUPS printing system (lp / lpstat), already set up in
# Linux Mint's "Printers" settings (System Settings > Printers).

set -euo pipefail

DIR="."
PRINTER=""
DRY_RUN=false
ASSUME_YES=false

usage() {
    echo "Usage: $0 [-d directory] [-p printer_name] [-n] [-y]"
    echo "  -d   Directory to print from (default: current directory)"
    echo "  -p   CUPS printer name (default: system default printer)"
    echo "  -n   Dry run: list files that would be printed, without printing"
    echo "  -y   Don't ask for confirmation before printing"
    exit 1
}

while getopts ":d:p:nyh" opt; do
    case "$opt" in
        d) DIR="$OPTARG" ;;
        p) PRINTER="$OPTARG" ;;
        n) DRY_RUN=true ;;
        y) ASSUME_YES=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# --- Sanity checks -----------------------------------------------------

if ! command -v lp >/dev/null 2>&1; then
    echo "Error: 'lp' command not found. Install CUPS client tools with:" >&2
    echo "  sudo apt install cups-client" >&2
    exit 1
fi

if [[ ! -d "$DIR" ]]; then
    echo "Error: directory '$DIR' does not exist." >&2
    exit 1
fi

if [[ -n "$PRINTER" ]]; then
    if ! lpstat -p "$PRINTER" >/dev/null 2>&1; then
        echo "Error: printer '$PRINTER' not found. Available printers:" >&2
        lpstat -p 2>/dev/null || echo "  (none configured)"
        exit 1
    fi
else
    if ! lpstat -d 2>/dev/null | grep -q 'system default destination'; then
        echo "Warning: no default printer set. Configure one in Printers" >&2
        echo "settings, or pass one explicitly with -p PrinterName." >&2
    fi
fi

# --- Collect matching files ---------------------------------------------
# Supported extensions: text, pdf, common image formats

shopt -s nullglob nocaseglob
FILES=(
    "$DIR"/*.txt
    "$DIR"/*.pdf
    "$DIR"/*.jpg
    "$DIR"/*.jpeg
    "$DIR"/*.png
    "$DIR"/*.gif
    "$DIR"/*.bmp
    "$DIR"/*.tif
    "$DIR"/*.tiff
    "$DIR"/*.webp
)
shopt -u nullglob nocaseglob

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No matching txt/pdf/image files found in '$DIR'."
    exit 0
fi

# Sort for predictable print order
IFS=$'\n' FILES=($(sort <<<"${FILES[*]}")); unset IFS

echo "Files to print (${#FILES[@]}):"
for f in "${FILES[@]}"; do
    echo "  - $f"
done

if $DRY_RUN; then
    echo "Dry run — nothing was sent to the printer."
    exit 0
fi

if ! $ASSUME_YES; then
    read -r -p "Send these ${#FILES[@]} file(s) to the printer? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# --- Print ---------------------------------------------------------------
# -o media=Letter         force US Letter paper size
# -o fit-to-page          scale content to fit the page (helps images/PDFs)
# -d PRINTER              only added if a specific printer was requested

LP_OPTS=(-o media=Letter -o fit-to-page)
[[ -n "$PRINTER" ]] && LP_OPTS+=(-d "$PRINTER")

FAILED=()
for f in "${FILES[@]}"; do
    echo "Printing: $f"
    if lp "${LP_OPTS[@]}" "$f" >/dev/null; then
        echo "  -> queued OK"
    else
        echo "  -> FAILED" >&2
        FAILED+=("$f")
    fi
done

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "All ${#FILES[@]} file(s) queued successfully."
else
    echo "${#FAILED[@]} file(s) failed to queue:"
    for f in "${FAILED[@]}"; do
        echo "  - $f"
    done
    exit 1
fi