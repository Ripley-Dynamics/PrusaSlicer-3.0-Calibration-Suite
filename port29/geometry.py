"""Primitives and engraved text for the 2.9 port, all as closed meshes with
outward-facing triangles.

Text: PrusaSlicer 2.9 has no text API a file can call, and a 3MF must carry
the text mesh itself, so labels are drawn with a stroke font: each glyph is a
few polylines on a 4 x 7 grid, every segment becomes a small box, the whole
label lies in the XY plane and is 1 mm thick toward +Z, centred on the origin
(the same conventions as the plugin's emboss_text, so lib/label.lua's
placement maths carries over unchanged).
"""

import math

from .threemf import Mesh


def prism(poly, z0, z1):
    """Extrude a counter-clockwise XY polygon (list of (x, y)) from z0 to z1."""
    n = len(poly)
    m = Mesh()
    for x, y in poly:
        m.vertices.append([x, y, z0])
    for x, y in poly:
        m.vertices.append([x, y, z1])
    # bottom (normal -Z): reversed winding; top (normal +Z): as given
    for i in range(1, n - 1):
        m.triangles.append((0, i + 1, i))
        m.triangles.append((n, n + i, n + i + 1))
    for i in range(n):
        j = (i + 1) % n
        m.triangles.append((i, j, n + j))
        m.triangles.append((i, n + j, n + i))
    return m


def box(w, d, h):
    """w along X, d along Y, h along Z, corner at the origin (api.make_cube)."""
    return prism([(0, 0), (w, 0), (w, d), (0, d)], 0, h)


def regular_polygon(r, n, cx=0.0, cy=0.0):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def cylinder(r, h, n=64):
    """Axis along Z, base centred on the origin (api.make_cylinder)."""
    return prism(regular_polygon(r, n), 0, h)


def cone(r, h, n=64):
    poly = regular_polygon(r, n)
    m = Mesh()
    for x, y in poly:
        m.vertices.append([x, y, 0.0])
    apex = len(m.vertices)
    m.vertices.append([0.0, 0.0, h])
    for i in range(1, n - 1):
        m.triangles.append((0, i + 1, i))
    for i in range(n):
        m.triangles.append((i, (i + 1) % n, apex))
    return m


def pyramid(base, h):
    """Square pyramid, base `base` x `base` with a corner at the origin."""
    m = Mesh()
    m.vertices = [[0, 0, 0], [base, 0, 0], [base, base, 0], [0, base, 0], [base / 2, base / 2, h]]
    m.triangles = [(0, 2, 1), (0, 3, 2), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)]
    return m


# --- stroke font -------------------------------------------------------------
# Glyphs on a 4-wide, 7-tall grid, y up. Each glyph: list of polylines.
GLYPH_W, GLYPH_H, GLYPH_GAP = 4.0, 7.0, 1.5
_O = [[(1, 0), (3, 0), (4, 1), (4, 6), (3, 7), (1, 7), (0, 6), (0, 1), (1, 0)]]
_P = [[(0, 0), (0, 7), (3, 7), (4, 6), (4, 4), (3, 3), (0, 3)]]
GLYPHS = {
    "0": [[(0, 0), (4, 0), (4, 7), (0, 7), (0, 0)], [(0, 0.5), (4, 6.5)]],
    "1": [[(0.5, 5.5), (2, 7), (2, 0)], [(0.5, 0), (3.5, 0)]],
    "2": [[(0, 6), (1, 7), (3, 7), (4, 6), (4, 4.5), (0, 0), (4, 0)]],
    "3": [[(0, 7), (4, 7), (2, 4.2), (3, 4.2), (4, 3.2), (4, 1), (3, 0), (1, 0), (0, 1)]],
    "4": [[(3, 0), (3, 7), (0, 2.5), (4, 2.5)]],
    "5": [[(4, 7), (0, 7), (0, 4), (3, 4), (4, 3), (4, 1), (3, 0), (0, 0)]],
    "6": [[(3.5, 7), (1, 7), (0, 6), (0, 1), (1, 0), (3, 0), (4, 1), (4, 3), (3, 4), (0, 4)]],
    "7": [[(0, 7), (4, 7), (1.5, 0)]],
    "8": [[(1, 3.5), (0, 4.5), (0, 6), (1, 7), (3, 7), (4, 6), (4, 4.5), (3, 3.5), (1, 3.5), (0, 2.5), (0, 1), (1, 0), (3, 0), (4, 1), (4, 2.5), (3, 3.5)]],
    "9": [[(0.5, 0), (3, 0), (4, 1), (4, 6), (3, 7), (1, 7), (0, 6), (0, 4), (1, 3), (4, 3)]],
    ".": [[(0.5, 0), (1.5, 0)]],
    ",": [[(1.5, 0.8), (0.5, -0.8)]],
    "-": [[(0.5, 3.5), (3.5, 3.5)]],
    "+": [[(0.5, 3.5), (3.5, 3.5)], [(2, 5), (2, 2)]],
    "/": [[(0, 0), (4, 7)]],
    ":": [[(2, 1), (2, 1.6)], [(2, 4.4), (2, 5)]],
    "%": [[(0, 0), (4, 7)], [(0, 7), (1, 7), (1, 6), (0, 6), (0, 7)], [(3, 1), (4, 1), (4, 0), (3, 0), (3, 1)]],
    "A": [[(0, 0), (0, 4.5), (2, 7), (4, 4.5), (4, 0)], [(0, 2.5), (4, 2.5)]],
    "B": [[(0, 0), (0, 7), (3, 7), (4, 6), (4, 4.5), (3, 3.5), (0, 3.5)], [(3, 3.5), (4, 2.5), (4, 1), (3, 0), (0, 0)]],
    "C": [[(4, 6), (3, 7), (1, 7), (0, 6), (0, 1), (1, 0), (3, 0), (4, 1)]],
    "D": [[(0, 0), (0, 7), (3, 7), (4, 6), (4, 1), (3, 0), (0, 0)]],
    "E": [[(4, 7), (0, 7), (0, 0), (4, 0)], [(0, 3.5), (3, 3.5)]],
    "F": [[(4, 7), (0, 7), (0, 0)], [(0, 3.5), (3, 3.5)]],
    "G": [[(4, 6), (3, 7), (1, 7), (0, 6), (0, 1), (1, 0), (3, 0), (4, 1), (4, 3), (2, 3)]],
    "H": [[(0, 0), (0, 7)], [(4, 0), (4, 7)], [(0, 3.5), (4, 3.5)]],
    "I": [[(1, 7), (3, 7)], [(2, 7), (2, 0)], [(1, 0), (3, 0)]],
    "J": [[(1, 7), (4, 7)], [(3, 7), (3, 1), (2, 0), (1, 0), (0, 1)]],
    "K": [[(0, 0), (0, 7)], [(4, 7), (0, 3), (4, 0)]],
    "L": [[(0, 7), (0, 0), (4, 0)]],
    "M": [[(0, 0), (0, 7), (2, 4), (4, 7), (4, 0)]],
    "N": [[(0, 0), (0, 7), (4, 0), (4, 7)]],
    "O": _O,
    "P": _P,
    "Q": _O + [[(2.5, 1.5), (4.2, -0.3)]],
    "R": _P + [[(2, 3), (4, 0)]],
    "S": [[(4, 6), (3, 7), (1, 7), (0, 6), (0, 4.5), (1, 3.5), (3, 3.5), (4, 2.5), (4, 1), (3, 0), (1, 0), (0, 1)]],
    "T": [[(0, 7), (4, 7)], [(2, 7), (2, 0)]],
    "U": [[(0, 7), (0, 1), (1, 0), (3, 0), (4, 1), (4, 7)]],
    "V": [[(0, 7), (2, 0), (4, 7)]],
    "W": [[(0, 7), (1, 0), (2, 4), (3, 0), (4, 7)]],
    "X": [[(0, 0), (4, 7)], [(0, 7), (4, 0)]],
    "Y": [[(0, 7), (2, 3.5), (4, 7)], [(2, 3.5), (2, 0)]],
    "Z": [[(0, 7), (4, 7), (0, 0), (4, 0)]],
}
NARROW = {".": 2.0, ",": 2.0, ":": 2.0, "I": 4.0, "1": 4.0, " ": 2.5}


def glyph_advance(ch):
    return NARROW.get(ch, GLYPH_W) + GLYPH_GAP


def _segment_box(p, q, t, z1):
    dx, dy = q[0] - p[0], q[1] - p[1]
    length = math.hypot(dx, dy)
    if length < 1e-9:
        dx, dy, length = 1.0, 0.0, 1.0
    ux, uy = dx / length, dy / length
    nx, ny = -uy * t / 2, ux * t / 2
    ex, ey = ux * t / 2, uy * t / 2  # square caps, so joints close
    poly = [(p[0] - ex - nx, p[1] - ey - ny), (q[0] + ex - nx, q[1] + ey - ny),
            (q[0] + ex + nx, q[1] + ey + ny), (p[0] - ex + nx, p[1] - ey + ny)]
    return prism(poly, 0.0, z1)


def text_width_units(text):
    return sum(glyph_advance(ch) for ch in text.upper()) - GLYPH_GAP if text else 0.0


def stroke_text(text, line_height, thickness=None, depth=1.0):
    """Text mesh in the XY plane, `line_height` mm tall (cap height), 1 mm thick
    toward +Z, centred on the origin. Unknown characters take a space."""
    text = str(text)
    scale = line_height / GLYPH_H
    t = thickness if thickness is not None else max(0.45, line_height * 0.14)
    mesh = Mesh()
    x = 0.0
    for ch in text.upper():
        for poly in GLYPHS.get(ch, []):
            for i in range(len(poly) - 1):
                p = (x + poly[i][0] * scale, poly[i][1] * scale)
                q = (x + poly[i + 1][0] * scale, poly[i + 1][1] * scale)
                mesh.append(_segment_box(p, q, t, depth))
        x += glyph_advance(ch) * scale
    if mesh.vertices:
        b = mesh.bounds()
        mesh.translate(-(b[0] + b[3]) / 2, -(b[1] + b[4]) / 2, 0.0)
    return mesh


def text_mesh(text, line_height, max_width=None, max_height=None):
    """Like lib/label.lua's text_mesh: shrink the line height so the label fits
    inside max_width x max_height. Returns (mesh, line_height, width, height)."""
    mesh = stroke_text(text, line_height)
    if not mesh.vertices:
        return mesh, line_height, 0.0, 0.0
    b = mesh.bounds()
    w, h = b[3] - b[0], b[4] - b[1]
    scale = 1.0
    if max_width and w > max_width:
        scale = min(scale, max_width / w)
    if max_height and h > max_height:
        scale = min(scale, max_height / h)
    if scale < 1.0:
        line_height = line_height * scale * 0.97
        mesh = stroke_text(text, line_height)
        b = mesh.bounds()
        w, h = b[3] - b[0], b[4] - b[1]
    return mesh, line_height, w, h


LABEL_DEPTH = 0.6  # mm the negative volume sinks into the part


def label_front(text, x, z, face_y, line_height, max_width=None, max_height=None, depth=LABEL_DEPTH):
    """Engraving on the face whose outward normal is -Y (lib/label.lua front)."""
    mesh, _, _, _ = text_mesh(text, line_height, max_width, max_height)
    mesh.rotate_x(90).translate(x, face_y + depth, z)
    return mesh


def label_back(text, x, z, face_y, line_height, max_width=None, max_height=None, depth=LABEL_DEPTH):
    """Engraving on the +Y face, readable from behind (rotate X 90 then Z 180)."""
    mesh, _, _, _ = text_mesh(text, line_height, max_width, max_height)
    mesh.rotate_x(90).rotate_z(180).translate(x, face_y - depth, z)
    return mesh


def label_top(text, x, y, top_z, line_height, max_width=None, max_height=None, depth=LABEL_DEPTH):
    mesh, _, _, _ = text_mesh(text, line_height, max_width, max_height)
    mesh.translate(x, y, top_z - depth)
    return mesh
