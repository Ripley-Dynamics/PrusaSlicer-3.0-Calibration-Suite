# The fan test model

Step 6 (Cooling tower) can print the **Ultimate Fan Speed Test V3** instead of
the built-in tower, and that model is **included in this bundle** as

    assets/fan/ultimate-fan-test-v3.stl

Nothing to download: run **Plugins > Filament Dial-In > 6. Cooling tower** with
**Model** set to `abyss` and it is loaded from here.

If the file has been removed (see the licence note at the bottom: a commercial
repackaging has to remove it), the command stops with an error naming this path
and the Printables model, and nothing is added to the plate. **Model: tower**,
the built-in tower, needs no asset at all.

## How the model is read

The model is designed around one rule: **fan speed rises 1% per mm of height**,
0% at the bottom and 100% at the top, with a marker every 10 mm. The command
inserts an `M106` on every layer at `round(z)` percent, so the height in
millimetres of the band that looks best *is* the fan percentage to use. It also
adds a small solid plate with the printer tag beside the model, because the
model itself carries no label.

## Licence and attribution

**"Ultimate Fan Speed Test V3"** by **Abyss** — **Printables model 200347** —
licensed **CC BY-NC 4.0**
(https://creativecommons.org/licenses/by-nc/4.0/). It is a remix of **"Ultimate
Fan Speed Test"** and **"Cooling direction test"** by **@MarioL_3d_designer**.

The file shipped here is the 26 November 2025 **"new version angle v2"** variant
(fan-direction fins, overhang angles 25 to 70 degrees), **unmodified**.

Keep that attribution with any copy of the model you share.

### This file alone is non-commercial

The rest of the bundle is MIT (with Prusa's AGPL-3.0-only calibration assets in
`assets/prusa`), but CC BY-NC 4.0 permits **non-commercial use only**. Anyone
selling this plugin, or bundling it with something sold, must delete
`ultimate-fan-test-v3.stl` and let each user place their own copy from the
Printables page instead. See `THIRD_PARTY.md` at the bundle root.
