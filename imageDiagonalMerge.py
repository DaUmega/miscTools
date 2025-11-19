#!/usr/bin/env python3
import argparse
from PIL import Image, ImageDraw


def merge_images(img1_path, img2_path, output_path, direction):
    img1 = Image.open(img1_path).convert("RGBA")
    img2 = Image.open(img2_path).convert("RGBA")

    img2 = img2.resize(img1.size)
    w, h = img1.size

    # Create mask
    mask = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(mask)

    if direction == "tl-br":  
        draw.polygon([(0, 0), (w, h), (0, h)], fill=255)

    elif direction == "bl-tr":
        draw.polygon([(0, h), (w, 0), (0, 0)], fill=255)

    else:
        raise ValueError("Invalid direction")

    result = Image.composite(img1, img2, mask)
    result.save(output_path)
    print(f"Saved merged image → {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Merge two images using a diagonal triangular split."
    )
    parser.add_argument("img1", help="First image")
    parser.add_argument("img2", help="Second image")
    parser.add_argument(
        "--out", default="merged.png",
        help="Output filename (default: merged.png)"
    )
    parser.add_argument(
        "--direction",
        choices=["tl-br", "bl-tr"],
        default="tl-br",
        help="Diagonal direction topleft-bottomright(tl-br) or bl-tr. Default: tl-br"
    )

    args = parser.parse_args()
    merge_images(args.img1, args.img2, args.out, args.direction)


if __name__ == "__main__":
    main()
