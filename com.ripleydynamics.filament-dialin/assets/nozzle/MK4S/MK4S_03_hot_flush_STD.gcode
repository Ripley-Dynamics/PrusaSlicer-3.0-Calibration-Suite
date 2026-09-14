; 03 Hot flush - Original Prusa MK4S - Standard nozzle
; 290C push-through: 5 x 40 mm with a 10 mm ram-back between stages
; Use nylon or a cleaning filament. Load it BEFORE starting this file.
; Clears colour / material carry-over and soft partial clogs. Nothing is pulled.
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
M0 Nylon or cleaning filament loaded? Paper under the nozzle? Then Continue
M73 P5 R9
M117 Heating to 290C
M104 S290
M109 S290
M117 Soaking at temperature
G4 S30
M117 Flush stage 1/5
M73 P15 R8
G1 E40 F180
G1 E-10 F1200 ; ram back to break up debris
G4 S2
G1 E10 F600
M117 Flush stage 2/5
M73 P29 R7
G1 E40 F180
G1 E-10 F1200 ; ram back to break up debris
G4 S2
G1 E10 F600
M117 Flush stage 3/5
M73 P43 R6
G1 E40 F180
G1 E-10 F1200 ; ram back to break up debris
G4 S2
G1 E10 F600
M117 Flush stage 4/5
M73 P57 R4
G1 E40 F180
G1 E-10 F1200 ; ram back to break up debris
G4 S2
G1 E10 F600
M117 Flush stage 5/5
M73 P71 R3
G1 E40 F180
G1 E-10 F1200 ; ram back to break up debris
G4 S2
G1 E10 F600
M117 Final slow push
G1 E20 F120
M400
M300 S440 P300
M0 Flush done. Unload it from the menu and load your print filament. Continue
M73 P100 R0
M104 S0
M107
M591 R ; restore filament-stuck detection
M84
M117 Hot flush finished
