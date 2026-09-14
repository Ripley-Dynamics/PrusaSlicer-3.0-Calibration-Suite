"""Step 5: the solid slab (mass check), as a PrusaSlicer 2.9 project.
Mirrors com.ripleydynamics.filament-dialin/05_slab.lua."""

from . import geometry as g
from .common import data_line, fmt, log
from .threemf import MODEL_PART, NEGATIVE_VOLUME, Object3mf, Project, Volume

POST, POST_HEIGHT, POST_INSET = 6, 12, 4
SOLID_PARAMS = {"fill_density": "100%", "fill_pattern": "rectilinear"}


def build_slab(size_x=60, size_y=60, height=20, posts=True, density=None, tag="printer", note="",
               bed=(250.0, 210.0), extrusion_multiplier=None):
    X, Y, Z = float(size_x), float(size_y), float(height)
    if not (X >= 20 and Y >= 20 and Z >= 5):
        raise ValueError("Slab must be at least 20 x 20 x 5 mm")
    density_source = "typed"
    if density is None:
        density, density_source = 1.27, "default for Prusament PETG"
    density = float(density)
    if not (0.5 < density < 3):
        raise ValueError("Density must be between 0.5 and 3 g/cm3")

    volumes = [Volume(g.box(X, Y, Z), MODEL_PART, "slab")]
    volume_mm3 = X * Y * Z
    if posts:
        for i, (px, py) in enumerate([(POST_INSET, POST_INSET), (X - POST_INSET - POST, POST_INSET),
                                      (POST_INSET, Y - POST_INSET - POST), (X - POST_INSET - POST, Y - POST_INSET - POST)]):
            volumes.append(Volume(g.box(POST, POST, POST_HEIGHT).translate(px, py, Z), MODEL_PART, f"post {i + 1}"))
        volume_mm3 += 4 * POST * POST * POST_HEIGHT

    volume_cm3 = volume_mm3 / 1000.0
    mass_g = volume_cm3 * density
    nominal = f"{fmt(volume_cm3, 1)}cc {fmt(mass_g, 1)}g"
    line = min(6.0, Z * 0.45)
    volumes.append(Volume(g.label_front(nominal, X / 2, Z / 2, 0.0, line, X - 4, Z - 1.5), NEGATIVE_VOLUME, "nominal"))
    back_text = tag if not str(note).strip() else f"{tag} {str(note).strip()}"
    volumes.append(Volume(g.label_back(back_text, X / 2, Z / 2, Y, line, X - 4, Z - 1.5), NEGATIVE_VOLUME, "tag"))

    bw, bd = bed
    obj = Object3mf(f"Slab {tag}", volumes, SOLID_PARAMS, position=(bw / 2 - X / 2, bd / 2 - Y / 2))
    project = Project(f"Dial-in slab {tag}")
    project.add_object(obj)

    info = {
        "tag": tag, "x": X, "y": Y, "z": Z, "posts": bool(posts), "volume_cm3": volume_cm3,
        "density": density, "density_source": density_source, "expected_g": mass_g,
        "extrusion_multiplier": extrusion_multiplier or 0,
    }
    return project, info


def report(info):
    log(f"solid slab for {info['tag']}: {fmt(info['x'])} x {fmt(info['y'])} x {fmt(info['z'])} mm"
        f"{' plus four witness posts' if info['posts'] else ''}, nominal volume {fmt(info['volume_cm3'], 2)} cm3")
    log(f"expected mass {fmt(info['expected_g'], 2)} g at {fmt(info['density'], 3)} g/cm3 ({info['density_source']}); "
        "engraved labels remove well under 0.1 g")
    em = info["extrusion_multiplier"]
    log(f"weigh the printed slab: new extrusion multiplier = {fmt(em, 4) if em else 'current multiplier'} x {fmt(info['expected_g'], 2)} / measured grams")
    log("open the .3mf in PrusaSlicer 2.9 (File > Import > Import 3MF, or double-click); the object is set to 100% rectilinear infill")
    print(data_line("slab", info))


def add_cli(sub, common):
    p = sub.add_parser("slab", parents=[common], help="Step 5: solid slab for the mass check")
    p.add_argument("--x", type=float, default=60, help="size X [mm]")
    p.add_argument("--y", type=float, default=60, help="size Y [mm]")
    p.add_argument("--z", type=float, default=20, help="height [mm]")
    p.add_argument("--no-posts", action="store_true", help="leave out the four witness posts")
    p.add_argument("--density", type=float, default=None, help="filament density [g/cm3] (default 1.27, Prusament PETG)")
    p.add_argument("--tag", default="printer", help="printer tag engraved on the back")
    p.add_argument("--note", default="", help="note engraved after the tag (spool, date...)")
    p.add_argument("--multiplier", type=float, default=None, help="current extrusion multiplier, for the formula in the log")
    p.set_defaults(run=run)


def run(args):
    project, info = build_slab(args.x, args.y, args.z, not args.no_posts, args.density, args.tag, args.note,
                               bed=args.bed, extrusion_multiplier=args.multiplier)
    out = args.output or f"dialin-05-slab-{args.tag.replace(' ', '_')}.3mf"
    project.write(out)
    report(info)
    log(f"wrote {out}")
    return out
