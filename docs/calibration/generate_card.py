#!/usr/bin/env python3
"""
Generate the Tovis camera-calibration card (v0) as print-ready SVG + PDF.

Target: Zebra ZXP Series 7, standard CR-80 card = 85.6 x 54 mm, 300 dpi.

Layout (landscape), matching how the iOS app samples:
  - big NEUTRAL GRAY in the center (the app's white-balance sample = center ~40%)
  - 24 ColorChecker swatches ringing top (1-12) + bottom (13-24) rows, for the
    future measured 3x3 color-correction matrix (values MUST be measured per print
    batch on an uncalibrated dye-sub printer -- see README).

Swatch RGB = the nominal ColorChecker sRGB values that also live in
TovisKit CameraCalibration.CardReferenceProfile.placeholderClassic (same order).
"""

# Nominal ColorChecker 24 (8-bit sRGB), reading order 1..24.
SWATCHES = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
    (133, 128, 177), (103, 189, 170), (214, 126, 44), (80, 91, 166),
    (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
    (187, 86, 149), (8, 133, 161), (243, 243, 242), (200, 200, 200),
    (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]
WB_GRAY = (128, 128, 128)  # pure neutral WB target (R=G=B)

# Card + layout, all mm, top-left origin.
CARD_W, CARD_H = 85.6, 54.0
BORDER = 2.5
INNER_X0, INNER_X1 = BORDER, CARD_W - BORDER
INNER_W = INNER_X1 - INNER_X0
TOP_Y, TOP_H = 2.5, 11.0
GRAY_Y, GRAY_H = 13.5, 25.0     # center 40% of 54mm (=21.6) fits inside this band
BOT_Y, BOT_H = 38.5, 10.0
LABEL_Y = 49.0
SWATCH_PAD, GAP = 0.75, 0.5


def swatch_rects(y, h):
    n = 12
    w = (INNER_W - GAP * (n - 1)) / n
    rects = []
    for i in range(n):
        x = INNER_X0 + i * (w + GAP)
        rects.append((x, y + SWATCH_PAD, w, h - 2 * SWATCH_PAD))
    return rects


def hexof(rgb):
    return "#%02X%02X%02X" % rgb


# ---------------------------------------------------------------- SVG
def build_svg():
    top = swatch_rects(TOP_Y, TOP_H)
    bot = swatch_rects(BOT_Y, BOT_H)
    p = []
    p.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{CARD_W}mm" '
             f'height="{CARD_H}mm" viewBox="0 0 {CARD_W} {CARD_H}">')
    p.append(f'<rect x="0" y="0" width="{CARD_W}" height="{CARD_H}" fill="#FFFFFF"/>')
    # registration frame
    p.append(f'<rect x="{INNER_X0}" y="{TOP_Y}" width="{INNER_W}" '
             f'height="{BOT_Y + BOT_H - TOP_Y}" fill="none" stroke="#111111" stroke-width="0.2"/>')
    # top + bottom swatches
    for (x, y, w, h), rgb in zip(top, SWATCHES[:12]):
        p.append(f'<rect x="{x:.3f}" y="{y:.3f}" width="{w:.3f}" height="{h:.3f}" fill="{hexof(rgb)}"/>')
    for (x, y, w, h), rgb in zip(bot, SWATCHES[12:]):
        p.append(f'<rect x="{x:.3f}" y="{y:.3f}" width="{w:.3f}" height="{h:.3f}" fill="{hexof(rgb)}"/>')
    # center WB gray
    p.append(f'<rect x="{INNER_X0}" y="{GRAY_Y}" width="{INNER_W}" height="{GRAY_H}" fill="{hexof(WB_GRAY)}"/>')
    p.append(f'<text x="{CARD_W/2:.2f}" y="{GRAY_Y+3.2:.2f}" font-family="Helvetica,Arial" '
             f'font-size="2.4" fill="#FFFFFF" text-anchor="middle">WHITE BALANCE — fill the frame with this</text>')
    # orientation dot (top-left inner)
    p.append(f'<circle cx="{INNER_X0+1.4:.2f}" cy="{TOP_Y+1.4:.2f}" r="0.9" fill="#111111"/>')
    # label strip
    p.append(f'<text x="{INNER_X0:.2f}" y="{LABEL_Y+1.6:.2f}" font-family="Helvetica,Arial" '
             f'font-size="2.2" fill="#111111">TOVIS  CALIBRATION</text>')
    p.append(f'<text x="{INNER_X1:.2f}" y="{LABEL_Y+1.6:.2f}" font-family="Helvetica,Arial" '
             f'font-size="2.2" fill="#111111" text-anchor="end">card v0 · CR-80 · 300dpi</text>')
    p.append('</svg>')
    return "\n".join(p)


# ---------------------------------------------------------------- PDF (hand-built vector)
MM2PT = 72.0 / 25.4
PW, PH = CARD_W * MM2PT, CARD_H * MM2PT


def pdf_rect(x, y, w, h):  # top-left mm -> PDF points (bottom-left origin)
    return (x * MM2PT, PH - (y + h) * MM2PT, w * MM2PT, h * MM2PT)


def build_pdf():
    top = swatch_rects(TOP_Y, TOP_H)
    bot = swatch_rects(BOT_Y, BOT_H)
    s = []
    def fill(rgb): s.append(f"{rgb[0]/255:.4f} {rgb[1]/255:.4f} {rgb[2]/255:.4f} rg")
    def rect(x, y, w, h): px, py, pw, ph = pdf_rect(x, y, w, h); s.append(f"{px:.3f} {py:.3f} {pw:.3f} {ph:.3f} re f")
    def text(x_mm, y_mm, size, rgb, txt, anchor="start"):
        approx = len(txt) * size * 0.5
        px = x_mm * MM2PT - (approx if anchor == "end" else approx / 2 if anchor == "middle" else 0)
        py = PH - y_mm * MM2PT
        s.append(f"{rgb[0]/255:.3f} {rgb[1]/255:.3f} {rgb[2]/255:.3f} rg")
        s.append(f"BT /F1 {size} Tf {px:.2f} {py:.2f} Td ({txt}) Tj ET")

    fill((255, 255, 255)); rect(0, 0, CARD_W, CARD_H)
    for (x, y, w, h), rgb in zip(top, SWATCHES[:12]): fill(rgb); rect(x, y, w, h)
    for (x, y, w, h), rgb in zip(bot, SWATCHES[12:]): fill(rgb); rect(x, y, w, h)
    fill(WB_GRAY); rect(INNER_X0, GRAY_Y, INNER_W, GRAY_H)
    fill((17, 17, 17)); rect(INNER_X0 + 0.6, TOP_Y + 0.6, 1.6, 1.6)  # orientation mark
    text(CARD_W / 2, GRAY_Y + 3.4, 6.5, (255, 255, 255), "WHITE BALANCE - fill the frame with this", "middle")
    text(INNER_X0, LABEL_Y + 1.7, 6, (17, 17, 17), "TOVIS  CALIBRATION")
    text(INNER_X1, LABEL_Y + 1.7, 6, (17, 17, 17), "card v0 - CR-80 - 300dpi", "end")
    stream = "\n".join(s).encode("latin-1")

    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.3f %.3f] "
                 "/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>" % (PW, PH)).encode())
    objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

    out = b"%PDF-1.4\n"
    offsets = []
    for i, o in enumerate(objs, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objs) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return out


import os
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "tovis-calibration-card-v0.svg"), "w").write(build_svg())
open(os.path.join(here, "tovis-calibration-card-v0.pdf"), "wb").write(build_pdf())
print("wrote tovis-calibration-card-v0.svg + .pdf  (%.1f x %.1f mm)" % (CARD_W, CARD_H))
