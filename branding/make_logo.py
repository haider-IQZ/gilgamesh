# Builds the Gilgamesh logo: 永 ("eternity", Gilgamesh's quest for immortality)
# in Kaisei Decol Bold, dark on a jellybeans-green rounded square (hanko style).
# The glyph is converted to a plain SVG path, so the logo needs no font installed.
# Kaisei Decol is SIL Open Font License, which allows using its glyphs in a logo.
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

FONT = "fonts/KaiseiDecol-Bold.ttf"   # SIL Open Font License, see fonts/KaiseiDecol-OFL.txt
GREEN, DARK = "#99ad6a", "#151515"
SIZE, RADIUS, GLYPH = 64, 11, 40   # canvas, corner radius, glyph box (same proportions as the draft)

font = TTFont(FONT)
gs = font.getGlyphSet()
glyph = gs[font.getBestCmap()[ord("永")]]

bp = BoundsPen(gs)
glyph.draw(bp)
x0, y0, x1, y1 = bp.bounds
sc = GLYPH / max(x1 - x0, y1 - y0)
w, h = (x1 - x0) * sc, (y1 - y0) * sc
ox = (SIZE - w) / 2 - x0 * sc
oy = (SIZE - h) / 2 + y1 * sc            # font units are y-up, SVG is y-down
pen = SVGPathPen(gs, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
glyph.draw(TransformPen(pen, (sc, 0, 0, -sc, ox, oy)))

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}">\n'
       f'  <rect width="{SIZE}" height="{SIZE}" rx="{RADIUS}" fill="{GREEN}"/>\n'
       f'  <path fill="{DARK}" d="{pen.getCommands()}"/>\n'
       f'</svg>\n')
open("gilgamesh-logo.svg", "w").write(svg)
print("gilgamesh-logo.svg written,", len(svg), "bytes")
