"""Step 11: the reference coupon, as a PrusaSlicer 2.9 project.
Mirrors com.ripleydynamics.filament-dialin/11_coupon.lua.

What each feature tests:
  the body     thick solid plastic: dimensions, top finish, heat soak
  the hole     inner-diameter accuracy (XY growth shrinks holes)
  the wing     an overhang at the chosen angle on the +X end
  the fins     thin walls of 2, 3 and 4 line widths: gap fill and thin-wall handling
"""

from . import geometry as g
from . import tower
from .common import SOLID_PARAMS, data_line, decimal, fmt, log, whole
from .threemf import MODEL_PART, NEGATIVE_VOLUME, Object3mf, Project, Volume

FIN_THICKNESSES = (0.8, 1.2, 1.6)
FIN_LENGTH, FIN_HEIGHT = 10, 8

DATA_KEYS = ("tag", "length", "width", "height", "hole", "overhang_angle", "fins", "perimeters", "xy", "foot")


def build_coupon(length=50, width=25, height=10, hole=10, overhang_angle=45, fins=True, perimeters=2,
                 xy_compensation=None, elephant_foot=None, tag="printer", note="", bed=(250.0, 210.0)):
    L, W, H = float(length), float(width), float(height)
    hole = float(hole)
    angle = float(overhang_angle)
    perimeters = int(perimeters)
    xy = decimal(xy_compensation, "XY compensation")
    foot = decimal(elephant_foot, "elephant foot compensation")

    if not (L >= 30 and W >= 12 and H >= 4):
        raise ValueError("Coupon must be at least 30 x 12 x 4 mm")
    if not (hole >= 0 and hole < W - 2 and hole < L * 0.4):
        raise ValueError("Hole must fit inside the coupon")
    if not (angle == 0 or 20 <= angle <= 80):
        raise ValueError("Overhang angle must be 0 or between 20 and 80 degrees")
    if not (1 <= perimeters <= 20):
        raise ValueError("Perimeters must be between 1 and 20")

    volumes = []
    if hole > 0:
        volumes.append(Volume(g.cylinder(hole / 2, H + 2).translate(L * 0.72, W / 2, -1), NEGATIVE_VOLUME, "hole"))
    reach = 0.0
    if angle > 0:
        wing, reach = tower.wing(x_face=L, depth=W, z0=0, section_height=H, angle_deg=angle,
                                 thickness=2, wing_depth=W * 0.6)
        volumes.append(wing)
    if fins:
        x = 4
        for t in FIN_THICKNESSES:
            volumes.append(Volume(g.box(FIN_LENGTH, t, FIN_HEIGHT).translate(x, W - 3 - t, H), MODEL_PART, f"fin {t}"))
            x = x + FIN_LENGTH + 4

    line = min(6.0, H * 0.55)
    volumes.append(Volume(g.label_front(tag, L / 2, H / 2, 0.0, line, L - 4, H - 1.2), NEGATIVE_VOLUME, "tag"))
    note = str(note or "").strip()
    if note != "":
        volumes.append(Volume(g.label_back(note, L / 2, H / 2, W, line, L - 4, H - 1.2), NEGATIVE_VOLUME, "note"))

    params = dict(SOLID_PARAMS)
    params["perimeters"] = whole(perimeters)
    if xy is not None:
        params["xy_size_compensation"] = xy
    if foot is not None:
        params["elefant_foot_compensation"] = foot

    volumes.insert(0, Volume(g.box(L, W, H), MODEL_PART, "body"))
    obj = Object3mf(f"Coupon {tag}", volumes, params)
    b = obj.bounds()
    obj.position = (bed[0] / 2 - (b[0] + b[3]) / 2, bed[1] / 2 - (b[1] + b[4]) / 2)
    project = Project(f"Dial-in coupon {tag}")
    project.add_object(obj)

    info = {"tag": tag, "length": L, "width": W, "height": H, "hole": hole, "overhang_angle": angle,
            "fins": bool(fins), "perimeters": perimeters, "xy": xy if xy is not None else 0,
            "foot": foot if foot is not None else 0,
            "xy_typed": xy, "foot_typed": foot, "reach": reach, "note": note}
    return project, info


def report(info):
    angle, xy, foot = info["overhang_angle"], info["xy_typed"], info["foot_typed"]
    wing = f"{fmt(angle, 0)} deg reaching {fmt(info['reach'], 1)} mm" if angle > 0 else "none"
    log(f"coupon for {info['tag']}: {fmt(info['length'])} x {fmt(info['width'])} x {fmt(info['height'])} mm, "
        f"hole {fmt(info['hole'])} mm, wing {wing}, fins {'0.8/1.2/1.6 mm' if info['fins'] else 'none'}, "
        f"{int(info['perimeters'])} perimeters, xy {fmt(xy, 3) if xy is not None else 'preset'}, "
        f"foot {fmt(foot, 3) if foot is not None else 'preset'}")
    log("each run centres a new coupon on the bed: press A (arrange) after adding several")
    print(data_line("coupon", {k: info[k] for k in DATA_KEYS}))


def add_cli(sub, common):
    p = sub.add_parser("coupon", parents=[common], help="Step 11: reference coupon")
    p.add_argument("--length", type=float, default=50, help="length X [mm]")
    p.add_argument("--width", type=float, default=25, help="width Y [mm]")
    p.add_argument("--height", type=float, default=10, help="height Z [mm]")
    p.add_argument("--hole", type=float, default=10, help="through-hole diameter [mm] (0 = none)")
    p.add_argument("--overhang-angle", type=float, default=45,
                   help="overhang wing angle from horizontal [deg] (0 = none)")
    p.add_argument("--no-fins", action="store_true", help="leave out the 0.8 / 1.2 / 1.6 mm fins")
    p.add_argument("--perimeters", type=int, default=2, help="perimeters")
    p.add_argument("--xy-compensation", default=None, help="XY size compensation [mm] (blank = leave the preset alone)")
    p.add_argument("--elephant-foot", default=None, help="elephant foot compensation [mm] (blank = leave the preset alone)")
    p.add_argument("--tag", default="printer", help="printer tag engraved on the front")
    p.add_argument("--note", default="", help="note engraved on the back (spool, date...)")
    p.set_defaults(run=run)


def run(args):
    project, info = build_coupon(args.length, args.width, args.height, args.hole, args.overhang_angle,
                                 not args.no_fins, args.perimeters, args.xy_compensation, args.elephant_foot,
                                 args.tag, args.note, bed=args.bed)
    out = args.output or f"dialin-11-coupon-{args.tag.replace(' ', '_')}.3mf"
    project.write(out)
    report(info)
    log(f"wrote {out}")
    return out
