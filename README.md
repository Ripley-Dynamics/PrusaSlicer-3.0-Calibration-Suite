# Filament Dial-In plugin for PrusaSlicer 3.0

A PrusaSlicer 3.0 Lua plugin bundle that generates the complete set of test
prints for dialing in a filament, with the emphasis on parts printed at
**100% infill** and on getting the **same part out of several printers**.

Most calibration prints are designed to use as little filament as possible.
That hides exactly what goes wrong on a solid 24-hour PETG part: a fraction
of a percent of over-extrusion accumulating into XY growth and top-surface
ridges, material piling on the nozzle and dropping as blobs, thermal
shrinkage over 150 mm, and heat soak in thick sections. The parts here are
sized for those failures, and the plugin does the arithmetic (nominal volume,
expected mass, shrinkage and growth formulas) and engraves the numbers on the
part along with a printer tag, so coupons from five printers can be laid side
by side and read without notes.

Written against the API documented in
[prusaslicer-lua-plugins-api-doc](https://github.com/jedisct1/prusaslicer-lua-plugins-api-doc)
and PrusaSlicer `3.0.0-alpha11`. It runs entirely inside the sandbox: no files
are written, no network, nothing outside the selected project and presets.

## Install

1. In PrusaSlicer 3.0 choose **Plugins > Show User Plugins Folder**.
2. Copy the whole `com.ripleydynamics.filament-dialin` directory into it.
3. Choose **Plugins > Rescan Plugins**.
4. The commands appear under **Plugins > Filament Dial-In**.

An unpacked bundle needs no signature. To distribute a signed ZIP, generate a
key pair with `PrusaSlicer plugin keygen`, sign with
`PrusaSlicer plugin sign --private <key> ./com.ripleydynamics.filament-dialin`,
and place the public key at `<user data>/authorized_authors/ripley-dynamics.pem`
on each machine (see the API doc's packaging page).

## The commands

The Plugins menu lists them in this order (filenames are numbered so the
menu follows the procedure).

| Menu entry | What it adds | What you read off it | What it feeds |
| --- | --- | --- | --- |
| 1. Temperature tower | PrusaSlicer's own calibration model (80 × 10 mm base, 10 mm steps with bridges and overhangs), one `M104` per step, printed solid | Bridge sag, overhang fray, gloss, layer bonding | `temperature`, `first_layer_temperature` |
| 2. Flow staircase (M221) | Staircase whose every tread is printed at its own `M221` value: pass 1 sweeps 80 to 120% in 5% steps, pass 2 sweeps 1% steps around the winner (OrcaSlicer's method, rebuilt for PrusaSlicer) | Top surface of each tread | `extrusion_multiplier` (coarse) |
| 3. Pressure advance tower | Hollow two-perimeter tower with a notch (long runs and 90° corners), perimeters forced to 120 mm/s, one PA value per band via `M572` / `M900` / Klipper's command, labels on a solid spine | Corner bulge (too little) or gaps after corners (too much) | `pressure_advance_value`, mode `enabled` |
| 4. Max volumetric flow | PrusaSlicer's single-wall comb with one speed modifier per band, plus a solid label column; or a solid block | Highest band with no gaps, roughness or extruder clicking | `filament_max_volumetric_speed` |
| 5. Solid slab (mass check) | 60 × 60 × 20 mm solid block, about 90 g, witness posts, nominal volume and expected mass engraved | Its weight on a 0.01 g scale, ridges on top, blobs on the posts | `extrusion_multiplier` (fine) |
| 6. Infill overlap calibration | Row of solid 25 mm blocks, each under a modifier with one overlap value | Top layer where infill meets the perimeters | `infill_overlap` |
| 7. Shrinkage and growth bar | 150 mm bar with two holes 130 mm apart, nominals engraved | Hole centre distance, width, hole diameter | scale factor, `xy_size_compensation` |
| 8. Reference coupon | 50 × 25 × 10 mm solid body with a hole, an overhang wing on the +X end, and 0.8 / 1.2 / 1.6 mm fins on top | Dimensions, the wing's underside, whether each fin is solid | `xy_size_compensation`, `elefant_foot_compensation`, thin-wall settings |
| 9. Stringing tower | Two pillars, temperature and optional fan steps | Stringing per band | temperature, fan limits |
| 10. Apply dialed-in values | Nothing printed. Writes typed values into the selected presets and reads them back | The log or the helper's drawer | the presets |
| Tools / Apply values from profile.lua | Nothing printed. Writes the values the sheet saved for the selected printer | The log or the helper's drawer | the presets |
| Tools / Periodic nozzle wipe G-code | Nothing printed. Inserts a brush-wipe routine every N mm of height | | production prints, once a brush is fitted |

Every command that sweeps something takes a minimum, a maximum, and a
switch: **by interval** (for example every 5 °C) or **by number of
sections**. Every part is engraved with the printer tag.

### Why this order, and what each step assumes

Each step changes one variable and assumes the earlier ones are already
applied to the presets. The sheet checks this from the `DATA` line every
command prints and warns when a step was printed with a different
temperature, multiplier, layer height, nozzle or print profile than the
earlier steps.

1. **Temperature** first, because flow, bridging and stringing all move
   with it. Printed solid on Prusa's model so heat soak in thick sections
   is part of the test.
2. **Flow, coarse then fine**, at the chosen temperature. Two passes on the
   staircase get within 1%. Apply the result before step 3.
3. **Pressure advance** once flow is right, because corner bulge from too
   little PA and over-extrusion look alike. PrusaSlicer 3.0 stores PA in the
   filament preset (mode plus value); Prusa firmware can also self-calibrate
   it, and the tower checks that result.
4. **Max volumetric flow** next, because everything after it prints at the
   new limit. Set the filament's volumetric limit and cooling slowdown to 0
   for this print (the command can write them, but see the caution below).
5. **Slab, weighed**, at the new multiplier and limit. Mass is the precise
   flow measurement and also proves the hotend keeps up at the new speeds;
   if the slab is light, step 3 was too optimistic.
6. **Infill overlap** only after flow is right, since overlap and
   over-extrusion look alike on a top surface. Take the lowest overlap with
   no gap beside the innermost perimeter; too much overlap is what bulges
   solid parts.
7. **Shrinkage bar** separates thermal shrinkage from perimeter growth.
8. **Coupon** confirms everything on a part-like object and adds the
   overhang and thin-wall checks that a production part will meet.
9. **Stringing** is optional and machine-specific.
10. **Apply** and save the filament preset under the printer's name.

## Why parts differ between printers at 100% infill

Three separate effects add up, and each test isolates one:

- **Volumetric over-extrusion.** Extruder gear wear, hobbing depth and
  thermistor offset change how much plastic really comes out for a given E
  move, by a few percent between machines. At 15% infill that excess has room
  to go; at 100% it has none. It shows as ridges on the top surface, growth in
  X and Y, the nozzle plowing through the previous layer, and PETG collecting
  on the nozzle until it drops. The **slab** measures it directly: a solid
  block of known volume weighed on a scale gives the over-extrusion to about
  0.1%, better than any visual test. The **flow tower** finds the right
  neighbourhood first.
- **XY growth of perimeters.** Squish and die swell push the outer wall
  outward by a fixed amount per side, independent of part size. The
  **coupon** and the **bar** measure it (outer width grows, holes shrink).
  Corrected with `xy_size_compensation`.
- **Thermal shrinkage.** PETG shrinks roughly 0.3 to 0.6% on cooling, so a
  150 mm part comes out 0.5 to 0.9 mm short while a 20 mm part looks fine. The
  **bar** measures it from the hole centre distance, where perimeter growth
  cancels. Corrected by scaling the model in PrusaSlicer (the Lua API cannot
  set scale).

## Procedure for Prusament PETG at 100% infill

Run this once per printer with the same spool, nozzle, layer height and
print profile, starting from the stock Prusament PETG profile. The sheet
(`wizard/index.html`) walks through it and does the arithmetic; the short
form:

1. **Temperature tower**: 260 down to 235 °C in 5 °C bands. Choose the
   coolest clean band. Apply it (step 9 or the profile).
2. **Flow staircase** pass 1 (80 to 120% by 5) then pass 2 (winner ± 4% by
   1). Multiplier = current × winner / 100. Apply it. Put `M221 S100` in the
   end G-code.
3. **Pressure advance tower**: 0.00 to 0.10 in 0.01 steps. Sharpest
   corners without gaps. Apply it (mode enabled plus the value).
4. **Max volumetric flow** on the comb, 6 to 24 mm³/s. Limit = 85% of the
   highest clean band. Apply it.
5. **Slab**: weigh it. Multiplier = printed multiplier × expected g /
   measured g. Apply it.
6. **Infill overlap**: 10 to 35% in 5% steps. Lowest value with no gap.
7. **Bar**: shrinkage from hole centres, XY growth from width and hole.
8. **Coupon** with everything applied; measure, judge wing and fins, keep.
9. **Stringing** if needed.
10. **Apply and save** the filament preset per printer.

### Nozzle brush

Nozzle pickup is mostly cured by getting the mass right, but PETG will still
collect on a long print. Once a brush is mounted somewhere the nozzle can
reach (a gantry-mounted silicone or brass brush beside the bed is typical),
**Tools > Periodic nozzle wipe G-code** inserts a routine every N mm of
height: retract, lift, travel to the brush, scrub back and forth, lower,
unretract. Enter the brush position in printer coordinates and check it in
the G-code preview before printing. It assumes relative E and absolute XYZ,
which is how Prusa profiles are set up. It replaces the bed's custom
per-layer G-code list, so use it on production prints, not on the towers.

## The dial-in sheet (step-by-step companion)

PrusaSlicer's plugin API has no window or panel API; the only interface a
plugin gets is the automatic Run dialog. The step-by-step walkthrough
therefore lives beside PrusaSlicer as a single page:
[`wizard/index.html`](wizard/index.html). Open it in any browser, or run it
through the helper below. For each printer it shows which command to run and
the dialog values to type, takes your measurements, and computes the results:
the extrusion multiplier from the slab's mass, shrinkage and XY growth from
the bar, deviations on the coupon, and the final values for the Apply
command. Records stay in the browser; Export shows JSON to copy between
machines.

### profile.lua: the sheet's values inside the plugin

Step 9 of the sheet writes a `profile.lua`, keyed by printer name as
PrusaSlicer shows it, with the tag and the dialed-in values for each
printer. Put it in the bundle folder (the helper does this with one click)
and:

- every command engraves the profile's tag when the dialog's tag field is
  blank, so parts are labelled consistently without typing;
- **Tools > Apply values from profile.lua** writes the temperatures,
  multiplier, volumetric limit, pressure advance (value plus mode
  enabled), fan and slowdown values into the selected filament preset and the overlap into the print preset, in one click,
  instead of retyping them into command 9.

No rescan is needed after changing `profile.lua`; it is read on every Run.

### The helper: running the sheet beside PrusaSlicer

`helper/dialin_helper.py` is a single standard-library Python script for the
PC that drives the printers. Start it from the repo folder:

```
python3 helper/dialin_helper.py
```

It opens the sheet at `http://127.0.0.1:8765/` and adds a status bar and a
log drawer to it:

- **Install / Update bundle** copies the plugin into PrusaSlicer's user
  plugins folder (detected from the PrusaSlicer-alpha, -beta or release data
  folder; override with `--plugins-dir`). An existing `profile.lua` is kept.
- **Save profile.lua** writes the sheet's profile straight into the bundle.
- **Launch PrusaSlicer** starts it as a child process and streams its
  output into the log drawer. The path is detected (installed builds, and
  portable zips unpacked in Downloads or on the Desktop) or set with
  `--prusaslicer`, which takes the executable or the folder of a portable
  zip. On Windows the helper runs `prusa-slicer-console.exe`; the GUI
  executable has no console output. A portable zip still keeps its user
  data, and therefore its plugins folder, under `%APPDATA%\PrusaSlicer-alpha`. Plugin errors, which PrusaSlicer otherwise only writes to its
  log, appear there in red.
- Every command prints one `DATA` line with the printer name, tag and its
  numbers. The helper forwards these and the sheet acts on them: it selects
  or creates the printer, jumps to that step, and records the slab's nominal
  volume and expected mass, the bar's nominal distances and the coupon's
  nominal sizes as PrusaSlicer computed them.

Measurements still come from your calipers and scale; the helper cannot
press Run in PrusaSlicer, and PrusaSlicer cannot read the sheet. Paths are
remembered in `dialin-helper.json` in your config folder.

### One build plate per test

PrusaSlicer 3.0 projects can hold several beds. The plugin always adds to
the bed that is currently selected and keeps custom per-layer G-code per
bed, but the API cannot create or select beds. So the routine for every
step is: add a bed (the + next to the bed tabs), select it, run the command.
The sheet repeats this reminder on each step.

## Things to know before running it

- **Numeric fields.** PrusaSlicer 3.0.0-alpha11 wires the `int` and `float`
  dialog controls in reverse, so whole-number fields are declared `int` and
  fields that need decimals (extrusion multiplier, compensation, extrusion
  width, density, sweep values) are declared as text and parsed. Every value
  is validated inside `execute`, and blank text fields mean "leave the preset
  value alone".
- **No dialog feedback.** A failed run is written to PrusaSlicer's log, not to
  the dialog. Start PrusaSlicer from a terminal, or through the helper, to
  see the `[filament-dialin]` lines that each command prints (expected mass,
  section speeds, values written, warnings).
- **Custom G-code is replaced.** The towers and the nozzle wipe clear the
  bed's custom G-code list before inserting their own entries (undo restores
  the old list).
- **Presets are modified, not saved.** Command 10 and Tools › Apply change
  the selected presets; command 4 does so only when its "write 0 into the
  preset's limits" option is on. The GUI shows them as modified. Switching
  printer or material profiles while presets are modified has crashed
  alpha11 (exit code 0xC0000409); save or discard the changes before
  switching.
- **One object per run.** PrusaSlicer centres each new object on the bed, so
  after adding two parts press **A** to arrange them.
- **Label text.** Labels are engraved 0.6 mm deep and shrunk to fit the face
  they sit on. A long printer name is shortened (`Original Prusa MK4S 0.4
  nozzle` becomes `MK4S 0.4`); type a short tag if you prefer.
- **Fan steps.** The stringing tower inserts `M106` per section. PrusaSlicer's
  own cooling logic may re-issue fan commands when it changes speed, so keep
  the filament's fan settings constant while running a fan sweep.
- **Setting keys.** The sweep plate passes the key straight to the slicer.
  An unknown key or one of an unsupported type (boolean, string, vector) is
  ignored silently by the alpha11 setter; the object list in PrusaSlicer shows
  what was really applied. `PrusaSlicer --export-config-schema schema.json`
  lists every key and type for your build.

## Development and tests

```
./run-tests.sh
```

needs Lua 5.4 (`lua5.4` or `lua` on the PATH). The runner mirrors
PrusaSlicer's two-stage lifecycle: every file is first evaluated without `api`
and `require`, as the discovery scan does, then each command is re-evaluated
in a sandbox with a mock of the alpha11 API (`test/mock_api.lua`) and its
`execute` is run with the dialog defaults and with variations. The mock keeps
the alpha11 quirks that matter: primitives report empty bounds, text meshes
report real bounds, percent and float-or-percent values come back opaque,
unknown keys are ignored by `set`, and custom G-code must be inserted in
ascending Z.

What the mock cannot check is the real slicer: run each command once on a
printer profile you care about and look at the result in the 3D view before
printing. Worth eyeballing the first time: label orientation on front and
back faces, that the overhang wings attach to the +X side, that the
volumetric tower's modifiers show per-section speeds in the object list, and
the nozzle wipe path in the G-code preview.

## Layout

```
prusaslicer-filament-dialin/
  README.md                          this file
  run-tests.sh                       runs the suite
  wizard/index.html                  the step-by-step dial-in sheet (offline page)
  helper/dialin_helper.py            serves the sheet beside PrusaSlicer, installs the bundle, streams its output
  com.ripleydynamics.filament-dialin/   the bundle to copy into the user plugins folder
    manifest.json
    01_temp_tower.lua                1. temperature tower on Prusa's model
    02_flow_stairs.lua               2. M221 flow staircase
    03_pa_tower.lua                  3. pressure advance tower
    04_volumetric_tower.lua          4. max volumetric flow on Prusa's comb
    05_slab.lua                      5. solid slab, mass check
    06_overlap.lua                   6. infill overlap calibration
    07_shrink_bar.lua                7. shrinkage and growth bar
    08_coupon.lua                    8. reference coupon
    09_stringing_tower.lua           9. stringing tower
    10_apply_results.lua             10. write values into presets
    tools_apply_profile.lua          Tools: write values from profile.lua
    tools_nozzle_wipe.lua            Tools: periodic nozzle wipe G-code
    profile.lua                      (optional) written by the sheet or the helper
    assets/prusa/                    Prusa's calibration STLs and comb SVG (AGPL-3.0, see THIRD_PARTY.md)
    lib/util.lua                     value parsing, preset readers, logging
    lib/label.lua                    engraved text on front, back and top faces
    lib/tower.lua                    stacked-section tower builder and overhang wing
  test/
    mock_api.lua                     stand-in for PrusaSlicer's api / VolumeType
    run_tests.lua                    discovery and execution tests
```
