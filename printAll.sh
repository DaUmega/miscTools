#!/usr/bin/env bash
#
# printAll.sh — recursively find printable documents under a directory,
# show a confirmation list (with page counts where possible), then send
# everything to the default CUPS printer.
#
# Usage:
#   ./printAll.sh <directory> [options]
#
# Options:
#   -p, --paper <letter|a4>   Paper size (default: letter)
#   -n, --no-shrink           Don't shrink/fit images to one page (default: fit)
#   -y, --yes                 Skip confirmation prompt
#       --dry-run             List what would be printed, then exit
#   -h, --help                Show this help
#
# Examples:
#   ./printAll.sh ~/Documents/taxes
#   ./printAll.sh ./scans -p a4
#   ./printAll.sh /shared/reports --no-shrink -y
#   ./printAll.sh . --dry-run
#
# Requires: lp/lpr (cups), find. Optional: pdfinfo (for PDF page counts).

set -euo pipefail

PAPER="letter"
SHRINK_IMAGES=true
ASSUME_YES=false
DRY_RUN=false
DIR=""

# --- extensions we consider printable ---
EXTENSIONS=(txt pdf doc docx odt rtf xls xlsx ods csv png jpg jpeg gif bmp tiff tif)

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--paper) PAPER="$2"; shift 2 ;;
    -n|--no-shrink) SHRINK_IMAGES=false; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) [[ -z "$DIR" ]] && DIR="$1" || { echo "Unexpected argument: $1" >&2; exit 1; }; shift ;;
  esac
done

[[ -z "$DIR" ]] && { echo "Error: directory argument required." >&2; usage; exit 1; }
[[ -d "$DIR" ]] || { echo "Error: '$DIR' is not a directory." >&2; exit 1; }
[[ "$PAPER" == "letter" || "$PAPER" == "a4" ]] || { echo "Error: --paper must be 'letter' or 'a4'." >&2; exit 1; }

# --- build find expression from EXTENSIONS ---
find_args=()
for ext in "${EXTENSIONS[@]}"; do
  find_args+=(-o -iname "*.${ext}")
done
mapfile -t FILES < <(find "$DIR" -type f \( "${find_args[@]:1}" \) | sort)

[[ ${#FILES[@]} -eq 0 ]] && { echo "No printable files found under '$DIR'."; exit 0; }

# --- best-effort page count ---
# PDFs: pdfinfo if available. Images: always 1 page. Everything else: unknown.
page_count() {
  local f="$1" ext="${1##*.}"
  ext="${ext,,}"
  case "$ext" in
    pdf)
      if command -v pdfinfo >/dev/null 2>&1; then
        pdfinfo "$f" 2>/dev/null | awk -F': *' '/^Pages/{print $2}'
      else
        echo "?"
      fi
      ;;
    png|jpg|jpeg|gif|bmp|tiff|tif) echo 1 ;;
    *) echo "?" ;;
  esac
}

echo "Found ${#FILES[@]} document(s) under '$DIR':"
echo
total=0
unknown=false
for f in "${FILES[@]}"; do
  pages=$(page_count "$f")
  if [[ "$pages" == "?" ]]; then
    unknown=true
    printf '  %-70s %s\n' "$f" "(pages unknown)"
  else
    total=$((total + pages))
    printf '  %-70s %s page(s)\n' "$f" "$pages"
  fi
done
echo
if $unknown; then
  echo "Total: at least $total known page(s), plus files with unknown page count."
else
  echo "Total: $total page(s)."
fi
echo "Paper: $PAPER | Shrink images to fit: $SHRINK_IMAGES"
echo

$DRY_RUN && { echo "(dry run — nothing sent to printer)"; exit 0; }

if ! $ASSUME_YES; then
  read -r -p "Send all ${#FILES[@]} file(s) to the printer? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# --- submit to printer queue ---
for f in "${FILES[@]}"; do
  lp_opts=(-o "media=$PAPER")
  ext="${f##*.}"; ext="${ext,,}"
  case "$ext" in
    png|jpg|jpeg|gif|bmp|tiff|tif)
      $SHRINK_IMAGES && lp_opts+=(-o fit-to-page)
      ;;
  esac
  echo "Queuing: $f"
  lp "${lp_opts[@]}" "$f"
done

echo "All files submitted to the print queue."
