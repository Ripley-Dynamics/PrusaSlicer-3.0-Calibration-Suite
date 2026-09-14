"""Filament Dial-In for PrusaSlicer 2.9.x: the test prints as ready-to-slice
3MF projects, generated here instead of inside PrusaSlicer.

PrusaSlicer 2.9 has no plugin API. Everything the 3.0 plugin does, though, has
a place in a PrusaSlicer project file: meshes, per-volume settings (modifiers,
negative volumes), per-object settings and per-layer custom G-code. `threemf`
writes such files; each step module builds one; `python3 -m port29 <step>`
is the command line. Standard library only, like the helper.
"""
