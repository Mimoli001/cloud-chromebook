#!/usr/bin/env python3
"""Generate the desktop wallpaper as a PNG, using only the Python standard library.

Usage: wallpaper.py <width> <height> <output.png>

The image is computed at a low logical resolution and then scaled up by pixel
duplication: the design is a smooth gradient, so the result looks identical and
it takes milliseconds even without Pillow.
"""
import struct
import sys
import zlib

LOGICAL_W, LOGICAL_H = 160, 90

TOP = (26, 48, 92)        # deep blue
BOTTOM = (10, 16, 32)     # near-black navy
GLOWS = (                 # (cx, cy, radius, colour, strength) in 0..1 space
    (0.22, 0.18, 0.55, (66, 133, 244), 0.55),    # Google blue
    (0.82, 0.30, 0.50, (155, 89, 182), 0.35),    # purple
    (0.55, 0.95, 0.60, (52, 168, 83), 0.18),     # green
)


def pixel(x, y, w, h):
    fx, fy = x / (w - 1), y / (h - 1)
    base = tuple(TOP[i] + (BOTTOM[i] - TOP[i]) * (fy ** 0.85) for i in range(3))
    acc = list(base)
    for cx, cy, radius, colour, strength in GLOWS:
        dx, dy = fx - cx, (fy - cy) * 1.6
        d = (dx * dx + dy * dy) ** 0.5
        if d < radius:
            falloff = (1.0 - d / radius) ** 2.2 * strength
            for i in range(3):
                acc[i] += (colour[i] - acc[i]) * falloff
    # subtle vignette so the shelf and windows pop
    vig = 1.0 - 0.22 * (((fx - 0.5) ** 2 + (fy - 0.5) ** 2) ** 0.5) * 2.0
    return bytes(min(255, max(0, int(acc[i] * vig))) for i in range(3))


def build(w, h):
    lw, lh = LOGICAL_W, LOGICAL_H
    row_cache = []
    for y in range(lh):
        row = bytearray()
        for x in range(lw):
            row += pixel(x, y, lw, lh)
        row_cache.append(bytes(row))
        row_cache.append(bytes(row))
    # duplicate each logical row twice (keeps 16:9 shapes close enough) then scale columns
    sx = max(1, round(w / lw))
    sy = max(1, round(h / (lh * 2)))
    rows = []
    for _ in range(sy):
        for row in row_cache:
            wide = bytearray()
            for x in range(lw):
                wide += row[x * 3:x * 3 + 3] * sx
            if len(wide) < w * 3:
                wide += wide[-3:] * ((w * 3 - len(wide)) // 3)
            rows.append(bytes(wide[: w * 3]))
            if len(rows) >= h:
                break
        if len(rows) >= h:
            break
    while len(rows) < h:
        rows.append(rows[-1])
    return rows[:h]


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 9))
    blob += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(blob)


def main():
    w = int(sys.argv[1]) if len(sys.argv) > 1 else 1600
    h = int(sys.argv[2]) if len(sys.argv) > 2 else 900
    out = sys.argv[3] if len(sys.argv) > 3 else "wallpaper.png"
    write_png(out, w, h, build(w, h))
    print(f"wallpaper: {out} ({w}x{h})")


if __name__ == "__main__":
    main()
