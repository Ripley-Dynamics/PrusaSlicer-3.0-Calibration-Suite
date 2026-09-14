; 01 Nylon cold pull - Prusa CORE One - High Flow / CHT nozzle
; purge 120 mm PA at 290C, cool to 60C, pull at 145C (firmware M1702 pattern)
; Load nylon (PA) BEFORE starting this file.
M862.3 P "COREONE" ; printer model check
M862.1 F1 ; needs a high-flow nozzle: printer warns if Nozzle Type is Standard
M17 ; enable steppers
G90 ; absolute XYZ
M83 ; relative E
M107 ; fan off
M302 S170 ; cold-extrusion protection at the default
M591 S0 ; filament-stuck (loadcell) detection off for this job, restored at end
M73 P0 R12
M117 Homing
G28 ; home all
G1 Z100 F720
G1 X125 Y110 F6000
M400
M0 Nylon loaded? Put paper under the nozzle to catch the purge, then Continue
M73 P5 R11
M117 Heating to 290C
M104 S290
M109 S290
M117 Soaking at temperature
G4 S45 ; let the melt wet all channels of the CHT core
M117 Purging nylon
M73 P15 R9
G1 E40 F300
G1 E40 F300
G1 E40 F300
G4 S3
M400
G4 S30 ; soak again so the nylon bonds to residue before cooling
M73 P35 R7
M117 Cooling down
M104 S0
M106 S240
M109 R60 ; wait until the nozzle has cooled to 60C
G4 S120
M107
M73 P75 R3
M117 Heating to 145C for the pull
M109 S145
M117 Cold pull
M302 S0 ; allow cold extrusion for the pull
G1 E-300 F3000
M302 S170 ; re-arm cold-extrusion protection (runout M600 then no-ops)
M400
M300 S440 P300
M0 Pull the filament out of the extruder by hand now, then press Continue
M73 P100 R0
M104 S0
M107
M591 R ; restore filament-stuck detection
M84
M117 Cold pull finished
