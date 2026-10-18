"""Generate assets/logo.png for dsh-guard-boot.

Usage:  python assets/make-logo.py

Draws a rounded-square app icon (supersampled 4x, downscaled with LANCZOS):
dark navy gradient background + white shield + navy restart arrow inside.
No external assets, no network. Requires Pillow only.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 512
SS = 4  # supersample factor
S = SIZE * SS

BG_TOP = (14, 34, 51)      # #0E2233
BG_BOTTOM = (27, 72, 104)  # #1B4868
NAVY = (17, 43, 66)        # #112B42
WHITE = (255, 255, 255)
GREEN = (61, 220, 132)     # #3DDC84
GREEN_DEEP = (32, 178, 100)  # #20B264


def gradient(size: int) -> Image.Image:
    """Vertical gradient, drawn 1px wide then stretched (cheap and smooth)."""
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        px[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
    return strip.resize((size, size), Image.BILINEAR)


def shield_points(cx: float, top: float, bottom: float, half_w: float) -> list[tuple[float, float]]:
    """Pointed shield: flat top, straight sides, quadratic taper to the tip."""
    shoulder = top + (bottom - top) * 0.58
    x0, y0 = cx + half_w, shoulder
    ctrl_x, ctrl_y = cx + half_w, bottom - (bottom - shoulder) * 0.42

    # right side, straight down then quadratic taper to the bottom tip
    right: list[tuple[float, float]] = []
    steps = 48
    for i in range(1, steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * ctrl_x + t**2 * cx
        y = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * ctrl_y + t**2 * bottom
        right.append((x, y))

    pts: list[tuple[float, float]] = [(cx - half_w, top), (cx + half_w, top), (cx + half_w, shoulder)]
    pts += right
    pts += [(2 * cx - x, y) for (x, y) in reversed(right)]  # mirror back up the left side
    pts += [(cx - half_w, shoulder)]
    return pts


def main() -> None:
    out = Path(__file__).resolve().parent / "logo.png"

    img = gradient(S).convert("RGBA")

    # rounded-square mask
    radius = int(S * 0.22)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)
    img.putalpha(mask)

    d = ImageDraw.Draw(img)

    # smooth top light (1px strip stretched: no visible seam)
    light = Image.new("L", (1, S))
    for y in range(S):
        v = max(0.0, 1.0 - y / (S * 0.62))
        light.putpixel((0, y), int((v ** 2) * 46))
    halo = Image.new("RGBA", (S, S), (150, 205, 245, 0))
    halo.putalpha(light.resize((S, S), Image.BILINEAR))
    img.alpha_composite(halo)

    # shield
    cx = S / 2
    top = S * 0.215
    bottom = S * 0.795
    half_w = S * 0.245
    shield = shield_points(cx, top, bottom, half_w)
    d.polygon(shield, fill=WHITE)

    # subtle inner shadow: navy edge line
    d.line(shield + [shield[0]], fill=(226, 233, 240), width=int(S * 0.006), joint="curve")

    # restart arrow (arc + arrowhead) inside the shield
    acx, acy = cx, (top + bottom) / 2 + S * 0.005
    r = S * 0.118
    width = int(S * 0.045)
    start, end = 42, 316
    d.arc([acx - r, acy - r, acx + r, acy + r], start=start, end=end, fill=NAVY, width=width)

    # arrowhead at the `start` end, pointing clockwise (increasing angle, y-down screen)
    th = math.radians(start)
    px, py = acx + r * math.cos(th), acy + r * math.sin(th)
    dx, dy = -math.sin(th), math.cos(th)
    nx, ny = -dy, dx
    tip = (px + dx * S * 0.058, py + dy * S * 0.058)
    base_c = (px - dx * S * 0.022, py - dy * S * 0.022)
    half = S * 0.049
    tri = [
        tip,
        (base_c[0] + nx * half, base_c[1] + ny * half),
        (base_c[0] - nx * half, base_c[1] - ny * half),
    ]
    d.polygon(tri, fill=NAVY)

    # green dot under the arrow head = "healthy"
    dr = S * 0.034
    dcy = acy + S * 0.185
    d.ellipse([cx - dr, dcy - dr, cx + dr, dcy + dr], fill=GREEN)
    d.ellipse([cx - dr, dcy - dr, cx + dr, dcy + dr], outline=GREEN_DEEP, width=int(S * 0.005))

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(out, "PNG", optimize=True)
    print(f"wrote {out} ({out.stat().st_size} bytes, {SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
