; 04 Flow test - Original Prusa MK4S - High Flow / CHT nozzle
; PLA at 220C, 40 mm at each speed, prompt between stages so you can watch
; Clicking / grinding or a thin curling strand = restriction at that flow.
; Load PLA BEFORE starting this file.
M862.3 P "MK4S" ; printer model check
M862.1 F1 ; needs a high-flow nozzle: printer warns if Nozzle Type is Standard
M17 ; enable steppers
G90 ; absolute XYZ
M83 ; relative E
M107 ; fan off
M302 S170 ; cold-extrusion protection at the default
M591 S0 ; filament-stuck (loadcell) detection off for this job, restored at end
M73 P0 R6
M117 Homing
G28 ; home all
G1 Z100 F720
G1 X125 Y105 F6000
M400
M0 PLA loaded? Paper under the nozzle? Watch the nozzle during each stage
M117 Heating to 220C
M104 S220
M109 S220
M117 Priming
G1 E15 F180
M400
M73 P10 R5
M0 Stage 1: 40mm at 4 mm/s (10 mm3/s). Watch for clicks or thinning
M117 Flow test 4 mm/s
G1 E40 F240
M400
G4 S2
M73 P36 R4
M0 Stage 2: 40mm at 8 mm/s (19 mm3/s). Watch for clicks or thinning
M117 Flow test 8 mm/s
G1 E40 F480
M400
G4 S2
M73 P63 R3
M0 Stage 3: 40mm at 11 mm/s (26 mm3/s). Watch for clicks or thinning
M117 Flow test 11 mm/s
G1 E40 F660
M400
G4 S2
M300 S440 P300
M0 Done. The first stage that clicked or thinned is the nozzle's real limit
M73 P100 R0
M104 S0
M107
M591 R ; restore filament-stuck detection
M84
M117 Flow test finished
