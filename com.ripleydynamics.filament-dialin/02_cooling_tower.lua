info = {
    id = "cooling_tower",
    type = "project.plugin",
    title = "Cooling tower: fan per band, overhang wings and a heat-soak pillar",
    menu = "Filament Dial-In/2. Cooling tower",
    params = {
        { name = "min_fan", label = "Lowest fan [%] (bottom band)", type = "int", default = 0 },
        { name = "max_fan", label = "Highest fan [%] (top band)", type = "int", default = 100 },
        { name = "by_interval", label = "Choose by interval (on) or by number of bands (off)", type = "bool", default = true },
        { name = "interval", label = "Interval [%]", type = "int", default = 20 },
        { name = "sections", label = "Number of bands (when interval is off)", type = "int", default = 6 },
        { name = "section_height", label = "Band height [mm]", type = "int", default = 8 },
        { name = "size", label = "Tower size [mm]", type = "int", default = 20 },
        { name = "overhang_angle", label = "Overhang wing angle from horizontal [deg] (0 = none)", type = "int", default = 45 },
        { name = "own_fan", label = "Write constant cooling into the filament preset so the bands are authoritative", type = "bool", default = true },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- Geometry after leotrax3d's fan tower (MIT): a square tower plus a slender
-- pillar 15 mm away. The head travels to the pillar every layer, so it gets
-- almost no time to cool and shows insufficient cooling first. Our overhang
-- wings on the +X side of each band add the overhang view.
--
-- Fan is firmware state, so each band is switched with M106. PrusaSlicer's
-- cooling logic re-emits its own fan speed whenever its computed value
-- changes (short layers, bridges, dynamic overhang fan), which would override
-- the bands. Two defences: the M106 is repeated on every layer of a band, and
-- with `own_fan` the preset's fan values are all set equal and the layer-time
-- thresholds to zero, so the slicer's value never changes and it emits once.
-- The boolean switches (cooling, fan_always_on, dynamic fan) cannot be written
-- by the alpha11 setter; the command reads them and warns instead.

local PILLAR, PILLAR_GAP = 6, 15
local BASE_H = 3

local function fan_gcode(percent, util)
    local pwm = util.fan_pwm(percent)
    return pwm == 0 and "M107" or ("M106 S" .. pwm)
end

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local fans = util.range { min = opts.min_fan, max = opts.max_fan, by_interval = opts.by_interval,
        interval = opts.interval, count = opts.sections, integer = true, max_count = 20 }
    for _, f in ipairs(fans) do assert(f >= 0 and f <= 100, "Fan out of range: " .. f) end
    local n = #fans
    local size = util.num(opts.size, "tower size", 20)
    local section_req = util.num(opts.section_height, "band height", 8)
    local angle = util.num(opts.overhang_angle, "overhang angle", 45)
    assert(size >= 10 and section_req >= 4, "Tower size must be >= 10 mm and band height >= 4 mm")
    assert(angle == 0 or (angle >= 20 and angle <= 80), "Overhang angle must be 0 or between 20 and 80 degrees")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local material = bed:material_presets(0)
    local h = util.align(section_req, lh, 2)
    local base_h = util.align(BASE_H, lh, 2)
    local total = base_h + n * h

    -- Warn about the switches we cannot flip.
    local function flag(key)
        local ok, v = pcall(function() return material:value(key) end)
        return ok and v or nil
    end
    if flag("enable_dynamic_fan_speeds") == true then
        util.log("WARNING: Filament > Cooling > 'Enable dynamic fan speeds' is on; the slicer changes fan on overhangs mid-layer. Turn it off for this print or the wings are not printed at the band's fan.")
    end
    if flag("fan_always_on") == false then
        util.log("note: fan_always_on is off; the first band's M107/M106 still applies from its first layer")
    end

    api.project:clear_layer_custom_steps(bed)
    local volumes = {
        { mesh = api.make_cube(PILLAR, PILLAR, total), type = VolumeType.Solid, translate = { x = size + PILLAR_GAP, y = (size - PILLAR) / 2 } },
    }
    local layers_per_band = math.max(1, math.floor(h / lh + 0.5))
    for i, f in ipairs(fans) do
        local z0 = base_h + (i - 1) * h
        local cmd = fan_gcode(f, util)
        for k = 0, layers_per_band - 1 do -- every layer of the band, so the slicer's own fan logic cannot win a layer
            api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z0 + k * lh, lh), cmd)
        end
        if angle > 0 then
            volumes[#volumes + 1] = tower.wing { x_face = size, depth = size, z0 = z0, section_height = h, angle_deg = angle, thickness = 2, wing_depth = size * 0.5 }
        end
        volumes[#volumes + 1] = label.front { text = f .. "%", x = size / 2, z = z0 + h / 2, face_y = 0,
            line_height = tower.label_line_height(h), max_width = size - 3, max_height = h - 1.5 }
    end
    volumes[#volumes + 1] = label.back { text = tag, x = size / 2, z = base_h / 2, face_y = size,
        line_height = math.min(3, base_h * 0.6), max_width = size - 3, max_height = base_h - 0.8 }

    if opts.own_fan then
        util.log("writing constant cooling into the filament preset (fan " .. fans[1] .. "% everywhere, no layer-time changes); presets are modified, not saved")
        for _, key in ipairs({ "min_fan_speed", "max_fan_speed", "bridge_fan_speed", "overhang_fan_speed_0", "overhang_fan_speed_1", "overhang_fan_speed_2", "overhang_fan_speed_3" }) do
            util.try_set(material, key, fans[1], key)
        end
        util.try_set(material, "fan_below_layer_time", 0, "fan below layer time")
        util.try_set(material, "slowdown_below_layer_time", 0, "slowdown below layer time")
        util.try_set(material, "full_fan_speed_layer", 0, "full fan speed layer")
        util.try_set(material, "disable_fan_first_layers", 1, "disable fan first layers")
    end

    api.project:add_object {
        mesh = api.make_cube(size, size, total),
        other_volumes = volumes,
        object_params = { fill_density = "15%", perimeters = 2, top_solid_layers = 3, bottom_solid_layers = 3 },
    }

    util.log(string.format("cooling tower for %s: %d bands of %s mm, fan %d%% to %d%%, pillar %s mm away, wings at %s deg",
        tag, n, util.fmt(h), fans[1], fans[n], util.fmt(PILLAR_GAP), angle > 0 and util.fmt(angle, 0) or "none"))
    util.log("read the pillar first, bottom up: fused or bulging layers mean too little cooling; then the wings; take the lowest fan that is clean, PETG strength drops with more fan")
    util.data(bed, "cooling", { tag = tag, values = util.join(fans, 0), sections = n, section_height = h, own_fan = opts.own_fan and true or false })
end
