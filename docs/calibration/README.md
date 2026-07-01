# Tovis camera-calibration card — v0 (Zebra ZXP Series 7)

Print-ready artifacts for the CR-80 calibration card the pro camera samples for
color/white-balance:

| File | Use |
|------|-----|
| `tovis-calibration-card-v0.pdf` | **Print this.** Vector, exact CR-80 (85.6 × 54 mm). |
| `tovis-calibration-card-v0.png` | 300 dpi raster (1011 × 636 px) for Zebra CardStudio. |
| `tovis-calibration-card-v0.svg` | Editable vector source. |
| `generate_card.py` | Regenerates all three (edit layout/colors here). |

Layout: 12 ColorChecker swatches top + 12 bottom (reading order 1–24, matching
`TovisKit CameraCalibration.CardReferenceProfile.placeholderClassic`), a large
**neutral gray in the center** (the white-balance target — the app samples the
center ~40% of the frame), and an orientation dot (top-left).

## Printing on the ZXP Series 7

- **Card:** standard CR-80, 300 dpi. The PDF/PNG are already exact size — print at
  **100 % / actual size**, no "fit to page" scaling.
- **Ribbon:** YMCKO (full color). Print at the **highest quality** setting.
- **⚠️ Turn OFF color enhancement / auto-correction** in the ZXP driver or
  CardStudio (any "vivid"/ICC/auto-color option). We want the swatches printed as
  close to the file values as the printer will do — an *unpredictable* print is
  useless as a reference.
- **NFC/RFID cards:** the chip is separate from the print. Encode the
  **card-version id** (e.g. `tovis-cal-v0-<batch>`) onto the chip with the ZXP's
  encoder or a phone NFC-writer app. v0 doesn't require NFC — you can hardcode /
  manually pick the card version in the app until the NFC read is wired up.

## What works immediately: white balance

No measurement needed. In the camera: tap the **eyedropper** button → fill the
dashed box with the card's center gray → **Set white balance**. The room's color
cast is neutralized so blondes/coppers/skin photograph true. A white towel works
too — the card just makes the neutral patch consistent.

## ⚠️ Before the 3×3 color matrix means anything: MEASURE the card

A dye-sub card printer is **not** color-accurate, so the printed swatches will
**not** equal the nominal ColorChecker values below. The white-balance path is
forgiving and doesn't care. The **color-correction matrix does** — it's only as
good as the *true* colors of your specific printed card. So for each print batch:

1. **Measure** each printed swatch — best: a spectrophotometer (e.g. an X-Rite
   ColorChecker passport reader / i1); acceptable: photograph the card in even
   daylight next to a *real* reference and read sRGB values.
2. Record them in the table below (measured columns).
3. Put the measured values into a new `CardReferenceProfile` in
   `TovisKit/.../CameraCalibration.swift`, keyed by the card's version id, and
   select it (via NFC read, or manually) before applying the matrix.

Until then, the matrix built from nominal values is illustrative only.

## Swatch reference (nominal ColorChecker sRGB) — fill in Measured per batch

Reading order = top row left→right (1–12), then bottom row left→right (13–24).

| # | Name | Nominal R,G,B | Measured R,G,B |
|--:|------|---------------|----------------|
| 1 | Dark skin | 115, 82, 68 | |
| 2 | Light skin | 194, 150, 130 | |
| 3 | Blue sky | 98, 122, 157 | |
| 4 | Foliage | 87, 108, 67 | |
| 5 | Blue flower | 133, 128, 177 | |
| 6 | Bluish green | 103, 189, 170 | |
| 7 | Orange | 214, 126, 44 | |
| 8 | Purplish blue | 80, 91, 166 | |
| 9 | Moderate red | 193, 90, 99 | |
| 10 | Purple | 94, 60, 108 | |
| 11 | Yellow green | 157, 188, 64 | |
| 12 | Orange yellow | 224, 163, 46 | |
| 13 | Blue | 56, 61, 150 | |
| 14 | Green | 70, 148, 73 | |
| 15 | Red | 175, 54, 60 | |
| 16 | Yellow | 231, 199, 31 | |
| 17 | Magenta | 187, 86, 149 | |
| 18 | Cyan | 8, 133, 161 | |
| 19 | White | 243, 243, 242 | |
| 20 | Neutral 8 | 200, 200, 200 | |
| 21 | Neutral 6.5 | 160, 160, 160 | |
| 22 | Neutral 5 | 122, 122, 121 | |
| 23 | Neutral 3.5 | 85, 85, 85 | |
| 24 | Black | 52, 52, 52 | |

Center WB patch = pure neutral 128,128,128 (not one of the 24).
