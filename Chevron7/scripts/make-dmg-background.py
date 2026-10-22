#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
"""Composes the DMG window background from the generated art.

Assets/DMG/art.png is the ambient picture (generated, its prompt in
art.png.json); this script draws what has to sit at exact coordinates on top
of it: the arrow between the two icons and the caption. It writes
background.png (660 x 400, the Finder window) and background@2x.png, which
package-release.sh hands to dmgbuild. The coordinates must match
icon_locations in Assets/DMG/dmgbuild-settings.py.

Needs Pillow and the SF Pro fonts in /Library/Fonts. The outputs are
committed, so a release never runs this.

Usage: make-dmg-background.py [ASSETS_DIR]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

WIDTH, HEIGHT = 660, 400
SCALE = 2
APP_CENTER = (165, 180)
APPLICATIONS_CENTER = (495, 180)
CAPTION = "Potiahnite Chevron7 do priečinka Applications"
# High enough to stay visible when Finder adds its tab bar to the window.
CAPTION_Y = 334
AMBER = (255, 178, 62)
TEXT = (214, 219, 229)
# Finder draws icon labels black in light appearance and white in dark, over
# whatever the picture holds; a plate of this luminance (about 0.18) keeps
# both above 4.5:1.
LABEL_PLATE = (116, 124, 150, 235)
LABEL_PLATE_EDGE = (214, 219, 229, 90)
LABEL_PLATE_SIZE = (132, 24)
# Finder centres a 13 pt label this far below the icon centre (measured).
LABEL_OFFSET_Y = 84
FONT = "/Library/Fonts/SF-Pro-Text-Regular.otf"


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Scales the art to fill size and crops the overflow around the centre."""
    ratio = max(size[0] / image.width, size[1] / image.height)
    scaled = image.resize(
        (round(image.width * ratio), round(image.height * ratio)), Image.LANCZOS
    )
    left = (scaled.width - size[0]) // 2
    top = (scaled.height - size[1]) // 2
    return scaled.crop((left, top, left + size[0], top + size[1]))


def draw_arrow(layer: Image.Image) -> None:
    """Three chevrons pointing at Applications, brightening towards it."""
    s = SCALE
    draw = ImageDraw.Draw(layer)
    mid_x = (APP_CENTER[0] + APPLICATIONS_CENTER[0]) / 2
    y = APP_CENTER[1]
    arm = 13
    step = 26
    for index, alpha in enumerate((90, 160, 255)):
        x = mid_x + (index - 1) * step
        points = [
            ((x - arm * 0.6) * s, (y - arm) * s),
            ((x + arm * 0.6) * s, y * s),
            ((x - arm * 0.6) * s, (y + arm) * s),
        ]
        draw.line(points, fill=AMBER + (alpha,), width=round(4.5 * s), joint="curve")
        for px, py in (points[0], points[2]):
            radius = 2.25 * s
            draw.ellipse(
                (px - radius, py - radius, px + radius, py + radius),
                fill=AMBER + (alpha,),
            )


def draw_label_plates(layer: Image.Image) -> None:
    s = SCALE
    draw = ImageDraw.Draw(layer)
    width, height = LABEL_PLATE_SIZE
    for cx, cy in (APP_CENTER, APPLICATIONS_CENTER):
        top = cy + LABEL_OFFSET_Y - height / 2
        draw.rounded_rectangle(
            ((cx - width / 2) * s, top * s, (cx + width / 2) * s, (top + height) * s),
            radius=height / 2 * s,
            fill=LABEL_PLATE,
            outline=LABEL_PLATE_EDGE,
            width=s,
        )


def draw_caption(layer: Image.Image) -> None:
    s = SCALE
    font = ImageFont.truetype(FONT, 13 * s)
    draw = ImageDraw.Draw(layer)
    draw.text(
        (WIDTH / 2 * s, CAPTION_Y * s), CAPTION, font=font, fill=TEXT + (235,), anchor="mm"
    )


def main() -> None:
    assets = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Assets" / "DMG"
    art = Image.open(assets / "art.png").convert("RGBA")
    canvas = cover(art, (WIDTH * SCALE, HEIGHT * SCALE))

    arrow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw_arrow(arrow)
    glow = arrow.filter(ImageFilter.GaussianBlur(6 * SCALE))
    canvas = Image.alpha_composite(canvas, glow)
    canvas = Image.alpha_composite(canvas, arrow)

    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw_label_plates(overlay)
    draw_caption(overlay)
    shadow = overlay.filter(ImageFilter.GaussianBlur(3 * SCALE))
    shadow = Image.merge("RGBA", (*Image.new("RGB", canvas.size, (0, 0, 0)).split(), shadow.getchannel("A").point(lambda a: a // 2)))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, overlay)

    retina = canvas.convert("RGB")
    retina.save(assets / "background@2x.png", optimize=True)
    retina.resize((WIDTH, HEIGHT), Image.LANCZOS).save(assets / "background.png", optimize=True)


if __name__ == "__main__":
    main()
