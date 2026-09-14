"""Minimal writer for PrusaSlicer 2.9.x 3MF project files.

Layout, as PrusaSlicer 2.9.6 writes and reads it (src/libslic3r/Format/3mf.cpp):

  [Content_Types].xml
  _rels/.rels                                   -> 3D/3dmodel.model
  3D/3dmodel.model                              one <object> per part, all of
                                                its volumes concatenated into
                                                one <mesh>; <build><item> per
                                                instance with its transform
  Metadata/Slic3r_PE_model.config               per-object settings, and per
                                                volume: the triangle range
                                                (firstid/lastid), name,
                                                volume_type (ModelPart,
                                                NegativeVolume,
                                                ParameterModifier), matrix and
                                                settings
  Metadata/Prusa_Slicer_custom_gcode_per_print_z.xml
                                                <code print_z type extruder
                                                color extra gcode/> entries;
                                                type 4 = custom G-code

Meshes are written in object coordinates with identity volume matrices, the
same as PrusaSlicer itself does, so nothing depends on how a reader applies
matrices. The importer flips a mesh whose signed volume is negative, but the
primitives here are built with outward-facing triangles anyway.
"""

import math
import zipfile
from xml.sax.saxutils import escape, quoteattr

MODEL_PART, NEGATIVE_VOLUME, MODIFIER = "ModelPart", "NegativeVolume", "ParameterModifier"
GCODE_CUSTOM = 4  # CustomGCode::Type::Custom


def fmt(v):
    """Compact number formatting for XML: no trailing zeros, no '-0'."""
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


class Mesh:
    """Indexed triangle mesh. Vertices are [x, y, z] lists; triangles are
    (i, j, k) with outward-facing counter-clockwise winding."""

    def __init__(self, vertices=None, triangles=None):
        self.vertices = [list(v) for v in (vertices or [])]
        self.triangles = [tuple(t) for t in (triangles or [])]

    def copy(self):
        return Mesh(self.vertices, self.triangles)

    def bounds(self):
        xs = [v[0] for v in self.vertices]
        ys = [v[1] for v in self.vertices]
        zs = [v[2] for v in self.vertices]
        return (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))

    def translate(self, dx=0.0, dy=0.0, dz=0.0):
        for v in self.vertices:
            v[0] += dx
            v[1] += dy
            v[2] += dz
        return self

    def scale(self, sx, sy=None, sz=None):
        sy = sx if sy is None else sy
        sz = sx if sz is None else sz
        for v in self.vertices:
            v[0] *= sx
            v[1] *= sy
            v[2] *= sz
        return self

    def rotate_x(self, degrees):
        c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
        for v in self.vertices:
            y, z = v[1], v[2]
            v[1], v[2] = c * y - s * z, s * y + c * z
        return self

    def rotate_y(self, degrees):
        c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
        for v in self.vertices:
            x, z = v[0], v[2]
            v[0], v[2] = c * x + s * z, -s * x + c * z
        return self

    def rotate_z(self, degrees):
        c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
        for v in self.vertices:
            x, y = v[0], v[1]
            v[0], v[1] = c * x - s * y, s * x + c * y
        return self

    def append(self, other):
        base = len(self.vertices)
        self.vertices.extend(list(v) for v in other.vertices)
        self.triangles.extend((a + base, b + base, c + base) for a, b, c in other.triangles)
        return self

    def signed_volume(self):
        total = 0.0
        for a, b, c in self.triangles:
            p, q, r = self.vertices[a], self.vertices[b], self.vertices[c]
            total += (p[0] * (q[1] * r[2] - q[2] * r[1])
                      - p[1] * (q[0] * r[2] - q[2] * r[0])
                      + p[2] * (q[0] * r[1] - q[1] * r[0]))
        return total / 6.0

    def is_closed(self):
        """Every directed edge has exactly one opposite twin."""
        edges = {}
        for a, b, c in self.triangles:
            for e in ((a, b), (b, c), (c, a)):
                edges[e] = edges.get(e, 0) + 1
        return all(n == 1 and edges.get((b, a), 0) == 1 for (a, b), n in edges.items())


class Volume:
    def __init__(self, mesh, vtype=MODEL_PART, name="", config=None):
        self.mesh = mesh
        self.vtype = vtype
        self.name = name
        self.config = dict(config or {})


class Object3mf:
    """One printable object: volumes in object coordinates, placed on the bed
    by `position` (x, y of the object origin; z is kept, the object should
    already sit at z >= 0)."""

    def __init__(self, name, volumes=None, config=None, position=(0.0, 0.0)):
        self.name = name
        self.volumes = list(volumes or [])
        self.config = dict(config or {})
        self.position = tuple(position)

    def bounds(self):
        b = None
        for v in self.volumes:
            if v.vtype != MODEL_PART:
                continue
            vb = v.mesh.bounds()
            b = vb if b is None else (min(b[0], vb[0]), min(b[1], vb[1]), min(b[2], vb[2]),
                                      max(b[3], vb[3]), max(b[4], vb[4]), max(b[5], vb[5]))
        return b


class Project:
    def __init__(self, title="Filament Dial-In"):
        self.title = title
        self.objects = []
        self.custom_gcodes = []  # (print_z, gcode)

    def add_object(self, obj):
        self.objects.append(obj)
        return obj

    def add_custom_gcode(self, print_z, gcode):
        self.custom_gcodes.append((float(print_z), gcode))

    # -- writing -------------------------------------------------------------
    def model_xml(self):
        out = ['<?xml version="1.0" encoding="UTF-8"?>',
               '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:slic3rpe="http://schemas.slic3r.org/3mf/2017/06">',
               ' <metadata name="slic3rpe:Version3mf">1</metadata>',
               f' <metadata name="Title">{escape(self.title)}</metadata>',
               ' <metadata name="Application">Filament Dial-In (port29)</metadata>',
               ' <resources>']
        items = []
        for idx, obj in enumerate(self.objects, start=1):
            merged = Mesh()
            for v in obj.volumes:
                merged.append(v.mesh)
            out.append(f'  <object id="{idx}" type="model">')
            out.append('   <mesh>')
            out.append('    <vertices>')
            for x, y, z in merged.vertices:
                out.append(f'     <vertex x="{fmt(x)}" y="{fmt(y)}" z="{fmt(z)}"/>')
            out.append('    </vertices>')
            out.append('    <triangles>')
            for a, b, c in merged.triangles:
                out.append(f'     <triangle v1="{a}" v2="{b}" v3="{c}"/>')
            out.append('    </triangles>')
            out.append('   </mesh>')
            out.append('  </object>')
            px, py = obj.position
            items.append(f'  <item objectid="{idx}" transform="1 0 0 0 1 0 0 0 1 {fmt(px)} {fmt(py)} 0" printable="1"/>')
        out.append(' </resources>')
        out.append(' <build>')
        out.extend(items)
        out.append(' </build>')
        out.append('</model>')
        return "\n".join(out) + "\n"

    def model_config_xml(self):
        out = ['<?xml version="1.0" encoding="UTF-8"?>', '<config>']
        for idx, obj in enumerate(self.objects, start=1):
            out.append(f' <object id="{idx}" instances_count="1">')
            out.append(f'  <metadata type="object" key="name" value={quoteattr(obj.name)}/>')
            for k, v in obj.config.items():
                out.append(f'  <metadata type="object" key={quoteattr(k)} value={quoteattr(str(v))}/>')
            first = 0
            for n, vol in enumerate(obj.volumes, start=1):
                last = first + len(vol.mesh.triangles) - 1
                out.append(f'  <volume firstid="{first}" lastid="{last}">')
                out.append(f'   <metadata type="volume" key="name" value={quoteattr(vol.name or f"{obj.name} {n}")}/>')
                if vol.vtype == MODIFIER:
                    out.append('   <metadata type="volume" key="modifier" value="1"/>')
                out.append(f'   <metadata type="volume" key="volume_type" value="{vol.vtype}"/>')
                out.append('   <metadata type="volume" key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>')
                out.append('   <metadata type="volume" key="source_is_builtin_volume" value="1"/>')
                for k, v in vol.config.items():
                    out.append(f'   <metadata type="volume" key={quoteattr(k)} value={quoteattr(str(v))}/>')
                out.append(f'   <mesh edges_fixed="0" degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>')
                out.append('  </volume>')
                first = last + 1
            out.append(' </object>')
        out.append('</config>')
        return "\n".join(out) + "\n"

    def custom_gcode_xml(self):
        out = ['<?xml version="1.0" encoding="UTF-8"?>', '<custom_gcodes_per_print_z bed_idx="0">']
        for z, g in sorted(self.custom_gcodes):
            out.append(f' <code print_z="{fmt(z)}" type="{GCODE_CUSTOM}" extruder="1" color="" extra={quoteattr(g)} gcode={quoteattr(g)}/>')
        out.append(' <mode value="SingleExtruder"/>')
        out.append('</custom_gcodes_per_print_z>')
        return "\n".join(out) + "\n"

    def write(self, path):
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("[Content_Types].xml",
                       '<?xml version="1.0" encoding="UTF-8"?>\n'
                       '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
                       ' <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
                       ' <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\n'
                       '</Types>')
            z.writestr("_rels/.rels",
                       '<?xml version="1.0" encoding="UTF-8"?>\n'
                       '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
                       ' <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\n'
                       '</Relationships>')
            z.writestr("3D/3dmodel.model", self.model_xml())
            z.writestr("Metadata/Slic3r_PE_model.config", self.model_config_xml())
            if self.custom_gcodes:
                z.writestr("Metadata/Prusa_Slicer_custom_gcode_per_print_z.xml", self.custom_gcode_xml())
        return path
