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


# --- sweep and unit helpers, mirroring lib/util.lua ---------------------------
def decimal(v, name="value"):
    """util.decimal: blank -> None, '0,95' -> 0.95."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = "".join(str(v).split()).replace(",", ".")
    if s == "":
        return None
    try:
        n = float(s)
    except ValueError:
        raise ValueError(f"{name} must be a number, got '{v}'")
    if n != n or n in (float("inf"), float("-inf")):
        raise ValueError(f"{name} must be finite")
    return n


def number_or_percent(v, name="value"):
    """'17.5%' -> (17.5, True); '0.45' -> (0.45, False); blank -> (None, False)."""
    if v is None:
        return None, False
    if isinstance(v, (int, float)):
        return float(v), False
    s = "".join(str(v).split()).replace(",", ".")
    if s == "":
        return None, False
    if s.endswith("%"):
        return decimal(s[:-1], name), True
    return decimal(s, name), False


def whole(n):
    """Integers print as '250', not '250.0'."""
    return int(n) if float(n) == math.floor(n) else n


def align(v, step, min_steps=1):
    """Nearest multiple of `step`, never below `min_steps` steps."""
    k = math.floor(v / step + 0.5)
    return max(k, min_steps) * step


def extrusion_area(width, height):
    return (width - height) * height + math.pi * (height / 2) ** 2


def flow_to_speed(flow, width, height):
    return flow / extrusion_area(width, height)


def fan_pwm(percent):
    p = max(0.0, min(100.0, float(percent)))
    return int(math.floor(p * 255 / 100 + 0.5))


def range_values(lo, hi, by_interval=True, interval=None, count=None, integer=False, max_count=30):
    """util.range: ascending values between lo and hi, by interval (steps from
    lo, stops at or below hi) or by count (evenly divided). Returns (values,
    effective interval)."""
    lo, hi = float(lo), float(hi)
    if not hi > lo:
        raise ValueError("Maximum must be greater than minimum")
    if by_interval:
        interval = float(interval)
        if not interval > 0:
            raise ValueError("Interval must be positive")
        n = int(math.floor((hi - lo) / interval + 1e-9)) + 1
        if n < 2:
            raise ValueError("The interval must fit at least twice between minimum and maximum")
        if n > max_count:
            raise ValueError(f"Too many steps ({n}); use a larger interval")
    else:
        n = int(math.floor(float(count) + 0.5))
        if not (2 <= n <= max_count):
            raise ValueError(f"Number of steps must be between 2 and {max_count}")
        interval = (hi - lo) / (n - 1)
    values = [lo + i * interval for i in range(n)]
    if integer:
        values = [int(math.floor(v + 0.5)) for v in values]
    else:
        values = [math.floor(v * 1000 + 0.5) / 1000 for v in values]
    if len(set(values)) != len(values):
        raise ValueError("The sweep collapses onto repeated values; use a coarser interval or fewer steps")
    return values, interval


def join(values, decimals=2):
    return ",".join(fmt(v, decimals) for v in values)


SOLID_PARAMS = {"fill_density": "100%", "fill_pattern": "rectilinear"}
