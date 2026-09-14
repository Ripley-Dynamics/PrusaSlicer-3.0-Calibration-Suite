"""Mockups of the MK4S 480x320 screens for the nozzle-maintenance files.

Geometry is taken from Prusa-Firmware-Buddy (HAS_LARGE_DISPLAY):
  include/guiconfig/GuiDefaults.hpp    screen 480x320, header 32, footer 23, PreviewThumbnailRect
                                       (30,82,313,173), MsgBoxLayoutRect/MessageIconRect/MessageTextRect,
                                       ProgressThumbnailRect (0,0,480,240), ProgressBarHeight 10,
                                       ButtonHeight 32, ButtonSpacing 6, ButtonIconSize 80
  src/gui/screen/screen_print_preview.cpp  title rect (30,40,420,24), vertical Print/Back buttons (94 wide)
  src/gui/gcode_description.hpp/.cpp   3 description lines under the thumbnail, 22 px pitch
  src/gui/screen_printing.cpp, ScreenPrintingModel.cpp  filename (30,38), bar (30,65,420,16), row_0 104,
                                       buttons 80 px at y=185, x = 90 + i*110, labels below
  src/gui/dialogs/print_progress.cpp   full-screen 480x240 thumbnail + bar + text row
  src/gui/dialogs/window_dlg_quickpause.cpp  M0 dialog: warning icon (70,90) + text (133,90,300,..) + Resume
  src/gui/fonts.hpp  small 7x13, normal/big 11x18, special 9x16, large bold 30x53 (digits)
  src/common/utils/color.hpp  COLOR_ORANGE 0xF8651B (brand), GRAY 0x808080, DARK_GRAY 0x5B5B5B, SILVER
Icons are hand-drawn approximations of the firmware's 16/48/80 px PNGs.
"""
from PIL import Image, ImageDraw, ImageFont
from thumbs import render as render_thumb

W, H = 480, 320
HEADER_H, FOOTER_H = 32, 23
BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
BRAND = (0xF8, 0x65, 0x1B)
GRAY = (0x80, 0x80, 0x80)
DGRAY = (0x5B, 0x5B, 0x5B)
SILVER = (0xC0, 0xC0, 0xC0)
YELLOW = (0xFF, 0xD2, 0x00)

MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
MONO_B = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
# firmware bitmap fonts are fixed-width; DejaVu Sans Mono at these sizes gives ~the same advance
F_SMALL = ImageFont.truetype(MONO, 12)     # 7x13
F_SPECIAL = ImageFont.truetype(MONO, 15)   # 9x16
F_NORMAL = ImageFont.truetype(MONO, 18)    # 11x18
F_LARGE = ImageFont.truetype(MONO_B, 50)   # 30x53 digits


def new_screen():
    img = Image.new("RGB", (W, H), BLACK)
    return img, ImageDraw.Draw(img)


def header(d, text, icon="print"):
    # icon_base 16x16 at (14,12), label right of it
    x, y = 14, 12
    if icon == "print":
        d.rectangle([x + 2, y + 5, x + 13, y + 12], outline=WHITE)
        d.rectangle([x + 4, y + 2, x + 11, y + 5], outline=WHITE)
        d.rectangle([x + 4, y + 10, x + 11, y + 14], outline=WHITE)
    d.text((x + 16 + 5, y - 1), text, font=F_SPECIAL, fill=WHITE)
    # right side status icons: usb + wifi
    ux = W - 14 - 16
    d.rectangle([ux + 5, y + 1, ux + 10, y + 14], outline=WHITE)
    d.rectangle([ux + 6, y + 2, ux + 9, y + 5], fill=WHITE)
    wx = ux - 16 - 6
    for r in (3, 7, 11):
        d.arc([wx + 8 - r, y + 8 - r, wx + 8 + r, y + 8 + r], 225, 315, fill=WHITE)
    d.ellipse([wx + 7, y + 7, wx + 9, y + 9], fill=WHITE)


def footer(d, items):
    # default footer items: speed, Z height, filament (footer_def.hpp default_items), special font
    y = H - FOOTER_H + 3
    cols = [40, 200, 360]
    for (icon, text), cx in zip(items, cols):
        ix = cx
        if icon == "speed":
            d.arc([ix, y, ix + 15, y + 15], 180, 360, fill=WHITE, width=2)
            d.line([ix + 7, y + 8, ix + 11, y + 3], fill=WHITE, width=2)
        elif icon == "z":
            d.text((ix, y - 1), "Z", font=F_SPECIAL, fill=WHITE)
        elif icon == "filament":
            d.ellipse([ix + 1, y + 1, ix + 14, y + 14], outline=WHITE, width=2)
            d.ellipse([ix + 6, y + 6, ix + 9, y + 9], fill=WHITE)
        d.text((ix + 22, y - 1), text, font=F_SPECIAL, fill=WHITE)


def rounded_button(d, rect, label, selected=True, font=F_NORMAL):
    x0, y0, x1, y1 = rect
    fill = BRAND if selected else GRAY
    d.rounded_rectangle(rect, radius=8, fill=fill)
    tw = d.textlength(label, font=font)
    d.text(((x0 + x1) / 2 - tw / 2, y0 + (y1 - y0) / 2 - 10), label, font=font, fill=BLACK if selected else WHITE)


def warning_icon(d, x, y, size=48):
    d.polygon([(x + size / 2, y + 2), (x + 2, y + size - 4), (x + size - 2, y + size - 4)], fill=YELLOW)
    d.rectangle([x + size / 2 - 2, y + 14, x + size / 2 + 2, y + 30], fill=BLACK)
    d.rectangle([x + size / 2 - 2, y + 34, x + size / 2 + 2, y + 38], fill=BLACK)


def wrap(d, text, font, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=font) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    lines.append(cur)
    return lines


def big_icon(d, x, y, kind, size=80):
    c = WHITE
    if kind == "print":
        d.rectangle([x + 10, y + 26, x + 70, y + 62], outline=c, width=3)
        d.rectangle([x + 22, y + 12, x + 58, y + 26], outline=c, width=3)
        d.rectangle([x + 22, y + 50, x + 58, y + 70], fill=BLACK, outline=c, width=3)
    elif kind == "back":
        d.polygon([(x + 22, y + 40), (x + 46, y + 20), (x + 46, y + 60)], fill=c)
        d.rectangle([x + 44, y + 34, x + 62, y + 46], fill=c)
    elif kind == "tune":
        for i in range(3):
            yy = y + 20 + i * 20
            d.line([x + 14, yy, x + 66, yy], fill=c, width=3)
            d.ellipse([x + 24 + i * 12 - 5, yy - 6, x + 24 + i * 12 + 5, yy + 6], fill=BLACK, outline=c, width=3)
    elif kind == "pause":
        d.rectangle([x + 22, y + 16, x + 34, y + 64], fill=c)
        d.rectangle([x + 46, y + 16, x + 58, y + 64], fill=c)
    elif kind == "stop":
        d.rectangle([x + 18, y + 18, x + 62, y + 62], fill=c)


# ------------------------------------------------------------------ screens
def screen_print_preview(spec, filename, print_time, material, used):
    img, d = new_screen()
    header(d, "PRINT")
    # title (30,40,420,24) big font, 2px dark-gray line under it
    d.text((30, 42), filename, font=F_NORMAL, fill=WHITE)
    d.rectangle([30, 64, 449, 65], fill=DGRAY)
    # thumbnail 313x173 at (30,82)
    img.paste(render_thumb(313, 173, spec).convert("RGB"), (30, 82))
    # description lines: y = 82+173+15 = 270, pitch 22, title small gray, value right-aligned at x=343
    # gcode_description.cpp shows only 2 lines when a preview thumbnail is present
    for i, (k, v) in enumerate([("Print Time", print_time), ("Material", material)]):
        y = 270 + i * 22
        d.text((30, y + 1), k, font=F_SMALL, fill=GRAY)
        d.text((343 - d.textlength(v, font=F_SMALL), y + 1), v, font=F_SMALL, fill=WHITE)
    # vertical Print / Back buttons, 94 px column centred right of the thumbnail
    bx = 343 + (480 - 343 - 94) // 2
    for i, (kind, label) in enumerate([("print", "Print"), ("back", "Back")]):
        iy = 82 + i * (80 + 16 + 37)
        ix = bx + (94 - 80) // 2
        if i == 0:
            d.rounded_rectangle([ix - 2, iy - 2, ix + 82, iy + 82], radius=8, outline=BRAND, width=2)
        big_icon(d, ix, iy, kind)
        tw = d.textlength(label, font=F_SPECIAL)
        d.text((bx + 47 - tw / 2, iy + 80 + 1), label, font=F_SPECIAL, fill=BRAND if i == 0 else WHITE)
    return img


def screen_compat_warning(items):
    img, d = new_screen()
    header(d, "PRINT")
    d.text((14, 44), "G-Code incompatibilities detected", font=F_SMALL, fill=WHITE)
    d.rectangle([14, 60, 465, 61], fill=DGRAY)
    y = 70
    for title, desc in items:
        d.rounded_rectangle([14, y, 465, y + 44], radius=5, fill=(0x22, 0x22, 0x22))
        warning_icon(d, 18, y + 6, 32)
        d.text((60, y + 5), title, font=F_SMALL, fill=YELLOW)
        d.text((60, y + 24), desc, font=F_SMALL, fill=SILVER)
        y += 50
    rounded_button(d, (6, 236, 236, 268), "Print", selected=True)
    rounded_button(d, (244, 236, 474, 268), "Back", selected=False)
    footer(d, [("speed", "100%"), ("z", "100.00"), ("filament", "PA")])
    return img


def screen_printing(filename, percent, message=None, remaining="11m"):
    img, d = new_screen()
    header(d, "PRINTING ...")
    d.text((30, 41), filename, font=F_NORMAL, fill=WHITE)
    # progress bar (30,65,420,16): brand fill on gray
    d.rectangle([30, 65, 449, 80], fill=GRAY)
    d.rectangle([30, 65, 30 + int(420 * percent / 100), 80], fill=BRAND)
    # big percent, right-top at row_0 (104), large digit font
    pt = f"{percent}%"
    d.text((450 - d.textlength(pt, font=F_LARGE), 96), pt, font=F_LARGE, fill=WHITE)
    if message:
        # message_popup (30, 104, 250, 70) multiline, replaces the time rows while shown
        for i, line in enumerate(wrap(d, message, F_NORMAL, 250)[:3]):
            d.text((30, 106 + i * 22), line, font=F_NORMAL, fill=WHITE)
    else:
        d.text((30, 108), "Remaining Time", font=F_SMALL, fill=SILVER)
        d.text((30, 126), remaining, font=F_NORMAL, fill=WHITE)
    # Tune / Pause / Stop 80px buttons at y=185, x=90+i*110, small labels below
    for i, (kind, label) in enumerate([("tune", "Tune"), ("pause", "Pause"), ("stop", "Stop")]):
        x = 90 + i * 110
        if i == 0:
            d.rounded_rectangle([x - 2, 183, x + 82, 267], radius=8, outline=BRAND, width=2)
        big_icon(d, x, 185, kind)
        tw = d.textlength(label, font=F_SMALL)
        d.text((x + 40 - tw / 2, 271), label, font=F_SMALL, fill=WHITE)
    footer(d, [("speed", "100%"), ("z", "100.00"), ("filament", "PA")])
    return img


def screen_progress_overlay(spec, percent, remaining="9m"):
    img, d = new_screen()
    img.paste(render_thumb(480, 240, spec).convert("RGB"), (0, 0))
    d.rectangle([0, 240, 479, 249], fill=GRAY)
    d.rectangle([0, 240, int(480 * percent / 100), 249], fill=BRAND)
    d.text((12, 262), "Remaining Time", font=F_SMALL, fill=SILVER)
    d.text((12, 282), remaining, font=F_NORMAL, fill=WHITE)
    pt = f"{percent}%"
    d.text((440 - 12 - 10 - d.textlength(pt, font=F_LARGE), 256), pt, font=F_LARGE, fill=WHITE)
    # "more" icon at the right
    for i in range(3):
        d.ellipse([456 + i * 7, 285, 460 + i * 7, 289], fill=WHITE)
    return img


def screen_quick_pause(message):
    img, d = new_screen()
    header(d, "PRINTING ...")
    warning_icon(d, 70, 90)
    for i, line in enumerate(wrap(d, message, F_NORMAL, 300)):
        d.text((133, 90 + i * 22), line, font=F_NORMAL, fill=WHITE)
    rounded_button(d, (6, 236, 474, 268), "Resume", selected=True)
    footer(d, [("speed", "100%"), ("z", "100.00"), ("filament", "PA")])
    return img


def sheet(screens, cols=2, pad=24, caption_h=36):
    f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 15)
    rows = (len(screens) + cols - 1) // cols
    out = Image.new("RGB", (cols * (W + pad) + pad, rows * (H + caption_h + pad) + pad), (40, 40, 40))
    d = ImageDraw.Draw(out)
    for i, (cap, im) in enumerate(screens):
        x = pad + (i % cols) * (W + pad)
        y = pad + (i // cols) * (H + caption_h + pad)
        d.text((x, y), cap, font=f, fill=(230, 230, 230))
        # bezel
        d.rectangle([x - 3, y + caption_h - 3, x + W + 2, y + caption_h + H + 2], fill=(15, 15, 15))
        out.paste(im, (x, y + caption_h))
    return out
