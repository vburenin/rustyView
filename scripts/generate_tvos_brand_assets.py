#!/usr/bin/env python3
"""Derive the layered tvOS app icon and Top Shelf images from the iOS icon.

The iOS icon is an orange glyph on a flat navy field. tvOS needs parallax
layers, so the navy field becomes the back layer and the glyph, keyed out of
that field, becomes the front layer. Run from the repository root:

    python3 -I scripts/generate_tvos_brand_assets.py \
        rustyView/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
        rustyViewTV/Assets.xcassets

Requires Pillow and NumPy. Output is deterministic for a given source icon.
"""

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

INFO = {"author": "xcode", "version": 1}
BRAND = "App Icon & Top Shelf Image.brandassets"


def write_json(path: Path, value) -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(value, indent=2) + "\n")


def background_color(source: np.ndarray) -> np.ndarray:
    corners = np.concatenate([source[:64, :64], source[:64, -64:], source[-64:, :64], source[-64:, -64:]])
    return corners.reshape(-1, 3).mean(axis=0)


def extract_glyph(source: np.ndarray, background: np.ndarray) -> Image.Image:
    """Alpha follows distance from the navy field, keeping the soft glow."""
    distance = np.linalg.norm(source.astype(np.float32) - background, axis=2)
    alpha = np.clip((distance - 28.0) / 70.0, 0.0, 1.0)
    rows, cols = np.where(alpha > 0.02)
    top, bottom, left, right = rows.min(), rows.max() + 1, cols.min(), cols.max() + 1
    rgba = np.dstack([source, (alpha * 255).astype(np.uint8)])[top:bottom, left:right]
    return Image.fromarray(rgba, "RGBA")


def back_layer(size, background: np.ndarray) -> Image.Image:
    width, height = size
    y, x = np.mgrid[0:height, 0:width].astype(np.float32)
    # A faint centered lift keeps the flat field from looking like a gap
    # while the focused icon tilts.
    falloff = np.hypot((x - width / 2) / width, (y - height / 2) / height)
    lift = np.clip(1.0 - falloff * 1.6, 0.0, 1.0)[..., None] * 14.0
    pixels = np.clip(background[None, None, :] + lift, 0, 255).astype(np.uint8)
    return Image.fromarray(pixels, "RGB")


def front_layer(size, glyph: Image.Image, height_fraction: float, offset_x: float = 0.0) -> Image.Image:
    width, height = size
    scale = height * height_fraction / glyph.height
    scaled = glyph.resize((round(glyph.width * scale), round(glyph.height * scale)), Image.LANCZOS)
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    left = round((width - scaled.width) / 2 + offset_x * width)
    layer.alpha_composite(scaled, (left, round((height - scaled.height) / 2)))
    return layer


def wordmark_font(size: int):
    for candidate in ("/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/SFNS.ttf",
                      "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def top_shelf(size, glyph: Image.Image, background: np.ndarray) -> Image.Image:
    width, height = size
    image = back_layer(size, background).convert("RGBA")
    mark = front_layer(size, glyph, 0.46, offset_x=-0.16)
    image.alpha_composite(mark)
    font = wordmark_font(round(height * 0.2))
    draw = ImageDraw.Draw(image)
    text = "rustyView"
    box = draw.textbbox((0, 0), text, font=font)
    text_x = round(width * 0.5 + width * 0.02)
    text_y = round((height - (box[3] - box[1])) / 2 - box[1])
    draw.text((text_x, text_y), text, font=font, fill=(255, 255, 255, 255))
    return image.convert("RGB")


def write_layered_stack(root: Path, name: str, sizes, glyph, background) -> None:
    stack = root / f"{name}.imagestack"
    write_json(stack, {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"},
                                                 {"filename": "Back.imagestacklayer"}]})
    for layer in ("Front", "Back"):
        layer_dir = stack / f"{layer}.imagestacklayer"
        write_json(layer_dir, {"info": INFO})
        content = layer_dir / "Content.imageset"
        images = []
        for scale, size in sizes:
            filename = f"{layer.lower()}{'' if scale == 1 else f'-{scale}x'}.png"
            image = back_layer(size, background) if layer == "Back" else front_layer(size, glyph, 0.6)
            content.mkdir(parents=True, exist_ok=True)
            image.save(content / filename, optimize=True)
            images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
        write_json(content, {"images": images, "info": INFO})


def write_top_shelf(root: Path, name: str, base_size, glyph, background) -> None:
    content = root / f"{name}.imageset"
    images = []
    for scale in (1, 2):
        size = (base_size[0] * scale, base_size[1] * scale)
        filename = f"top-shelf{'-wide' if 'Wide' in name else ''}{'' if scale == 1 else '-2x'}.png"
        content.mkdir(parents=True, exist_ok=True)
        top_shelf(size, glyph, background).save(content / filename, optimize=True)
        images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
    write_json(content, {"images": images, "info": INFO})


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    source_path, catalog = Path(sys.argv[1]), Path(sys.argv[2])
    source = np.asarray(Image.open(source_path).convert("RGB"))
    background = background_color(source)
    glyph = extract_glyph(source, background)

    write_json(catalog, {"info": INFO})
    brand = catalog / BRAND
    write_json(brand, {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ], "info": INFO})
    write_layered_stack(brand, "App Icon", [(1, (400, 240)), (2, (800, 480))], glyph, background)
    write_layered_stack(brand, "App Icon - App Store", [(1, (1280, 768))], glyph, background)
    write_top_shelf(brand, "Top Shelf Image", (1920, 720), glyph, background)
    write_top_shelf(brand, "Top Shelf Image Wide", (2320, 720), glyph, background)
    return 0


if __name__ == "__main__":
    sys.exit(main())
