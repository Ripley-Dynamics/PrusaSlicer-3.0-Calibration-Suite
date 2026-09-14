#!/usr/bin/env python3
"""Prusa nozzle-maintenance suite: generates one .bgcode (plus readable .gcode) per routine.

Usage: python3 make_suite.py            -> everything in BUILD
       python3 make_suite.py MK4S       -> one printer

Routines
  01 cold_pull_nylon  STD/HF  nylon purge 290C -> cool -> 145C extruder-driven cold pull
  02 cold_pull_pla            the firmware's own Cold Pull recipe (M1702) as a file: PLA, 90/95C
  03 hot_flush        STD/HF  290C push-through flush with ram/retract cycles to break up debris
  04 flow_test        STD/HF  PLA at 220C, stepped extrusion speeds, watch for clicking/thinning
  05 nozzle_brush             heat to 250C, park front and high, hold for a brass-brush clean

All follow the firmware Cold Pull (Prusa-Firmware-Buddy src/marlin_stubs/M1702.cpp) conventions:
fan 240/255 for cooling, 50 mm/s extruder pull under a cold-extrude guard, prompt for the
manual pull. bgcode packing per libbgcode doc/specifications.md (v1, CRC32, no compression).

Firmware facts the sequences rely on (all verified in the Buddy source):
  * M0 <text> shows a Quick Pause dialog with the text and a Continue button, heaters stay on.
  * M302 S0 allows extruding below 170C (needed for the 145C / 95C pull); M302 S170 re-arms.
  * When filament leaves the sensor mid-print the firmware injects "M600 A". It is re-armed
    (M302 S170) before the pull finishes so that M600 exits at once with "hotend too cold".
  * M591 S0 / M591 R switch the loadcell filament-stuck detector off / back to its setting.
  * M862.1 F1 makes the pre-print check warn "Nozzle not high-flow" if Nozzle Type is Standard.
  * MAX_CMD_SIZE is 96: every line here is kept under 90 characters.
"""
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from thumbs import thumbnails, HOT, COLD, WHITE, GREEN  # noqa: E402

OUT = Path(__file__).parent / "out_suite"
MAX_LINE = 90

# pull_mm = min(300, EXTRUDE_MAXLENGTH) as in firmware M1702; EXTRUDE_MAXLENGTH is 200 on MK4S, 1000 on Core One
PRINTERS = {
    "MK4S":     dict(pid="MK4S", label="Original Prusa MK4S", pull_mm=200, x=125, y=105, z=100, brush_xyz=(125, 0, 150)),
    "COREONE":  dict(pid="COREONE", label="Prusa CORE One", pull_mm=300, x=125, y=110, z=100, brush_xyz=(125, 0, 150)),
    "COREONEL": dict(pid="COREONEL", label="Prusa CORE One L", pull_mm=300, x=150, y=150, z=100, brush_xyz=(150, 0, 150)),
}
# which routines are built per printer (the full suite is MK4S-only for now)
BUILD = {
    "MK4S": ["cold_pull_nylon:STD", "cold_pull_nylon:HF", "cold_pull_pla", "hot_flush:STD", "hot_flush:HF",
             "flow_test:STD", "flow_test:HF", "nozzle_brush"],
    "COREONE": ["cold_pull_nylon:STD", "cold_pull_nylon:HF"],
    "COREONEL": ["cold_pull_nylon:STD", "cold_pull_nylon:HF"],
}

NOZZLES = {
    "STD": dict(label="Standard nozzle", thumb="STANDARD NOZZLE", hf_flag=False),
    "HF": dict(label="High Flow / CHT nozzle", thumb="HIGH FLOW / CHT", hf_flag=True),
}


class G:
    """Tiny G-code builder with the shared prologue/epilogue."""

    def __init__(self, p: dict, title: str, comments: list[str], hf_flag: bool, minutes: int):
        self.p = p
        self.L: list[str] = []
        a = self.a
        a(f"; {title}")
        for c in comments:
            a(f"; {c}")
        a(f'M862.3 P "{self.p["pid"]}" ; printer model check')
        if hf_flag:
            a("M862.1 F1 ; needs a high-flow nozzle: printer warns if Nozzle Type is Standard")
        a("M17 ; enable steppers")
        a("G90 ; absolute XYZ")
        a("M83 ; relative E")
        a("M107 ; fan off")
        a("M302 S170 ; cold-extrusion protection at the default")
        a("M591 S0 ; filament-stuck (loadcell) detection off for this job, restored at end")
        a(f"M73 P0 R{minutes}")
        a("M117 Homing")
        a("G28 ; home all")

    def a(self, line: str):
        assert len(line) < MAX_LINE, f"line too long for firmware buffer: {line!r}"
        self.L.append(line)

    def park(self, x=None, y=None, z=None):
        p = self.p
        self.a(f"G1 Z{z if z is not None else p['z']} F720")
        self.a(f"G1 X{x if x is not None else p['x']} Y{y if y is not None else p['y']} F6000")
        self.a("M400")

    def prompt(self, text: str):
        self.a(f"M0 {text}")

    def heat(self, temp: int, label: str = None):
        self.a(f"M117 {label or f'Heating to {temp}C'}")
        self.a(f"M104 S{temp}")
        self.a(f"M109 S{temp}")

    def extrude(self, mm: float, feed: int):
        """Extrude mm (may exceed 200) at feed mm/min, split under EXTRUDE_MAXLENGTH."""
        done = 0
        while done < mm:
            step = min(40, mm - done)
            self.a(f"G1 E{step:g} F{feed}")
            done += step

    def cool(self, to: int, dwell_s: int):
        self.a("M117 Cooling down")
        self.a("M104 S0")
        self.a("M106 S240")
        self.a(f"M109 R{to} ; wait until the nozzle has cooled to {to}C")
        self.a(f"G4 S{dwell_s}")
        self.a("M107")

    def pull(self, pull_temp: int, hold_temp: int):
        """Firmware-style automatic pull: heat, allow cold extrusion, retract at 50 mm/s."""
        self.a(f"M117 Heating to {pull_temp}C for the pull")
        self.a(f"M109 S{pull_temp}")
        if hold_temp != pull_temp:
            self.a(f"M104 S{hold_temp} ; firmware raises the target slightly for the pull")
        self.a("M117 Cold pull")
        self.a("M302 S0 ; allow cold extrusion for the pull")
        self.a(f"G1 E-{self.p['pull_mm']} F3000")
        self.a("M302 S170 ; re-arm cold-extrusion protection (runout M600 then no-ops)")
        self.a("M400")
        self.a("M300 S440 P300")
        self.prompt("Pull the filament out of the extruder by hand now, then press Continue")

    def end(self, msg: str, fan_cool_s: int = 0):
        self.a("M73 P100 R0")
        self.a("M104 S0")
        if fan_cool_s:
            self.a("M106 S240")
            self.a(f"G4 S{fan_cool_s}")
        self.a("M107")
        self.a("M591 R ; restore filament-stuck detection")
        self.a("M84")
        self.a(f"M117 {msg}")

    def text(self) -> str:
        return "\n".join(self.L) + "\n"


# ---------------------------------------------------------------- routines
def cold_pull_nylon(p: dict, nz: str):
    n = NOZZLES[nz]
    hf = n["hf_flag"]
    purge_mm, feed = (120, 300) if hf else (80, 180)
    g = G(p, f"01 Nylon cold pull - {p['label']} - {n['label']}",
          [f"purge {purge_mm} mm PA at 290C, cool to 60C, pull at 145C (firmware M1702 pattern)",
           "Load nylon (PA) BEFORE starting this file."], hf, 12)
    g.park()
    g.prompt("Nylon loaded? Put paper under the nozzle to catch the purge, then Continue")
    g.a("M73 P5 R11")
    g.heat(290)
    if hf:
        g.a("M117 Soaking at temperature")
        g.a("G4 S45 ; let the melt wet all channels of the CHT core")
    g.a("M117 Purging nylon")
    g.a("M73 P15 R9")
    g.extrude(purge_mm, feed)
    g.a("G4 S3")
    g.a("M400")
    if hf:
        g.a("G4 S30 ; soak again so the nylon bonds to residue before cooling")
    g.a("M73 P35 R7")
    g.cool(60, 120)
    g.a("M73 P75 R3")
    g.pull(145, 145)
    g.end("Cold pull finished")
    spec = dict(icon="pull", title=["NYLON", "COLD PULL"],
                rows=[("Purge  290°C", HOT), ("Pull    145°C", COLD)],
                nozzle=n["thumb"], printer=p["label"])
    return g.text(), spec, "PA", purge_mm, f"01_cold_pull_nylon_{nz}"


def cold_pull_pla(p: dict):
    g = G(p, f"02 PLA cold pull (firmware recipe) - {p['label']}",
          ["same numbers as the firmware Cold Pull: cool with fan, pull at 90C, hold 95C",
           "Load PLA BEFORE starting this file. Any nozzle type."], False, 10)
    g.park()
    g.prompt("PLA loaded? Put paper under the nozzle to catch the purge, then Continue")
    g.a("M73 P5 R9")
    g.heat(215)
    g.a("M117 Purging PLA")
    g.extrude(30, 180)
    g.a("G4 S3")
    g.a("M400")
    g.a("M73 P30 R7")
    g.cool(45, 120)
    g.a("M73 P75 R2")
    g.pull(90, 95)
    g.end("Cold pull finished")
    spec = dict(icon="pull", title=["PLA", "COLD PULL"],
                rows=[("Purge  215°C", HOT), ("Pull      90°C", COLD)],
                nozzle="ANY NOZZLE", printer=p["label"])
    return g.text(), spec, "PLA", 30, "02_cold_pull_pla"


def hot_flush(p: dict, nz: str):
    n = NOZZLES[nz]
    hf = n["hf_flag"]
    stages, feed, soak = (6, 360, 45) if hf else (5, 180, 30)
    total = stages * 40
    g = G(p, f"03 Hot flush - {p['label']} - {n['label']}",
          [f"290C push-through: {stages} x 40 mm with a 10 mm ram-back between stages",
           "Use nylon or a cleaning filament. Load it BEFORE starting this file.",
           "Clears colour / material carry-over and soft partial clogs. Nothing is pulled."],
          hf, 10)
    g.park()
    g.prompt("Nylon or cleaning filament loaded? Paper under the nozzle? Then Continue")
    g.a("M73 P5 R9")
    g.heat(290)
    g.a("M117 Soaking at temperature")
    g.a(f"G4 S{soak}")
    for i in range(stages):
        g.a(f"M117 Flush stage {i + 1}/{stages}")
        g.a(f"M73 P{15 + int(70 * i / stages)} R{8 - int(7 * i / stages)}")
        g.a(f"G1 E40 F{feed}")
        g.a("G1 E-10 F1200 ; ram back to break up debris")
        g.a("G4 S2")
        g.a("G1 E10 F600")
    g.a("M117 Final slow push")
    g.a("G1 E20 F120")
    g.a("M400")
    g.a("M300 S440 P300")
    g.prompt("Flush done. Unload it from the menu and load your print filament. Continue")
    g.end("Hot flush finished")
    spec = dict(icon="flush", title=["HOT", "FLUSH"],
                rows=[("290°C", HOT), (f"{total} mm push-through", WHITE)],
                nozzle=n["thumb"], printer=p["label"])
    return g.text(), spec, "PA", total + 20, f"03_hot_flush_{nz}"


def flow_test(p: dict, nz: str):
    n = NOZZLES[nz]
    hf = n["hf_flag"]
    speeds = (4, 8, 11) if hf else (2, 4, 6)  # mm/s of 1.75 filament
    g = G(p, f"04 Flow test - {p['label']} - {n['label']}",
          ["PLA at 220C, 40 mm at each speed, prompt between stages so you can watch",
           "Clicking / grinding or a thin curling strand = restriction at that flow.",
           "Load PLA BEFORE starting this file."], hf, 6)
    g.park()
    g.prompt("PLA loaded? Paper under the nozzle? Watch the nozzle during each stage")
    g.heat(220)
    g.a("M117 Priming")
    g.a("G1 E15 F180")
    g.a("M400")
    for i, sp in enumerate(speeds):
        mm3 = round(sp * 2.405)
        g.a(f"M73 P{10 + int(80 * i / len(speeds))} R{5 - i}")
        g.prompt(f"Stage {i + 1}: 40mm at {sp} mm/s ({mm3} mm3/s). Watch for clicks or thinning")
        g.a(f"M117 Flow test {sp} mm/s")
        g.a(f"G1 E40 F{sp * 60}")
        g.a("M400")
        g.a("G4 S2")
    g.a("M300 S440 P300")
    g.prompt("Done. The first stage that clicked or thinned is the nozzle's real limit")
    g.end("Flow test finished")
    spec = dict(icon="test", title=["FLOW", "TEST"],
                rows=[("PLA  220°C", HOT), ("  ".join(f"{s}" for s in speeds) + " mm/s", WHITE)],
                nozzle=n["thumb"], printer=p["label"])
    return g.text(), spec, "PLA", 15 + 40 * len(speeds), f"04_flow_test_{nz}"


def nozzle_brush(p: dict):
    g = G(p, f"05 Nozzle brush clean - {p['label']}",
          ["heats to 250C, parks the nozzle front and high, holds while you brass-brush it",
           "Any filament, any nozzle. Keep the brush off the silicone sock and thermistor."],
          False, 5)
    bx, by, bz = p['brush_xyz']
    g.park(x=bx, y=by, z=bz)
    g.prompt("Have a brass brush ready. The nozzle will heat to 250C. Continue")
    g.heat(250)
    g.a("M300 S440 P300")
    g.prompt("HOT! Brush the nozzle tip and sides now. Press Continue when done")
    g.a("M117 Cooling with fan")
    g.end("Nozzle brush finished", fan_cool_s=90)
    spec = dict(icon="brush", title=["NOZZLE", "BRUSH"],
                rows=[("Hold  250°C", HOT), ("brass brush the tip", WHITE)],
                nozzle="ANY NOZZLE", printer=p["label"])
    return g.text(), spec, None, 0, "05_nozzle_brush"


# ---------------------------------------------------------------- bgcode writer
MAGIC = b"GCDE"
VERSION = 1
CHECKSUM_CRC32 = 1
BT_FILE_META, BT_GCODE, BT_SLICER_META, BT_PRINTER_META, BT_PRINT_META, BT_THUMB = 0, 1, 2, 3, 4, 5


def block(btype: int, params: bytes, data: bytes) -> bytes:
    header = struct.pack("<HHI", btype, 0, len(data))
    payload = header + params + data
    return payload + struct.pack("<I", zlib.crc32(payload) & 0xFFFFFFFF)


def ini(pairs) -> bytes:
    return "".join(f"{k}={v}\n" for k, v in pairs if v is not None).encode()


def bgcode(p: dict, gcode: str, spec: dict, filament: str, used_mm: int, minutes: int) -> bytes:
    enc0 = struct.pack("<H", 0)
    used = [("filament used [mm]", f"{used_mm}"),
            ("filament used [g]", f"{used_mm * 0.00275:.2f}"),
            ("filament used [cm3]", f"{used_mm * 0.0024:.2f}"),
            ("estimated printing time (normal mode)", f"{minutes}m 0s")]
    out = MAGIC + struct.pack("<IH", VERSION, CHECKSUM_CRC32)
    out += block(BT_FILE_META, enc0, ini([("Producer", "mk4s nozzle maintenance suite")]))
    out += block(BT_PRINTER_META, enc0, ini(
        [("printer_model", p["pid"]), ("filament_type", filament)] + used
        + [("bed_temperature", "0"), ("extruder_colour", "#F0F0F0")]))
    for fmt, w, h, data, _img in thumbnails(spec):
        out += block(BT_THUMB, struct.pack("<HHH", fmt, w, h), data)
    out += block(BT_PRINT_META, enc0, ini(used))
    out += block(BT_SLICER_META, enc0, ini([
        ("printer_model", p["pid"]), ("filament_type", filament),
        ("notes", " ".join(spec["title"]) + f" - {spec['nozzle']} - {p['label']}")]))
    out += block(BT_GCODE, enc0, gcode.encode())
    return out


def read_bgcode(buf: bytes):
    magic, version, cks = struct.unpack_from("<4sIH", buf, 0)
    assert magic == MAGIC and version == VERSION and cks == CHECKSUM_CRC32, "bad file header"
    pos, blocks = 10, []
    while pos < len(buf):
        btype, comp, usize = struct.unpack_from("<HHI", buf, pos)
        hlen = 8 if comp == 0 else 12
        dsize = usize if comp == 0 else struct.unpack_from("<I", buf, pos + 8)[0]
        plen = 2 if btype != BT_THUMB else 6
        end = pos + hlen + plen + dsize
        crc_stored = struct.unpack_from("<I", buf, end)[0]
        assert crc_stored == zlib.crc32(buf[pos:end]) & 0xFFFFFFFF, f"CRC mismatch, block {btype}"
        blocks.append((btype, buf[pos + hlen + plen:end]))
        pos = end + 4
    assert pos == len(buf), "trailing bytes"
    order = [b for b, _ in blocks]
    nthumb = order.count(BT_THUMB)
    assert order == [BT_FILE_META, BT_PRINTER_META] + [BT_THUMB] * nthumb + [BT_PRINT_META, BT_SLICER_META, BT_GCODE], order
    return blocks


ROUTINE_FNS = {"cold_pull_nylon": cold_pull_nylon, "cold_pull_pla": cold_pull_pla,
               "hot_flush": hot_flush, "flow_test": flow_test, "nozzle_brush": nozzle_brush}


def main():
    OUT.mkdir(exist_ok=True)
    want = sys.argv[1:] or list(BUILD)
    for pid in want:
        p = PRINTERS[pid]
        for key in BUILD[pid]:
            fn, *nz = key.split(":")
            gcode, spec, filament, used_mm, name = ROUTINE_FNS[fn](p, *nz)
            minutes = int(gcode.split("M73 P0 R")[1].split()[0])
            b = bgcode(p, gcode, spec, filament, used_mm, minutes)
            fname = f"{pid}_{name}"
            (OUT / f"{fname}.gcode").write_text(gcode)
            (OUT / f"{fname}.bgcode").write_bytes(b)
            assert read_bgcode(b)[-1][1].decode() == gcode, "gcode round-trip mismatch"
            print(f"{fname}: {len(b)} bytes, {len(gcode.splitlines())} lines, verified")


if __name__ == "__main__":
    sys.exit(main())
