Prusa nozzle maintenance suite (MK4S full suite; Core One / Core One L nylon cold pull)
=====================================================================================

Copy the .bgcode files for your printer to its USB stick. Files are numbered so they sort in order.

MK4S/bgcode
  MK4S_01_cold_pull_nylon_STD / _HF   nylon purge 290C, fan-cool, extruder-driven cold pull at 145C
  MK4S_02_cold_pull_pla               the firmware's own Cold Pull numbers (PLA, pull 90C, hold 95C)
  MK4S_03_hot_flush_STD / _HF         290C push-through with ram-back cycles (nylon or cleaning filament)
  MK4S_04_flow_test_STD / _HF         PLA 220C, stepped speeds with prompts; watch for clicking/thinning
  MK4S_05_nozzle_brush                heat to 250C, park front and high, hold for a brass-brush clean
COREONE/bgcode, COREONEL/bgcode
  01_cold_pull_nylon_STD / _HF        same nylon cold pull, with the 300 mm pull the firmware uses there

STD = standard nozzle. HF = High Flow / CHT (longer soak, bigger and faster purge). HF files carry
M862.1 F1, so the printer warns "Nozzle not high-flow" if its Nozzle Type setting is Standard.

gcode/       the same sequences as readable plain G-code
thumbnails/  the image embedded in each file (480x240), as shown on the printer's progress screen
screens/     mockups of what the MK4S display shows while a file runs (from the firmware GUI layout)
generator/   python3 make_suite.py            rebuilds everything into out_suite/ (needs: pip install pillow)
             python3 make_suite.py MK4S       one printer
             make_suite.py holds the routines and all temperatures/lengths/speeds; thumbs.py renders
             and QOI-encodes the thumbnails; screens.py draws the screen mockups.

Before any run: load the filament the prompt names, put a scrap of paper on the bed under the
nozzle, and watch the first run. Nothing has been tested on hardware yet. Everything was built and
verified against the Prusa-Firmware-Buddy source and the bgcode specification.
The prompts say "Continue"; the firmware's button is labelled "Resume". Same thing.

Suggested order for a suspected clog: flow test -> hot flush -> flow test -> nylon cold pull -> flow test.
Do not use an acupuncture needle on High Flow / CHT nozzles (the core sits right behind the tip).
