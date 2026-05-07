#!/usr/bin/env python3
"""Generate EqualEase app and menu bar icon assets."""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "EqualEase" / "EqualEase" / "Assets.xcassets"
APP_ICON_SET = ASSETS / "AppIcon.appiconset"
MENU_BAR_SET = ASSETS / "MenuBarIcon.imageset"
ACCENT_SET = ASSETS / "AccentColor.colorset"

HARVEST_ORANGE = (240, 100, 28)
HARVEST_ORANGE_LIGHT = (255, 138, 35)
HARVEST_ORANGE_DARK = (189, 54, 24)
WHITE_INK = (255, 255, 255)

APP_ICON_SLOTS = [
    ("16x16", "1x", 16),
    ("16x16", "2x", 32),
    ("32x32", "1x", 32),
    ("32x32", "2x", 64),
    ("128x128", "1x", 128),
    ("128x128", "2x", 256),
    ("256x256", "1x", 256),
    ("256x256", "2x", 512),
    ("512x512", "1x", 512),
    ("512x512", "2x", 1024),
]


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def color_lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(lerp(x, y, t) for x, y in zip(a, b))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def draw_app_icon(size: int) -> Image.Image:
    scale = size / 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Dock/App Switcher icons need a transparent safe area. Drawing the orange
    # tile edge-to-edge made EqualEase appear larger than neighboring app icons.
    inset = max(1, round(92 * scale))
    tile_size = size - inset * 2
    tile_scale = tile_size / 1024

    # Diagonal orange gradient clipped to a rounded tile inside the full canvas.
    tile = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
    pix = tile.load()
    for y in range(tile_size):
        for x in range(tile_size):
            t = (x + y) / (2 * (tile_size - 1)) if tile_size > 1 else 0
            if t < 0.46:
                c = color_lerp(HARVEST_ORANGE_LIGHT, HARVEST_ORANGE, t / 0.46)
            else:
                c = color_lerp(HARVEST_ORANGE, HARVEST_ORANGE_DARK, (t - 0.46) / 0.54)
            pix[x, y] = (*c, 255)
    mask = rounded_mask(tile_size, round(216 * tile_scale))
    img.alpha_composite(Image.composite(tile, Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0)), mask), (inset, inset))

    # Simple white equalizer bars, optically centered slightly below the
    # mathematical center so the icon does not feel like it is floating upward.
    draw = ImageDraw.Draw(img)
    radius = round(31 * tile_scale)
    bars = [
        (244, 392, 306, 752),
        (362, 282, 424, 752),
        (480, 548, 542, 752),
        (598, 468, 660, 752),
        (716, 238, 778, 752),
    ]
    for x0, y0, x1, y1 in bars:
        draw.rounded_rectangle(
            (
                inset + round(x0 * tile_scale),
                inset + round(y0 * tile_scale),
                inset + round(x1 * tile_scale),
                inset + round(y1 * tile_scale),
            ),
            radius=radius,
            fill=WHITE_INK,
        )

    return img


def draw_menu_icon(size: int) -> Image.Image:
    # Menu-bar icons are tiny; use a simple EQ bar graph, not full sliders.
    supersample = 4
    canvas = size * supersample
    scale = canvas / 18
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    ink = (0, 0, 0, 255)
    bars = [
        (4.0, 8.0, 7.0, 15.0),
        (8.0, 4.0, 11.0, 15.0),
        (12.0, 6.0, 15.0, 15.0),
    ]
    radius = 1.5 * scale
    for x0, y0, x1, y1 in bars:
        draw.rounded_rectangle(
            (x0 * scale, y0 * scale, x1 * scale, y1 * scale),
            radius=radius,
            fill=ink,
        )
    return img.resize((size, size), Image.Resampling.LANCZOS)


def write_app_icons() -> None:
    APP_ICON_SET.mkdir(parents=True, exist_ok=True)
    for old in APP_ICON_SET.glob("EqualEase-AppIcon-*.png"):
        old.unlink()
    images = []
    for logical_size, scale, pixels in APP_ICON_SLOTS:
        filename = f"EqualEase-AppIcon-{pixels}.png"
        draw_app_icon(pixels).save(APP_ICON_SET / filename)
        images.append({"idiom": "mac", "scale": scale, "size": logical_size, "filename": filename})
    (APP_ICON_SET / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def write_menu_bar_icon() -> None:
    MENU_BAR_SET.mkdir(parents=True, exist_ok=True)
    for old in MENU_BAR_SET.glob("EqualEase-MenuBarIcon*.png"):
        old.unlink()
    draw_menu_icon(18).save(MENU_BAR_SET / "EqualEase-MenuBarIcon.png")
    draw_menu_icon(36).save(MENU_BAR_SET / "EqualEase-MenuBarIcon@2x.png")
    contents = {
        "images": [
            {"idiom": "universal", "scale": "1x", "filename": "EqualEase-MenuBarIcon.png"},
            {"idiom": "universal", "scale": "2x", "filename": "EqualEase-MenuBarIcon@2x.png"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }
    (MENU_BAR_SET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_accent_color() -> None:
    ACCENT_SET.mkdir(parents=True, exist_ok=True)
    contents = {
        "colors": [
            {
                "idiom": "universal",
                "color": {
                    "color-space": "srgb",
                    "components": {
                        "red": f"{HARVEST_ORANGE[0] / 255:.6f}",
                        "green": f"{HARVEST_ORANGE[1] / 255:.6f}",
                        "blue": f"{HARVEST_ORANGE[2] / 255:.6f}",
                        "alpha": "1.000",
                    },
                },
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ACCENT_SET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> None:
    write_app_icons()
    write_menu_bar_icon()
    write_accent_color()


if __name__ == "__main__":
    main()
