#!/usr/bin/env bash
#
# printAll.sh: recursively find printable documents under a directory,
# show a confirmation list (with page counts where possible), then send
# everything to the default CUPS printer.
#
# Images are fit to the printable WIDTH only, not to one page: a long,
# narrow screenshot is scaled to fill the page width and split across
# as many pages as its height needs, so text stays readable instead of
# shrinking to a tiny strip on one page.
#
# Usage:
#   ./printAll.sh <directory> [options]
#
# Options:
#   -p, --paper <letter|a4>   Paper size (default: letter)
#   -w, --fit-width           Fit images to width, paginated (default)
#   -f, --fit-to-page         Fit each image to a single page
#   -n, --no-shrink           Send images as-is, no scaling
#   -y, --yes                 Skip confirmation prompt
#       --dry-run             List what would be printed, then exit
#   -h, --help                Show this help
#
# Examples:
#   ./printAll.sh ~/Documents/taxes
#   ./printAll.sh ./scans -p a4
#   ./printAll.sh ./scans --fit-to-page -y
#   ./printAll.sh /shared/reports --no-shrink -y
#   ./printAll.sh . --dry-run
#
# Requires: lp/lpr (cups), find, python3 + Pillow (for fit-to-width
# images). Without Pillow, fit-to-width images fall back to CUPS
# fit-to-page with a warning. Optional: pdfinfo (for PDF page counts).

set -euo pipefail

PAPER="letter"
IMAGE_MODE="width" # width | page | none; last image-mode flag wins
ASSUME_YES=false
DRY_RUN=false
DIR=""
TMPDIR=""

# --- extensions we consider printable ---
EXTENSIONS=(txt pdf doc docx odt rtf xls xlsx ods csv png jpg jpeg gif bmp tiff tif)

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--paper) PAPER="$2"; shift 2 ;;
    -w|--fit-width) IMAGE_MODE="width"; shift ;;
    -f|--fit-to-page|--fit-page) IMAGE_MODE="page"; shift ;;
    -n|--no-shrink|--no-fit-width|--no-fit|--no-scale) IMAGE_MODE="none"; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) [[ -z "$DIR" ]] && DIR="$1" || { echo "Unexpected argument: $1" >&2; exit 1; }; shift ;;
  esac
done

[[ -z "$DIR" ]] && { echo "Error: directory argument required." >&2; usage; exit 1; }
[[ -d "$DIR" ]] || { echo "Error: '$DIR' is not a directory." >&2; exit 1; }
[[ "$PAPER" == "letter" || "$PAPER" == "a4" ]] || { echo "Error: --paper must be 'letter' or 'a4'." >&2; exit 1; }

# Paper size in inches, 0.5in margins all round.
if [[ "$PAPER" == "letter" ]]; then
  PAPER_W=8.5; PAPER_H=11.0
else
  PAPER_W=8.2677; PAPER_H=11.6929 # A4: 210 x 297 mm
fi
PRINT_W=$(python3 -c "print($PAPER_W - 1.0)")
PRINT_H=$(python3 -c "print($PAPER_H - 1.0)")

is_image() {
  case "${1##*.}" in
    [Pp][Nn][Gg]|[Jj][Pp][Gg]|[Jj][Pp][Ee][Gg]|[Gg][Ii][Ff]|[Bb][Mm][Pp]|[Tt][Ii][Ff][Ff]|[Tt][Ii][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

# Convert an image to a paper-sized, multi-page PDF: scaled to the
# printable width, sliced vertically into printable-height chunks, each
# chunk padded with white margins to a full paper page. Prints 1:1 with
# plain `lp -o media=...`, no fit-to-page scaling. Prints the page
# count on stdout; exits non-zero if Pillow is missing or conversion
# fails, so the caller can fall back to fit-to-page.
image_to_fitwidth_pdf() {
  python3 - "$1" "$2" "$PAPER_W" "$PAPER_H" "$PRINT_W" "$PRINT_H" <<'PY' 2>/dev/null
import math, sys
from PIL import Image, ImageOps
src, dst, pw_paper, ph_paper, pw, ph = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:7])
im = Image.open(src)
im = ImageOps.exif_transpose(im)
if "A" in im.getbands():  # composite transparency onto white
    bg = Image.new("RGB", im.size, "white")
    bg.paste(im, mask=im.split()[-1])
    im = bg
elif im.mode != "RGB":
    im = im.convert("RGB")
w, h = im.size
dpi = w / pw
if dpi > 300:  # cap raster size; 300 dpi is plenty for print
    w, h = int(round(pw * 300)), int(round(h * pw * 300 / im.size[0]))
    im = im.resize((w, h), Image.LANCZOS)
    dpi = 300.0
chunk_h = max(1, int(round(w * ph / pw)))
canvas_w, canvas_h = int(round(pw_paper * dpi)), int(round(ph_paper * dpi))
margin = int(round(0.5 * dpi))
pages = []
for y in range(0, h, chunk_h):
    page = Image.new("RGB", (canvas_w, canvas_h), "white")
    page.paste(im.crop((0, y, w, min(h, y + chunk_h))), (margin, margin))
    pages.append(page)
pages[0].save(dst, "PDF", save_all=True, append_images=pages[1:], resolution=dpi)
print(len(pages))
PY
}

# --- build find expression from EXTENSIONS ---
find_args=()
for ext in "${EXTENSIONS[@]}"; do
  find_args+=(-o -iname "*.${ext}")
done
mapfile -t FILES < <(find "$DIR" -type f \( "${find_args[@]:1}" \) | sort)

[[ ${#FILES[@]} -eq 0 ]] && { echo "No printable files found under '$DIR'."; exit 0; }

# --- best-effort page count ---
# PDFs: pdfinfo if available. Fit-to-width images: ceil(height / chunk
# height), same slicing as the converter. Fit-to-page and no-shrink
# images: 1, as before. Everything else: unknown.
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
    png|jpg|jpeg|gif|bmp|tiff|tif)
      if [[ "$IMAGE_MODE" == "width" ]] && python3 -c "import PIL" 2>/dev/null; then
        python3 - "$f" "$PRINT_W" "$PRINT_H" <<'PY' 2>/dev/null || echo "?"
import math, sys
from PIL import Image, ImageOps
im = ImageOps.exif_transpose(Image.open(sys.argv[1]))
w, h = im.size
pw, ph = map(float, sys.argv[2:4])
print(math.ceil(h / max(1, round(w * ph / pw))))
PY
      else
        echo 1
      fi
      ;;
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
case "$IMAGE_MODE" in
  width) echo "Paper: $PAPER | Images: fit to width, paginated vertically" ;;
  page)  echo "Paper: $PAPER | Images: fit to one page" ;;
  none)  echo "Paper: $PAPER | Images: sent as-is (no scaling)" ;;
esac
echo

$DRY_RUN && { echo "(dry run: nothing sent to printer)"; exit 0; }

if ! $ASSUME_YES; then
  read -r -p "Send all ${#FILES[@]} file(s) to the printer? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# --- submit to printer queue ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
warned_fallback=false
for f in "${FILES[@]}"; do
  lp_opts=(-o "media=$PAPER")
  if is_image "$f" && [[ "$IMAGE_MODE" == "width" ]]; then
    tmp_pdf=$(mktemp "$TMPDIR/img-XXXXXX.pdf")
    if pages=$(image_to_fitwidth_pdf "$f" "$tmp_pdf"); then
      echo "Queuing: $f ($pages page(s), fit to width)"
      lp "${lp_opts[@]}" "$tmp_pdf"
      continue
    fi
    # Fall back to fit-to-page for this file, don't lose the batch.
    if ! $warned_fallback; then
      echo "Warning: fit-to-width conversion unavailable (needs python3 + Pillow); falling back to fit-to-page for images." >&2
      warned_fallback=true
    fi
    lp_opts+=(-o fit-to-page)
  elif is_image "$f" && [[ "$IMAGE_MODE" == "page" ]]; then
    lp_opts+=(-o fit-to-page)
  fi
  echo "Queuing: $f"
  lp "${lp_opts[@]}" "$f"
done

echo "All files submitted to the print queue."
