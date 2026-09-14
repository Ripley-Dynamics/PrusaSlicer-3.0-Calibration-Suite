"""Tests for port29.preset29: PrusaSlicer 2.9 filament presets flattened from a
vendor bundle. Uses a small synthetic bundle; the real PrusaResearch.ini is
used too when PRUSA_VENDOR_INI points at one."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from port29 import preset29 as P  # noqa: E402

SYNTHETIC = """
# synthetic vendor bundle
[vendor]
name = Test

[printer:Test Printer 0.4 nozzle]
printer_model = TP
printer_notes = "PRINTER_VENDOR_TEST\\nPRINTER_MODEL_TP"
nozzle_diameter = 0.4
nozzle_high_flow = 0
single_extruder_multi_material = 0

[printer:Test Printer 0.6 nozzle]
inherits = Test Printer 0.4 nozzle
nozzle_diameter = 0.6

[filament:*common*]
filament_density = 1.0
filament_retract_length = 1
start_filament_gcode = "; Filament gcode\\nM900 K0.05"
filament_notes = ""
renamed_from = "Old common"
bed_temperature = 60

[filament:*PET*]
inherits = *common*
filament_density = 1.27
temperature = 240
bed_temperature = 85
custom_a = from PET

[filament:*TP*]
temperature = 250
custom_a = from TP

[filament:Test PETG]
inherits = *PET*
filament_vendor = Tester
compatible_printers_condition = nozzle_diameter[0]!=0.6

[filament:Test PETG @TP]
inherits = Test PETG; *TP*
compatible_printers_condition = printer_model=="TP" and nozzle_diameter[0]==0.4 and ! nozzle_high_flow[0]

[filament:Test PETG @TP 0.6]
inherits = Test PETG; *TP*
temperature = 245
compatible_printers_condition = printer_model=~/(TP|TPX)/ and nozzle_diameter[0]==0.6
"""


class Flatten(unittest.TestCase):
    def setUp(self):
        self.s = P.parse_ini(SYNTHETIC)

    def test_child_wins_then_later_parent(self):
        cfg = P.flatten(self.s, "filament", "Test PETG @TP")
        self.assertEqual(cfg["filament_vendor"], "Tester")            # own chain
        self.assertEqual(cfg["temperature"], "250")                    # *TP* (later parent) beats *PET*
        self.assertEqual(cfg["custom_a"], "from TP")
        self.assertEqual(cfg["filament_density"], "1.27")             # *PET* beats *common*
        self.assertEqual(cfg["bed_temperature"], "85")
        self.assertEqual(cfg["filament_retract_length"], "1")         # from *common* through two levels
        self.assertNotIn("renamed_from", cfg)                          # never inherited
        self.assertEqual(cfg["inherits"], "Test PETG; *TP*")           # the section's own key survives
        self.assertEqual(P.flatten(self.s, "filament", "Test PETG @TP 0.6")["temperature"], "245")

    def test_public_names(self):
        self.assertEqual(sorted(P.filament_names(self.s)), ["Test PETG", "Test PETG @TP", "Test PETG @TP 0.6"])

    def test_unknown(self):
        with self.assertRaises(KeyError):
            P.flatten(self.s, "filament", "Nope")


class Conditions(unittest.TestCase):
    def setUp(self):
        self.s = P.parse_ini(SYNTHETIC)
        self.p04 = P.flatten(self.s, "printer", "Test Printer 0.4 nozzle")
        self.p06 = P.flatten(self.s, "printer", "Test Printer 0.6 nozzle")

    def test_operators(self):
        e = P.eval_condition
        self.assertTrue(e('printer_model=="TP"', self.p04))
        self.assertFalse(e('printer_model!="TP"', self.p04))
        self.assertTrue(e("nozzle_diameter[0]==0.4", self.p04))
        self.assertTrue(e("nozzle_diameter[0]!=0.4", self.p06))
        self.assertTrue(e("printer_model=~/(TP|TPX)/", self.p04))
        self.assertFalse(e("printer_model=~/TPX/", self.p04))
        self.assertTrue(e("printer_notes=~/.*PRINTER_MODEL_TP.*/", self.p04))
        self.assertTrue(e("printer_notes!~/.*MINI.*/", self.p04))
        self.assertTrue(e("! nozzle_high_flow[0]", self.p04))
        self.assertTrue(e("! single_extruder_multi_material", self.p04))
        self.assertTrue(e('(printer_model=="X" or nozzle_diameter[0]==0.4) and ! nozzle_high_flow[0]', self.p04))
        self.assertFalse(e('printer_model=="X" or nozzle_diameter[0]==0.4 and nozzle_high_flow[0]', self.p04))
        self.assertTrue(e("", self.p04))

    def test_compatible_and_pick(self):
        self.assertEqual(P.compatible_filaments(self.s, "Test Printer 0.4 nozzle", "Test PETG"), ["Test PETG", "Test PETG @TP"])
        self.assertEqual(P.compatible_filaments(self.s, "Test Printer 0.6 nozzle", "Test PETG"), ["Test PETG @TP 0.6"])
        # several hits: the most specific (longest) name wins; one hit: that one
        self.assertEqual(P.pick_system_preset(self.s, "Test PETG", printer_preset="Test Printer 0.4 nozzle"), "Test PETG @TP")
        self.assertEqual(P.pick_system_preset(self.s, "Test PETG", printer_preset="Test Printer 0.6 nozzle"), "Test PETG @TP 0.6")
        # by name when no printer preset is known
        self.assertEqual(P.pick_system_preset(self.s, "Test PETG", "TP", 0.4), "Test PETG @TP")
        self.assertEqual(P.pick_system_preset(self.s, "Test PETG", "TP", 0.6), "Test PETG @TP 0.6")
        self.assertEqual(P.pick_system_preset(self.s, "Test PETG", "ZZ", 0.4), "Test PETG")
        with self.assertRaises(KeyError):
            P.pick_system_preset(self.s, "Nope", "TP", 0.4)


class Build(unittest.TestCase):
    def test_build(self):
        s = P.parse_ini(SYNTHETIC)
        text, info = P.build_preset(s, "Test PETG", "Test PETG - dialed", {"temperature": 238, "extrusion_multiplier": 0.9752, "min_fan_speed": None},
                                    "TP", 0.4, "Test Printer 0.4 nozzle", "Per object: xy -0.02", 0.045, "prusa")
        self.assertEqual(info["system_preset"], "Test PETG @TP")
        self.assertEqual(sorted(info["changed"]), ["extrusion_multiplier", "start_filament_gcode", "temperature"])
        cfg = P.parse_ini("[x]\n" + "\n".join(l for l in text.splitlines() if not l.startswith("#")))["x"]
        self.assertEqual(cfg["inherits"], "Test PETG @TP")
        self.assertEqual(cfg["temperature"], "238")
        self.assertEqual(cfg["extrusion_multiplier"], "0.9752")
        self.assertEqual(cfg["filament_density"], "1.27")
        self.assertEqual(cfg["filament_retract_length"], "1")
        self.assertEqual(cfg["compatible_printers"], '"Test Printer 0.4 nozzle"')
        self.assertEqual(cfg["filament_settings_id"], '"Test PETG - dialed"')
        self.assertEqual(P.unquote_ini(cfg["start_filament_gcode"]), "; Filament gcode\nM900 K0.05\nM572 S0.045 ; dialed-in pressure advance")
        self.assertIn("Per object: xy -0.02", P.unquote_ini(cfg["filament_notes"]))
        self.assertNotIn("renamed_from", cfg)
        self.assertNotIn("min_fan_speed", cfg)   # None = keep, and the synthetic bundle has none
        # marlin PA command
        text2, _ = P.build_preset(s, "Test PETG", "n", {}, "TP", 0.4, pressure_advance=0.05, firmware="marlin")
        self.assertIn("M900 K0.05 ; dialed-in pressure advance", text2)

    def test_quote_roundtrip(self):
        for v in ['plain', 'with "quotes"', 'two\nlines', 'back\\slash']:
            self.assertEqual(P.unquote_ini(P.quote_ini(v)), v)
        self.assertEqual(P.safe_filename('a/b:c*d'), "a_b_c_d")

    @unittest.skipUnless(os.environ.get("PRUSA_VENDOR_INI") and os.path.isfile(os.environ.get("PRUSA_VENDOR_INI", "")), "set PRUSA_VENDOR_INI to a PrusaResearch.ini")
    def test_real_bundle(self):
        s = P.parse_ini(open(os.environ["PRUSA_VENDOR_INI"], encoding="utf-8", errors="replace").read())
        self.assertEqual(P.compatible_filaments(s, "Original Prusa MK4S 0.4 nozzle", "Prusament PETG"), ["Prusament PETG @MK4S"])
        self.assertEqual(P.compatible_filaments(s, "Original Prusa MK4S 0.6 nozzle", "Prusament PETG"), ["Prusament PETG @MK4S 0.6"])
        self.assertEqual(P.compatible_filaments(s, "Original Prusa XL 0.4 nozzle", "Prusament PETG"), ["Prusament PETG @XL"])
        text, info = P.build_preset(s, "Prusament PETG", "t", {"temperature": 245}, printer_preset="Original Prusa MK4S 0.4 nozzle")
        self.assertEqual(info["system_preset"], "Prusament PETG @MK4S")
        self.assertGreater(info["keys"], 50)


if __name__ == "__main__":
    unittest.main()
