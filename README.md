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

| Menu entry | What it adds | What you read off it | What it feeds |
| --- | --- | --- | --- |
| 1. Temperature tower | Solid 30 × 16 mm tower, 10 mm bands, one `M104` per band, optional overhang wings | Gloss, overhang quality, layer bonding, corner bulge | `temperature`, `first_layer_temperature` |
| 2. Flow tower (M221) | Solid tower, one `M221 S<flow%>` per band | The band with a flat top and nominal 30 × 16 mm with calipers | `extrusion_multiplier` (coarse) |
| 3. Max volumetric flow tower | Solid tower, one modifier per band setting all speeds for a target mm³/s | Highest band with no under-extrusion, gaps or grinding | `filament_max_volumetric_speed` |
| 4. Setting sweep plate | Row of 25 mm solid blocks, each under a modifier with one per-region setting | Block with no perimeter/infill gap and no bulge | `infill_overlap` (or any numeric per-region key) |
| 5. Solid slab (mass check, endurance) | 60 × 60 × 20 mm solid block, about 90 g, four witness posts, nominal volume and expected mass engraved | Its weight on a 0.01 g scale; ridges on the top; blobs on the posts and edges | `extrusion_multiplier` (fine) |
| 6. Shrinkage and growth bar | 150 mm bar with two 6 mm holes 130 mm apart, nominal numbers engraved | Hole centre distance, width, hole diameter | scale factor, `xy_size_compensation` |
| 7. Reference coupon | 50 × 25 × 10 mm solid block with a 10 mm hole, tag on the front, note on the back | Length, width, height, hole with calipers; top finish | `xy_size_compensation`, `elefant_foot_compensation` |
| 8. Stringing tower | Two pillars, temperature and optional fan steps | Stringing per band | temperature, fan limits |
| 9. Apply dialed-in values | Nothing printed. Writes the chosen values into the selected filament and print presets and reads them back | The application log | the presets |
| Tools / Periodic nozzle wipe G-code | Nothing printed. Inserts a brush-wipe routine every N mm of height on the bed's custom G-code list | | production prints, once a brush is fitted |

Every tower puts the printer tag on the back of its plinth; the plate, slab,
bar and coupon put it on a back or front face.

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

Run this once per printer with the same spool and nozzle size, starting from
the stock Prusament PETG profile, with the same print preset everywhere.

1. **Temperature tower.** 260 °C at the bottom dropping 5 °C per band to
   235 °C. Pick the coolest band whose layers still bond and whose overhang
   wing is clean. Thick solid parts run hotter than thin ones because layers
   are still warm when the next one lands, so favour the cooler end.
2. **Flow tower.** `M221` from 104% down to 92% in 2% steps. Find the band
   where the top is flat (no ridges, no pinholes) and measure each band
   against 30 × 16 mm. Set the extrusion multiplier to current × chosen % /
   100. Add `M221 S100` to the printer's end G-code, because `M221` persists.
3. **Max volumetric flow tower.** 6 to 24 mm³/s by default; the command lifts
   the preset's volumetric and layer-time limits so the requested speeds are
   really used (uncheck the option to keep them). Set the filament limit to
   roughly 85% of the highest clean band. This is what stops a fast printer
   from under-extruding solid infill and leaving voids that lower the mass.
4. **Setting sweep plate.** `infill_overlap` 10% to 35%. Take the lowest
   overlap with no gap between perimeters and solid infill; too much overlap
   is what makes solid parts bulge. Other sweeps worth running once:
   `solid_infill_extrusion_width` (`0.4` step `0.05`), `perimeters` (`2` step
   `1`), `top_solid_infill_speed`.
5. **Solid slab.** Print with the values so far, let it cool, weigh it. The
   command logs the expected mass from the preset's `filament_density`
   (1.27 g/cm³ for Prusament PETG) and the current multiplier, and engraves
   the nominal volume and mass on the front:

   new multiplier = current multiplier × expected g / measured g

   Then look at the part: ridges on the top mean the overlap or width is still
   too high even at the right mass; blobs on the posts or edges mean the
   nozzle is picking material up, which the mass correction usually fixes.
   Make it bigger (100 × 100 × 40 mm is about 500 g) when you want a test
   that runs as long as a production part.
6. **Shrinkage bar.** Measure the hole centre distance C as the average of the
   near-edge and far-edge gaps between the two holes, the width Wm and a hole
   diameter Dm. Then, with the engraved nominals C0, W0, D0:

   shrinkage s = 1 − C / C0
   XY growth per side g = (Wm − W0 × (1 − s)) / 2, cross-check with (D0 × (1 − s) − Dm) / 2

   Set `xy_size_compensation` to −g and scale production models by
   1 / (1 − s) in each axis (or ignore s if the parts are small).
7. **Reference coupon.** One per printer with everything applied. Measure all
   four dimensions and compare across printers; adjust elephant foot from the
   first layer's flare. Keep the coupons: tag and note are engraved.
8. **Stringing tower** if retraction or fan behaviour differs between machines.
9. **Apply dialed-in values.** Type the numbers into the dialog. The command
   writes them into the selected presets and logs the read-back. Nothing is
   saved until you save the preset, so save the filament preset under a
   printer-specific name (for example `Prusament PETG - MK4S #3`) and select
   it in that printer's profile.

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

## Things to know before running it

- **Numeric fields.** PrusaSlicer 3.0.0-alpha11 wires the `int` and `float`
  dialog controls in reverse, so whole-number fields are declared `int` and
  fields that need decimals (extrusion multiplier, compensation, extrusion
  width, density, sweep values) are declared as text and parsed. Every value
  is validated inside `execute`, and blank text fields mean "leave the preset
  value alone".
- **No dialog feedback.** A failed run is written to PrusaSlicer's log, not to
  the dialog. Start PrusaSlicer from a terminal to see the `[filament-dialin]`
  lines that each command prints (expected mass, section speeds, values
  written, warnings).
- **Custom G-code is replaced.** The towers and the nozzle wipe clear the
  bed's custom G-code list before inserting their own entries (undo restores
  the old list).
- **Presets are modified, not saved.** Commands 3 and 9 change the selected
  presets. The GUI shows them as modified.
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
  com.ripleydynamics.filament-dialin/   the bundle to copy into the user plugins folder
    manifest.json
    temp_tower.lua                   1. temperature tower
    flow_tower.lua                   2. M221 flow tower
    volumetric_tower.lua             3. max volumetric flow tower
    sweep_plate.lua                  4. per-region setting sweep
    slab.lua                         5. solid slab, mass check
    shrink_bar.lua                   6. shrinkage and growth bar
    coupon.lua                       7. reference coupon
    stringing_tower.lua              8. stringing tower
    apply_results.lua                9. write values into presets
    nozzle_wipe.lua                  Tools: periodic nozzle wipe G-code
    lib/util.lua                     value parsing, preset readers, logging
    lib/label.lua                    engraved text on front, back and top faces
    lib/tower.lua                    stacked-section tower builder and overhang wing
  test/
    mock_api.lua                     stand-in for PrusaSlicer's api / VolumeType
    run_tests.lua                    discovery and execution tests
```
