"""Tests for the second batch of port29 steps: the shrinkage bar (8), the hole
and fit gauge (9), the small-feature tower (10), the reference coupon (11) and
the nozzle-clean file picker (0). They check the same numbers as the plugin's
own tests in test/run_tests.lua.
Run: python3 -m unittest discover -s test -p 'test_*.py'"""

import argparse
import contextlib
import io
import math
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from port29 import clean, coupon, gauge, shrink_bar, small_feature  # noqa: E402
from port29.common import parse_bed  # noqa: E402
from port29.threemf import MODEL_PART, NEGATIVE_VOLUME, Mesh  # noqa: E402

NS = {"m": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"}
BUNDLE = os.path.join(os.path.dirname(__file__), "..", "com.ripleydynamics.filament-dialin")


def read_3mf(path):
    z = zipfile.ZipFile(path)
    return z.namelist(), ET.fromstring(z.read("3D/3dmodel.model")), ET.fromstring(z.read("Metadata/Slic3r_PE_model.config"))


def sub_mesh(verts, tris):
    used = sorted({i for t in tris for i in t})
    remap = {o: n for n, o in enumerate(used)}
    return Mesh([verts[i] for i in used], [tuple(remap[i] for i in t) for t in tris])


def run_cli(module, argv):
    """Drive a module's run() through a parser built with its own add_cli()."""
    ap = argparse.ArgumentParser()
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-o", "--output")
    common.add_argument("--bed", type=parse_bed, default=(250.0, 210.0))
    sub = ap.add_subparsers(dest="step", required=True)
    module.add_cli(sub, common)
    args = ap.parse_args(argv)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = args.run(args)
    return result, out.getvalue()


def report_text(module, info):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        module.report(info)
    return out.getvalue()


def data_of(text):
    for line in text.splitlines():
        if " DATA " in line:
            return line
    raise AssertionError("no DATA line in:\n" + text)


class MeshChecks(unittest.TestCase):
    """Every volume of every step is a closed solid with positive volume."""

    def check_object(self, obj):
        for v in obj.volumes:
            self.assertTrue(v.mesh.is_closed(), f"{obj.name}: {v.name} is not closed")
            self.assertGreater(v.mesh.signed_volume(), 0, f"{obj.name}: {v.name} is inside out")

    def test_all_steps(self):
        for project, _ in (shrink_bar.build_bar(tag="MK4S 0.4"),
                           gauge.build_gauge(tag="MK4S 0.4"),
                           gauge.build_gauge(tag="T", size_row=False, clearance_step="0.25"),
                           small_feature.build_small(tag="MK4S 0.4"),
                           small_feature.build_small(tag="T", pillars=False),
                           coupon.build_coupon(tag="MK4S 0.4", note="PETG lot 42", xy_compensation="-0.05"),
                           coupon.build_coupon(tag="T", overhang_angle=0, fins=False, hole=0)):
            for obj in project.objects:
                self.check_object(obj)


class ShrinkBar(unittest.TestCase):
    def test_default_bar_matches_the_plugin(self):
        project, info = shrink_bar.build_bar(tag="MK4S 0.4")
        obj = project.objects[0]
        self.assertEqual([v.vtype for v in obj.volumes], [MODEL_PART] + [NEGATIVE_VOLUME] * 4)
        self.assertEqual(obj.config, {"fill_density": "100%", "fill_pattern": "rectilinear"})
        self.assertEqual(obj.volumes[0].mesh.bounds(), (0, 0, 0, 150, 20, 8))
        holes = [v for v in obj.volumes if v.name.startswith("hole")]
        self.assertEqual(len(holes), 2)
        for hole, cx in zip(holes, (10.0, 140.0)):
            b = hole.mesh.bounds()
            self.assertAlmostEqual((b[0] + b[3]) / 2, cx)       # centres 130 mm apart
            self.assertAlmostEqual((b[1] + b[4]) / 2, 10.0)     # on the bar's centre line
            self.assertAlmostEqual(b[3] - b[0], 6.0)            # 6 mm diameter
            self.assertAlmostEqual(b[2], -1)                    # through hole
            self.assertAlmostEqual(b[5], 9)
        self.assertAlmostEqual(info["c0"], 130.0)

    def test_labels_sink_into_the_faces(self):
        obj = shrink_bar.build_bar(tag="MK4S 0.4")[0].objects[0]
        nominal, tag = obj.volumes[3], obj.volumes[4]
        self.assertEqual(nominal.name, "nominal")
        b = nominal.mesh.bounds()
        self.assertAlmostEqual(b[1], -0.4)        # 0.4 mm proud of the front face
        self.assertAlmostEqual(b[4], 0.6)         # 0.6 mm into the part
        self.assertLessEqual(b[3] - b[0], 150 - 20 - 6 - 8 + 0.01)
        b = tag.mesh.bounds()
        self.assertAlmostEqual(b[1], 19.4)        # 0.6 mm into the back face
        self.assertAlmostEqual(b[4], 20.4)

    def test_centred_on_the_bed(self):
        obj = shrink_bar.build_bar(tag="T", bed=(250.0, 210.0))[0].objects[0]
        self.assertEqual(obj.position, (50.0, 95.0))

    def test_report_and_data(self):
        _, info = shrink_bar.build_bar(tag="MK4S 0.4")
        text = report_text(shrink_bar, info)
        self.assertEqual(data_of(text),
                         '[filament-dialin] DATA step="bar" c0=130 height=8 hole=6 length=150 tag="MK4S 0.4" width=20')
        self.assertIn("holes 6 mm, centres 130 mm apart", text)
        self.assertIn("shrinkage = 1 - C / 130", text)

    def test_engraved_nominals(self):
        # the label text the plugin engraves: "C 130 W 20 D 6"
        from port29 import geometry as g
        obj = shrink_bar.build_bar(tag="T")[0].objects[0]
        expected = g.label_front("C 130 W 20 D 6", 75.0, 4.0, 0.0, 4.0, 116.0, 6.5)
        self.assertEqual(len(obj.volumes[3].mesh.triangles), len(expected.triangles))

    def test_validation(self):
        for kwargs, message in (({"length": 50}, "at least 60 x 10 x 3"),
                                ({"width": 8}, "at least 60 x 10 x 3"),
                                ({"height": 2}, "at least 60 x 10 x 3"),
                                ({"hole": 1}, "2 mm of wall"),
                                ({"hole": 17}, "2 mm of wall"),
                                ({"hole_inset": 3}, "inside the bar"),
                                ({"hole_inset": 80}, "inside the bar")):
            with self.assertRaises(ValueError) as e:
                shrink_bar.build_bar(**kwargs)
            self.assertIn(message, str(e.exception))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "bar.3mf")
            path, text = run_cli(shrink_bar, ["bar", "--tag", "C1 0.4", "--bed", "250x220", "-o", out])
            self.assertEqual(path, out)
            self.assertIn('DATA step="bar"', text)
            self.assertIn("wrote " + out, text)
            names, model, cfg = read_3mf(out)
            self.assertIn("3D/3dmodel.model", names)
            self.assertEqual(model.find(".//m:item", NS).get("transform"), "1 0 0 0 1 0 0 0 1 50 100 0")
            self.assertEqual(len(cfg.findall(".//volume")), 5)


class Gauge(unittest.TestCase):
    def setUp(self):
        self.project, self.info = gauge.build_gauge(tag="MK4S 0.4")
        self.obj = self.project.objects[0]

    def holes(self):
        return [v for v in self.obj.volumes if v.name.startswith(("clearance", "hole"))]

    def test_one_object_with_the_plate_pins_and_pegs(self):
        solids = [v for v in self.obj.volumes if v.vtype == MODEL_PART]
        self.assertEqual([v.name for v in solids],
                         ["plate", "pin 1", "pin 2", "peg 4", "peg 6", "peg 8", "peg 10"])
        self.assertEqual(len(self.project.objects), 1)
        plate = self.obj.volumes[0].mesh.bounds()
        self.assertEqual(plate, (0, 0, 0, 123.0, 54.5, 6.0))
        for loose in solids[1:]:
            self.assertGreater(loose.mesh.bounds()[0], plate[3] + 5, loose.name)  # beside the plate
        self.assertEqual(self.obj.config, {"fill_density": "100%", "fill_pattern": "rectilinear", "perimeters": 3})

    def test_clearance_and_size_holes(self):
        holes = self.holes()
        self.assertEqual(len(holes), 6 + 9)     # six clearance holes and nine size holes
        radii = [(v.mesh.bounds()[3] - v.mesh.bounds()[0]) / 2 for v in holes]
        self.assertAlmostEqual(radii[0], 3.0)   # 6.0 mm clearance hole for the 6 mm pin
        self.assertAlmostEqual(radii[5], 3.25)  # 6.5 mm
        self.assertAlmostEqual(radii[6], 1.5)   # size row starts at 3 mm
        self.assertAlmostEqual(radii[14], 10.0)  # and ends at 20 mm
        for v in holes:
            b = v.mesh.bounds()
            self.assertAlmostEqual(b[2], -1)    # through the 6 mm plate
            self.assertAlmostEqual(b[5], 7)
        pitch = 6 + 0.5 + 4
        for i, v in enumerate(holes[:6], start=1):
            b = v.mesh.bounds()
            self.assertAlmostEqual((b[0] + b[3]) / 2, pitch * (i - 0.5))
        x, centres = 4, []
        for d in gauge.HOLE_SIZES:
            centres.append(x + d / 2)
            x += d + 4
        for v, cx in zip(holes[6:], centres):
            self.assertAlmostEqual((v.mesh.bounds()[0] + v.mesh.bounds()[3]) / 2, cx)

    def test_labels(self):
        tops = [v for v in self.obj.volumes if v.name.startswith("label")]
        self.assertEqual(len(tops), 6 + 9)
        for v in tops:
            b = v.mesh.bounds()
            self.assertAlmostEqual(b[2], 5.4)   # 0.6 mm into the 6 mm top face
            self.assertAlmostEqual(b[5], 6.4)
        tag = self.obj.volumes[-1]
        self.assertEqual(tag.name, "tag")
        self.assertAlmostEqual(tag.mesh.bounds()[1], -0.4)
        self.assertAlmostEqual(tag.mesh.bounds()[4], 0.6)

    def test_data(self):
        self.assertEqual(data_of(report_text(gauge, self.info)),
                         '[filament-dialin] DATA step="gauge" clearances="0,0.1,0.2,0.3,0.4,0.5" '
                         'hole_sizes="3,4,5,6,8,10,12,15,20" peg_sizes="4,6,8,10" pin=6 size_row=true '
                         'tag="MK4S 0.4" thickness=6')
        self.assertIn("6 clearance holes for a 6 mm pin (0 to 0.5 mm)", report_text(gauge, self.info))
        self.assertIn("plate 123 x 54.5 x 6 mm", report_text(gauge, self.info))

    def test_clearance_row_only(self):
        project, info = gauge.build_gauge(size_row=False, clearance_step="0.25", tag="T")
        obj = project.objects[0]
        self.assertEqual(len([v for v in obj.volumes if v.name.startswith("clearance")]), 3)
        self.assertEqual([v.name for v in obj.volumes if v.vtype == MODEL_PART], ["plate", "pin 1", "pin 2"])
        self.assertIn("size_row=false", data_of(report_text(gauge, info)))
        self.assertEqual(info["clearances"], "0,0.25,0.5")

    def test_validation(self):
        for kwargs, message in (({"min_clearance": "-0.1"}, "negative"),
                                ({"pin": 2}, "Pin must be 3 to 20 mm"),
                                ({"pin": 25}, "Pin must be 3 to 20 mm"),
                                ({"thickness": 2}, "at least 3 mm thick"),
                                ({"clearance_step": "0"}, "Interval must be positive"),
                                ({"max_clearance": "-1"}, "Maximum must be greater"),
                                ({"clearance_step": "0.01"}, "Too many steps"),
                                ({"min_clearance": ""}, "must be a number")):
            with self.assertRaises(ValueError) as e:
                gauge.build_gauge(**kwargs)
            self.assertIn(message, str(e.exception))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "g.3mf")
            _, text = run_cli(gauge, ["gauge", "--tag", "MK4S 0.4", "--pin", "8", "-o", out])
            self.assertIn("pin=8", text)
            names, model, cfg = read_3mf(out)
            verts = [[float(v.get(a)) for a in "xyz"] for v in model.findall(".//m:vertex", NS)]
            tris = [tuple(int(t.get(a)) for a in ("v1", "v2", "v3")) for t in model.findall(".//m:triangle", NS)]
            for v in cfg.findall(".//volume"):
                m = sub_mesh(verts, tris[int(v.get("firstid")):int(v.get("lastid")) + 1])
                self.assertTrue(m.is_closed())


class SmallFeature(unittest.TestCase):
    def test_features_stand_on_the_plate(self):
        project, info = small_feature.build_small(tag="MK4S 0.4")
        obj = project.objects[0]
        self.assertEqual([v.name for v in obj.volumes],
                         ["plate", "pyramid", "cone", "pillar 3", "pillar 5", "pillar 8", "tag"])
        self.assertEqual([v.vtype for v in obj.volumes], [MODEL_PART] * 6 + [NEGATIVE_VOLUME])
        self.assertEqual(obj.volumes[0].mesh.bounds(), (0, 0, 0, 100.0, 36.0, 2.0))
        for v in obj.volumes[1:6]:
            b = v.mesh.bounds()
            self.assertAlmostEqual(b[2], 2.0, msg=v.name)    # on the 2 mm plate
            self.assertAlmostEqual(b[5], 42.0, msg=v.name)   # 40 mm tall
            self.assertAlmostEqual((b[1] + b[4]) / 2, 18.0, msg=v.name)  # centred on Y like the Lua
        for v, size in ((obj.volumes[1], 20.0), (obj.volumes[2], 16.0),
                        (obj.volumes[3], 3.0), (obj.volumes[4], 5.0), (obj.volumes[5], 8.0)):
            b = v.mesh.bounds()
            self.assertAlmostEqual(b[3] - b[0], size, msg=v.name)
            self.assertAlmostEqual(b[4] - b[1], size, msg=v.name)
        # laid out left to right with 8 mm gaps
        self.assertAlmostEqual(obj.volumes[1].mesh.bounds()[0], 8.0)
        self.assertAlmostEqual(obj.volumes[2].mesh.bounds()[0], 36.0)
        self.assertAlmostEqual(obj.volumes[3].mesh.bounds()[0], 60.0)
        self.assertAlmostEqual(info["plate_h"], 2.0)

    def test_label_and_plate_height_follow_the_layer_height(self):
        obj = small_feature.build_small(tag="T", layer_height=0.3)[0].objects[0]
        self.assertAlmostEqual(obj.volumes[0].mesh.bounds()[5], 2.1)   # aligned to whole layers
        tag = obj.volumes[-1]
        self.assertAlmostEqual(tag.mesh.bounds()[1], -0.4)
        self.assertAlmostEqual(tag.mesh.bounds()[4], 0.6)

    def test_pillars_optional(self):
        project, info = small_feature.build_small(tag="T", pillars=False)
        obj = project.objects[0]
        self.assertEqual([v.name for v in obj.volumes], ["plate", "pyramid", "cone", "tag"])
        self.assertEqual(obj.volumes[0].mesh.bounds()[3], 8 + 20 + 8 + 16 + 8)
        self.assertIn("pillars=false", data_of(report_text(small_feature, info)))
        self.assertIn("pillars none", report_text(small_feature, info))

    def test_data_and_unknown_preset_values(self):
        _, info = small_feature.build_small(tag="MK4S 0.4")
        text = report_text(small_feature, info)
        self.assertEqual(data_of(text),
                         '[filament-dialin] DATA step="small" cone_diameter=16 height=40 min_print_speed=0 '
                         'pillars=true pyramid_base=20 slowdown=0 tag="MK4S 0.4"')
        self.assertIn("slows layers under ? s down to ? mm/s", text)
        _, info = small_feature.build_small(tag="MK4S 0.4", slowdown=20, min_print_speed=15)
        text = report_text(small_feature, info)
        self.assertIn("slows layers under 20 s down to 15 mm/s", text)
        self.assertIn("min_print_speed=15", data_of(text))
        self.assertIn("slowdown=20", data_of(text))

    def test_validation(self):
        for kwargs in ({"height": 10}, {"pyramid_base": 7}, {"cone_diameter": 5}):
            with self.assertRaises(ValueError) as e:
                small_feature.build_small(**kwargs)
            self.assertIn("Height >= 15 mm, pyramid base >= 8 mm, cone >= 6 mm", str(e.exception))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "s.3mf")
            _, text = run_cli(small_feature, ["small", "--tag", "T", "--no-pillars", "--slowdown", "20",
                                              "--min-print-speed", "15", "-o", out])
            self.assertIn('DATA step="small"', text)
            self.assertIn("slowdown=20", text)
            names, model, cfg = read_3mf(out)
            self.assertEqual(len(cfg.findall(".//volume")), 4)


class Coupon(unittest.TestCase):
    def setUp(self):
        self.project, self.info = coupon.build_coupon(tag="MK4S 0.4", note="PETG lot 42",
                                                      xy_compensation="-0.05", elephant_foot="0.15")
        self.obj = self.project.objects[0]

    def test_body_hole_wing_and_fins(self):
        self.assertEqual([v.name for v in self.obj.volumes],
                         ["body", "hole", "wing 45", "fin 0.8", "fin 1.2", "fin 1.6", "tag", "note"])
        self.assertEqual([v.vtype for v in self.obj.volumes],
                         [MODEL_PART, NEGATIVE_VOLUME] + [MODEL_PART] * 4 + [NEGATIVE_VOLUME] * 2)
        self.assertEqual(self.obj.volumes[0].mesh.bounds(), (0, 0, 0, 50.0, 25.0, 10.0))
        b = self.obj.volumes[1].mesh.bounds()
        self.assertAlmostEqual((b[0] + b[3]) / 2, 50 * 0.72)   # hole at x = 0.72 L
        self.assertAlmostEqual((b[1] + b[4]) / 2, 12.5)
        self.assertAlmostEqual(b[3] - b[0], 10.0)
        self.assertAlmostEqual(b[2], -1)
        self.assertAlmostEqual(b[5], 11)
        wing = self.obj.volumes[2].mesh.bounds()
        self.assertAlmostEqual(wing[2], 0.0)                    # underside starts on the bed
        self.assertGreater(wing[3], 50.0)                       # reaches out past the +X face
        # a 45 deg wing reaches out as far as it rises: H - 0.5 - thickness * cos(45)
        self.assertAlmostEqual(self.info["reach"], 10 - 0.5 - 2 * math.cos(math.radians(45)), places=6)
        self.assertAlmostEqual(wing[4] - wing[1], 25 * 0.6)     # 60% of the width
        for v, t in zip(self.obj.volumes[3:6], (0.8, 1.2, 1.6)):
            b = v.mesh.bounds()
            self.assertAlmostEqual(b[4] - b[1], t, msg=v.name)  # 0.8 / 1.2 / 1.6 mm fins
            self.assertAlmostEqual(b[3] - b[0], 10.0)
            self.assertAlmostEqual(b[5] - b[2], 8.0)
            self.assertAlmostEqual(b[2], 10.0)                  # standing on top
            self.assertAlmostEqual(b[4], 25 - 3)                # along the back edge
        self.assertAlmostEqual(self.obj.volumes[3].mesh.bounds()[0], 4.0)
        self.assertAlmostEqual(self.obj.volumes[4].mesh.bounds()[0], 18.0)
        self.assertAlmostEqual(self.obj.volumes[5].mesh.bounds()[0], 32.0)

    def test_object_params(self):
        self.assertEqual(self.obj.config, {"fill_density": "100%", "fill_pattern": "rectilinear", "perimeters": 2,
                                           "xy_size_compensation": -0.05, "elefant_foot_compensation": 0.15})
        plain = coupon.build_coupon(tag="T")[0].objects[0]
        self.assertEqual(plain.config, {"fill_density": "100%", "fill_pattern": "rectilinear", "perimeters": 2})
        self.assertIsInstance(plain.config["perimeters"], int)

    def test_tag_and_note_sink_into_the_faces(self):
        tag, note = self.obj.volumes[6], self.obj.volumes[7]
        self.assertAlmostEqual(tag.mesh.bounds()[1], -0.4)
        self.assertAlmostEqual(tag.mesh.bounds()[4], 0.6)
        self.assertAlmostEqual(note.mesh.bounds()[1], 24.4)
        self.assertAlmostEqual(note.mesh.bounds()[4], 25.4)
        self.assertLessEqual(tag.mesh.bounds()[3] - tag.mesh.bounds()[0], 50 - 4 + 0.01)

    def test_features_optional(self):
        project, info = coupon.build_coupon(tag="T", overhang_angle=0, fins=False, hole=0)
        obj = project.objects[0]
        self.assertEqual([v.name for v in obj.volumes], ["body", "tag"])
        text = report_text(coupon, info)
        self.assertIn("wing none, fins none", text)
        self.assertIn("xy preset, foot preset", text)
        self.assertIn("hole=0 ", data_of(text))
        self.assertTrue(data_of(text).endswith(" xy=0"), data_of(text))

    def test_data(self):
        text = report_text(coupon, self.info)
        self.assertEqual(data_of(text),
                         '[filament-dialin] DATA step="coupon" fins=true foot=0.15 height=10 hole=10 length=50 '
                         'overhang_angle=45 perimeters=2 tag="MK4S 0.4" width=25 xy=-0.05')
        self.assertIn("coupon for MK4S 0.4: 50 x 25 x 10 mm, hole 10 mm, wing 45 deg reaching", text)
        self.assertIn("2 perimeters, xy -0.05, foot 0.15", text)

    def test_validation(self):
        for kwargs, message in (({"length": 20}, "at least 30 x 12 x 4"),
                                ({"width": 10}, "at least 30 x 12 x 4"),
                                ({"height": 3}, "at least 30 x 12 x 4"),
                                ({"hole": 24}, "fit inside the coupon"),
                                ({"hole": 21}, "fit inside the coupon"),
                                ({"overhang_angle": 10}, "between 20 and 80"),
                                ({"overhang_angle": 85}, "between 20 and 80"),
                                ({"perimeters": 0}, "between 1 and 20"),
                                ({"perimeters": 21}, "between 1 and 20"),
                                ({"xy_compensation": "abc"}, "must be a number")):
            with self.assertRaises(ValueError) as e:
                coupon.build_coupon(**kwargs)
            self.assertIn(message, str(e.exception))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "c.3mf")
            _, text = run_cli(coupon, ["coupon", "--tag", "T", "--xy-compensation", "-0.05",
                                       "--elephant-foot", "0.15", "--note", "lot 42", "-o", out])
            self.assertIn('DATA step="coupon"', text)
            self.assertIn("xy=-0.05", text)
            names, model, cfg = read_3mf(out)
            obj_meta = [m.get("value") for m in cfg.find(".//object") if m.get("key") == "xy_size_compensation"]
            self.assertEqual(obj_meta, ["-0.05"])


class NozzleClean(unittest.TestCase):
    def file_of(self, printer, **kwargs):
        _, info = clean.build_clean(printer, **kwargs)
        self.assertTrue(os.path.isfile(os.path.join(BUNDLE, *info["file"].split("/"))), info["file"])
        self.assertTrue(os.path.isfile(os.path.join(BUNDLE, *info["plain"].split("/"))), info["plain"])
        return info

    def test_mk4s_and_core_one_files(self):
        info = self.file_of("Original Prusa MK4S 0.4 nozzle")
        self.assertEqual(info["file"], "assets/nozzle/MK4S/MK4S_01_cold_pull_nylon_STD.bgcode")
        self.assertEqual(info["plain"], "assets/nozzle/MK4S/MK4S_01_cold_pull_nylon_STD.gcode")
        self.assertEqual((info["printer_model"], info["family"], info["method"]), ("MK4S", "MK4S", "usb"))
        c1 = self.file_of("Original Prusa CORE One+ 0.4 nozzle")
        self.assertEqual(c1["printer_model"], "COREONE")
        self.assertEqual(c1["file"], "assets/nozzle/COREONE/COREONE_01_cold_pull_nylon_STD.bgcode")
        cl = self.file_of("Original Prusa CORE One L+ HF0.4 nozzle", high_flow=True)
        self.assertEqual(cl["printer_model"], "COREONEL")   # not mistaken for the CORE One
        self.assertEqual(cl["file"], "assets/nozzle/COREONEL/COREONEL_01_cold_pull_nylon_HF.bgcode")
        self.assertEqual(clean.detect("original prusa core one l"), ("COREONEL", "CORE One L / L+"))
        self.assertEqual(clean.detect("Original Prusa CORE One")[0], "COREONE")

    def test_high_flow_variants(self):
        self.assertEqual(self.file_of("MK4S", high_flow=True)["file"],
                         "assets/nozzle/MK4S/MK4S_01_cold_pull_nylon_HF.bgcode")
        self.assertEqual(self.file_of("MK4S", high_flow=True, routine="hot_flush")["file"],
                         "assets/nozzle/MK4S/MK4S_03_hot_flush_HF.bgcode")
        self.assertEqual(self.file_of("MK4S", high_flow=True, routine="flow_test")["file"],
                         "assets/nozzle/MK4S/MK4S_04_flow_test_HF.bgcode")
        # routines without a nozzle variant ignore the High Flow switch
        self.assertEqual(self.file_of("MK4S", high_flow=True, routine="nozzle_brush")["file"],
                         "assets/nozzle/MK4S/MK4S_05_nozzle_brush.bgcode")
        self.assertEqual(self.file_of("MK4S", high_flow=True, routine="cold_pull_pla")["file"],
                         "assets/nozzle/MK4S/MK4S_02_cold_pull_pla.bgcode")

    def test_routine_names_are_normalised(self):
        self.assertEqual(self.file_of("MK4S", routine="Hot Flush")["routine"], "hot_flush")
        self.assertEqual(self.file_of("MK4S", routine="nozzle-brush")["routine"], "nozzle_brush")
        self.assertEqual(self.file_of("MK4S", routine="")["routine"], "cold_pull_nylon")

    def test_every_file_the_command_can_name_ships(self):
        for folder in ("MK4S", "COREONE", "COREONEL"):
            for nz in ("STD", "HF"):
                for ext in (".bgcode", ".gcode"):
                    name = f"{folder}_01_cold_pull_nylon_{nz}{ext}"
                    self.assertTrue(os.path.isfile(os.path.join(BUNDLE, "assets", "nozzle", folder, name)), name)

    def test_failures(self):
        with self.assertRaises(ValueError) as e:
            clean.build_clean("Original Prusa CORE One", routine="hot_flush")
        self.assertIn("exists only for the MK4S", str(e.exception))
        with self.assertRaises(ValueError) as e:
            clean.build_clean("Original Prusa MK4S", routine="acid_bath")
        self.assertIn("Routine must be one of", str(e.exception))
        for unknown in ("Original Prusa XL 0.4 nozzle", "Original Prusa MINI+"):
            with self.assertRaises(ValueError) as e:
                clean.build_clean(unknown)
            self.assertIn("No nozzle maintenance file", str(e.exception))

    def test_report_and_data(self):
        _, info = clean.build_clean("Original Prusa MK4S 0.4 nozzle")
        text = report_text(clean, info)
        self.assertIn("MK4S_01_cold_pull_nylon_STD.bgcode", text)
        self.assertIn("nozzle clean for MK4S 0.4 (MK4S, standard nozzle)", text)
        self.assertIn("nothing was added to the plate", text)
        self.assertEqual(data_of(text),
                         '[filament-dialin] DATA step="clean" family="MK4S" '
                         'file="assets/nozzle/MK4S/MK4S_01_cold_pull_nylon_STD.bgcode" high_flow=false method="usb" '
                         'plain="assets/nozzle/MK4S/MK4S_01_cold_pull_nylon_STD.gcode" printer_model="MK4S" '
                         'routine="cold_pull_nylon" tag="MK4S 0.4"')
        self.assertIn("High Flow nozzle", report_text(clean, clean.build_clean("MK4S", high_flow=True)[1]))

    def test_cli_writes_nothing_and_copies_on_request(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "ignored.3mf")
            path, text = run_cli(clean, ["clean", "--printer", "Original Prusa MK4S 0.4 nozzle", "-o", out])
            self.assertFalse(os.path.exists(out))       # -o is ignored, no 3MF is written
            self.assertIn('DATA step="clean"', text)
            self.assertTrue(os.path.isfile(path))
            stick = os.path.join(d, "usb")
            path, text = run_cli(clean, ["clean", "--printer", "Original Prusa CORE One L", "--high-flow",
                                         "--tag", "C1L", "--copy-to", stick])
            copied = os.path.join(stick, "COREONEL_01_cold_pull_nylon_HF.bgcode")
            self.assertEqual(path, copied)
            self.assertTrue(os.path.isfile(copied))
            self.assertGreater(os.path.getsize(copied), 0)
            self.assertIn("copied COREONEL_01_cold_pull_nylon_HF.bgcode to " + stick, text)
            self.assertIn('tag="C1L"', text)
            self.assertEqual(sorted(os.listdir(stick)), ["COREONEL_01_cold_pull_nylon_HF.bgcode"])


if __name__ == "__main__":
    unittest.main()
