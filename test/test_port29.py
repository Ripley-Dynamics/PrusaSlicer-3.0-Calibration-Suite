"""Tests for the PrusaSlicer 2.9 port (port29): the 3MF writer, the primitives,
the stroke font and the slab step. Run: python3 -m unittest discover -s test -p 'test_*.py'"""

import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from port29 import geometry as g  # noqa: E402
from port29.common import data_line, fmt  # noqa: E402
from port29.slab import build_slab  # noqa: E402
from port29.threemf import MODEL_PART, MODIFIER, NEGATIVE_VOLUME, Mesh, Object3mf, Project, Volume  # noqa: E402

NS = {"m": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"}


def read_3mf(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    model = ET.fromstring(z.read("3D/3dmodel.model"))
    cfg = ET.fromstring(z.read("Metadata/Slic3r_PE_model.config"))
    gcode = ET.fromstring(z.read("Metadata/Prusa_Slicer_custom_gcode_per_print_z.xml")) if "Metadata/Prusa_Slicer_custom_gcode_per_print_z.xml" in names else None
    return names, model, cfg, gcode


def sub_mesh(verts, tris):
    used = sorted({i for t in tris for i in t})
    remap = {o: n for n, o in enumerate(used)}
    return Mesh([verts[i] for i in used], [tuple(remap[i] for i in t) for t in tris])


class Primitives(unittest.TestCase):
    def check_solid(self, m, volume, places=3):
        self.assertTrue(m.is_closed(), "mesh is not closed")
        self.assertAlmostEqual(m.signed_volume(), volume, places=places)

    def test_box(self):
        self.check_solid(g.box(2, 3, 4), 24)
        self.assertEqual(g.box(2, 3, 4).bounds(), (0, 0, 0, 2, 3, 4))

    def test_cylinder_cone_pyramid(self):
        import math
        self.assertTrue(g.cylinder(5, 10, 256).is_closed())
        self.assertAlmostEqual(g.cylinder(5, 10, 256).signed_volume(), math.pi * 25 * 10, delta=1.0)
        self.assertTrue(g.cone(5, 10, 256).is_closed())
        self.assertAlmostEqual(g.cone(5, 10, 256).signed_volume(), math.pi * 25 * 10 / 3, delta=0.5)
        self.check_solid(g.pyramid(6, 9), 6 * 6 * 9 / 3)

    def test_transforms(self):
        m = g.box(1, 2, 3).rotate_x(90)
        b = m.bounds()
        self.assertAlmostEqual(b[1], -3)
        self.assertAlmostEqual(b[4], 0)
        self.assertAlmostEqual(b[5], 2)
        m2 = g.box(1, 2, 3).rotate_x(90).rotate_z(180).translate(10, 20, 30)
        b2 = m2.bounds()
        self.assertAlmostEqual(b2[0], 9)
        self.assertAlmostEqual(b2[4], 23)


class StrokeFont(unittest.TestCase):
    def test_every_glyph_is_a_closed_solid(self):
        for ch in g.GLYPHS:
            m = g.stroke_text(ch, 6)
            self.assertTrue(m.vertices, ch)
            self.assertTrue(m.is_closed(), ch)
            self.assertGreater(m.signed_volume(), 0, ch)
            b = m.bounds()
            self.assertAlmostEqual(b[2], 0)
            self.assertAlmostEqual(b[5], 1)

    def test_centred_and_sized(self):
        m = g.stroke_text("73.7cc 93.6g", 6)
        b = m.bounds()
        self.assertAlmostEqual((b[0] + b[3]) / 2, 0, places=6)
        self.assertAlmostEqual((b[1] + b[4]) / 2, 0, places=6)
        self.assertGreater(b[4] - b[1], 6)         # cap height plus stroke
        self.assertLess(b[4] - b[1], 7.5)

    def test_fit_shrinks(self):
        m, lh, w, h = g.text_mesh("MK4S 0.4 SPOOL 12", 6, max_width=30)
        self.assertLessEqual(w, 30.01)
        self.assertLess(lh, 6)

    def test_unknown_characters_do_not_crash(self):
        self.assertTrue(g.stroke_text("ä§ end", 5).is_closed())


class Writer(unittest.TestCase):
    def test_roundtrip_structure(self):
        p = Project("t")
        obj = Object3mf("thing", [Volume(g.box(10, 10, 10), MODEL_PART, "body"),
                                  Volume(g.box(12, 12, 12).translate(-1, -1, -1), MODIFIER, "mod", {"fill_density": "0%"}),
                                  Volume(g.box(2, 2, 2).translate(4, 4, 9), NEGATIVE_VOLUME, "hole")],
                        {"perimeters": 3}, position=(100, 100))
        p.add_object(obj)
        p.add_custom_gcode(5.1, "M104 S250")
        p.add_custom_gcode(0.1, "M221 S95 ; a \"quoted\" <thing>")
        with tempfile.TemporaryDirectory() as d:
            path = p.write(os.path.join(d, "t.3mf"))
            names, model, cfg, gcode = read_3mf(path)
        self.assertIn("[Content_Types].xml", names)
        self.assertIn("_rels/.rels", names)
        tris = model.findall(".//m:triangle", NS)
        self.assertEqual(len(tris), 36)
        vols = cfg.findall(".//volume")
        self.assertEqual([(v.get("firstid"), v.get("lastid")) for v in vols], [("0", "11"), ("12", "23"), ("24", "35")])
        types = [[m.get("value") for m in v if m.get("key") == "volume_type"][0] for v in vols]
        self.assertEqual(types, [MODEL_PART, MODIFIER, NEGATIVE_VOLUME])
        self.assertTrue(any(m.get("key") == "modifier" and m.get("value") == "1" for m in vols[1]))
        self.assertTrue(any(m.get("key") == "fill_density" and m.get("value") == "0%" for m in vols[1]))
        self.assertTrue(any(m.get("key") == "perimeters" and m.get("value") == "3" for m in cfg.find(".//object")))
        codes = gcode.findall("code")
        self.assertEqual([c.get("print_z") for c in codes], ["0.1", "5.1"])
        self.assertEqual(codes[0].get("type"), "4")
        self.assertEqual(codes[0].get("extra"), 'M221 S95 ; a "quoted" <thing>')
        self.assertEqual(gcode.find("mode").get("value"), "SingleExtruder")
        self.assertEqual(model.find(".//m:item", NS).get("transform"), "1 0 0 0 1 0 0 0 1 100 100 0")
        self.assertEqual(model.find(".//m:metadata[@name='slic3rpe:Version3mf']", NS).text, "1")


class Slab(unittest.TestCase):
    def test_default_slab_matches_the_plugin(self):
        project, info = build_slab(tag="MK4S 0.4")
        self.assertAlmostEqual(info["volume_cm3"], 73.728)
        self.assertAlmostEqual(info["expected_g"], 93.63456)
        self.assertEqual(info["density_source"], "default for Prusament PETG")
        obj = project.objects[0]
        self.assertEqual(obj.config, {"fill_density": "100%", "fill_pattern": "rectilinear"})
        self.assertEqual([v.vtype for v in obj.volumes], [MODEL_PART] * 5 + [NEGATIVE_VOLUME] * 2)
        self.assertEqual(obj.position, (95.0, 75.0))
        for v in obj.volumes:
            self.assertTrue(v.mesh.is_closed(), v.name)
            self.assertGreater(v.mesh.signed_volume(), 0, v.name)
        for i in range(1, 5):
            b = obj.volumes[i].mesh.bounds()
            self.assertAlmostEqual(b[2], 20)
            self.assertAlmostEqual(b[5], 32)
        front = obj.volumes[5].mesh.bounds()
        self.assertAlmostEqual(front[1], -0.4)   # 0.4 mm proud of the front face
        self.assertAlmostEqual(front[4], 0.6)    # 0.6 mm into the part
        self.assertLessEqual(front[3] - front[0], 56.01)
        back = obj.volumes[6].mesh.bounds()
        self.assertAlmostEqual(back[1], 59.4)
        self.assertAlmostEqual(back[4], 60.4)
        self.assertEqual(data_line("slab", {"x": 60, "tag": "MK4S 0.4", "posts": True, "expected_g": 93.63456}),
                         '[filament-dialin] DATA step="slab" expected_g=93.6346 posts=true tag="MK4S 0.4" x=60')

    def test_options_and_validation(self):
        _, info = build_slab(40, 50, 10, posts=False, density=1.24, tag="X", note="spool 7", bed=(300, 300))
        self.assertAlmostEqual(info["volume_cm3"], 20.0)
        self.assertAlmostEqual(info["expected_g"], 24.8)
        with self.assertRaises(ValueError):
            build_slab(10, 60, 20)
        with self.assertRaises(ValueError):
            build_slab(density=5)

    def test_cli_writes_a_project(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "s.3mf")
            r = subprocess.run([sys.executable, "-m", "port29", "slab", "--tag", "C1 0.4", "--bed", "250x220", "--x", "50", "-o", out],
                               capture_output=True, text=True, cwd=os.path.join(os.path.dirname(__file__), ".."))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('DATA step="slab"', r.stdout)
            self.assertIn("x=50", r.stdout)
            names, model, cfg, _ = read_3mf(out)
            self.assertEqual(model.find(".//m:item", NS).get("transform"), "1 0 0 0 1 0 0 0 1 100 80 0")
            verts = [[float(v.get(a)) for a in "xyz"] for v in model.findall(".//m:vertex", NS)]
            tris = [tuple(int(t.get(a)) for a in ("v1", "v2", "v3")) for t in model.findall(".//m:triangle", NS)]
            for v in cfg.findall(".//volume"):
                m = sub_mesh(verts, tris[int(v.get("firstid")):int(v.get("lastid")) + 1])
                self.assertTrue(m.is_closed())

    def test_fmt(self):
        self.assertEqual(fmt(73.728, 1), "73.7")
        self.assertEqual(fmt(60.0), "60")
        self.assertEqual(fmt(-0.0001), "0")


if __name__ == "__main__":
    unittest.main()
