#!/usr/bin/env python3
"""Generate the desktop wallpaper as a PNG, using only the Python standard library.

Usage: wallpaper.py <width> <height> <output.png>

Yaru-style aubergine gradient with an orange glow, painted smoothly at the real
resolution (per-pixel math, no block scaling -> no banding).
"""
import struct
import sys
import zlib

TOP = (44, 6, 36)         # Yaru aubergine (dark)
BOTTOM = (16, 3, 14)      # near-black aubergine
GLOWS = (                 # (cx, cy, radius, colour, strength) in 0..1 space
    (0.78, 0.16, 0.55, (233, 84, 32), 0.55),     # Ubuntu orange
    (0.18, 0.74, 0.62, (119, 41, 83), 0.60),     # aubergine
    (0.55, 0.50, 0.45, (250, 150, 90), 0.10),    # warm haze
)


def build(w, h):
    rows = []
    for y in range(h):
        fy = y / (h - 1)
        base = tuple(TOP[i] + (BOTTOM[i] - TOP[i]) * (fy ** 0.85) for i in range(3))
        row = bytearray()
        for x in range(w):
            fx = x / (w - 1)
            acc = list(base)
            for cx, cy, radius, colour, strength in GLOWS:
                dx = fx - cx
                dy = (fy - cy) * 1.6
                d2 = dx * dx + dy * dy
                if d2 < radius * radius:
                    falloff = (1.0 - (d2 ** 0.5) / radius) ** 2.2 * strength
                    acc[0] += (colour[0] - acc[0]) * falloff
                    acc[1] += (colour[1] - acc[1]) * falloff
                    acc[2] += (colour[2] - acc[2]) * falloff
            vig = 1.0 - 0.22 * (((fx - 0.5) ** 2 + (fy - 0.5) ** 2) ** 0.5) * 2.0
            row += bytes((min(255, max(0, int(v * vig))) for v in acc))
        rows.append(bytes(row))
    return rows


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 6))
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
