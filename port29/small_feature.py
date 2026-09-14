"""Step 10: the small-feature tower, as a PrusaSlicer 2.9 project.
Mirrors com.ripleydynamics.filament-dialin/10_small_feature_tower.lua.

As the pyramid and cone narrow, layer time falls until the slicer's "slow down
below layer time" and fan rules take over; PETG tips that melt, round off or
drag show that those settings need more time or more fan on this printer. The
pillars are constant short layers at three sizes.
"""

from . import geometry as g
from .common import SOLID_PARAMS, align, data_line, fmt, log
from .threemf import MODEL_PART, NEGATIVE_VOLUME, Object3mf, Project, Volume

PILLAR_SIZES = (3, 5, 8)
PLATE_H = 2

DATA_KEYS = ("tag", "height", "pyramid_base", "cone_diameter", "pillars", "slowdown", "min_print_speed")


def build_small(height=40, pyramid_base=20, cone_diameter=16, pillars=True, tag="printer",
                layer_height=0.2, bed=(250.0, 210.0), slowdown=None, min_print_speed=None):
    H, base, cone_d = float(height), float(pyramid_base), float(cone_diameter)
    if not (H >= 15 and base >= 8 and cone_d >= 6):
        raise ValueError("Height >= 15 mm, pyramid base >= 8 mm, cone >= 6 mm")
    lh = float(layer_height)
    plate_h = align(PLATE_H, lh, 2)
    gap = 8
    x = gap
    volumes = []

    # pyramid: geometry.pyramid is centred on X/Y with its base at Z 0
    volumes.append(Volume(g.pyramid(base, H).translate(x + base / 2, gap + base / 2, plate_h), MODEL_PART, "pyramid"))
    x = x + base + gap
    volumes.append(Volume(g.cone(cone_d / 2, H).translate(x + cone_d / 2, gap + base / 2, plate_h), MODEL_PART, "cone"))
    x = x + cone_d + gap
    if pillars:
        for d in PILLAR_SIZES:
            volumes.append(Volume(g.cylinder(d / 2, H).translate(x + d / 2, gap + base / 2, plate_h),
                                  MODEL_PART, f"pillar {d}"))
            x = x + d + gap
    plate_w, plate_d = x, base + 2 * gap
    volumes.append(Volume(g.label_front(tag, plate_w / 2, plate_h / 2, 0.0, min(2.5, plate_h * 0.6),
                                        plate_w - 4, plate_h - 0.6), NEGATIVE_VOLUME, "tag"))

    volumes.insert(0, Volume(g.box(plate_w, plate_d, plate_h), MODEL_PART, "plate"))
    obj = Object3mf(f"Small-feature tower {tag}", volumes, SOLID_PARAMS)
    b = obj.bounds()
    obj.position = (bed[0] / 2 - (b[0] + b[3]) / 2, bed[1] / 2 - (b[1] + b[4]) / 2)
    project = Project(f"Dial-in small-feature tower {tag}")
    project.add_object(obj)

    info = {"tag": tag, "height": H, "pyramid_base": base, "cone_diameter": cone_d, "pillars": bool(pillars),
            "slowdown": 0 if slowdown is None else float(slowdown),
            "min_print_speed": 0 if min_print_speed is None else float(min_print_speed),
            "slowdown_read": None if slowdown is None else float(slowdown),
            "min_print_speed_read": None if min_print_speed is None else float(min_print_speed),
            "plate_h": plate_h, "plate_w": plate_w, "plate_d": plate_d}
    return project, info


def report(info):
    slow, minspeed = info["slowdown_read"], info["min_print_speed_read"]
    log(f"small-feature tower for {info['tag']}: {fmt(info['height'])} mm tall pyramid ({fmt(info['pyramid_base'])} base), "
        f"cone ({fmt(info['cone_diameter'])}), pillars {'3/5/8 mm' if info['pillars'] else 'none'}; "
        f"preset slows layers under {fmt(slow, 0) if slow is not None else '?'} s down to "
        f"{fmt(minspeed, 0) if minspeed is not None else '?'} mm/s")
    log("tips that melt, round off or get dragged mean the layer-time slowdown or fan needs more on this printer; "
        "note the height where each feature degrades")
    print(data_line("small", {k: info[k] for k in DATA_KEYS}))


def add_cli(sub, common):
    p = sub.add_parser("small", parents=[common], help="Step 10: small-feature tower")
    p.add_argument("--height", type=float, default=40, help="feature height [mm]")
    p.add_argument("--pyramid-base", type=float, default=20, help="pyramid base [mm]")
    p.add_argument("--cone-diameter", type=float, default=16, help="cone base diameter [mm]")
    p.add_argument("--no-pillars", action="store_true", help="leave out the 3, 5 and 8 mm pillars")
    p.add_argument("--layer-height", type=float, default=0.2, help="layer height [mm] (default 0.2)")
    p.add_argument("--slowdown", type=float, default=None,
                   help="the preset's slowdown_below_layer_time [s], for the log (default: unknown, '?')")
    p.add_argument("--min-print-speed", type=float, default=None,
                   help="the preset's min_print_speed [mm/s], for the log (default: unknown, '?')")
    p.add_argument("--tag", default="printer", help="printer tag engraved on the front")
    p.set_defaults(run=run)


def run(args):
    project, info = build_small(args.height, args.pyramid_base, args.cone_diameter, not args.no_pillars,
                                args.tag, args.layer_height, bed=args.bed, slowdown=args.slowdown,
                                min_print_speed=args.min_print_speed)
    out = args.output or f"dialin-10-small-{args.tag.replace(' ', '_')}.3mf"
    project.write(out)
    report(info)
    log(f"wrote {out}")
    return out
