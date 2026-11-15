#!/usr/bin/env python3
# Three onboarding windows side by side, for the README.
#
#   python3 -I docs/images/src/onboarding-strip.py out.png light|dark step1.png step2.png step3.png
#
# The steps are screenshots of onboarding.html (see ../README.md). Needs Pillow.
import sys
from PIL import Image, ImageDraw, ImageFilter
out, theme, parts = sys.argv[1], sys.argv[2], sys.argv[3:]
ims = [Image.open(p).convert("RGBA") for p in parts]
w, h = ims[0].size
scale = 0.62
tw, th = int(w * scale), int(h * scale)
gap, pad = 56, 72
W = pad * 2 + tw * len(ims) + gap * (len(ims) - 1)
H = pad * 2 + th
bg = Image.new("RGBA", (W, H))
top, bottom = ((236, 240, 244), (222, 228, 234)) if theme == "light" else ((32, 36, 42), (20, 23, 27))
d = ImageDraw.Draw(bg)
for y in range(H):
    f = y / H
    d.line([(0, y), (W, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * f) for i in range(3)) + (255,))
r = 24
for i, im in enumerate(ims):
    im = im.resize((tw, th), Image.LANCZOS)
    x = pad + i * (tw + gap)
    mask = Image.new("L", (tw, th), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, tw - 1, th - 1], r, fill=255)
    shadow = Image.new("RGBA", (tw + 120, th + 120), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([60, 76, 60 + tw, 76 + th], r, fill=(0, 0, 0, 70 if theme == "light" else 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    bg.alpha_composite(shadow, (x - 60, pad - 60))
    bg.paste(im, (x, pad), mask)
    edge = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, tw - 1, th - 1], r, outline=(0, 0, 0, 40) if theme == "light" else (255, 255, 255, 30), width=2)
    bg.alpha_composite(edge, (x, pad))
bg.convert("RGB").save(out)
