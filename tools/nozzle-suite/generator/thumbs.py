"""Thumbnail rendering + QOI encoding for the MK4S nozzle-maintenance bgcode suite.

The Buddy firmware (src/common/thumbnail_sizes.hpp, src/gui/window_thumbnail.cpp) asks the
file for QOI images at exact sizes on the large-display printers (MK4S, Core One, Core One L):
  313x173  print preview screen
  480x240  progress screen (440x240 is the legacy fallback width)
PrusaSlicer additionally emits 16x16/QOI and 640x480/PNG (used by PrusaLink / Connect).
"""
import io
import struct
from PIL import Image, ImageDraw, ImageFont

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

BG = (20, 20, 20, 255)
ORANGE = (255, 106, 0, 255)
WHITE = (240, 240, 240, 255)
GREY = (150, 150, 150, 255)
HOT = (255, 72, 40, 255)
COLD = (80, 170, 255, 255)
GREEN = (90, 200, 120, 255)


def _font(path, size):
    return ImageFont.truetype(path, size)


def _icon_pull(d, cx, top, nozzle_y, s):
    d.rectangle([cx - 28 * s, nozzle_y - 40 * s, cx + 28 * s, nozzle_y - 10 * s], fill=(90, 90, 90, 255))
    d.polygon([(cx - 22 * s, nozzle_y - 10 * s), (cx + 22 * s, nozzle_y - 10 * s),
               (cx + 6 * s, nozzle_y + 16 * s), (cx - 6 * s, nozzle_y + 16 * s)], fill=(140, 140, 140, 255))
    d.line([(cx, nozzle_y + 16 * s), (cx, top)], fill=ORANGE, width=max(3, int(8 * s)))
    d.ellipse([cx - 11 * s, nozzle_y + 12 * s, cx + 11 * s, nozzle_y + 44 * s], fill=HOT)
    d.polygon([(cx, top - 2), (cx - 14 * s, top + 18 * s), (cx + 14 * s, top + 18 * s)], fill=ORANGE)


def _icon_flush(d, cx, top, nozzle_y, s):
    d.rectangle([cx - 28 * s, nozzle_y - 40 * s, cx + 28 * s, nozzle_y - 10 * s], fill=(90, 90, 90, 255))
    d.polygon([(cx - 22 * s, nozzle_y - 10 * s), (cx + 22 * s, nozzle_y - 10 * s),
               (cx + 6 * s, nozzle_y + 16 * s), (cx - 6 * s, nozzle_y + 16 * s)], fill=(140, 140, 140, 255))
    d.line([(cx, top), (cx, nozzle_y - 40 * s)], fill=ORANGE, width=max(3, int(8 * s)))
    # thick molten stream out of the tip, downward arrow
    d.line([(cx, nozzle_y + 16 * s), (cx, nozzle_y + 60 * s)], fill=HOT, width=max(3, int(10 * s)))
    d.polygon([(cx, nozzle_y + 78 * s), (cx - 14 * s, nozzle_y + 58 * s), (cx + 14 * s, nozzle_y + 58 * s)], fill=HOT)


def _icon_test(d, cx, top, nozzle_y, s):
    _icon_flush(d, cx, top, nozzle_y, s)
    # small bar chart to the right of the nozzle
    bx = cx - 82 * s
    for i, hgt in enumerate((18, 30, 44)):
        d.rectangle([bx + i * 14 * s, nozzle_y + 60 * s - hgt * s, bx + (i * 14 + 10) * s, nozzle_y + 60 * s],
                    fill=GREEN if i < 2 else ORANGE)


def _icon_brush(d, cx, top, nozzle_y, s):
    d.rectangle([cx - 28 * s, nozzle_y - 40 * s, cx + 28 * s, nozzle_y - 10 * s], fill=(90, 90, 90, 255))
    d.polygon([(cx - 22 * s, nozzle_y - 10 * s), (cx + 22 * s, nozzle_y - 10 * s),
               (cx + 6 * s, nozzle_y + 16 * s), (cx - 6 * s, nozzle_y + 16 * s)], fill=(140, 140, 140, 255))
    # brush handle + bristles under the tip
    d.rectangle([cx - 50 * s, nozzle_y + 30 * s, cx + 10 * s, nozzle_y + 40 * s], fill=(180, 140, 60, 255))
    for i in range(7):
        x = cx - 46 * s + i * 8 * s
        d.line([(x, nozzle_y + 30 * s), (x, nozzle_y + 18 * s)], fill=(220, 190, 90, 255), width=max(1, int(2 * s)))


ICONS = {"pull": _icon_pull, "flush": _icon_flush, "test": _icon_test, "brush": _icon_brush}


def render(w: int, h: int, spec: dict) -> Image.Image:
    """spec: title (2 lines), rows [(text, color)], nozzle (str), printer (str), icon (key)."""
    img = Image.new("RGBA", (w, h), BG)
    d = ImageDraw.Draw(img)
    s = h / 240.0

    if w <= 32:
        d.line([(w * 0.5, 1), (w * 0.5, h - 2)], fill=ORANGE, width=max(2, w // 5))
        d.ellipse([w * 0.25, h * 0.55, w * 0.75, h - 1], fill=HOT)
        return img

    ICONS[spec.get("icon", "pull")](d, int(w * 0.20), int(h * 0.10), int(h * 0.62), s)

    x = int(w * 0.36)
    f_title = _font(FONT_BOLD, int(30 * s))
    f_body = _font(FONT_BOLD, int(22 * s))
    f_small = _font(FONT, int(16 * s))
    y = int(h * 0.08)
    for line in spec["title"]:
        d.text((x, y), line, font=f_title, fill=WHITE)
        y += int(34 * s)
    y += int(6 * s)
    for text, color in spec["rows"]:
        d.text((x, y), text, font=f_body, fill=color)
        y += int(28 * s)
    y += int(6 * s)
    d.text((x, y), spec["nozzle"], font=f_body, fill=ORANGE)
    y += int(30 * s)
    d.text((x, y), spec["printer"], font=f_small, fill=GREY)
    return img


# ------------------------------------------------------------------ QOI encoder (spec 1.0)
def qoi_encode(img: Image.Image) -> bytes:
    img = img.convert("RGBA")
    w, h = img.size
    px = img.tobytes()
    out = bytearray(b"qoif" + struct.pack(">IIBB", w, h, 4, 0))  # channels=4, colorspace=sRGB
    index = [(0, 0, 0, 0)] * 64
    pr, pg, pb, pa = 0, 0, 0, 255
    run = 0
    n = w * h
    for i in range(n):
        r, g, b, a = px[4 * i], px[4 * i + 1], px[4 * i + 2], px[4 * i + 3]
        if (r, g, b, a) == (pr, pg, pb, pa):
            run += 1
            if run == 62 or i == n - 1:
                out.append(0xC0 | (run - 1))
                run = 0
            continue
        if run:
            out.append(0xC0 | (run - 1))
            run = 0
        k = (r * 3 + g * 5 + b * 7 + a * 11) % 64
        if index[k] == (r, g, b, a):
            out.append(k)
        else:
            index[k] = (r, g, b, a)
            if a == pa:
                dr = (r - pr + 128) % 256 - 128
                dg = (g - pg + 128) % 256 - 128
                db = (b - pb + 128) % 256 - 128
                if -2 <= dr <= 1 and -2 <= dg <= 1 and -2 <= db <= 1:
                    out.append(0x40 | ((dr + 2) << 4) | ((dg + 2) << 2) | (db + 2))
                else:
                    dr_dg, db_dg = dr - dg, db - dg
                    if -32 <= dg <= 31 and -8 <= dr_dg <= 7 and -8 <= db_dg <= 7:
                        out.append(0x80 | (dg + 32))
                        out.append(((dr_dg + 8) << 4) | (db_dg + 8))
                    else:
                        out += bytes((0xFE, r, g, b))
            else:
                out += bytes((0xFF, r, g, b, a))
        pr, pg, pb, pa = r, g, b, a
    out += b"\x00\x00\x00\x00\x00\x00\x00\x01"
    return bytes(out)


def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.convert("RGBA").save(buf, format="PNG", optimize=True)
    return buf.getvalue()


# (format code per bgcode spec: 0=PNG, 1=JPG, 2=QOI), width, height
THUMBNAIL_SET = [
    (2, 16, 16),
    (2, 313, 173),
    (2, 440, 240),
    (2, 480, 240),
    (0, 640, 480),
]


def thumbnails(spec: dict):
    """Yield (format, width, height, bytes, PIL image)."""
    for fmt, w, h in THUMBNAIL_SET:
        img = render(w, h, spec)
        data = qoi_encode(img) if fmt == 2 else png_bytes(img)
        yield fmt, w, h, data, img
