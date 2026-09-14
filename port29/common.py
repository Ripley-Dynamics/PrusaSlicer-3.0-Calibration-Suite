"""Shared bits for the step generators: number formatting and the DATA line the
sheet's helper already parses from the 3.0 plugin's output."""

import math


def fmt(n, decimals=2):
    """util.fmt: up to `decimals` places, no trailing zeros, no '-0'."""
    s = f"{n:.{decimals}f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def encode_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        if float(v) == math.floor(v) and abs(v) < 1e15:
            return str(int(v))
        return f"{v:.6g}"
    s = str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{s}"'


LOG_PREFIX = "[filament-dialin] "


def log(*parts):
    print(LOG_PREFIX + " ".join(str(p) for p in parts))


def data_line(step, fields):
    keys = sorted(fields)
    parts = ["step=" + encode_value(step)] + [f"{k}={encode_value(fields[k])}" for k in keys]
    return LOG_PREFIX + "DATA " + " ".join(parts)


def short_printer_tag(name, max_len=18):
    s = str(name)
    for a, b in (("Original Prusa ", ""), ("Prusa ", ""), (" nozzle", ""), (" Input Shaper", " IS")):
        s = s.replace(a, b, 1) if a.endswith(" ") and s.startswith(a) else s.replace(a, b)
    s = " ".join(s.split())[:max_len]
    return s or "printer"


def parse_bed(text):
    """'250x210' -> (250.0, 210.0)."""
    w, d = str(text).lower().replace("×", "x").split("x")
    return float(w), float(d)
