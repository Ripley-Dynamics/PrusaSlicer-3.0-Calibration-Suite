"""Step 8: the shrinkage and XY growth bar, as a PrusaSlicer 2.9 project.
Mirrors com.ripleydynamics.filament-dialin/08_shrink_bar.lua."""

from . import geometry as g
from .common import SOLID_PARAMS, data_line, fmt, log
from .threemf import MODEL_PART, NEGATIVE_VOLUME, Object3mf, Project, Volume

DATA_KEYS = ("tag", "length", "width", "height", "hole", "c0")


def build_bar(length=150, width=20, height=8, hole=6, hole_inset=10, tag="printer", bed=(250.0, 210.0)):
    L, W, H = float(length), float(width), float(height)
    d, inset = float(hole), float(hole_inset)
    if not (L >= 60 and W >= 10 and H >= 3):
        raise ValueError("Bar must be at least 60 x 10 x 3 mm")
    if not (d >= 2 and d <= W - 4):
        raise ValueError("Hole must leave at least 2 mm of wall on each side")
    if not (inset >= d / 2 + 2 and inset * 2 + d < L):
        raise ValueError("Hole inset must keep the holes inside the bar")

    centre_distance = L - 2 * inset

    volumes = [Volume(g.box(L, W, H), MODEL_PART, "bar")]
    for n, cx in enumerate([inset, L - inset], start=1):
        volumes.append(Volume(g.cylinder(d / 2, H + 2).translate(cx, W / 2, -1), NEGATIVE_VOLUME, f"hole {n}"))

    line = min(5.0, H * 0.5)
    max_w = L - 2 * inset - d - 8
    nominal = f"C {fmt(centre_distance, 2)} W {fmt(W, 2)} D {fmt(d, 2)}"
    volumes.append(Volume(g.label_front(nominal, L / 2, H / 2, 0.0, line, max_w, H - 1.5), NEGATIVE_VOLUME, "nominal"))
    volumes.append(Volume(g.label_back(tag, L / 2, H / 2, W, line, max_w, H - 1.5), NEGATIVE_VOLUME, "tag"))

    obj = Object3mf(f"Shrink bar {tag}", volumes, SOLID_PARAMS)
    b = obj.bounds()
    obj.position = (bed[0] / 2 - (b[0] + b[3]) / 2, bed[1] / 2 - (b[1] + b[4]) / 2)
    project = Project(f"Dial-in shrinkage bar {tag}")
    project.add_object(obj)

    info = {"tag": tag, "length": L, "width": W, "height": H, "hole": d, "c0": centre_distance,
            "hole_inset": inset}
    return project, info


def report(info):
    c0 = fmt(info["c0"], 2)
    log(f"shrinkage bar for {info['tag']}: {fmt(info['length'])} x {fmt(info['width'])} x {fmt(info['height'])} mm, "
        f"holes {fmt(info['hole'])} mm, centres {c0} mm apart")
    log("measure hole centre distance C as (near-edge gap + far-edge gap) / 2: growth cancels, "
        f"so shrinkage = 1 - C / {c0}")
    log(f"measure width Wm and hole diameter Dm: XY growth per side = (Wm - {fmt(info['width'], 2)} x (1 - shrinkage)) / 2, "
        f"cross-check with ({fmt(info['hole'], 2)} x (1 - shrinkage) - Dm) / 2")
    print(data_line("bar", {k: info[k] for k in DATA_KEYS}))


def add_cli(sub, common):
    p = sub.add_parser("bar", parents=[common], help="Step 8: shrinkage and XY growth bar")
    p.add_argument("--length", type=float, default=150, help="bar length X [mm]")
    p.add_argument("--width", type=float, default=20, help="bar width Y [mm]")
    p.add_argument("--height", type=float, default=8, help="bar height Z [mm]")
    p.add_argument("--hole", type=float, default=6, help="hole diameter [mm]")
    p.add_argument("--hole-inset", type=float, default=10, help="hole centre distance from each end [mm]")
    p.add_argument("--tag", default="printer", help="printer tag engraved on the back")
    p.set_defaults(run=run)


def run(args):
    project, info = build_bar(args.length, args.width, args.height, args.hole, args.hole_inset,
                              args.tag, bed=args.bed)
    out = args.output or f"dialin-08-bar-{args.tag.replace(' ', '_')}.3mf"
    project.write(out)
    report(info)
    log(f"wrote {out}")
    return out
