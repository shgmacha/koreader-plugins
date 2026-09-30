#!/usr/bin/env python3
"""Draws Blossom's grayscale garden icons (SVG) into blossom.koplugin/icons/."""
import math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "blossom.koplugin", "icons")
INK, SOFT, PETAL, LIGHT, LEAF, MID = "#333333", "#6a6a6a", "#d2d2d2", "#ececec", "#bcbcbc", "#9a9a9a"
S = f'stroke="{INK}" stroke-linejoin="round" stroke-linecap="round"'

def stem(x=24, top=26, bottom=46, leaf=True, side=1):
    out = f'<path d="M{x} {bottom} C{x} {bottom-8} {x} {top+8} {x} {top}" fill="none" {S} stroke-width="2.4"/>'
    if leaf:
        lx = x - 12 * side
        out += (f'<path d="M{x} {bottom-8} C{x-4*side} {bottom-8} {lx} {bottom-12} {lx} {bottom-18} '
                f'C{x-6*side} {bottom-18} {x} {bottom-14} {x} {bottom-8} Z" fill="{LEAF}" {S} stroke-width="1.8"/>')
    return out

def tulip(x=24, y=0):
    return (stem(x, 24 + y, 46 + y) +
            f'<path d="M{x-10} {8+y} C{x-11} {19+y} {x-6} {25+y} {x} {25+y} C{x+6} {25+y} {x+11} {19+y} {x+10} {8+y} '
            f'L{x+5} {14+y} L{x} {5+y} L{x-5} {14+y} Z" fill="{PETAL}" {S} stroke-width="2.3"/>')

def daisy(x=24, y=16, r=6.5, center=MID, n=8, stem_to=46):
    out = stem(x, y + 4, stem_to, side=-1) if stem_to else ""
    for k in range(n):
        a = 360 * k / n
        out += (f'<ellipse cx="{x}" cy="{y - r}" rx="{r*0.5:.1f}" ry="{r:.1f}" transform="rotate({a:.0f} {x} {y})" '
                f'fill="white" {S} stroke-width="1.8"/>')
    out += f'<circle cx="{x}" cy="{y}" r="{r*0.62:.1f}" fill="{center}" {S} stroke-width="1.8"/>'
    return out

def sunflower(x=24, y=16):
    return daisy(x, y, r=7, center=SOFT, n=12)

def sprout(x=24, bottom=46):
    return (f'<path d="M{x} {bottom} C{x} {bottom-8} {x} {bottom-14} {x} {bottom-20}" fill="none" {S} stroke-width="2.4"/>'
            f'<path d="M{x} {bottom-16} C{x-8} {bottom-16} {x-14} {bottom-22} {x-14} {bottom-30} C{x-6} {bottom-30} {x} {bottom-24} {x} {bottom-16} Z" fill="{LEAF}" {S} stroke-width="1.8"/>'
            f'<path d="M{x} {bottom-20} C{x+7} {bottom-20} {x+14} {bottom-26} {x+14} {bottom-34} C{x+6} {bottom-34} {x} {bottom-28} {x} {bottom-20} Z" fill="{PETAL}" {S} stroke-width="1.8"/>')

def rose(x=24, y=15):
    return (stem(x, y + 9, 46) +
            f'<circle cx="{x}" cy="{y}" r="10" fill="{PETAL}" {S} stroke-width="2.3"/>'
            f'<path d="M{x-5} {y+1} C{x-5} {y-5} {x+4} {y-6} {x+5} {y-1} C{x+6} {y+4} {x} {y+6} {x-2} {y+2} C{x-3} {y-1} {x+1} {y-3} {x+2} {y}" fill="none" {S} stroke-width="1.8"/>')

def bud(x=24):
    return (stem(x, 22, 46, side=-1) +
            f'<path d="M{x} {6} C{x+7} {12} {x+7} {20} {x} {23} C{x-7} {20} {x-7} {12} {x} {6} Z" fill="{PETAL}" {S} stroke-width="2.2"/>'
            f'<path d="M{x-6} {18} C{x-3} {21} {x+3} {21} {x+6} {18}" fill="none" {S} stroke-width="1.6"/>')

def butterfly(x=24, y=24):
    return (f'<path d="M{x} {y-2} C{x-6} {y-16} {x-20} {y-16} {x-18} {y-4} C{x-17} {y+2} {x-6} {y+2} {x} {y-2} Z" fill="{PETAL}" {S} stroke-width="2"/>'
            f'<path d="M{x} {y-2} C{x+6} {y-16} {x+20} {y-16} {x+18} {y-4} C{x+17} {y+2} {x+6} {y+2} {x} {y-2} Z" fill="{PETAL}" {S} stroke-width="2"/>'
            f'<path d="M{x} {y} C{x-4} {y+2} {x-14} {y+6} {x-11} {y+13} C{x-7} {y+16} {x-2} {y+8} {x} {y} Z" fill="{LIGHT}" {S} stroke-width="2"/>'
            f'<path d="M{x} {y} C{x+4} {y+2} {x+14} {y+6} {x+11} {y+13} C{x+7} {y+16} {x+2} {y+8} {x} {y} Z" fill="{LIGHT}" {S} stroke-width="2"/>'
            f'<ellipse cx="{x}" cy="{y+2}" rx="1.8" ry="9" fill="{INK}"/>'
            f'<path d="M{x-1} {y-6} C{x-3} {y-12} {x-6} {y-14} {x-7} {y-15} M{x+1} {y-6} C{x+3} {y-12} {x+6} {y-14} {x+7} {y-15}" fill="none" {S} stroke-width="1.4"/>')

def ladybug(x=24, y=26):
    return (f'<circle cx="{x}" cy="{y-11}" r="5" fill="{INK}"/>'
            f'<ellipse cx="{x}" cy="{y+2}" rx="13" ry="14" fill="{PETAL}" {S} stroke-width="2.3"/>'
            f'<path d="M{x} {y-12} L{x} {y+16}" {S} stroke-width="1.8"/>'
            + "".join(f'<circle cx="{x+dx}" cy="{y+dy}" r="2.6" fill="{INK}"/>' for dx, dy in [(-6,-3),(6,-3),(-7,6),(7,6),(-3,11),(3,11)]))

def svg(body, w=48, h=48):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">{body}</svg>\n'

def close_flower(x=24, y=24):
    """A round five-petal flower with a little x in its heart: the close button."""
    out = ""
    for k in range(5):
        a = 360 * k / 5
        out += (f'<ellipse cx="{x}" cy="{y-11}" rx="8" ry="10" transform="rotate({a:.0f} {x} {y})" '
                f'fill="{LIGHT}" {S} stroke-width="2.2"/>')
    out += f'<circle cx="{x}" cy="{y}" r="9" fill="white" {S} stroke-width="2.2"/>'
    out += f'<path d="M{x-3.6} {y-3.6} L{x+3.6} {y+3.6} M{x+3.6} {y-3.6} L{x-3.6} {y+3.6}" {S} stroke-width="2.6" fill="none"/>'
    return out

def back_flower(x=24, y=24):
    """The same round flower with a little ‹ in its heart: the back button."""
    out = close_flower(x, y).rsplit("<path", 1)[0]
    out += f'<path d="M{x+1.5} {y-4.5} L{x-3} {y} L{x+1.5} {y+4.5}" {S} stroke-width="2.8" fill="none"/>'
    return out

def lily(x=24, y=24):
    """A lily bloom seen from above, no stem: six pointed petals and three little stamens."""
    out = ""
    for k, fill in [(0, LIGHT), (2, LIGHT), (4, LIGHT), (1, PETAL), (3, PETAL), (5, PETAL)]:
        a = 60 * k + 30
        out += (f'<path d="M{x} {y} C{x-7} {y-8} {x-5} {y-16} {x} {y-21} C{x+5} {y-16} {x+7} {y-8} {x} {y} Z" '
                f'transform="rotate({a} {x} {y})" fill="{fill}" {S} stroke-width="1.9"/>')
        out += f'<path d="M{x} {y-4} L{x} {y-14}" transform="rotate({a} {x} {y})" stroke="{MID}" stroke-width="1.2" fill="none"/>'
    for a in (0, 120, 240):
        out += (f'<path d="M{x} {y} L{x} {y-9}" transform="rotate({a} {x} {y})" {S} stroke-width="1.4" fill="none"/>'
                f'<circle cx="{x}" cy="{y-10}" r="1.8" transform="rotate({a} {x} {y})" fill="{INK}"/>')
    return out

def rose_bloom(x=24, y=24, ink=INK, petal=PETAL, light=LIGHT):
    """A rose seen from above, no stem: five round outer petals, a cupped middle and a spiral heart."""
    st = f'stroke="{ink}" stroke-linejoin="round" stroke-linecap="round"'
    out = ""
    for k in range(5):
        a = 72 * k
        out += (f'<circle cx="{x}" cy="{y-10}" r="9" transform="rotate({a} {x} {y})" fill="{petal}" {st} stroke-width="2"/>')
    out += f'<circle cx="{x}" cy="{y}" r="11" fill="{light}" {st} stroke-width="2"/>'
    out += (f'<path d="M{x-6} {y+1} C{x-6} {y-6} {x+5} {y-7} {x+6} {y-1} C{x+7} {y+5} {x} {y+7} {x-3} {y+3} '
            f'C{x-5} {y} {x-1} {y-4} {x+2} {y-2} C{x+4} {y} {x+1} {y+3} {x} {y+1}" fill="none" {st} stroke-width="1.8"/>')
    return out

def calendar(ink=INK, paper="white", band=PETAL, dot=MID):
    """A little desk calendar: rounded page, two binder rings, a soft top band and a heart on the grid."""
    st = f'stroke="{ink}" stroke-linejoin="round" stroke-linecap="round"'
    out = f'<rect x="6" y="9" width="36" height="33" rx="7" fill="{paper}" {st} stroke-width="2.4"/>'
    out += f'<path d="M6 16 C6 12 9 9 13 9 L35 9 C39 9 42 12 42 16 L42 19 L6 19 Z" fill="{band}" {st} stroke-width="2.4"/>'
    for x in (16, 32):
        out += f'<rect x="{x-2}" y="4" width="4" height="9" rx="2" fill="{paper}" {st} stroke-width="2"/>'
    for i, (x, y) in enumerate([(14, 26), (21, 26), (28, 26), (35, 26), (14, 33), (21, 33)]):
        out += f'<circle cx="{x}" cy="{y}" r="1.8" fill="{dot}"/>'
    out += (f'<path d="M31 37.5 C28 35.5 26 33.5 26 31.3 C26 29.8 27.2 28.8 28.5 28.8 C29.6 28.8 30.5 29.5 31 30.4 '
            f'C31.5 29.5 32.4 28.8 33.5 28.8 C34.8 28.8 36 29.8 36 31.3 C36 33.5 34 35.5 31 37.5 Z" fill="{ink}"/>')
    return out

ICONS = {
    "tulip": tulip(), "daisy": daisy(), "sprout": sprout(), "rose": rose(), "bud": bud(),
    "sunflower": sunflower() , "butterfly": butterfly(), "ladybug": ladybug(), "close_flower": close_flower(), "back_flower": back_flower(), "lily": lily(), "rose_bloom": rose_bloom(),
    "rose_bloom_soft": rose_bloom(ink=MID, petal=LIGHT, light="#f6f6f6"),
    "calendar": calendar(), "calendar_soft": calendar(ink=MID, band=LIGHT, dot=LEAF),
}

def bed(w=600, h=90):
    """A little garden bed: soft ground, grass tufts and flowers of different heights."""
    ground = h - 12
    out = f'<path d="M0 {ground} C{w*0.2} {ground-6} {w*0.35} {ground+4} {w*0.5} {ground-2} C{w*0.65} {ground-8} {w*0.8} {ground+3} {w} {ground-3} L{w} {h} L0 {h} Z" fill="{LIGHT}" stroke="{MID}" stroke-width="1.5"/>'
    # grass tufts
    for i in range(0, w, 23):
        gx = i + 6
        out += f'<path d="M{gx-4} {ground+2} L{gx-6} {ground-8} M{gx} {ground+2} L{gx} {ground-11} M{gx+4} {ground+2} L{gx+7} {ground-7}" stroke="{MID}" stroke-width="1.6" stroke-linecap="round" fill="none"/>'
    plants = [(40, "tulip", 0.95), (95, "daisy", 0.8), (150, "sprout", 0.7), (205, "rose", 1.0), (262, "bud", 0.75),
              (318, "sunflower", 1.05), (375, "daisy", 0.85), (430, "tulip", 0.8), (485, "sprout", 0.75), (545, "rose", 0.9)]
    for x, kind, s in plants:
        top = ground + 2 - 48 * s
        out += f'<g transform="translate({x - 24*s:.1f} {top:.1f}) scale({s})">{ICONS[kind]}</g>'
    out += f'<g transform="translate(250 2) scale(0.55)">{butterfly()}</g>'
    return svg(out, w, h)

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, body in ICONS.items():
        with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
            f.write(svg(body))
    with open(os.path.join(OUT, "garden_bed.svg"), "w") as f:
        f.write(bed())
    print("wrote", len(ICONS) + 1, "icons to", os.path.abspath(OUT))
