"""Step 13 for PrusaSlicer 2.9.x: a complete user filament preset (.ini).

PrusaSlicer 2.9 keeps user presets as full .ini files in <user data>/filament/.
A config bundle whose section only `inherits` a system preset starts from the
program defaults, not from that preset (PresetBundle::load_configbundle in
2.9.6), so the file has to carry every key. This module reads the vendor
bundle PrusaSlicer 2.9 ships (PrusaResearch.ini), flattens the `inherits`
chain of the chosen system filament exactly as PrusaSlicer does (child keys
win; parents are applied last-to-first, so a later parent in the list wins
over an earlier one; `renamed_from` is not inherited), applies the dialed-in
values and writes the result with `inherits = <system preset>` so PrusaSlicer
shows it as derived from that preset.

    python3 -m port29 preset --base "Prusament PETG" --model MK4S --nozzle 0.4 \
        --name "Prusament PETG - MK4S 0.4 dialed" --temperature 245 ... -o out.ini
    python3 -m port29 preset ... --install      # writes into <user data>/filament/

Pressure advance has no preset key in 2.9: it is appended to
start_filament_gcode as an M572 (Prusa) / M900 (Marlin) line.
"""

import os
import platform
from datetime import date
from pathlib import Path

from .common import fmt, log

FILAMENT = "filament"


def data_dir_candidates():
    system = platform.system()
    names = ["PrusaSlicer", "PrusaSlicer-beta", "PrusaSlicer-alpha"]
    if system == "Windows":
        base = Path(os.environ.get("APPDATA", Path.home()))
    elif system == "Darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return [base / n for n in names]


def find_vendor_ini(vendor="PrusaResearch"):
    """PrusaSlicer copies the vendor bundles it uses into <user data>/vendor/."""
    for d in data_dir_candidates():
        p = d / "vendor" / f"{vendor}.ini"
        if p.is_file():
            return p
    return None


def parse_ini(text):
    """[section] -> ordered dict of key -> raw value string. PrusaSlicer's
    format: one `key = value` per line, values verbatim (quoted G-code keeps
    its quotes and \\n escapes), '#' comments, no continuation lines."""
    sections, current = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, {})
            continue
        if current is None or "=" not in line:
            continue
        k, v = line.split("=", 1)
        sections[current][k.strip()] = v.strip()
    return sections


def split_inherits(value):
    return [p.strip() for p in value.split(";") if p.strip()]


def flatten(sections, kind, name, _cache=None):
    """The fully resolved key set of preset `kind:name`, following PrusaSlicer's
    flatten_configbundle_hierarchy."""
    _cache = {} if _cache is None else _cache
    if name in _cache:
        return _cache[name]
    key = f"{kind}:{name}"
    if key not in sections:
        raise KeyError(f"{kind} preset '{name}' is not in the vendor bundle")
    own = dict(sections[key])
    result = dict(own)
    for parent in reversed(split_inherits(own.get("inherits", ""))):
        for k, v in flatten(sections, kind, parent, _cache).items():
            if k == "renamed_from":
                continue
            result.setdefault(k, v)
    _cache[name] = result
    return result


def filament_names(sections):
    return [s[len(FILAMENT) + 1:] for s in sections if s.startswith(FILAMENT + ":") and not s[len(FILAMENT) + 1:].startswith("*")]


# --- PrusaSlicer's compatibility conditions -----------------------------------
# compatible_printers_condition is a small expression language: ==, !=, =~ and
# !~ (regex, whole-string match), and/or/!, parentheses, string literals,
# numbers and config keys with an optional [index]. It is evaluated against
# the printer preset's flattened values, which is exactly what PrusaSlicer does
# to decide which filaments a printer shows.
import re as _re

_TOK = _re.compile(r'\s*(?:(==|!=|=~|!~|&&|\|\||[()!])|("(?:[^"\\]|\\.)*")|(/(?:[^/\\]|\\.)*/)|([A-Za-z_][A-Za-z0-9_]*(?:\[\d+\])?)|([-+]?\d+(?:\.\d+)?))')


def _tokens(expr):
    out, i = [], 0
    expr = expr.strip()
    while i < len(expr):
        m = _TOK.match(expr, i)
        if not m or m.end() == i:
            raise ValueError(f"cannot parse condition near: {expr[i:i+20]!r}")
        i = m.end()
        op, s, rx, ident, num = m.groups()
        if op: out.append(("op", op))
        elif s: out.append(("str", s[1:-1].replace('\\"', '"').replace("\\\\", "\\")))
        elif rx: out.append(("rx", rx[1:-1]))
        elif ident:
            if ident in ("and", "or", "not"): out.append(("op", {"and": "&&", "or": "||", "not": "!"}[ident]))
            else: out.append(("id", ident))
        elif num: out.append(("num", num))
    return out


def _lookup(cfg, ident):
    m = _re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?:\[(\d+)\])?", ident)
    key, idx = m.group(1), m.group(2)
    raw = unquote_ini(cfg.get(key, ""))
    if idx is not None:
        parts = [p.strip() for p in raw.split(",")] if raw else [""]
        raw = parts[min(int(idx), len(parts) - 1)]
    return raw


def _as_number(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _truthy(v):
    n = _as_number(v)
    return bool(n) if n is not None else bool(v)


def eval_condition(expr, cfg):
    """True when `expr` (a compatible_printers_condition) holds for the
    flattened printer config `cfg`. An empty condition is always true."""
    if not str(expr).strip():
        return True
    toks = _tokens(expr)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else (None, None)

    def take():
        t = toks[pos[0]]; pos[0] += 1
        return t

    def value():
        kind, v = take()
        if kind == "op" and v == "(":
            r = expr_or()
            assert take() == ("op", ")"), "missing )"
            return r
        if kind == "op" and v == "!":
            return not _truthy(value())
        if kind == "id":
            return _lookup(cfg, v)
        if kind in ("str", "num", "rx"):
            return v
        raise ValueError(f"unexpected token {v!r}")

    def comparison():
        left = value()
        kind, v = peek()
        if kind == "op" and v in ("==", "!=", "=~", "!~"):
            take()
            right = value()
            if v in ("=~", "!~"):
                hit = _re.fullmatch(str(right), str(left), _re.DOTALL) is not None  # boost::regex: . matches newline
                return hit if v == "=~" else not hit
            ln, rn = _as_number(left), _as_number(right)
            eq = (ln == rn) if (ln is not None and rn is not None) else (str(left) == str(right))
            return eq if v == "==" else not eq
        return left

    def expr_and():
        r = _truthy(comparison())
        while peek() == ("op", "&&"):
            take(); r = _truthy(comparison()) and r
        return r

    def expr_or():
        r = expr_and()
        while peek() == ("op", "||"):
            take(); r = expr_and() or r
        return r

    result = expr_or()
    if pos[0] != len(toks):
        raise ValueError("trailing tokens in condition")
    return bool(result)


def alias_of(name):
    return name.split("@")[0].strip()


def compatible_filaments(sections, printer_preset, base=None):
    """The public filament sections whose compatible_printers_condition holds
    for `printer_preset` (a [printer:...] section name), optionally only those
    with alias `base`."""
    printer = flatten(sections, "printer", printer_preset)
    hits = []
    for name in filament_names(sections):
        if base and alias_of(name) != base:
            continue
        cfg = flatten(sections, FILAMENT, name)
        try:
            ok = eval_condition(unquote_ini(cfg.get("compatible_printers_condition", "")), printer)
        except (ValueError, AssertionError):
            ok = False
        if ok:
            hits.append(name)
    return hits


def pick_system_preset(sections, base, model=None, nozzle=None, printer_preset=None):
    """The vendor section to derive from. With a printer preset name the
    choice is PrusaSlicer's own: the `base` filament whose compatibility
    condition holds for that printer. Otherwise by name:
    '<base> @<MODEL> <nozzle>', '<base> @<MODEL>', '<base>'."""
    if printer_preset and f"printer:{printer_preset}" in sections:
        hits = compatible_filaments(sections, printer_preset, base)
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            # several are compatible (a generic one and a printer-specific one):
            # take the most specific, the one with the longest name
            hits.sort(key=lambda n: (-len(n), n))
            return hits[0]
        raise KeyError(f"no '{base}' filament in the vendor bundle is compatible with printer preset '{printer_preset}'")
    return pick_by_name(sections, base, model, nozzle)


def pick_by_name(sections, base, model=None, nozzle=None):
    """The vendor section to derive from: '<base> @<MODEL> <nozzle>' when the
    bundle has one for that nozzle, else '<base> @<MODEL>', else '<base>'."""
    names = set(filament_names(sections))
    tries = []
    if model:
        if nozzle and abs(float(nozzle) - 0.4) > 1e-6:
            tries.append(f"{base} @{model} {fmt(float(nozzle), 2)}")
        tries.append(f"{base} @{model}")
    tries.append(base)
    for t in tries:
        if t in names:
            return t
    raise KeyError(f"no system filament preset named {', '.join(repr(t) for t in tries)} in the vendor bundle")


def quote_ini(s):
    """A string value for the .ini: PrusaSlicer quotes G-code and notes, with
    newlines as \\n and quotes/backslashes escaped."""
    s = str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\r\n", "\n").replace("\n", "\\n")
    return f'"{s}"'


def unquote_ini(s):
    s = str(s).strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1].replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")
    return s


PA_COMMANDS = {"prusa": "M572 S{pa}", "marlin": "M900 K{pa}", "klipper": "SET_PRESSURE_ADVANCE ADVANCE={pa}", "reprap": "M572 D0 S{pa}"}


def build_preset(sections, base, name, values, model=None, nozzle=None, printer_preset=None, notes=None,
                 pressure_advance=None, firmware="prusa", system_preset=None):
    """Returns (ini text, info). `values` maps filament keys to plain values
    (temperature, first_layer_temperature, extrusion_multiplier,
    filament_max_volumetric_speed, min_fan_speed, max_fan_speed,
    slowdown_below_layer_time, min_print_speed...)."""
    system = system_preset or pick_system_preset(sections, base, model, nozzle, printer_preset)
    cfg = flatten(sections, FILAMENT, system)
    cfg.pop("renamed_from", None)
    cfg.pop("alias", None)
    cfg["inherits"] = system
    cfg["filament_settings_id"] = quote_ini(name)
    if printer_preset:
        cfg["compatible_printers"] = quote_ini(printer_preset)
    for k, v in values.items():
        if v is None:
            continue
        cfg[k] = str(v) if not isinstance(v, float) else fmt(v, 4)
    if pressure_advance is not None:
        template = PA_COMMANDS[firmware]
        line = template.format(pa=fmt(float(pressure_advance), 4)) + " ; dialed-in pressure advance"
        start = unquote_ini(cfg.get("start_filament_gcode", '""'))
        start = (start + "\n" if start else "") + line
        cfg["start_filament_gcode"] = quote_ini(start)
    note = f"Dialed in with the Filament Dial-In sheet on {date.today().isoformat()}"
    if notes:
        note += ". " + str(notes)
    existing = unquote_ini(cfg.get("filament_notes", '""'))
    cfg["filament_notes"] = quote_ini((existing + "\n" if existing else "") + note)
    changed = [k for k in values if values[k] is not None] + (["start_filament_gcode"] if pressure_advance is not None else [])
    lines = [f"# PrusaSlicer 2.9 filament preset written by the Filament Dial-In sheet ({date.today().isoformat()}).",
             f"# Derived from the system preset '{system}'; every other value is that preset's,",
             f"# flattened from the vendor bundle. Save as <user data>/filament/{name}.ini and restart PrusaSlicer,",
             "# or File > Import > Import Config."]
    for k in sorted(cfg):
        lines.append(f"{k} = {cfg[k]}")
    return "\n".join(lines) + "\n", {"system_preset": system, "keys": len(cfg), "changed": changed, "name": name}


def safe_filename(name):
    return "".join("_" if c in '\\/:*?"<>|' or ord(c) < 32 else c for c in name).strip() or "dialed"


def install_path(name):
    for d in data_dir_candidates():
        if d.is_dir():
            return d / FILAMENT / f"{safe_filename(name)}.ini"
    raise RuntimeError("no PrusaSlicer 2.9 user data folder found; pass -o to write the file elsewhere")


def add_cli(sub, common):
    p = sub.add_parser("preset", parents=[common], help="Step 13: a complete PrusaSlicer 2.9 filament preset (.ini)")
    p.add_argument("--vendor-ini", help="PrusaResearch.ini to read (default: the copy under PrusaSlicer's user data folder, vendor/)")
    p.add_argument("--base", required=True, help='system filament to derive from, e.g. "Prusament PETG"')
    p.add_argument("--system-preset", help="exact vendor section to use instead of the one picked from --base/--model/--nozzle")
    p.add_argument("--model", help="printer model id as in the vendor bundle: MK4S, MK4, COREONE, COREONEL, XL, MINI, MK3S")
    p.add_argument("--nozzle", type=float, default=0.4)
    p.add_argument("--printer-preset", help='pin the preset to one printer preset name, e.g. "Original Prusa MK4S 0.4 nozzle"')
    p.add_argument("--name", required=True, help="name of the new preset")
    p.add_argument("--tag", default="")
    p.add_argument("--temperature", type=int)
    p.add_argument("--first-layer-temperature", type=int)
    p.add_argument("--extrusion-multiplier", type=float)
    p.add_argument("--max-volumetric-speed", type=float)
    p.add_argument("--min-fan", type=int)
    p.add_argument("--max-fan", type=int)
    p.add_argument("--slowdown", type=int, help="slowdown_below_layer_time [s]")
    p.add_argument("--min-print-speed", type=float)
    p.add_argument("--pressure-advance", type=float, help="appended to start_filament_gcode as M572/M900 (see --firmware)")
    p.add_argument("--firmware", choices=sorted(PA_COMMANDS), default="prusa")
    p.add_argument("--notes", default="", help="appended to filament_notes (per-object values, scale factor...)")
    p.add_argument("--install", action="store_true", help="write into <user data>/filament/<name>.ini instead of -o")
    p.set_defaults(run=run)


def run(args):
    ini_path = Path(args.vendor_ini) if args.vendor_ini else find_vendor_ini()
    if not ini_path or not Path(ini_path).is_file():
        raise SystemExit("PrusaResearch.ini not found; start PrusaSlicer 2.9 once (it copies the vendor bundle into its user data folder) or pass --vendor-ini")
    sections = parse_ini(Path(ini_path).read_text(encoding="utf-8", errors="replace"))
    values = {
        "temperature": args.temperature, "first_layer_temperature": args.first_layer_temperature,
        "extrusion_multiplier": args.extrusion_multiplier, "filament_max_volumetric_speed": args.max_volumetric_speed,
        "min_fan_speed": args.min_fan, "max_fan_speed": args.max_fan, "slowdown_below_layer_time": args.slowdown,
        "min_print_speed": args.min_print_speed,
    }
    text, info = build_preset(sections, args.base, args.name, values, args.model, args.nozzle, args.printer_preset,
                              args.notes, args.pressure_advance, args.firmware, args.system_preset)
    out = install_path(args.name) if args.install else Path(args.output or f"{safe_filename(args.name)}.ini")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    log(f"filament preset '{args.name}' derived from '{info['system_preset']}' ({ini_path}): {info['keys']} keys, changed {', '.join(info['changed']) or 'nothing'}")
    log(f"wrote {out}" + ("; restart PrusaSlicer 2.9 to see it in the filament list" if args.install else "; copy it to <user data>/filament/ and restart PrusaSlicer, or File > Import > Import Config"))
    return str(out)
