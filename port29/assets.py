"""The bundle's STL and SVG assets as meshes (api.load_stl / api.emboss_svg)."""

import math
import os
import re
import struct

from .threemf import Mesh

BUNDLE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "com.ripleydynamics.filament-dialin")


def asset_path(rel):
    return os.path.join(BUNDLE_DIR, *rel.split("/"))


def load_stl(rel):
    """Binary or ASCII STL -> Mesh, vertices merged by exact coordinate."""
    data = open(asset_path(rel), "rb").read()
    tris = []
    is_ascii = data[:5] == b"solid" and b"facet" in data[:1000]
    if not is_ascii and len(data) >= 84:
        n = struct.unpack("<I", data[80:84])[0]
        if 84 + 50 * n == len(data):
            for i in range(n):
                o = 84 + 50 * i + 12
                tris.append([struct.unpack("<fff", data[o + 12 * k:o + 12 * k + 12]) for k in range(3)])
        else:
            is_ascii = True
    if is_ascii:
        nums = re.findall(rb"vertex\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)", data)
        for i in range(0, len(nums) - 2, 3):
            tris.append([tuple(float(c) for c in nums[i + k]) for k in range(3)])
    index, verts, faces = {}, [], []
    for t in tris:
        ids = []
        for p in t:
            key = (round(p[0], 6), round(p[1], 6), round(p[2], 6))
            if key not in index:
                index[key] = len(verts)
                verts.append([float(key[0]), float(key[1]), float(key[2])])
            ids.append(index[key])
        if len(set(ids)) == 3:
            faces.append(tuple(ids))
    return Mesh(verts, faces)


# --- SVG outline -> extruded mesh ---------------------------------------------
_TOKEN = re.compile(r"[MmLlHhVvCcZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def svg_path_polygon(d, tolerance=0.05):
    """Flatten one closed SVG path (M/L/H/V/C/Z, absolute or relative) into a
    list of (x, y). Cubic curves are subdivided until flat within tolerance."""
    tokens = _TOKEN.findall(d)
    pts, i, cmd = [], 0, None
    cur, start = (0.0, 0.0), (0.0, 0.0)

    def num():
        nonlocal i
        v = float(tokens[i]); i += 1
        return v

    def bezier(p0, p1, p2, p3):
        n = max(4, int(math.ceil(math.dist(p0, p1) + math.dist(p1, p2) + math.dist(p2, p3)) / tolerance ** 0.5))
        n = min(n, 64)
        for k in range(1, n + 1):
            t = k / n
            u = 1 - t
            pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                        u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))

    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]; i += 1
            if cmd in "Zz":
                cur = start
                continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            x, y = num(), num()
            cur = (cur[0] + x, cur[1] + y) if rel and pts else (x, y)
            start = cur
            pts.append(cur)
            cmd = "l" if rel else "L"
        elif c == "L":
            x, y = num(), num()
            cur = (cur[0] + x, cur[1] + y) if rel else (x, y)
            pts.append(cur)
        elif c == "H":
            x = num()
            cur = (cur[0] + x if rel else x, cur[1])
            pts.append(cur)
        elif c == "V":
            y = num()
            cur = (cur[0], cur[1] + y if rel else y)
            pts.append(cur)
        elif c == "C":
            c1 = (num(), num()); c2 = (num(), num()); end = (num(), num())
            if rel:
                c1 = (cur[0] + c1[0], cur[1] + c1[1]); c2 = (cur[0] + c2[0], cur[1] + c2[1]); end = (cur[0] + end[0], cur[1] + end[1])
            bezier(cur, c1, c2, end)
            cur = end
        else:
            raise ValueError(f"unsupported SVG path command {cmd}")
    # drop duplicate consecutive points and a closing repeat
    out = []
    for p in pts:
        if not out or math.dist(out[-1], p) > 1e-6:
            out.append(p)
    if len(out) > 1 and math.dist(out[0], out[-1]) < 1e-6:
        out.pop()
    return out


def polygon_area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly))) / 2


def triangulate(poly):
    """Ear clipping for a simple polygon (no holes). Returns index triples,
    counter-clockwise."""
    n = len(poly)
    idx = list(range(n))
    if polygon_area(poly) < 0:
        idx.reverse()
    tris = []

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    def inside(p, a, b, c):
        return cross(a, b, p) >= -1e-12 and cross(b, c, p) >= -1e-12 and cross(c, a, p) >= -1e-12

    guard = 0
    while len(idx) > 3 and guard < 10 * n:
        guard += 1
        m = len(idx)
        for k in range(m):
            ia, ib, ic = idx[(k - 1) % m], idx[k], idx[(k + 1) % m]
            a, b, c = poly[ia], poly[ib], poly[ic]
            if cross(a, b, c) <= 1e-12:
                continue  # reflex or degenerate
            if any(inside(poly[j], a, b, c) for j in idx if j not in (ia, ib, ic)):
                continue
            tris.append((ia, ib, ic))
            del idx[k]
            break
        else:
            # no ear found (numerical trouble): clip the least-bad vertex
            k = max(range(m), key=lambda k: cross(poly[idx[(k - 1) % m]], poly[idx[k]], poly[idx[(k + 1) % m]]))
            tris.append((idx[(k - 1) % m], idx[k], idx[(k + 1) % m]))
            del idx[k]
    if len(idx) == 3:
        tris.append(tuple(idx))
    return tris


def extrude_polygon(poly, height, z0=0.0):
    """Closed mesh from a simple polygon extruded along +Z."""
    if polygon_area(poly) < 0:
        poly = list(reversed(poly))
    n = len(poly)
    m = Mesh()
    for x, y in poly:
        m.vertices.append([x, y, z0])
    for x, y in poly:
        m.vertices.append([x, y, z0 + height])
    for a, b, c in triangulate(poly):
        m.triangles.append((a, c, b))
        m.triangles.append((n + a, n + b, n + c))
    for i in range(n):
        j = (i + 1) % n
        m.triangles.append((i, j, n + j))
        m.triangles.append((i, n + j, n + i))
    return m


def emboss_svg(rel, height):
    """api.emboss_svg: the SVG's single path, in mm (viewBox units), extruded
    to `height`, Y flipped so +Y in the SVG (down) becomes -Y (front). The
    result is centred on X/Y and starts at z = 0."""
    text = open(asset_path(rel), encoding="utf-8").read()
    d = re.search(r'\sd="([^"]+)"', text, re.S).group(1)
    poly = svg_path_polygon(d)
    poly = [(x, -y) for x, y in poly]
    mesh = extrude_polygon(poly, height)
    b = mesh.bounds()
    mesh.translate(-(b[0] + b[3]) / 2, -(b[1] + b[4]) / 2, 0.0)
    return mesh
