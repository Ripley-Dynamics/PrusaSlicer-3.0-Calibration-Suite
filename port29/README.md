# port29: the dial-in prints for PrusaSlicer 2.9.x

PrusaSlicer 2.9 has no plugin API, so this folder builds the same test prints
as ready-to-slice **3MF projects** instead. Everything the 3.0 plugin does in
the slicer has a place in a PrusaSlicer project file:

| Plugin (3.0) | Project file (2.9.6) |
| --- | --- |
| `api.make_cube` / cylinder / cone / pyramid / `load_stl` | meshes in `3D/3dmodel.model` |
| `VolumeType.Solid` / `Modifier` / `Negative` | `volume_type` in `Metadata/Slic3r_PE_model.config` |
| per-volume and per-object params | `<metadata type="volume"/"object" key=... value=.../>` in the same file |
| `insert_layer_custom_gcode` | `Metadata/Prusa_Slicer_custom_gcode_per_print_z.xml`, `type="4"` (custom) |
| `api.emboss_text` | a stroke font drawn from boxes (`geometry.stroke_text`), same placement maths |
| reading the selected presets | typed on the command line (or by the sheet) |

Standard library only, like the helper. Verified against the 2.9.6 source of
`src/libslic3r/Format/3mf.cpp` (attribute names, volume type strings, the
custom G-code entry format, `slic3rpe:Version3mf` = 1).

## Use

```sh
python3 -m port29 slab --tag "MK4S 0.4" --density 1.27 --bed 250x210 -o slab.3mf
```

Open the `.3mf` in PrusaSlicer 2.9 (double-click, or File > Import > Import
3MF). The object arrives centred on the bed with its per-object settings
(100% rectilinear infill for the slab) and its engraved labels as negative
volumes. The command prints the same log lines and `DATA` line as the plugin,
so the helper's log parser and the sheet understand it.

`--bed` is the bed size the object is centred on: MK4S 250x210, CORE One
250x220, CORE One L 300x300, XL 360x360.

## Status

| Step | State |
| --- | --- |
| 5 Solid slab | done (`slab.py`) |
| 3MF writer, primitives, stroke-font labels | done (`threemf.py`, `geometry.py`) |
| 1, 2, 3, 3b, 4, 6 to 12 | to port: same pattern, each is one module |
| 13 preset file | planned: a complete `.ini` flattened from the vendor bundle (see below) |

Tests: `python3 -m unittest discover -s test -p 'test_*.py'` (also run by
`./run-tests.sh`). They check closed, outward-facing meshes, the triangle
ranges in the model config, the labels' depth into the faces, and the numbers
against the plugin's.

## Presets for 2.9.6

A user filament preset in 2.9.6 is an `.ini` in `<user data>/filament/`. An
imported config bundle whose section `inherits` a system preset starts from
PrusaSlicer's *defaults*, not from that preset (checked in
`PresetBundle::load_configbundle`), so the file has to be complete. The plan:
read the vendor bundle that ships with 2.9.6 (`resources/profiles/PrusaResearch.ini`,
or the user's copy under `<user data>/vendor/`), flatten the `inherits` chain
of the chosen base filament the way PrusaSlicer does, apply the dialed-in
values, and write the full `.ini` with `inherits` and `compatible_printers`
set. Then File > Import > Import Config, or drop it into the folder and restart.

## Not yet verified

Nothing here has been opened in PrusaSlicer 2.9 itself. The file structure
follows the 2.9.6 writer line by line and every generated mesh is validated,
but the first import on a real installation is the test that counts.
