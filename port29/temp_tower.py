"""Step 1: the temperature tower on Prusa's calibration model, as a
PrusaSlicer 2.9 project. Mirrors com.ripleydynamics.filament-dialin/01_temp_tower.lua.

Geometry comes from PrusaSlicer's own calibration plugin (assets/prusa): a
80 x 10 x 1 mm base and 80 x 10 x 10 mm steps with bridge and overhang
features. Each step is one temperature band. Measured from the STL, the front
face (y = -5) is flat at x = -25.72..-5.72 (labels) and x = 20..30 (printer
tag); the overhang cut-out starts at x = 30, so the tag is kept inside
20.5..29.5.
"""

from . import assets
from . import geometry as g
from . import tower
from .common import SOLID_PARAMS, data_line, fmt, join, log, range_values
from .threemf import MODEL_PART, NEGATIVE_VOLUME, Object3mf, Project, Volume

BASE_STL = "assets/prusa/temp_tower-base.stl"
STEP_STL = "assets/prusa/temp_tower-step.stl"
LABEL_X, TAG_X = -16, 25
DATA_KEYS = ("tag", "values", "sections", "section_height", "solid", "layer_height")


def build_temp_tower(max_temp=260, min_temp=235, by_interval=True, interval=5, sections=6,
                     solid=True, tag="printer", layer_height=0.2, bed=(250.0, 210.0)):
    lh = float(layer_height)
    if not lh > 0:
        raise ValueError("layer height must be positive")
    temps, _ = range_values(min_temp, max_temp, by_interval=by_interval, interval=interval,
                            count=sections, integer=True, max_count=20)
    for t in temps:
        if not (150 <= t <= 350):
            raise ValueError(f"Temperature out of range: {t}")
    # hottest at the bottom: descending order
    temps.sort(reverse=True)
    n = len(temps)

    base = assets.load_stl(BASE_STL)
    bb = base.bounds()
    base_h = bb[5] - bb[2]
    step = assets.load_stl(STEP_STL)
    sb = step.bounds()
    step_h = sb[5] - sb[2]
    if not (base_h > 0 and step_h > 0):
        raise ValueError("Prusa calibration models did not load")
    front_y = min(bb[1], sb[1])

    project = Project(f"Dial-in temperature tower {tag}")
    # the base carries the object's translate (z = -bb.min_z): it lands on the bed
    volumes = [Volume(base.translate(0, 0, -bb[2]), MODEL_PART, "base")]
    for i, t in enumerate(temps):
        z0 = base_h + i * step_h
        volumes.append(Volume(step.copy().translate(0, 0, z0 - sb[2]), MODEL_PART, f"step {t} C"))
        project.add_custom_gcode(tower.gcode_z(z0, lh), f"M104 S{t}")
        volumes.append(Volume(g.label_front(str(t), LABEL_X, z0 + 4, front_y, 4.5, 20, 6),
                              NEGATIVE_VOLUME, f"label {t}"))
    volumes.append(Volume(g.label_front(tag, TAG_X, base_h + 4, front_y, 3.5, 9, 6),
                          NEGATIVE_VOLUME, "tag"))

    obj = Object3mf(f"Temp tower {tag}", volumes, SOLID_PARAMS if solid else {})
    b = obj.bounds()
    bw, bd = bed
    obj.position = (bw / 2 - (b[0] + b[3]) / 2, bd / 2 - (b[1] + b[4]) / 2)
    project.add_object(obj)

    info = {"tag": tag, "values": join(temps, 0), "sections": n, "section_height": step_h,
            "solid": bool(solid), "layer_height": lh, "temps": temps,
            "total_height": base_h + n * step_h, "base_height": base_h}
    return project, info


def report(info):
    temps = info["temps"]
    log(f"temperature tower for {info['tag']}: {info['sections']} bands of {fmt(info['section_height'])} mm, "
        f"{temps[0]} C (bottom) to {temps[-1]} C (top), layer {fmt(info['layer_height'], 3)} mm")
    log("the base prints at the preset temperature; each M104 lands on its band's first layer; "
        "bridges and overhangs are Prusa's calibration model")
    log("open the .3mf in PrusaSlicer 2.9 (File > Import > Import 3MF, or double-click); the per-layer "
        "temperature changes travel with the project"
        + ("; the object is set to 100% rectilinear infill" if info["solid"] else ""))
    print(data_line("temp", {k: info[k] for k in DATA_KEYS}))


def add_cli(sub, common):
    p = sub.add_parser("temp", parents=[common], help="Step 1: temperature tower on Prusa's calibration model")
    p.add_argument("--max-temp", type=float, default=260, help="hottest section [C] (printed first, at the bottom)")
    p.add_argument("--min-temp", type=float, default=235, help="coolest section [C] (top)")
    p.add_argument("--by-count", action="store_true", help="choose by number of sections instead of by interval")
    p.add_argument("--interval", type=float, default=5, help="interval [C]")
    p.add_argument("--sections", type=float, default=6, help="number of sections (with --by-count)")
    p.add_argument("--no-solid", action="store_true", help="keep the preset's infill instead of 100%%")
    p.add_argument("--tag", default="printer", help="printer tag engraved on the base")
    p.add_argument("--layer-height", type=float, default=0.2, help="layer height [mm] the project will be sliced at")
    p.set_defaults(run=run)


def run(args):
    project, info = build_temp_tower(args.max_temp, args.min_temp, not args.by_count, args.interval,
                                     args.sections, not args.no_solid, args.tag,
                                     layer_height=args.layer_height, bed=args.bed)
    out = args.output or f"dialin-01-temp-{args.tag.replace(' ', '_')}.3mf"
    project.write(out)
    report(info)
    log(f"wrote {out}")
    return out
