"""Step 0: which nozzle-maintenance file to run from the USB stick before testing.
Mirrors com.ripleydynamics.filament-dialin/00_nozzle_clean.lua.

Nothing is added to a plate and no 3MF is written: the cleaning runs from the
printer's own firmware. The bundle ships Prusa-firmware maintenance files
(com.ripleydynamics.filament-dialin/assets/nozzle/<PRINTER>/*.bgcode, with the
same sequences as plain .gcode beside them) that home, park high at the bed
centre, heat, purge, cool with the fan and do the extruder-driven cold pull
with the printer's own prompts, thumbnail and progress bar. This command works
out which file matches the printer and nozzle, says where it is, and tells the
sheet; --copy-to puts it on a USB stick.
"""

import os
import re
import shutil

from . import assets
from .common import data_line, log, short_printer_tag

# pattern (on the lowercased printer name), folder, display name.
# Longer names first, so "core one l" is not taken for "core one".
PRINTERS = (
    (re.compile(r"core one l(?![a-z])"), "COREONEL", "CORE One L / L+"),
    (re.compile(r"core one"), "COREONE", "CORE One / One+ / One+ (Gen 2)"),
    (re.compile(r"mk4s"), "MK4S", "MK4S"),
)

# file: {} is the folder name; nozzle: True when STD/HF variants exist.
ROUTINES = {
    "cold_pull_nylon": {"file": "{}_01_cold_pull_nylon", "nozzle": True, "all": True,
                        "what": "nylon purge at 290 C, fan cool-down, extruder-driven cold pull at 145 C"},
    "cold_pull_pla": {"file": "{}_02_cold_pull_pla", "nozzle": False,
                      "what": "the firmware's own Cold Pull numbers with PLA (pull 90 C, hold 95 C)"},
    "hot_flush": {"file": "{}_03_hot_flush", "nozzle": True,
                  "what": "290 C push-through with ram-back cycles, nylon or cleaning filament"},
    "flow_test": {"file": "{}_04_flow_test", "nozzle": True,
                  "what": "PLA at 220 C, stepped speeds with prompts; watch for clicking or thinning"},
    "nozzle_brush": {"file": "{}_05_nozzle_brush", "nozzle": False,
                     "what": "heat to 250 C, park front and high, hold for a brass-brush clean"},
}
ROUTINE_ORDER = ("cold_pull_nylon", "cold_pull_pla", "hot_flush", "flow_test", "nozzle_brush")

DATA_KEYS = ("tag", "routine", "high_flow", "printer_model", "family", "file", "plain", "method")


def detect(name):
    """(folder, family) for a printer name, or (None, None)."""
    lower = str(name).lower()
    for pattern, folder, family in PRINTERS:
        if pattern.search(lower):
            return folder, family
    return None, None


def build_clean(printer, routine="cold_pull_nylon", high_flow=False, tag=""):
    """Works out the maintenance file. Returns (None, info): this step writes no
    3MF, so there is no project to return."""
    routine_key = re.sub(r"[\s\-]", "_", str(routine or "").lower())
    if routine_key == "":
        routine_key = "cold_pull_nylon"
    spec = ROUTINES.get(routine_key)
    if spec is None:
        raise ValueError("Routine must be one of " + ", ".join(ROUTINE_ORDER))
    high_flow = bool(high_flow)

    name = str(printer)
    tag = str(tag or "").strip() or short_printer_tag(name)
    folder, family = detect(name)
    if folder is None:
        supported = "; ".join(p[2] for p in PRINTERS)
        raise ValueError(f"No nozzle maintenance file for printer '{name}'. Files ship for {supported}. "
                         "For other printers use the printer's own cold-pull routine, or adapt the MK4S "
                         "sequence with tools/nozzle-suite/generator/make_suite.py.")
    if not spec.get("all") and folder != "MK4S":
        raise ValueError(f"Routine {routine_key} exists only for the MK4S; the {family} ships cold_pull_nylon.")

    base = spec["file"].format(folder)
    if spec["nozzle"]:
        base = base + ("_HF" if high_flow else "_STD")
    rel = "assets/nozzle/" + folder + "/" + base

    info = {"tag": tag, "routine": routine_key, "high_flow": high_flow, "printer_model": folder, "family": family,
            "file": rel + ".bgcode", "plain": rel + ".gcode", "method": "usb",
            "base": base, "what": spec["what"], "printer": name, "path": assets.asset_path(rel + ".bgcode")}
    return None, info


def report(info):
    log(f"nozzle clean for {info['tag']} ({info['family']}, {'High Flow' if info['high_flow'] else 'standard'} nozzle): "
        f"run {info['base']}.bgcode from the USB stick")
    log(f"the file is in the bundle: {info['path']} (the sheet offers it as a download; "
        f"the same sequence as plain G-code is {info['base']}.gcode)")
    log("routine: " + info["what"])
    log("before the run: load the filament the prompt names, put a scrap of paper on the bed under the nozzle, "
        "watch the first run; the prompts say Continue, the printer's button says Resume")
    log("a suspected clog (MK4S): flow_test, hot_flush, flow_test, cold_pull_nylon, flow_test; "
        "do not use a needle on a High Flow / CHT nozzle")
    log("nothing was added to the plate; this step prints from the USB stick, not from PrusaSlicer")
    print(data_line("clean", {k: info[k] for k in DATA_KEYS}))


def add_cli(sub, common):
    p = sub.add_parser("clean", parents=[common],
                       help="Step 0: the nozzle maintenance file to run from the USB stick (no 3MF)")
    p.add_argument("--printer", required=True,
                   help="printer name, as PrusaSlicer shows it (MK4S, CORE One, CORE One L)")
    p.add_argument("--routine", default="cold_pull_nylon",
                   help="cold_pull_nylon (default), cold_pull_pla, hot_flush, flow_test, nozzle_brush "
                        "(the last four: MK4S only)")
    p.add_argument("--high-flow", action="store_true", help="High Flow / CHT nozzle (longer soak, bigger purge)")
    p.add_argument("--copy-to", default=None, help="copy the .bgcode into this directory (a USB stick)")
    p.add_argument("--tag", default="", help="printer tag for the sheet (blank = from the printer name)")
    p.set_defaults(run=run)


def run(args):
    """Prints where the file is; writes no 3MF, so args.output is ignored."""
    _, info = build_clean(args.printer, args.routine, args.high_flow, args.tag)
    report(info)
    dest = info["path"]
    if args.copy_to:
        if not os.path.isfile(info["path"]):
            raise ValueError(f"{info['file']} is not in the bundle at {info['path']}")
        os.makedirs(args.copy_to, exist_ok=True)
        dest = shutil.copy2(info["path"], os.path.join(args.copy_to, info["base"] + ".bgcode"))
        log(f"copied {info['base']}.bgcode to {args.copy_to}")
    return dest
