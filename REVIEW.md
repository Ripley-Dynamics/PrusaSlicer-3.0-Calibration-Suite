# Code review, 2026-09-14

Reviewed by an Opus agent over the whole repository at commit `fb659c8`
(branch identical to `main`), then every finding was independently
re-verified against the code, the mock API and the shipped STLs. Status
per finding: **confirmed** (reproduced or read directly in the code),
**confirmed, revised** (real, but the severity or a detail changed on
verification), or **rejected**.

Test suite: `./run-tests.sh` on Lua 5.4.6 passes 26/26 (at the reviewed commit; the
follow-up commit below keeps it at 26/26 with the rewritten step 0 and the new
bed, relative-E and file checks).

## Follow-up commit (same day)

Decisions from the maintainer, and what changed:

- **1 done.** Every request to the helper must carry the loopback `Host` it
  was started on; every POST must carry the sheet's own `Origin` (and, when
  the browser sends it, a same-origin `Sec-Fetch-Site`). The sheet uses
  relative URLs so nothing there changed; foreign pages get 403.
- **2** accepted as is for now.
- **3** explained below; unchanged.
- **4 done.** Step 0 no longer writes a purge into a sliced print. The bundle
  ships the Prusa-firmware maintenance files (`assets/nozzle/<PRINTER>/`,
  `.bgcode` plus plain `.gcode`) for the MK4S, CORE One / One+ / One+ (Gen 2)
  and CORE One L / L+; the command names the file for the selected printer and
  nozzle (standard or High Flow), the helper serves it at
  `/assets/nozzle/...` and the sheet offers the downloads. Generator source is
  in `tools/nozzle-suite/`.
- **5 done.** `util.try_set` probes the key first and reports "NOT written"
  for a key the preset does not have, and reads enums back as strings so a
  rejected value (`pressure_advance = enbaled`) is reported instead of
  counted. Separately, the sheet's Save preset now produces a complete
  PrusaSlicer 3.0 filament preset (YAML user preset inheriting the system
  preset) and the helper writes it into PrusaSlicer's user presets folder.
- **6 done.** `util.require_relative_e` reads `use_relative_e_distances` from
  the printer preset; the PA line test and the nozzle wipe's retract refuse an
  absolute-E profile and warn when the value cannot be read.
- **7** explained below; unchanged.
- **8** by design (100% infill suite); a selectable test infill is planned.
- **9 done.** Tag moved to x = 25, max width 9 mm, inside the measured flat
  face (x 20..30); comment corrected.
- **10 done.** The PA line's bed table now holds only XL / XL+ (360 × 360),
  CORE One / One+ / One+ (Gen 2) (250 × 220), CORE One L / L+ (300 × 300) and
  MK4S (250 × 210), matched longest-name-first with `xl` as a whole word, and
  the command refuses a pattern that would run off the bed. Any other printer
  types its bed centre.
- **11** explained below; unchanged.
- **12 done.** Every `id` interpolated into an HTML attribute in the sheet now
  goes through `esc()`.

## Critical and high

1. **Confirmed. Helper HTTP API has no Origin, Host or token check.**
   `helper/dialin_helper.py` `do_POST` (about line 648). While the helper
   runs, any web page can send a no-preflight `text/plain` POST to
   `127.0.0.1:8765`. `/api/config` accepts an arbitrary executable path and
   `/api/launch` spawns it; `/api/profile` writes arbitrary Lua into the
   installed bundle, which `lib/util.lua` `require("profile")` executes on
   every command run. Missing Host check also enables DNS rebinding.
   Fix: reject any Origin other than the served origin, require the exact
   Host, and add a per-process token that the served page echoes.

2. **Confirmed, revised to high. Self-update runs unverified code from `main`.**
   `self_update` downloads `helper/dialin_helper.py`, only `compile()`s it,
   overwrites itself and re-executes. No hash, signature or pinned commit.
   The `DIALIN_RAW_BASE` override (line 187) accepts `file://` and `http://`.
   Revised because an attacker who can set the user's environment variables
   can already run code; the real exposure is the trust placed in the
   GitHub account. Document the trust model or pin to a release and hash.

3. **Confirmed. `--auto` (the double-click launcher) destroys local edits.**
   `update_from_github` calls `copy_bundle(new_bundle, BUNDLE_SRC)`, which
   `rmtree`s the checkout's bundle folder, and overwrites `wizard/index.html`
   and `README.md` in the checkout (`REFRESHED`). No prompt, no backup, and
   the window is minimised. Run from a non-checkout folder it writes those
   files next to wherever `helper/` lives.

4. **Confirmed. Step 0 purges 140 mm of filament in place at first-layer height.**
   `00_nozzle_clean.lua` `purge()` emits only `G1 E.. F150`; no Z lift or XY
   move anywhere in the sequence. Add a lift/park before the first purge.

5. **Confirmed. `util.try_set` returns true for writes that never happened.**
   `lib/util.lua` lines 345 to 366. Reproduced against the mock: unknown key,
   invalid enum, bool and string destinations all return `true` with nothing
   written. Step 13 and Tools/Apply then report "N preset value(s) written".
   `pressure_advance` (enum) is never verifiable this way. Probe the key with
   `box:value` before writing and return false when the probe raises.

6. **Confirmed. Relative E is assumed, never checked.**
   `grep -rn relative_e` over the bundle returns nothing. `03_pa_line.lua`,
   `00_nozzle_clean.lua` and `tools_nozzle_wipe.lua` emit delta E values. On
   an absolute-E profile the PA line becomes a multi-metre retraction. Read
   `use_relative_e_distances` from the printer preset and assert.

## Medium

7. **Confirmed. `util.range` rounds to 3 decimals and produces duplicates.**
   Reproduced: `0..0.002 by 0.0005` gives `0,0.001,0.001,0.002,0.002`;
   `0..5, 10 sections, integer` gives `0,1,1,2,2,3,3,4,4,5`. Assert values
   are distinct, and round to a precision derived from the interval.

8. **Confirmed. Tools/Apply forces 100% rectilinear infill unconditionally.**
   `tools_apply_profile.lua` lines 151 to 152 run whenever `print_preset` is
   on (default true), regardless of profile.lua. Step 13 puts the same
   behaviour behind an opt-in that defaults to false. Also no range checks on
   values read from profile.lua, and a bad value aborts after earlier keys
   were already written.

9. **Confirmed by measurement. Temperature tower tag overlaps the overhang zone.**
   Front-plane vertices of `temp_tower-step.stl` sit at x = -40, -25.72,
   -5.72, 20, 30, 40. The flat tag face is x 20..30, but `TAG_X = 30` with
   `max_width = 15` spans 22.5..37.5. The code comment and README say 22..38.
   Move the tag to x = 25 with max width about 9.

10. **Confirmed. PA line pattern reaches the rear edge of a MINI bed.**
    `03_pa_line.lua`: `PLATE = 10`, MINI centre y = 90, so `y0 = 100`; the
    default 17 lines at 5 mm spacing put the last line at y = 180 and its
    digits past it. Also `bed_centre` substring-matches `"xl"` anywhere in
    the printer name. Carry a bed size per family and assert the fit.

11. **Confirmed. Slab nominal volume ignores the engraved labels.**
    `05_slab.lua`: `volume_mm3 = X*Y*Z + posts`; the two negative label
    volumes are not subtracted, yet the log claims "well under 0.1 g" and
    the README claims 0.1% accuracy. The exact size of the error depends on
    glyph coverage; it is of the same order as the accuracy claimed.

12. **Confirmed. Unescaped `id` in HTML attributes in the sheet.**
    `wizard/index.html` lines 673, 689, 801, 1093 interpolate `x.id` / `p.id`
    without `esc()`. `Import JSON` parses an arbitrary file and `migrate()`
    does not touch `id`, so a crafted export gets script on the helper's
    origin, which then reaches the endpoints in finding 1 with no CSRF needed.

13. **Confirmed. Nozzle wipe lowers Z and unretracts at the brush.**
    `tools_nozzle_wipe.lua` lines 52 to 75: no return move to the pre-wipe XY
    before the descent; the prime is deposited in the brush and the slicer's
    retraction state is now wrong.

14. **Confirmed. Multi-tool printers always use slot 0 / tool 1.**
    Every `material_presets(0)` and `tools[1]` call, including step 13's
    writes. `tool_count` is readable and never consulted.

15. **Confirmed. `bed:material_presets(0)` called outside `pcall` in seven places.**
    `00_nozzle_clean.lua:99`, `03_pa_line.lua:100,143`, `03b_pa_tower.lua:103`,
    `04_flow_stairs.lua:146`, `05_slab.lua:34`, `06_cooling_tower.lua:145`,
    `10_small_feature_tower.lua:60`, `13_apply_results.lua:25`,
    `tools_apply_profile.lua:55`, `02_volumetric_tower.lua:108-112`. The
    `pcall` inside `read_number` does not cover the argument expression.

16. **Confirmed. `manifest.json` `repo` points at `Prusa-USA-StockChecker`.**

17. **Confirmed. Sheet gate graph disagrees with the README for step 13.**
    `GATES.apply = ["temp"]` in `wizard/index.html`; README's diagram gates
    step 13 on 10, 11, 12 and the plate.

## Low

18. **Confirmed.** `tools_open_sheet.lua` hard-codes port 8765 in its message.
19. **Confirmed.** `07_overlap.lua` allows `gap >= 0` while modifiers are
    inflated 1 mm per side, so with gap under 2 mm a later modifier overrides
    the neighbouring block's edge.
20. **Confirmed.** `02_volumetric_tower.lua` spine is a 14 x 8 mm island
    3 mm from the comb, up to 120 mm tall, with no brim or bed-size check.
21. **Confirmed.** `first_layer_height` is never read; `tower.gcode_z` assumes
    layers at multiples of `layer_height`, so band boundaries shift by up to
    one layer on profiles where the two differ.
22. **Confirmed, revised.** `detect_prusaslicer` globs `**/PrusaSlicer*.AppImage`
    under the whole home directory on Linux. Opus said this runs even when a
    path is saved; it does not. `Helper.__init__` short-circuits with `or`, so
    the scan only runs when neither the flag nor the saved path resolves.
23. **Confirmed.** `INSTALLED.json` records the SHA from a separate, later,
    rate-limited API call, not the commit actually inside the zip.
24. **Confirmed.** No `LICENSE` file despite the MIT claim in README and manifest.
25. **Confirmed.** `onData` in the sheet creates `p.steps[d.step]` for any step
    id, so Tools/Apply's `apply_profile` pollutes saved state.
26. **Confirmed, nit.** `Dial-In Sheet.cmd` is mode 0644 while the shell
    scripts are 0755. The nested `cmd /c "..."` quoting is correct; a path
    containing `& ^ ( )` would still break it.

## Test gaps (all confirmed by reading `test/`)

- No test passes `try_set` an unknown key, bool/string destination or bad enum.
- No bed extents in the mock, so off-bed patterns are undetectable.
- `util.range` tests check counts and endpoints, not distinctness.
- No Python tests at all for the helper.

## Checked and found correct

Asset bounding boxes match the STLs and SVG; `make_cube` argument order;
label rotation maths; custom G-code ascending-Z ordering; `util.fmt`,
`util.align`, `util.extrusion_area`, `util.fan_pwm`; interval arithmetic and
end inclusion; discovery-time safety (no `io`, `os`, `load`, top-level
`api`); menu id ordering; Lua string escaping when the sheet writes
profile.lua; `textContent` use in the log drawer; sheet-to-plugin DATA key
contract; `subprocess` list form with no shell; zip member filtering.
