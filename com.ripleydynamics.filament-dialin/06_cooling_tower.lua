info = {
    id = "06_cooling_tower",
    type = "project.plugin",
    title = "Cooling tower: fan per band, overhang wings and a heat-soak pillar",
    menu = "Filament Dial-In/6. Cooling tower",
    params = {
        { name = "model", label = "Model: tower (the built-in one, which uses the fan fields below) or abyss (the included Ultimate Fan Speed Test V3, which brings its own fan ramp and ignores them)", type = "string", default = "tower" },
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

-- Two models, one command.
--
-- `tower` (the built-in one) is after leotrax3d's fan tower (MIT): a square
-- tower plus a slender pillar 15 mm away. The head travels to the pillar every
-- layer, so it gets almost no time to cool and shows insufficient cooling
-- first. Our overhang wings on the +X side of each band add the overhang view.
--
-- `abyss` prints the "Ultimate Fan Speed Test V3" instead (Printables model
-- 200347, by Abyss, a remix of MarioL_3d_designer's Ultimate Fan Speed Test
-- and Cooling direction test). It ships in assets/fan/ under CC BY-NC 4.0,
-- with the attribution in assets/fan/README.md: that one file may not be used
-- commercially, so a commercial redistribution of this bundle has to drop it.
-- The model is about 88 x 24 x 100 mm and is designed around one rule: fan
-- speed rises 1% per mm of height, 0% at the bottom and 100% at the top, with
-- a marker every 10 mm. So the command ignores the fan fields and inserts an
-- M106 on every layer at clamp(round(z), 0, 100) percent, and the height in mm
-- of the band that looks best IS the fan percentage to use. A small solid plate
-- with the printer tag is added beside it, because the model carries no label.
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

-- The fan test model, shipped in assets/fan (CC BY-NC 4.0, see its README).
local ABYSS_STL = "assets/fan/ultimate-fan-test-v3.stl"
local ABYSS_SOURCE = "Printables model 200347, 'Ultimate Fan Speed Test V3' by Abyss (CC BY-NC 4.0)"
local ABYSS_PER_MM = 1 -- percent of fan per mm of height, by the model's design
local TAG_W, TAG_D, TAG_H, TAG_GAP = 12, 30, 3, 5

local function fan_gcode(percent, util)
    local pwm = util.fan_pwm(percent)
    return pwm == 0 and "M107" or ("M106 S" .. pwm)
end

-- All the fan values the preset can hold, set equal so the slicer's own
-- cooling logic never changes its mind mid-print.
local function pin_fan(util, material, percent)
    util.log("writing constant cooling into the filament preset (fan " .. percent .. "% everywhere, no layer-time changes); presets are modified, not saved")
    for _, key in ipairs({ "min_fan_speed", "max_fan_speed", "bridge_fan_speed", "overhang_fan_speed_0", "overhang_fan_speed_1", "overhang_fan_speed_2", "overhang_fan_speed_3" }) do
        util.try_set(material, key, percent, key)
    end
    util.try_set(material, "fan_below_layer_time", 0, "fan below layer time")
    util.try_set(material, "slowdown_below_layer_time", 0, "slowdown below layer time")
    util.try_set(material, "full_fan_speed_layer", 0, "full fan speed layer")
    util.try_set(material, "disable_fan_first_layers", 1, "disable fan first layers")
end

-- The Ultimate Fan Speed Test V3: the model is the test, we only add the fan
-- ramp, a tag plate and the lift onto the bed.
local function abyss_model(o)
    local util, label, tower = o.util, o.label, o.tower
    local bed, lh, tag = o.bed, o.lh, o.tag

    local ok, mesh = pcall(api.load_stl, ABYSS_STL)
    assert(ok and mesh, string.format(
        "%s could not be loaded. It ships with this bundle (%s), so either the install is incomplete or the file was removed (a commercial redistribution has to remove it); put the STL back at that path, from the plugin package or from the model page (see assets/fan/README.md)",
        ABYSS_STL, ABYSS_SOURCE))
    local b = mesh:bounds()
    local height = b.max_z - b.min_z
    assert(height > 10, "the model in " .. ABYSS_STL .. " is only " .. util.fmt(height) .. " mm tall; the Ultimate Fan Speed Test V3 is about 100 mm")

    -- One M106 per layer, 1% of fan per mm of height, from the bed to the top.
    local layers = math.max(1, math.floor(height / lh + 1e-6))
    api.project:clear_layer_custom_steps(bed)
    for i = 0, layers - 1 do
        local z = i * lh
        local percent = math.max(0, math.min(100, math.floor(z * ABYSS_PER_MM + 0.5)))
        api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z, lh), fan_gcode(percent, util))
    end

    -- A tag plate beside the model, solid, with the tag engraved on its top.
    local plate_x = b.max_x + TAG_GAP
    local centre_y = (b.min_y + b.max_y) / 2
    local plate_y = centre_y - TAG_D / 2
    local volumes = {
        { mesh = api.make_cube(TAG_W, TAG_D, TAG_H), type = VolumeType.Solid, translate = { x = plate_x, y = plate_y, z = b.min_z } },
        { mesh = api.make_cube(TAG_W + 2, TAG_D + 2, TAG_H + 1), type = VolumeType.Modifier,
          translate = { x = plate_x - 1, y = plate_y - 1, z = b.min_z - 1 }, params = util.solid_params() },
    }
    local tag_label = label.top {
        text = tag, x = plate_x + TAG_W / 2, y = centre_y, top_z = b.min_z + TAG_H,
        line_height = 6, max_width = TAG_D - 4, max_height = TAG_W - 2,
    }
    tag_label.rotate = { z = 90 } -- the text reads along the plate's long (Y) side
    volumes[#volumes + 1] = tag_label

    if o.own_fan then
        pin_fan(util, o.material, 0)
    end

    api.project:add_object {
        mesh = mesh,
        other_volumes = volumes,
        translate = { z = -b.min_z },
    }

    util.log(string.format("cooling test for %s: the Ultimate Fan Speed Test V3 from %s, %s x %s x %s mm, %d layers of %s mm each carrying their own M106, tag plate %s x %s mm beside it",
        tag, ABYSS_STL, util.fmt(b.max_x - b.min_x), util.fmt(b.max_y - b.min_y), util.fmt(height),
        layers, util.fmt(lh, 3), util.fmt(TAG_W), util.fmt(TAG_D)))
    util.log("the fan rises 1% per mm of height (0% at the bed, 100% at the top, a marker every 10 mm), so the height in mm of the band that looks best IS the fan percentage; the fan range fields and the built-in tower's size, band height and wing options are ignored for this model")
    util.data(bed, "cooling", { tag = tag, model = "abyss", range = util.fmt(ABYSS_PER_MM) .. "% per mm", values = "0,100",
        sections = layers, section_height = lh, height = height, own_fan = o.own_fan and true or false })
end

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local model = tostring(opts.model or "tower"):lower():gsub("%s", "")
    assert(model == "tower" or model == "abyss",
        "Model must be 'tower' (the built-in one) or 'abyss' (the Ultimate Fan Speed Test V3 STL in " .. ABYSS_STL .. ")")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local material = bed:material_presets(0)

    -- Warn about the switches we cannot flip.
    local function flag(key)
        local ok, v = pcall(function() return material:value(key) end)
        return ok and v or nil
    end
    if flag("enable_dynamic_fan_speeds") == true then
        util.log("WARNING: Filament > Cooling > 'Enable dynamic fan speeds' is on; the slicer changes fan on overhangs mid-layer. Turn it off for this print, or the overhangs (the wings on the built-in tower) are not printed at the fan the height asks for.")
    end
    if flag("fan_always_on") == false then
        util.log("note: fan_always_on is off; the first band's M107/M106 still applies from its first layer")
    end

    if model == "abyss" then
        return abyss_model { util = util, label = label, tower = tower, bed = bed, lh = lh, tag = tag,
            material = material, own_fan = opts.own_fan }
    end

    local fans = util.range { min = opts.min_fan, max = opts.max_fan, by_interval = opts.by_interval,
        interval = opts.interval, count = opts.sections, integer = true, max_count = 20 }
    for _, f in ipairs(fans) do assert(f >= 0 and f <= 100, "Fan out of range: " .. f) end
    local n = #fans
    local size = util.num(opts.size, "tower size", 20)
    local section_req = util.num(opts.section_height, "band height", 8)
    local angle = util.num(opts.overhang_angle, "overhang angle", 45)
    assert(size >= 10 and section_req >= 4, "Tower size must be >= 10 mm and band height >= 4 mm")
    assert(angle == 0 or (angle >= 20 and angle <= 80), "Overhang angle must be 0 or between 20 and 80 degrees")

    local h = util.align(section_req, lh, 2)
    local base_h = util.align(BASE_H, lh, 2)
    local total = base_h + n * h

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
        pin_fan(util, material, fans[1])
    end

    api.project:add_object {
        mesh = api.make_cube(size, size, total),
        other_volumes = volumes,
        object_params = { fill_density = "15%", perimeters = 2, top_solid_layers = 3, bottom_solid_layers = 3 },
    }

    util.log(string.format("cooling tower for %s (built-in tower): %d bands of %s mm, fan %d%% to %d%%, pillar %s mm away, wings at %s deg",
        tag, n, util.fmt(h), fans[1], fans[n], util.fmt(PILLAR_GAP), angle > 0 and util.fmt(angle, 0) or "none"))
    util.log("read the pillar first, bottom up: fused or bulging layers mean too little cooling; then the wings; take the lowest fan that is clean, PETG strength drops with more fan")
    util.data(bed, "cooling", { tag = tag, model = "tower", values = util.join(fans, 0), sections = n,
        section_height = h, own_fan = opts.own_fan and true or false })
end
