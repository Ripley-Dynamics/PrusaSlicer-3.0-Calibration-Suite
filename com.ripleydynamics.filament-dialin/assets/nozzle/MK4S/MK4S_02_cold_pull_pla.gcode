; 02 PLA cold pull (firmware recipe) - Original Prusa MK4S
; same numbers as the firmware Cold Pull: cool with fan, pull at 90C, hold 95C
; Load PLA BEFORE starting this file. Any nozzle type.
M862.3 P "MK4S" ; printer model check
M17 ; enable steppers
G90 ; absolute XYZ
M83 ; relative E
M107 ; fan off
M302 S170 ; cold-extrusion protection at the default
M591 S0 ; filament-stuck (loadcell) detection off for this job, restored at end
M73 P0 R10
M117 Homing
G28 ; home all
G1 Z100 F720
G1 X125 Y105 F6000
M400
M0 PLA loaded? Put paper under the nozzle to catch the purge, then Continue
M73 P5 R9
M117 Heating to 215C
M104 S215
M109 S215
M117 Purging PLA
G1 E30 F180
G4 S3
M400
M73 P30 R7
M117 Cooling down
M104 S0
M106 S240
M109 R45 ; wait until the nozzle has cooled to 45C
G4 S120
M107
M73 P75 R2
M117 Heating to 90C for the pull
M109 S90
M104 S95 ; firmware raises the target slightly for the pull
M117 Cold pull
M302 S0 ; allow cold extrusion for the pull
G1 E-200 F3000
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
