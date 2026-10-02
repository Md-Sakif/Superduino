#!/usr/bin/env python3
"""Generates data/fonts/superduino-icons.ttf, Superduino's own icons.

The bundled icons.ttf (from fontello, see fontello-config.json) has no check
mark or arrow for Build and Upload, and the renderer only draws rectangles and
text, so these icons are glyphs of a small font, drawn here as outlines:

  "V"  check mark  (Build: "verify", as in the Arduino IDE)
  "U"  right arrow (Upload)

Run it again after changing a glyph:  python3 scripts/make-superduino-icons.py
Needs fontTools (pip install fonttools).
"""
import math
import os

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPM = 1000
ADVANCE = 1000
OUT = os.path.join(os.path.dirname(__file__), "..", "data", "fonts", "superduino-icons.ttf")


def stroke(points, width):
    """Outline of a polyline drawn with a pen of `width`, mitred at the corners."""
    half = width / 2

    def normal(a, b):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        return -dy / length * half, dx / length * half

    def offset_side(sign):
        side = []
        for i, p in enumerate(points):
            normals = []
            if i > 0:
                normals.append(normal(points[i - 1], p))
            if i < len(points) - 1:
                normals.append(normal(p, points[i + 1]))
            if len(normals) == 1:
                nx, ny = normals[0]
            else:
                # miter: the sum of both normals, scaled to keep the pen width
                (ax, ay), (bx, by) = normals
                mx, my = ax + bx, ay + by
                scale = (half * half) / (mx * ax + my * ay)
                nx, ny = mx * scale, my * scale
            side.append((p[0] + sign * nx, p[1] + sign * ny))
        return side

    return offset_side(1) + list(reversed(offset_side(-1)))


def clockwise(contour):
    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(contour, contour[1:] + contour[:1]))
    return contour if area < 0 else list(reversed(contour))


def glyph(contours):
    pen = TTGlyphPen(None)
    for contour in contours:
        contour = clockwise([(round(x), round(y)) for x, y in contour])
        pen.moveTo(contour[0])
        for point in contour[1:]:
            pen.lineTo(point)
        pen.closePath()
    return pen.glyph()


def empty():
    return TTGlyphPen(None).glyph()


GLYPHS = {
    # check mark: short stroke down to the corner, long stroke up
    "check": [stroke([(150, 400), (390, 160), (860, 630)], 130)],
    # right arrow: shaft and head as one outline
    "arrow": [[(120, 330), (560, 330), (560, 130), (900, 395), (560, 660), (560, 460), (120, 460)]],
}
CHARS = {"V": "check", "U": "arrow"}


def main():
    names = [".notdef", "space"] + list(GLYPHS)
    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(names)
    cmap = {ord(" "): "space"}
    cmap.update({ord(char): name for char, name in CHARS.items()})
    fb.setupCharacterMap(cmap)
    glyphs = {".notdef": empty(), "space": empty()}
    glyphs.update({name: glyph(contours) for name, contours in GLYPHS.items()})
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({name: (ADVANCE, 0) for name in names})
    fb.setupHorizontalHeader(ascent=850, descent=-150)
    fb.setupNameTable({"familyName": "Superduino Icons", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=850, sTypoDescender=-150, usWinAscent=850, usWinDescent=150)
    fb.setupPost()
    fb.save(OUT)
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
