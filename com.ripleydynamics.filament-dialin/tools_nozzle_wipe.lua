info = {
    id = "nozzle_wipe",
    type = "project.plugin",
    title = "Periodic nozzle wipe on a brush (custom G-code every N mm)",
    menu = "Filament Dial-In/Tools/Periodic nozzle wipe G-code",
    params = {
        { name = "brush_x", label = "Brush start X [mm]", type = "int", default = 240 },
        { name = "brush_y", label = "Brush start Y [mm]", type = "int", default = -3 },
        { name = "stroke", label = "Stroke length [mm] (negative = toward -X)", type = "int", default = -30 },
        { name = "along_y", label = "Stroke along Y instead of X", type = "bool", default = false },
        { name = "strokes", label = "Number of back-and-forth strokes", type = "int", default = 3 },
        { name = "lift", label = "Z lift before travelling to the brush [mm]", type = "int", default = 2 },
        { name = "every", label = "Wipe every N mm of height", type = "int", default = 5 },
        { name = "first", label = "First wipe height [mm]", type = "int", default = 5 },
        { name = "last", label = "Last wipe height [mm]", type = "int", default = 250 },
        { name = "retract", label = "Retract before the wipe [mm] (relative E, 0 = none)", type = "string", default = "0.8" },
        { name = "travel_speed", label = "Travel speed [mm/min]", type = "int", default = 9000 },
        { name = "wipe_speed", label = "Wipe speed [mm/min]", type = "int", default = 3000 },
    },
}

function execute(opts)
    local util = require("lib/util")

    local bx = util.num(opts.brush_x, "brush X", 240)
    local by = util.num(opts.brush_y, "brush Y", -3)
    local stroke = util.num(opts.stroke, "stroke length", -30)
    local strokes = util.int(opts.strokes, "strokes", 3)
    local lift = util.num(opts.lift, "lift", 2)
    local every = util.num(opts.every, "interval", 5)
    local first = util.num(opts.first, "first height", 5)
    local last = util.num(opts.last, "last height", 250)
    local retract = util.decimal(opts.retract, "retract") or 0
    local travel = util.int(opts.travel_speed, "travel speed", 9000)
    local wipe = util.int(opts.wipe_speed, "wipe speed", 3000)

    assert(stroke ~= 0 and math.abs(stroke) <= 200, "Stroke length must be non-zero and at most 200 mm")
    assert(strokes >= 1 and strokes <= 20, "Strokes must be between 1 and 20")
    assert(lift >= 0 and lift <= 20, "Lift must be between 0 and 20 mm")
    assert(every >= 0.5, "Interval must be at least 0.5 mm")
    assert(first > 0 and last >= first, "Heights must be positive and last >= first")
    assert((last - first) / every <= 2000, "Too many wipes; raise the interval")
    assert(retract >= 0 and retract <= 10, "Retract must be between 0 and 10 mm")
    assert(travel > 0 and wipe > 0, "Speeds must be positive")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)

    local axis = opts.along_y and "Y" or "X"
    local far = (opts.along_y and by or bx) + stroke
    local near = opts.along_y and by or bx
    local lines = { "; filament-dialin nozzle wipe" }
    if retract > 0 then
        lines[#lines + 1] = string.format("G1 E-%s F2400", util.fmt(retract, 3))
    end
    if lift > 0 then
        lines[#lines + 1] = "G91"
        lines[#lines + 1] = string.format("G1 Z%s F600", util.fmt(lift, 3))
        lines[#lines + 1] = "G90"
    end
    lines[#lines + 1] = string.format("G1 X%s Y%s F%d", util.fmt(bx, 3), util.fmt(by, 3), travel)
    for _ = 1, strokes do
        lines[#lines + 1] = string.format("G1 %s%s F%d", axis, util.fmt(far, 3), wipe)
        lines[#lines + 1] = string.format("G1 %s%s F%d", axis, util.fmt(near, 3), wipe)
    end
    if lift > 0 then
        lines[#lines + 1] = "G91"
        lines[#lines + 1] = string.format("G1 Z-%s F600", util.fmt(lift, 3))
        lines[#lines + 1] = "G90"
    end
    if retract > 0 then
        lines[#lines + 1] = string.format("G1 E%s F2400", util.fmt(retract, 3))
    end
    lines[#lines + 1] = "; end nozzle wipe"
    local gcode = table.concat(lines, "\n")

    -- The bed keeps one custom G-code list; entries must be appended in
    -- ascending Z, so the list is replaced.
    api.project:clear_layer_custom_steps(bed)
    local count = 0
    local z = first
    while z <= last + 1e-9 do
        api.project:insert_layer_custom_gcode(bed, z + lh * 0.5, gcode)
        count = count + 1
        z = z + every
    end

    util.log(string.format("inserted %d nozzle wipes from %s mm to %s mm every %s mm at brush (%s, %s), %d strokes of %s mm along %s",
        count, util.fmt(first), util.fmt(z - every), util.fmt(every), util.fmt(bx), util.fmt(by), strokes, util.fmt(stroke), axis))
    util.log("assumes relative E (M83) and absolute XYZ, as in Prusa profiles; make sure the brush position is inside the printer's travel limits")
    util.log("this replaced any custom per-layer G-code on the bed, so run it after the towers, not with them")
end
