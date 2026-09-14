"""Stacked-section tower builder, port of lib/tower.lua."""

import math

from . import geometry as g
from .common import align
from .threemf import MODEL_PART, MODIFIER, NEGATIVE_VOLUME, Object3mf, Volume

MODIFIER_MARGIN = 2


def gcode_z(z0, layer_height):
    """Half a layer above the section start: lands on its first layer."""
    return z0 + layer_height * 0.5


def label_line_height(section_h):
    return max(2.5, min(7.0, section_h * 0.55))


def build(project, spec):
    """spec keys: width, depth, base_height, section_height, layer_height,
    sections (list of dicts with optional label, gcode, params), tag, extra_x,
    name. Adds the custom G-code to `project`; returns (Object3mf, dims) where
    dims has total_height, section_height, base_height, section_z."""
    sections = spec["sections"]
    if not sections:
        raise ValueError("a tower needs at least one section")
    lh = spec["layer_height"]
    w, d = float(spec["width"]), float(spec["depth"])
    section_h = align(spec["section_height"], lh, 2)
    base_h = align(spec["base_height"], lh, 1) if spec.get("base_height", 0) > 0 else 0.0
    total = base_h + len(sections) * section_h
    margin, extra_x = MODIFIER_MARGIN, spec.get("extra_x", 0)

    volumes = [Volume(g.box(w, d, total), MODEL_PART, spec.get("name", "tower"))]
    section_z = []
    for i, s in enumerate(sections):
        z0 = base_h + i * section_h
        section_z.append(z0)
        if s.get("gcode"):
            project.add_custom_gcode(gcode_z(z0, lh), s["gcode"])
        if s.get("params"):
            volumes.append(Volume(g.box(w + 2 * margin + extra_x, d + 2 * margin, section_h).translate(-margin, -margin, z0),
                                  MODIFIER, f"band {i + 1}", dict(s["params"])))
        if s.get("label"):
            volumes.append(Volume(g.label_front(s["label"], w / 2, z0 + section_h / 2, 0.0, label_line_height(section_h), w - 3, section_h - 1.5),
                                  NEGATIVE_VOLUME, f"label {s['label']}"))
    if spec.get("tag") and base_h >= 3:
        volumes.append(Volume(g.label_back(spec["tag"], w / 2, base_h / 2, d, min(6.0, base_h * 0.6), w - 3, base_h - 1),
                              NEGATIVE_VOLUME, "tag"))
    obj = Object3mf(spec.get("name", "tower"), volumes)
    return obj, {"total_height": total, "section_height": section_h, "base_height": base_h, "section_z": section_z}


def wing(x_face, depth, z0, section_height, angle_deg, thickness=2.0, wing_depth=None):
    """Overhang slab on the +X face, underside at angle_deg from horizontal.
    Returns (Volume, reach in +X)."""
    rad = math.radians(angle_deg)
    rise_available = section_height - 0.5 - thickness * math.cos(rad)
    if not rise_available > 1:
        raise ValueError("section too short for an overhang wing")
    length = rise_available / math.sin(rad)
    wd = wing_depth if wing_depth is not None else depth * 0.6
    mesh = g.box(length, wd, thickness).rotate_y(-angle_deg).translate(x_face, (depth - wd) / 2, z0)
    return Volume(mesh, MODEL_PART, f"wing {angle_deg:g}"), length * math.cos(rad)
