#!/usr/bin/env python3
"""MacMUSH app icon: a genie lamp with a rainbow apple rising out of the smoke.

Drawn as SVG so it stays editable, rasterised with cairosvg, composited in
Pillow, and packed into a multi-size .icns by hand -- there is no iconutil off
macOS, and cairosvg has no filter support, so the smoke is blurred after the
fact rather than with feGaussianBlur.

Two sets of artwork, not one scaled down: `full` above 64px, `simple` at 64 and
below, where the six stripes and the lamp's handle turn to mush. Shipping
different drawings at different sizes is what Apple's own icon sets do, and it
is the only way the 1977 apple survives the menu bar.
"""
import io
import math
import os
import struct

from PIL import Image, ImageChops, ImageFilter

# ---------------------------------------------------------------- palette

# The plate is the app's own scrollback colour, so the icon and the window it
# opens are recognisably the same object. See Sources/MacMUSH/Theme.swift.
PLATE_TOP, PLATE_BOT = "#16161f", "#08080d"
RIM, HAIRLINE = "#b8860b", "#fff3c4"

# The 1977 six-stripe apple, top to bottom.
STRIPES = ["#61bb46", "#fdb827", "#f5821f", "#e03a3e", "#963d97", "#009ddc"]

GOLD_STOPS = [(0, "#ffeaa8"), (0.26, "#f7c948"), (0.60, "#d89b14"), (1, "#8f5f07")]


# ---------------------------------------------------------------- geometry

def squircle(cx, cy, half, n=5.0, samples=720):
    """Apple's icon shape: a superellipse, not a rounded rectangle.

    The corners on a Big Sur icon have continuous curvature -- the radius eases
    in rather than starting abruptly where the straight edge ends. n=5 is the
    usual approximation, and it is close enough that the icon sits level with
    the system ones in the Dock instead of looking slightly pinched.
    """
    pts = []
    for i in range(samples):
        t = 2.0 * math.pi * i / samples
        c, s = math.cos(t), math.sin(t)
        pts.append("%.2f,%.2f" % (
            cx + half * math.copysign(abs(c) ** (2.0 / n), c),
            cy + half * math.copysign(abs(s) ** (2.0 / n), s)))
    return "M " + " L ".join(pts) + " Z"


def _bezier(p, t):
    """One cubic, de Casteljau. Returns the point and the tangent."""
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p
    u = 1 - t
    x = u*u*u*x0 + 3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t*x3
    y = u*u*u*y0 + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y3
    dx = 3*u*u*(x1-x0) + 6*u*t*(x2-x1) + 3*t*t*(x3-x2)
    dy = 3*u*u*(y1-y0) + 6*u*t*(y2-y1) + 3*t*t*(y3-y2)
    return x, y, dx, dy


def ribbon(segments, width_at, samples=140):
    """A closed path around a centreline whose width varies along it.

    Hand-authoring both edges of a tapering curl as Beziers is a fight; walking
    the centreline and stepping off along the normal is not. `width_at` takes a
    position from 0 to 1 and returns the half-width there.
    """
    left, right = [], []
    for i in range(samples + 1):
        t = i / samples
        seg = min(int(t * len(segments)), len(segments) - 1)
        x, y, dx, dy = _bezier(segments[seg], t * len(segments) - seg)
        n = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / n, dx / n
        w = width_at(t)
        left.append("%.2f,%.2f" % (x + nx * w, y + ny * w))
        right.append("%.2f,%.2f" % (x - nx * w, y - ny * w))
    return "M " + " L ".join(left + right[::-1]) + " Z"


# ---------------------------------------------------------------- the apple

def apple(cx, cy, h, ident, leaf=True):
    """The 1977 apple, drawn in its own 200x250 space and transformed into place.

    Returns four separate SVG fragments rather than one, because the silhouette
    is a boolean: three overlapping lobes unioned, then a cleft and a bite
    subtracted. SVG expresses that with a <mask> -- white unions, black carves --
    and cairosvg ignores masks outright, so v1 rendered a rainbow brick with an
    apple-shaped bulge on one side. The union and the subtraction happen in
    Pillow instead (see `compose`), which needs the parts kept apart:

      body    the three lobes, white, to be unioned
      cut     the cleft and the bite, white, to be subtracted from `body`
      paint   the six stripes as full-width bands, cropped by the result
      leaf    drawn on top, not part of the silhouette

    The bands are drawn wider than the fruit on purpose; the silhouette is what
    trims them, so their own edges never need to line up with anything.
    """
    s = h / 250.0
    g = f'<g transform="translate({cx - 100*s:.2f},{cy - 125*s:.2f}) scale({s:.4f})">'

    # Taller than wide -- x 10..190 against y 56..250. The apple is a portrait
    # shape; matching lobe and belly radii the obvious way gives a squat one
    # that reads as a tomato at small sizes.
    body = (g + '<ellipse cx="68" cy="142" rx="58" ry="86" fill="#fff"/>'
                '<ellipse cx="132" cy="142" rx="58" ry="86" fill="#fff"/>'
                '<ellipse cx="100" cy="170" rx="76" ry="80" fill="#fff"/></g>')

    # Above y=70 the two lobes have not met yet, so there is already a notch
    # between them; this only deepens it into the heart-shaped dip the leaf
    # sits in. The bite is the classic one, upper right, breaking the edge.
    cut = (g + '<path d="M 78 22 L 122 22 L 122 54 C 119 86 81 86 78 54 Z" fill="#fff"/>'
               '<circle cx="192" cy="126" r="44" fill="#fff"/></g>')

    band = 194.0 / 6.0  # the body runs y 56..250
    paint = g + "".join(
        f'<rect x="-40" y="{56 + i*band - 0.6:.2f}" width="280" '
        f'height="{band + 1.2:.2f}" fill="{c}"/>' for i, c in enumerate(STRIPES)) + "</g>"

    # The leaf tip reaches y=0 and the body bottom y=250, so the drawing fills
    # its nominal box and `h` means what it says at the call site.
    leaf_svg = ""
    if leaf:
        leaf_svg = (g + '<path d="M 100 62 C 104 34 126 8 156 0 C 160 30 142 56 100 62 Z" '
                    f'fill="{STRIPES[0]}"/></g>')
    return body, cut, paint, leaf_svg


# ---------------------------------------------------------------- the lamp

def _gold(x1, y1, x2, y2):
    stops = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in GOLD_STOPS)
    return (f'<linearGradient id="gold" gradientUnits="userSpaceOnUse" '
            f'x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stops}</linearGradient>')


def lamp_full():
    """Body, spout, handle, lid, foot -- all filled from one gradient in user
    space, so the pieces overlap without showing a seam where they meet."""
    return '''
  <path d="M 456 786 L 596 786 L 610 812 C 613 820 607 826 599 826 L 453 826
           C 445 826 439 820 442 812 Z" fill="url(#gold)"/>
  <path d="M 392 676 C 350 668 310 650 276 630 C 263 640 255 654 253 670
           C 266 692 306 712 348 724 C 370 730 388 732 402 733 Z" fill="url(#gold)"/>
  <ellipse cx="266" cy="646" rx="23" ry="14" fill="url(#gold)" transform="rotate(-32 266 646)"/>
  <path d="M 682 664 C 754 647 796 685 777 727 C 764 756 724 767 694 764"
        fill="none" stroke="url(#gold)" stroke-width="26" stroke-linecap="round"/>
  <path d="M 364 716 C 364 662 430 630 528 630 C 626 630 692 662 692 716
           C 692 770 626 798 528 798 C 430 798 364 770 364 716 Z" fill="url(#gold)"/>
  <path d="M 490 634 C 492 608 507 592 528 592 C 549 592 564 608 566 634 Z" fill="url(#gold)"/>
  <circle cx="528" cy="586" r="15" fill="url(#gold)"/>
  <ellipse cx="452" cy="676" rx="66" ry="21" fill="#fff8dc" opacity="0.26"
           transform="rotate(-15 452 676)"/>
  <path d="M 380 700 C 388 660 442 638 524 636" fill="none" stroke="#fff8dc"
        stroke-width="6" stroke-linecap="round" opacity="0.26"/>'''


def lamp_simple():
    """Fewer parts, thicker everything. The lid's finial, the spout's flared lip
    and both highlights are gone: under about 64px they are each a pixel or two
    of slightly different gold, which reads as noise on the silhouette rather
    than as detail."""
    return '''
  <path d="M 410 800 L 610 800 L 626 836 L 394 836 Z" fill="url(#gold)"/>
  <path d="M 366 700 C 316 688 268 664 232 638 C 218 652 210 670 210 690
           C 230 718 284 742 340 756 Z" fill="url(#gold)"/>
  <path d="M 686 660 C 778 642 830 696 804 748 C 785 784 736 798 698 794"
        fill="none" stroke="url(#gold)" stroke-width="40" stroke-linecap="round"/>
  <path d="M 326 726 C 326 660 406 620 512 620 C 618 620 698 660 698 726
           C 698 792 618 830 512 830 C 406 830 326 792 326 726 Z" fill="url(#gold)"/>
  <path d="M 470 624 C 472 594 489 578 512 578 C 535 578 552 594 554 624 Z" fill="url(#gold)"/>'''


# ---------------------------------------------------------------- layers

def _svg(body, defs="", size=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 1024 1024"><defs>{defs}</defs>{body}</svg>')


def layers(simple=False):
    """Every layer as its own full-canvas SVG, keyed by what `compose` does to it.

    They are kept apart because two steps of this drawing cannot happen in SVG
    at all under cairosvg: the smoke has to be blurred (no filter support) and
    the apple has to be unioned and carved (no mask support). Both become Pillow
    operations, which means the pieces have to arrive separately. Rendering them
    all against the same 1024 viewBox is what keeps them in register.
    """
    half = 424 if simple else 412
    plate = squircle(512, 512, half)

    plate_defs = f'''
      <linearGradient id="plate" gradientUnits="userSpaceOnUse" x1="200" y1="140" x2="850" y2="900">
        <stop offset="0" stop-color="{PLATE_TOP}"/><stop offset="1" stop-color="{PLATE_BOT}"/>
      </linearGradient>
      <radialGradient id="halo" gradientUnits="userSpaceOnUse" cx="516" cy="300" r="290">
        <stop offset="0" stop-color="#ffd77a" stop-opacity="0.30"/>
        <stop offset="1" stop-color="#ffd77a" stop-opacity="0"/>
      </radialGradient>'''

    plate_body = [f'<path d="{plate}" fill="url(#plate)"/>',
                  f'<path d="{plate}" fill="none" stroke="{RIM}" '
                  f'stroke-width="{20 if simple else 13}"/>']
    if not simple:
        plate_body.append(f'<path d="{squircle(512, 512, 392)}" fill="none" '
                          f'stroke="{HAIRLINE}" stroke-width="3" opacity="0.40"/>')
    # The halo is its own layer, not part of the plate, because it has to be
    # clipped. A 290-radius circle centred at y=300 reaches y=10, well past the
    # plate's top edge at y=100, and an unclipped one hangs a soft grey smudge
    # in the transparent margin above the icon -- visible against a light Dock
    # or a Finder row, and unmistakably wrong.
    glow = '<circle cx="516" cy="300" r="290" fill="url(#halo)"/>'

    # Warm at the spout where it is still lamplight, cooling and thinning as it
    # rises. The opacities look high for smoke because they are about to be
    # blurred across a twentieth of the canvas, which costs most of them, and
    # because this sits on a near-black plate where anything subtle vanishes.
    gx = (250, 660, 470, 420) if simple else (290, 650, 560, 232)
    smoke_defs = f'''
      <linearGradient id="smoke" gradientUnits="userSpaceOnUse"
                      x1="{gx[0]}" y1="{gx[1]}" x2="{gx[2]}" y2="{gx[3]}">
        <stop offset="0" stop-color="#ffd98a" stop-opacity="0.92"/>
        <stop offset="0.45" stop-color="#ffe9bc" stop-opacity="0.66"/>
        <stop offset="0.80" stop-color="#ece6f2" stop-opacity="0.42"/>
        <stop offset="1" stop-color="#dce4fa" stop-opacity="0.18"/>
      </linearGradient>'''

    if simple:
        # One plume, no curl -- at 32px the S-bend is two pixels wide and reads
        # as a smudge. It runs from the spout to under the apple's left cheek so
        # that the two objects touch: a gap here, at sizes where the gap is one
        # pixel, leaves an apple that is merely above a lamp rather than out of
        # one. Wider than the full version's, for the same reason.
        smoke = '<path d="%s" fill="url(#smoke)"/>' % ribbon(
            [[(266, 634), (228, 556), (306, 490), (446, 452)]],
            lambda t: 18 + 52 * (t ** 0.68))
    else:
        # The second segment starts exactly where the first ends. It has to:
        # `ribbon` walks the segments back to back without joining them, so a
        # gap between them shows up as a step in the middle of the plume.
        path = ribbon(
            [[(270, 630), (218, 556), (248, 468), (330, 420)],
             [(330, 420), (398, 378), (452, 344), (500, 322)]],
            lambda t: 14 + 52 * (t ** 0.72))
        smoke = (f'<path d="{path}" fill="url(#smoke)"/>'
                 '<ellipse cx="392" cy="392" rx="30" ry="16" fill="#f4ecdc" opacity="0.30"'
                 ' transform="rotate(-30 392 392)"/>'
                 '<ellipse cx="322" cy="524" rx="22" ry="13" fill="#ffd88a" opacity="0.34"'
                 ' transform="rotate(26 322 524)"/>')

    if simple:
        gold, lamp, ap = _gold(300, 610, 740, 860), lamp_simple(), apple(516, 322, 330, "s")
    else:
        gold, lamp, ap = _gold(330, 590, 750, 840), lamp_full(), apple(516, 300, 290, "f")
    body, cut, paint, leaf = ap

    return {"plate": _svg("".join(plate_body), plate_defs),
            "glow": _svg(glow, plate_defs),
            "smoke": _svg(smoke, smoke_defs),
            "clip": _svg(f'<path d="{plate}" fill="#fff"/>'),
            "apple_body": _svg(body),
            "apple_cut": _svg(cut),
            "apple_paint": _svg(paint),
            "apple_leaf": _svg(leaf),
            "lamp": _svg(lamp, gold)}


# ---------------------------------------------------------------- rendering

def _png(svg, px):
    import cairosvg
    return Image.open(io.BytesIO(cairosvg.svg2png(
        bytestring=svg.encode(), output_width=px, output_height=px))).convert("RGBA")


def compose(px, simple=False):
    svg = layers(simple)
    render = {k: _png(v, px) for k, v in svg.items() if v}

    plate_alpha = render["clip"].getchannel("A")

    def clipped(layer):
        """Trim a layer to the plate's fill. Anything soft-edged has to go
        through this: the rim is the icon's outer boundary, and a glow or a
        blurred plume crossing it stops being part of the object."""
        layer = layer.copy()
        layer.putalpha(Image.composite(
            layer.getchannel("A"), Image.new("L", layer.size, 0), plate_alpha))
        return layer

    img = Image.alpha_composite(render["plate"], clipped(render["glow"]))

    # No smoke at 16px. The plume lands on about three pixels there, and three
    # blurred grey pixels between the lamp and the apple do not read as smoke --
    # they read as dirt, and they take the clear gap that is doing the real work
    # of telling the two shapes apart. What survives at 16px is a gold lamp and
    # a coloured apple, so the drawing keeps those and spends nothing else.
    if px > 16:
        # Enough blur to soften the ribbon's edge into vapour, not enough to
        # lose its shape. Past about 1.5% of the canvas the plume stops being a
        # curl of smoke and becomes a grey thumbprint; the simple artwork takes
        # even less, since at 32px a soft edge is most of the shape.
        img = Image.alpha_composite(img, clipped(render["smoke"].filter(
            ImageFilter.GaussianBlur(px * (0.007 if simple else 0.010)))))

    # The silhouette SVG could not express: the three lobes union simply by
    # being drawn over each other, and subtracting the cut layer's coverage
    # takes the cleft and the bite back out. Working on the alpha channels
    # keeps the antialiased edges intact -- a thresholded mask would give the
    # fruit a staircase outline at every size that matters.
    fruit = ImageChops.subtract(render["apple_body"].getchannel("A"),
                                render["apple_cut"].getchannel("A"))
    paint = render["apple_paint"]
    paint.putalpha(fruit)
    img = Image.alpha_composite(img, paint)
    if "apple_leaf" in render:
        img = Image.alpha_composite(img, render["apple_leaf"])

    return Image.alpha_composite(img, render["lamp"])


# ---------------------------------------------------------------- packing

def icns(entries):
    """Pack an .icns by hand -- iconutil is macOS-only and this container is not.

    The format is trivial: a magic word, the total length, then typed chunks
    that each carry their own length. Every type used here takes a PNG as its
    payload on any macOS that can run this app, which is what makes writing the
    container by hand reasonable. The TOC is how Finder picks a size without
    parsing the rest.
    """
    toc = b"".join(struct.pack(">4sI", t.encode(), len(d) + 8) for t, d in entries)
    body = struct.pack(">4sI", b"TOC ", len(toc) + 8) + toc
    for t, d in entries:
        body += struct.pack(">4sI", t.encode(), len(d) + 8) + d
    return b"icns" + struct.pack(">I", len(body) + 8) + body


# Type -> pixels. The @2x types repeat pixel sizes deliberately: macOS picks by
# type, not by dimension, and a missing type falls back to a scaled neighbour
# that looks softer than the real thing would have.
SPEC = [("icp4", 16), ("icp5", 32), ("icp6", 64),
        ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
        ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]

if __name__ == "__main__":
    out = os.path.dirname(os.path.abspath(__file__))
    cache = {}

    def png(px):
        if px not in cache:
            buf = io.BytesIO()
            compose(px, simple=px <= 64).save(buf, "PNG")
            cache[px] = buf.getvalue()
        return cache[px]

    open(os.path.join(out, "icon.icns"), "wb").write(icns([(t, png(px)) for t, px in SPEC]))
    open(os.path.join(out, "icon.png"), "wb").write(png(1024))
    for px in (16, 32, 64, 128, 256, 512):
        open(os.path.join(out, f"preview-{px}.png"), "wb").write(png(px))
    print("wrote icns,", sum(len(v) for v in cache.values()) // 1024, "KiB of PNG")
