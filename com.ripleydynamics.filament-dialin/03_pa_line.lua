info = {
    id = "pa_line",
    type = "project.plugin",
    title = "Pressure advance line test (OrcaSlicer PA Line), recommended",
    menu = "Filament Dial-In/3. Pressure advance line (recommended)",
    params = {
        { name = "min_pa", label = "Lowest pressure advance (bottom line), e.g. 0.00", type = "string", default = "0.00" },
        { name = "max_pa", label = "Highest pressure advance (top line), e.g. 0.08", type = "string", default = "0.08" },
        { name = "by_interval", label = "Choose by interval (on) or by number of lines (off)", type = "bool", default = true },
        { name = "interval", label = "Interval, e.g. 0.005", type = "string", default = "0.005" },
        { name = "sections", label = "Number of lines (when interval is off)", type = "int", default = 9 },
        { name = "slow_speed", label = "Slow segment speed [mm/s]", type = "int", default = 20 },
        { name = "fast_speed", label = "Fast segment speed [mm/s]", type = "int", default = 100 },
        { name = "spacing", label = "Line spacing [mm]", type = "int", default = 5 },
        { name = "bed_x", label = "Bed centre X [mm] (0 = from printer name)", type = "int", default = 0 },
        { name = "bed_y", label = "Bed centre Y [mm] (0 = from printer name)", type = "int", default = 0 },
        { name = "retract", label = "Retraction to mirror the slicer's [mm] (relative E)", type = "string", default = "0.8" },
        { name = "firmware", label = "Firmware: prusa (M572), marlin (M900), klipper, reprap", type = "string", default = "prusa" },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- OrcaSlicer's "PA Line": one extruded line per pressure advance value, each
-- made of a short slow run, a long fast run and a short slow run, with the
-- value written beside it in extruded digits. The right value is the line
-- whose fast run has the same width as its slow runs: no thin start, no fat
-- blob at the end.
--
-- The plugin API cannot emit G-code directly, so the whole pattern is one
-- custom per-layer G-code entry on the first layer of a small anchor plate
-- that PrusaSlicer centres on the bed. The pattern is drawn in absolute bed
-- coordinates above that plate. Relative extrusion (M83, the Prusa default)
-- is assumed; absolute-E profiles would be thrown off.

local SHORT, LONG = 20, 40                -- Orca's segment lengths
local DIGIT_W, DIGIT_H, DIGIT_GAP = 2, 3, 0.8
local PLATE = 10

local COMMANDS = {
    prusa = "M572 S%s", marlin = "M900 K%s", klipper = "SET_PRESSURE_ADVANCE ADVANCE=%s", reprap = "M572 D0 S%s",
}

-- Bed centres by printer family, front-left origin.
local BED_CENTRES = {
    { "core one", 125, 110 }, { "xl", 180, 180 }, { "mini", 90, 90 }, { "mk4", 125, 105 }, { "mk3", 125, 105 }, { "mk2", 125, 105 },
}

-- Seven-segment strokes in a unit cell: x 0..1, y 0..1 (y up).
local SEG = {
    a = { 0, 1, 1, 1 }, b = { 1, 1, 1, 0.5 }, c = { 1, 0.5, 1, 0 }, d = { 0, 0, 1, 0 }, e = { 0, 0.5, 0, 0 }, f = { 0, 1, 0, 0.5 }, g = { 0, 0.5, 1, 0.5 },
}
local GLYPHS = {
    ["0"] = "abcdef", ["1"] = "bc", ["2"] = "abged", ["3"] = "abgcd", ["4"] = "fgbc", ["5"] = "afgcd",
    ["6"] = "afgedc", ["7"] = "abc", ["8"] = "abcdefg", ["9"] = "abcdfg",
}

local function bed_centre(name)
    local lower = name:lower()
    for _, entry in ipairs(BED_CENTRES) do
        if lower:find(entry[1], 1, true) then
            return entry[2], entry[3]
        end
    end
    return nil
end

function execute(opts)
    local util = require("lib/util")
    local tower = require("lib/tower")

    local firmware = tostring(opts.firmware or "prusa"):lower():gsub("%s", "")
    local template = COMMANDS[firmware]
    assert(template, "Firmware must be one of prusa, marlin, klipper, reprap")
    local values = util.range {
        min = util.decimal(opts.min_pa, "lowest pressure advance"), max = util.decimal(opts.max_pa, "highest pressure advance"),
        by_interval = opts.by_interval, interval = util.decimal(opts.interval, "interval"), count = opts.sections, max_count = 30,
    }
    local n = #values
    assert(values[1] >= 0 and values[n] <= 2, "Pressure advance must be between 0 and 2")
    local slow = util.num(opts.slow_speed, "slow speed", 20)
    local fast = util.num(opts.fast_speed, "fast speed", 100)
    local spacing = util.num(opts.spacing, "spacing", 5)
    local retract = util.decimal(opts.retract, "retraction") or 0
    assert(slow >= 5 and fast > slow, "Fast speed must be greater than slow speed, slow at least 5 mm/s")
    assert(spacing >= DIGIT_H + 1, "Line spacing must be at least " .. (DIGIT_H + 1) .. " mm so the labels fit")
    assert(retract >= 0 and retract <= 10, "Retraction must be between 0 and 10 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local nozzle = util.nozzle(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local name = util.printer_name(bed)
    local cx, cy = util.num(opts.bed_x, "bed centre X", 0), util.num(opts.bed_y, "bed centre Y", 0)
    if cx <= 0 or cy <= 0 then
        cx, cy = bed_centre(name)
        assert(cx, "Bed centre unknown for printer '" .. name .. "': enter Bed centre X and Y (half the bed size)")
    end

    local width = nozzle * 1.2
    local diameter = util.read_number(bed:material_presets(0), "filament_diameter") or 1.75
    local e_per_mm = util.extrusion_area(width, lh) / (math.pi * (diameter / 2) ^ 2)
    local x0 = cx - (SHORT + LONG + SHORT) / 2
    local y0 = cy + PLATE / 2 + 5
    local label_x = x0 + SHORT + LONG + SHORT + 4
    local fmt = function(v) return util.fmt(v, 4) end

    local g = { "; filament-dialin pressure advance line test", "G90" }
    local function travel(x, y) g[#g + 1] = string.format("G0 X%s Y%s F9000", fmt(x), fmt(y)) end
    local function line(x1, y1, x2, y2, speed)
        local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
        g[#g + 1] = string.format("G1 X%s Y%s E%s F%d", fmt(x2), fmt(y2), fmt(len * e_per_mm), math.floor(speed * 60 + 0.5))
    end
    local function glyph(ch, x, y)
        if ch == "." then
            travel(x + DIGIT_W * 0.3, y); line(x + DIGIT_W * 0.3, y, x + DIGIT_W * 0.6, y, slow); return DIGIT_W * 0.6
        end
        if ch == "1" then -- centred stroke instead of the seven-segment right edge
            travel(x + DIGIT_W * 0.5, y); line(x + DIGIT_W * 0.5, y, x + DIGIT_W * 0.5, y + DIGIT_H, slow); return DIGIT_W * 0.6
        end
        local segs = GLYPHS[ch]
        if not segs then return DIGIT_W end
        for i = 1, #segs do
            local sgm = SEG[segs:sub(i, i)]
            travel(x + sgm[1] * DIGIT_W, y + sgm[2] * DIGIT_H)
            line(x + sgm[1] * DIGIT_W, y + sgm[2] * DIGIT_H, x + sgm[3] * DIGIT_W, y + sgm[4] * DIGIT_H, slow)
        end
        return DIGIT_W
    end
    if retract > 0 then g[#g + 1] = string.format("G1 E%s F2400", fmt(retract)) end
    for i, pa in ipairs(values) do
        local y = y0 + (i - 1) * spacing
        g[#g + 1] = string.format(template, util.fmt(pa, 4))
        travel(x0, y)
        line(x0, y, x0 + SHORT, y, slow)
        line(x0 + SHORT, y, x0 + SHORT + LONG, y, fast)
        line(x0 + SHORT + LONG, y, x0 + SHORT + LONG + SHORT, y, slow)
        local text = string.format("%.3f", pa)
        local x = label_x
        for c = 1, #text do
            x = x + glyph(text:sub(c, c), x, y - DIGIT_H / 2) + DIGIT_GAP
        end
    end
    local preset_pa = util.read_number(bed:material_presets(0), "pressure_advance_value")
    if preset_pa and preset_pa > 0 then g[#g + 1] = string.format(template, util.fmt(preset_pa, 4)) .. " ; back to the preset's value" end
    if retract > 0 then g[#g + 1] = string.format("G1 E-%s F2400", fmt(retract)) end
    g[#g + 1] = "; end pressure advance line test"

    api.project:clear_layer_custom_steps(bed)
    api.project:insert_layer_custom_gcode(bed, tower.gcode_z(0, lh), table.concat(g, "\n"))

    -- The anchor: a small solid plate at the bed centre so the print has a first layer to carry the pattern.
    api.project:add_object {
        mesh = api.make_cube(PLATE, PLATE, util.align(1, lh, 2)),
        object_params = util.solid_params(),
    }

    util.log(string.format("pressure advance line test for %s: %d lines, %s to %s (%s), %s/%s mm/s, bed centre (%s, %s), pattern %s x %s mm above the anchor plate",
        tag, n, util.fmt(values[1], 3), util.fmt(values[n], 3), firmware, util.fmt(slow), util.fmt(fast), util.fmt(cx), util.fmt(cy),
        util.fmt(SHORT + LONG + SHORT + 4 + 5 * (DIGIT_W + DIGIT_GAP)), util.fmt((n - 1) * spacing)))
    util.log("pick the line whose fast middle run is as wide as its slow ends: thin start = too little PA, fat end blob = too much; the value is written beside each line")
    util.log("requires relative extrusion (M83) in the printer profile; check the pattern position in the G-code preview before printing")
    util.data(bed, "pa", { method = "line", tag = tag, values = util.join(values, 3), sections = n, slow = slow, fast = fast,
        bed_x = cx, bed_y = cy, firmware = firmware, line_width = width })
end
