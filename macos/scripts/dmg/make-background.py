#!/usr/bin/env python3
# Draws the installer window background: a light field, a soft glow behind
# each icon slot, an arrow from the app to Applications and one line of
# instruction. Writes background.png (660x400) and background@2x.png beside
# this script; release.sh turns the pair into the image the window shows.
# Needs Pillow; run it only when the art changes, and commit both PNGs.
import math
import os
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
W, H = 660, 400
def render(scale):
    k = scale * 4                      # supersample, then downsample for smooth edges
    im = Image.new("RGB", (W*k, H*k), (246, 249, 248))
    # soft mint glow behind each icon slot
    glow = Image.new("L", (W*k, H*k), 0); g = ImageDraw.Draw(glow)
    for cx in (170, 490):
        r = 118*k
        g.ellipse((cx*k-r, 182*k-r, cx*k+r, 182*k+r), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(46*k))
    tint = Image.new("RGB", (W*k, H*k), (214, 240, 234))
    im = Image.composite(tint, im, glow)
    d = ImageDraw.Draw(im)
    teal = (0, 107, 90)
    # arc arrow from the app slot to Applications
    x0, x1, y = 262, 398, 176
    pts = []
    for i in range(61):
        t = i/60; x = x0 + (x1-x0)*t; yy = y - 22*math.sin(math.pi*t)
        pts.append((x*k, yy*k))
    # the head points along the curve's own tangent at its end
    ang = math.atan2(22*math.pi, x1-x0); L = 15*k; spread = math.radians(28)
    tip = pts[-1]
    base = (tip[0] - L*math.cos(ang), tip[1] - L*math.sin(ang))
    body = [q for q in pts if q[0] < base[0]] + [base]
    d.line(body, fill=teal, width=int(4.5*k), joint="curve")
    r = 2.25*k; d.ellipse((pts[0][0]-r, pts[0][1]-r, pts[0][0]+r, pts[0][1]+r), fill=teal)
    left = (tip[0] - L*math.cos(ang-spread), tip[1] - L*math.sin(ang-spread))
    right = (tip[0] - L*math.cos(ang+spread), tip[1] - L*math.sin(ang+spread))
    d.polygon([tip, left, right], fill=teal)
    # caption
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int(14*k))
    except OSError:
        f = ImageFont.load_default()
    text = "Drag CGM Relay into Applications"
    tw = d.textlength(text, font=f)
    d.text(((W*k - tw)/2, 322*k), text, font=f, fill=(84, 96, 93))
    return im.resize((W*scale, H*scale), Image.LANCZOS)
render(1).save(f"{out}/background.png")
render(2).save(f"{out}/background@2x.png")
