info = {
    id = "pa_tower",
    type = "project.plugin",
    title = "Pressure advance tower (corners at speed, one PA value per band)",
    menu = "Filament Dial-In/4b. Pressure advance tower (alternative)",
    params = {
        { name = "min_pa", label = "Lowest pressure advance (bottom), e.g. 0.00", type = "string", default = "0.00" },
        { name = "max_pa", label = "Highest pressure advance (top), e.g. 0.10", type = "string", default = "0.10" },
        { name = "by_interval", label = "Choose by interval (on) or by number of bands (off)", type = "bool", default = true },
        { name = "interval", label = "Interval, e.g. 0.01", type = "string", default = "0.01" },
        { name = "sections", label = "Number of bands (when interval is off)", type = "int", default = 6 },
        { name = "section_height", label = "Band height [mm]", type = "int", default = 5 },
        { name = "speed", label = "Perimeter speed for the test [mm/s]", type = "int", default = 120 },
        { name = "firmware", label = "Firmware: prusa (M572), marlin (M900), klipper, reprap", type = "string", default = "prusa" },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- OrcaSlicer's PA tower, rebuilt: a hollow two-perimeter tower whose outline
-- has long fast runs, a notch with inner corners and 90-degree outer
-- corners. Perimeter speed is forced high so every corner is a hard
-- deceleration and acceleration. Pressure advance changes on each band's
-- first layer. Judge the corners: too little PA bulges and blobs at the
-- corners, too much leaves gaps and thin lines right after them.
--
-- PrusaSlicer 3.0 keeps the value in the filament preset
-- (pressure_advance = enabled, pressure_advance_value). Prusa firmware can
-- also self-calibrate (pressure_advance = automatic_calibration); this tower
-- is the way to check that result or to tune by eye.

local BODY_L, BODY_D, NOTCH_W, NOTCH_D = 40, 12, 12, 4.5
local SPINE_W, SPINE_D = 12, 8
local PLINTH_H = 5

local COMMANDS = {
    prusa = "M572 S%s",
    marlin = "M900 K%s",
    klipper = "SET_PRESSURE_ADVANCE ADVANCE=%s",
    reprap = "M572 D0 S%s",
}

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local firmware = tostring(opts.firmware or "prusa"):lower():gsub("%s", "")
    local template = COMMANDS[firmware]
    assert(template, "Firmware must be one of prusa, marlin, klipper, reprap")
    local values = util.range {
        min = util.decimal(opts.min_pa, "lowest pressure advance"), max = util.decimal(opts.max_pa, "highest pressure advance"),
        by_interval = opts.by_interval, interval = util.decimal(opts.interval, "interval"), count = opts.sections, max_count = 20,
    }
    local n = #values
    assert(values[1] >= 0 and values[n] <= 2, "Pressure advance must be between 0 and 2")
    local section_req = util.num(opts.section_height, "band height", 5)
    local speed = util.num(opts.speed, "speed", 120)
    assert(section_req >= 3 and speed >= 10, "Band height must be at least 3 mm and speed at least 10 mm/s")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local h = util.align(section_req, lh, 2)
    local plinth_h = util.align(PLINTH_H, lh, 2)
    local total = n * h
    local depth = BODY_D + SPINE_D

    api.project:clear_layer_custom_steps(bed)
    local volumes = {
        -- hollow body on top of the plinth, with a notch cut into the front
        { mesh = api.make_cube(BODY_L, BODY_D, total), type = VolumeType.Solid, translate = { z = plinth_h } },
        { mesh = api.make_cube(NOTCH_W, NOTCH_D + 1, total + 2), type = VolumeType.Negative, translate = { x = (BODY_L - NOTCH_W) / 2, y = -1, z = plinth_h - 1 } },
        -- solid label spine on the back, and a solid plinth, via modifiers
        { mesh = api.make_cube(SPINE_W, SPINE_D, total), type = VolumeType.Solid, translate = { x = (BODY_L - SPINE_W) / 2, y = BODY_D, z = plinth_h } },
        { mesh = api.make_cube(SPINE_W + 2, SPINE_D + 2, total + 2), type = VolumeType.Modifier, translate = { x = (BODY_L - SPINE_W) / 2 - 1, y = BODY_D - 1, z = plinth_h - 1 },
          params = { perimeters = 3, fill_density = "100%", top_solid_layers = 3, bottom_solid_layers = 3 } },
        { mesh = api.make_cube(BODY_L + 2, depth + 2, plinth_h + 1), type = VolumeType.Modifier, translate = { x = -1, y = -1, z = -1 },
          params = { perimeters = 2, fill_density = "100%", top_solid_layers = 3, bottom_solid_layers = 3 } },
    }
    for i, pa in ipairs(values) do
        local z0 = plinth_h + (i - 1) * h
        api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z0, lh), string.format(template, util.fmt(pa, 4)))
        volumes[#volumes + 1] = {
            mesh = api.make_cube(BODY_L + 2, depth + 2, h), type = VolumeType.Modifier, translate = { x = -1, y = -1, z = z0 },
            params = { perimeter_speed = speed, external_perimeter_speed = speed, small_perimeter_speed = speed },
        }
        volumes[#volumes + 1] = label.back {
            text = string.format("%.3f", pa), x = BODY_L / 2, z = z0 + h / 2, face_y = depth,
            line_height = math.min(4.5, h * 0.55), max_width = SPINE_W - 2, max_height = h - 1.5,
        }
    end
    volumes[#volumes + 1] = label.front {
        text = tag, x = BODY_L / 2, z = plinth_h / 2, face_y = 0,
        line_height = math.min(3.5, plinth_h * 0.6), max_width = BODY_L - 4, max_height = plinth_h - 1,
    }

    api.project:add_object {
        mesh = api.make_cube(BODY_L, depth, plinth_h),
        other_volumes = volumes,
        object_params = { fill_density = "0%", perimeters = 2, top_solid_layers = 0, bottom_solid_layers = 0 },
    }

    local current = util.read_number(bed:material_presets(0), "pressure_advance_value")
    util.log(string.format("pressure advance tower for %s: %d bands of %s mm, %s to %s (%s), perimeters at %s mm/s",
        tag, n, util.fmt(h), util.fmt(values[1], 3), util.fmt(values[n], 3), firmware, util.fmt(speed)))
    util.log("judge the corners on the front: bulges and blobs = too little PA, gaps and thin lines after corners = too much; the plinth prints at the preset's value"
        .. (current and (" (" .. util.fmt(current, 3) .. ")") or ""))
    util.data(bed, "pa", { method = "tower", tag = tag, values = util.join(values, 3), sections = n, section_height = h, speed = speed, firmware = firmware })
end
