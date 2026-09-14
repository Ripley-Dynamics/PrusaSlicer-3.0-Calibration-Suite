; 05 Nozzle brush clean - Original Prusa MK4S
; heats to 250C, parks the nozzle front and high, holds while you brass-brush it
; Any filament, any nozzle. Keep the brush off the silicone sock and thermistor.
M862.3 P "MK4S" ; printer model check
M17 ; enable steppers
G90 ; absolute XYZ
M83 ; relative E
M107 ; fan off
M302 S170 ; cold-extrusion protection at the default
M591 S0 ; filament-stuck (loadcell) detection off for this job, restored at end
M73 P0 R5
M117 Homing
G28 ; home all
G1 Z150 F720
G1 X125 Y0 F6000
M400
M0 Have a brass brush ready. The nozzle will heat to 250C. Continue
M117 Heating to 250C
M104 S250
M109 S250
M300 S440 P300
M0 HOT! Brush the nozzle tip and sides now. Press Continue when done
M117 Cooling with fan
M73 P100 R0
M104 S0
M106 S240
G4 S90
M107
M591 R ; restore filament-stuck detection
M84
M117 Nozzle brush finished
