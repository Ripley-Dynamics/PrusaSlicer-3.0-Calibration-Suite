"""Step 9: the hole and fit gauge, as a PrusaSlicer 2.9 project.
Mirrors com.ripleydynamics.filament-dialin/09_hole_fit_gauge.lua.

Layout after leotrax3d's tolerance test (MIT), extended with a hole-size row
and pegs. Everything is one object so the loose pins print beside the plate
instead of being centred onto it.
"""

from . import geometry as g
from .common import SOLID_PARAMS, data_line, decimal, fmt, join, log, range_values
from .threemf import MODEL_PART, NEGATIVE_VOLUME, Object3mf, Project, Volume

HOLE_SIZES = (3, 4, 5, 6, 8, 10, 12, 15, 20)
PEG_SIZES = (4, 6, 8, 10)
MARGIN, LABEL_ROW = 4, 6

DATA_KEYS = ("tag", "pin", "clearances", "thickness", "size_row", "hole_sizes", "peg_sizes")


def _number(v, name):
    n = decimal(v, name)
    if n is None:
        raise ValueError(f"{name} must be a number, got '{v}'")
    return n


def build_gauge(pin=6, min_clearance="0.0", max_clearance="0.5", clearance_step="0.1", thickness=6,
                size_row=True, tag="printer", bed=(250.0, 210.0)):
    pin = float(pin)
    t = float(thickness)
    clearances, _ = range_values(_number(min_clearance, "lowest clearance"),
                                 _number(max_clearance, "highest clearance"),
                                 by_interval=True, interval=_number(clearance_step, "clearance step"),
                                 max_count=12)
    if not (3 <= pin <= 20 and t >= 3):
        raise ValueError("Pin must be 3 to 20 mm and the plate at least 3 mm thick")
    if clearances[0] < 0:
        raise ValueError("Clearance cannot be negative")
    size_row = bool(size_row)

    volumes = []

    # Row 1: clearance holes for the pin.
    pitch = pin + clearances[-1] + MARGIN
    row1_w = pitch * len(clearances)
    row1_d = pin + clearances[-1] + MARGIN * 2 + LABEL_ROW
    plate_w, plate_d = row1_w, row1_d
    for i, c in enumerate(clearances, start=1):
        cx = pitch * (i - 0.5)
        volumes.append(Volume(g.cylinder((pin + c) / 2, t + 2).translate(cx, LABEL_ROW + (row1_d - LABEL_ROW) / 2, -1),
                              NEGATIVE_VOLUME, f"clearance +{fmt(c, 2)}"))
        volumes.append(Volume(g.label_top("+" + fmt(c, 2), cx, LABEL_ROW / 2, t, 3.2, pitch - 1.5, LABEL_ROW - 1),
                              NEGATIVE_VOLUME, f"label +{fmt(c, 2)}"))

    # Row 2: hole sizes 3..20 mm, and pegs standing beside the plate.
    if size_row:
        x = MARGIN
        row2_d = 20 + MARGIN * 2 + LABEL_ROW
        y_c = row1_d + LABEL_ROW + (row2_d - LABEL_ROW) / 2
        for d in HOLE_SIZES:
            cx = x + d / 2
            volumes.append(Volume(g.cylinder(d / 2, t + 2).translate(cx, y_c, -1), NEGATIVE_VOLUME, f"hole {d}"))
            volumes.append(Volume(g.label_top(str(d), cx, row1_d + LABEL_ROW / 2, t, 3.2, d + MARGIN - 1, LABEL_ROW - 1),
                                  NEGATIVE_VOLUME, f"label {d}"))
            x = x + d + MARGIN
        plate_w = max(plate_w, x)
        plate_d = row1_d + row2_d

    # Loose pieces beside the plate: two pins and the pegs.
    px = plate_w + 8
    for k in range(1, 3):
        volumes.append(Volume(g.cylinder(pin / 2, t * 2).translate(px + pin / 2, 6 + (k - 1) * (pin + 6), 0),
                              MODEL_PART, f"pin {k}"))
    if size_row:
        y = 6 + 2 * (pin + 6) + 4
        for d in PEG_SIZES:
            volumes.append(Volume(g.cylinder(d / 2, t * 2).translate(px + d / 2, y + d / 2, 0), MODEL_PART, f"peg {d}"))
            y = y + d + 5
    volumes.append(Volume(g.label_front(tag, plate_w / 2, t / 2, 0.0, min(4.0, t * 0.55), plate_w - 6, t - 1.2),
                          NEGATIVE_VOLUME, "tag"))

    volumes.insert(0, Volume(g.box(plate_w, plate_d, t), MODEL_PART, "plate"))
    params = dict(SOLID_PARAMS)
    params["perimeters"] = 3
    obj = Object3mf(f"Hole and fit gauge {tag}", volumes, params)
    b = obj.bounds()
    obj.position = (bed[0] / 2 - (b[0] + b[3]) / 2, bed[1] / 2 - (b[1] + b[4]) / 2)
    project = Project(f"Dial-in hole and fit gauge {tag}")
    project.add_object(obj)

    info = {"tag": tag, "pin": pin, "clearances": join(clearances, 2), "thickness": t, "size_row": size_row,
            "hole_sizes": ",".join(str(d) for d in HOLE_SIZES), "peg_sizes": ",".join(str(d) for d in PEG_SIZES),
            "clearance_values": clearances, "plate_w": plate_w, "plate_d": plate_d}
    return project, info


def report(info):
    c = info["clearance_values"]
    log(f"hole and fit gauge for {info['tag']}: {len(c)} clearance holes for a {fmt(info['pin'])} mm pin "
        f"({fmt(c[0], 2)} to {fmt(c[-1], 2)} mm)"
        f"{', hole sizes 3 to 20 mm with 4/6/8/10 mm pegs' if info['size_row'] else ''}, "
        f"plate {fmt(info['plate_w'])} x {fmt(info['plate_d'])} x {fmt(info['thickness'])} mm")
    log("first hole the pin enters without force = your sliding-fit clearance; measure the size-row holes and pegs "
        "to see how much small holes shrink beyond the XY compensation")
    print(data_line("gauge", {k: info[k] for k in DATA_KEYS}))


def add_cli(sub, common):
    p = sub.add_parser("gauge", parents=[common], help="Step 9: hole and fit gauge")
    p.add_argument("--pin", type=float, default=6, help="pin diameter [mm]")
    p.add_argument("--min-clearance", default="0.0", help="lowest clearance [mm]")
    p.add_argument("--max-clearance", default="0.5", help="highest clearance [mm]")
    p.add_argument("--clearance-step", default="0.1", help="clearance step [mm]")
    p.add_argument("--thickness", type=float, default=6, help="plate thickness [mm]")
    p.add_argument("--no-size-row", action="store_true",
                   help="leave out the row of 3 to 20 mm holes and the 4 to 10 mm pegs")
    p.add_argument("--tag", default="printer", help="printer tag engraved on the front")
    p.set_defaults(run=run)


def run(args):
    project, info = build_gauge(args.pin, args.min_clearance, args.max_clearance, args.clearance_step,
                                args.thickness, not args.no_size_row, args.tag, bed=args.bed)
    out = args.output or f"dialin-09-gauge-{args.tag.replace(' ', '_')}.3mf"
    project.write(out)
    report(info)
    log(f"wrote {out}")
    return out
