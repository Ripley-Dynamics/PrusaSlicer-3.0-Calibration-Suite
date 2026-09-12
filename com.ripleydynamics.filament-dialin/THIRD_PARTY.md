# Third-party assets and design credits

Everything in this bundle is MIT licensed except the files listed below, which
is why `manifest.json` declares `MIT AND AGPL-3.0-only AND CC-BY-NC-4.0`.

## Prusa Research calibration assets — AGPL-3.0-only

`assets/prusa/temp_tower-base.stl`, `assets/prusa/temp_tower-step.stl` and
`assets/prusa/hreben.svg` are copied unchanged from PrusaSlicer 3.0.0-alpha11,
`resources/lua/com.prusa3d.slicer.calibration`, Copyright Prusa Research a.s.,
licensed under the GNU Affero General Public License v3.0 only
(AGPL-3.0-only). See https://github.com/prusa3d/PrusaSlicer. The combination is
distributed under the terms of the AGPL for these three files.

## Ultimate Fan Speed Test V3 — CC BY-NC 4.0, non-commercial

`assets/fan/ultimate-fan-test-v3.stl` is **"Ultimate Fan Speed Test V3"** by
**Abyss**, **Printables model 200347**, licensed **CC BY-NC 4.0**
(https://creativecommons.org/licenses/by-nc/4.0/). It is a remix of **"Ultimate
Fan Speed Test"** and **"Cooling direction test"** by **@MarioL_3d_designer**.
The file shipped here is the 26 November 2025 **"new version angle v2"** variant
(fan-direction fins, overhang angles 25 to 70 degrees), **unmodified**.

**This one file may not be used commercially.** CC BY-NC 4.0 allows anyone to
download, print, modify and pass it on with attribution for non-commercial
purposes only. Anyone who sells this plugin, or ships it as part of something
sold, must delete `assets/fan/ultimate-fan-test-v3.stl` and let each user place
their own copy: step 6 then stops with an error naming the path and the model
number when `Model: abyss` is chosen, and its built-in tower needs no asset at
all.

Keep the attribution above with any copy of the model you share.
`assets/fan/README.md` describes how the command reads it.

## Design credits — no files copied

The cooling tower's slender heat-soak pillar and the clearance-hole row of the
hole and fit gauge follow leotrax3d's fan tower and tolerance test from
https://github.com/leotrax3d/prusaslicer-plugins-unofficial (MIT). The code
here is a re-implementation on this bundle's helpers.

The flow staircase follows Crepmähn's "Extrusion Multiplier/Flow-Rate
Calibration for PrusaSlicer" (Printables model 1190404): one flat chip per flow
value, stacked with risers only a few layers tall, which is OrcaSlicer's
one-pass flow test built the way PrusaSlicer can build it. No files are copied
from it; the geometry is generated here.
