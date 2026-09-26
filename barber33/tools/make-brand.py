"""Barber 33 brand assets.

The mark is a barber pole rather than the numerals: "33" is unreadable at
16px, a striped pole is not, and it says "barbershop" before anyone has read
a word. Everything is drawn 4x and downsampled, which is cheaper than
fighting PIL for antialiased curves.
"""
from PIL import Image, ImageDraw, ImageFont

SS   = 4                      # supersample factor
BG   = (12, 12, 14, 255)      # --ink
CREAM= (246, 242, 234, 255)
BRASS= (200, 160, 70, 255)
RED  = (192,  57,  46, 255)

def pole(size, bleed=False, pitch=0.032):
    """One icon. bleed=True fills the whole square (iOS masks its own corner)."""
    W = size * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d   = ImageDraw.Draw(img)

    if bleed:
        d.rectangle([0, 0, W, W], fill=BG)
    else:
        d.rounded_rectangle([0, 0, W - 1, W - 1], radius=int(W * 0.215), fill=BG)

    # the pole
    pw  = W * 0.30
    x0, x1 = (W - pw) / 2, (W + pw) / 2
    y0, y1 = W * 0.155, W * 0.845
    r   = pw / 2

    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([x0, y0, x1, y1], radius=r, fill=255)

    # diagonal stripes, drawn across the whole canvas and then clipped to the pole
    stripes = Image.new("RGBA", (W, W), CREAM)
    sd      = ImageDraw.Draw(stripes)
    # pitch is the horizontal width of one stripe as a fraction of the icon.
    # Four of them make a colour cycle, so ~3 red stripes end up on the pole at
    # the default — which is what a real pole looks like. Small sizes need a
    # coarser pitch or the stripes disappear into grey at 16px.
    band    = W * pitch
    shear   = W * 0.55                   # lean of the stripe, ~61 degrees
    seq     = [RED, None, BRASS, None]   # None leaves the cream showing through
    i, x = 0, -W
    while x < W * 2:
        col = seq[i % len(seq)]
        if col:
            sd.polygon([(x, 0), (x + band, 0), (x + band - shear, W), (x - shear, W)], fill=col)
        x += band
        i += 1
    img.paste(stripes, (0, 0), mask)

    # brass caps top and bottom — what stops it reading as a striped pill
    cw, ch = pw * 1.26, W * 0.052
    cx0, cx1 = (W - cw) / 2, (W + cw) / 2
    for cy in (y0 - ch * 0.42, y1 - ch * 0.58):
        d.rounded_rectangle([cx0, cy, cx1, cy + ch], radius=ch / 2, fill=BRASS)

    return img.resize((size, size), Image.LANCZOS)

import os
HERE = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.join(HERE, "..", "icons") + os.sep
for n, kw in [(512, {}), (192, {}), (180, dict(bleed=True)),
              (32, dict(pitch=0.085)), (16, dict(pitch=0.125))]:
    name = {512: "icon-512.png", 192: "icon-192.png", 180: "apple-touch-icon.png",
            32: "favicon-32.png", 16: "favicon-16.png"}[n]
    pole(n, **kw).save(OUT + name, optimize=True)
    print("wrote", name)

# ---- share card -------------------------------------------------------------
# What WhatsApp, Messenger and Facebook show when someone sends the shop to a
# friend — for a walk-in barbershop that link IS the marketing, so it gets the
# name, the town and the one thing that matters: no appointment needed.
W, H = 1200, 630

# A warm off-centre glow. Computed on a 60x32 grid and scaled up, which costs
# nothing and gives a genuinely smooth ramp; drawing concentric ellipses left
# visible rings.
gw, gh = 60, 32
grad = Image.new("RGB", (gw, gh))
gp   = grad.load()
for gy in range(gh):
    for gx in range(gw):
        dx, dy = (gx - gw * 0.66) / (gw * 0.62), (gy - gh * 0.46) / (gh * 0.86)
        f = max(0.0, 1.0 - (dx * dx + dy * dy)) ** 1.6
        gp[gx, gy] = (int(12 + 30 * f), int(12 + 22 * f), int(14 + 10 * f))
card = grad.resize((W, H), Image.BICUBIC)
cd   = ImageDraw.Draw(card)

mark = pole(316)                                   # rounded, transparent corners
card.paste(mark, (762, 157), mark)

B = lambda p: ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", p)
R = lambda p: ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", p)

X = 96
cd.rectangle([X, 172, X + 84, 179], fill=RED[:3])
cd.text((X, 300), "BARBER", font=B(108), fill=CREAM[:3], anchor="ls")
# "33" and the town share a baseline; POREČ is placed off the measured width of
# the numerals so the two never collide whatever the font does.
f33 = B(108)
cd.text((X, 424), "33", font=f33, fill=BRASS[:3], anchor="ls")
cd.text((X + cd.textlength("33", font=f33) + 34, 424), "POREČ",
        font=B(44), fill=CREAM[:3], anchor="ls")
cd.text((X, 505), "Walk-in barbershop \u2014 bez naru\u010divanja",
        font=R(34), fill=(163, 155, 145), anchor="ls")

card.save(OUT + "../assets/share-card.jpg", quality=88, optimize=True, progressive=True)
print("wrote share-card.jpg")
