info = {
    id = "01_temp_tower",
    type = "project.plugin",
    title = "Temperature tower (Prusa calibration model, 100% infill)",
    menu = "Filament Dial-In/1. Temperature tower",
    params = {
        { name = "max_temp", label = "Hottest section [C] (printed first, at the bottom)", type = "int", default = 260 },
        { name = "min_temp", label = "Coolest section [C] (top)", type = "int", default = 235 },
        { name = "by_interval", label = "Choose by interval (on) or by number of sections (off)", type = "bool", default = true },
        { name = "interval", label = "Interval [C]", type = "int", default = 5 },
        { name = "sections", label = "Number of sections (when interval is off)", type = "int", default = 6 },
        { name = "solid", label = "Print at 100% infill", type = "bool", default = true },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- Geometry comes from PrusaSlicer's own calibration plugin (assets/prusa):
-- a 80 x 10 x 1 mm base and 80 x 10 x 10 mm steps with bridge and overhang
-- features. Each step is one temperature band. Measured from the STL, the
-- front face (y = -5) is flat at x = -25.72..-5.72 (labels) and x = 20..30
-- (printer tag); the overhang cut-out starts at x = 30, so the tag is kept
-- inside 20.5..29.5.
local LABEL_X, TAG_X = -16, 25

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local temps = util.range {
        min = opts.min_temp, max = opts.max_temp, by_interval = opts.by_interval,
        interval = opts.interval, count = opts.sections, integer = true, max_count = 20,
    }
    for _, t in ipairs(temps) do
        assert(t >= 150 and t <= 350, "Temperature out of range: " .. t)
    end
    -- hottest at the bottom: descending order
    table.sort(temps, function(a, b) return a > b end)
    local n = #temps

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)

    local base = api.load_stl("assets/prusa/temp_tower-base.stl")
    local bb = base:bounds()
    local base_h = bb.max_z - bb.min_z
    local step = api.load_stl("assets/prusa/temp_tower-step.stl")
    local sb = step:bounds()
    local step_h = sb.max_z - sb.min_z
    assert(base_h > 0 and step_h > 0, "Prusa calibration models did not load")
    local front_y = math.min(bb.min_y, sb.min_y)
    local back_y = sb.max_y

    api.project:clear_layer_custom_steps(bed)
    local volumes = {}
    for i, t in ipairs(temps) do
        local z0 = base_h + (i - 1) * step_h
        volumes[#volumes + 1] = {
            mesh = api.load_stl("assets/prusa/temp_tower-step.stl"),
            type = VolumeType.Solid,
            translate = { z = z0 - sb.min_z },
        }
        api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z0, lh), "M104 S" .. t)
        volumes[#volumes + 1] = label.front {
            text = tostring(t), x = LABEL_X, z = z0 + 4, face_y = front_y,
            line_height = 4.5, max_width = 20, max_height = 6,
        }
    end
    volumes[#volumes + 1] = label.front {
        text = tag, x = TAG_X, z = base_h + 4, face_y = front_y,
        line_height = 3.5, max_width = 9, max_height = 6,
    }

    api.project:add_object {
        mesh = base,
        other_volumes = volumes,
        translate = { z = -bb.min_z },
        object_params = opts.solid and util.solid_params() or nil,
    }

    util.log(string.format("temperature tower for %s: %d bands of %s mm, %d C (bottom) to %d C (top), layer %s mm",
        tag, n, util.fmt(step_h), temps[1], temps[n], util.fmt(lh, 3)))
    util.log("the base prints at the preset temperature; each M104 lands on its band's first layer; bridges and overhangs are Prusa's calibration model")
    util.data(bed, "temp", { tag = tag, values = util.join(temps, 0), sections = n, section_height = step_h,
        solid = opts.solid and true or false })
end
