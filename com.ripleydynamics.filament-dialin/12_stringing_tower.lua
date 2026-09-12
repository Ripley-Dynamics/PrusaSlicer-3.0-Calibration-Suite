info = {
    id = "stringing_tower",
    type = "project.plugin",
    title = "Stringing tower (temperature and fan steps)",
    menu = "Filament Dial-In/12. Stringing tower",
    params = {
        { name = "max_temp", label = "Hottest section [C] (bottom)", type = "int", default = 250 },
        { name = "min_temp", label = "Coolest section [C] (top)", type = "int", default = 225 },
        { name = "by_interval", label = "Choose by interval (on) or by number of sections (off)", type = "bool", default = true },
        { name = "interval", label = "Interval [C] (0 = constant temperature, sections from the count)", type = "int", default = 5 },
        { name = "sections", label = "Number of sections (when interval is off or 0)", type = "int", default = 6 },
        { name = "fan_start", label = "Bottom section fan [%] (-1 = leave fan to slicer)", type = "int", default = -1 },
        { name = "fan_step", label = "Fan increase per section [%]", type = "int", default = 0 },
        { name = "section_height", label = "Section height [mm]", type = "int", default = 8 },
        { name = "pillar", label = "Pillar size [mm]", type = "int", default = 8 },
        { name = "gap", label = "Gap between pillars [mm]", type = "int", default = 50 },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    -- Interval 0 means "same temperature all the way up"; the number of
    -- sections then comes from the sections field.
    local interval = util.int(opts.interval, "interval", 5)
    local constant = opts.by_interval and interval == 0
    local temps
    if constant then
        local n = util.int(opts.sections, "sections", 6)
        assert(n >= 2 and n <= 20, "Number of sections must be between 2 and 20")
        temps = {}
        for i = 1, n do temps[i] = util.int(opts.max_temp, "temperature") end
    else
        temps = util.range { min = opts.min_temp, max = opts.max_temp, by_interval = opts.by_interval,
            interval = interval, count = opts.sections, integer = true, max_count = 20 }
        table.sort(temps, function(a, b) return a > b end)
    end
    for _, t in ipairs(temps) do
        assert(t >= 150 and t <= 350, "Temperature out of range: " .. t)
    end
    local n = #temps
    local fan_start = util.int(opts.fan_start, "fan start", -1)
    local fan_step = util.int(opts.fan_step, "fan step", 0)
    local section_req = util.num(opts.section_height, "section height", 8)
    local pillar = util.num(opts.pillar, "pillar size", 8)
    local gap = util.num(opts.gap, "gap", 50)
    assert(section_req >= 4, "Section height must be at least 4 mm")
    assert(pillar >= 4 and gap >= 10, "Pillars must be at least 4 mm and at least 10 mm apart")
    local use_fan = fan_start >= 0

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)

    local section_h = util.align(section_req, lh, 2)
    local margin = 2
    local base_h = util.align(2, lh, 2)
    local plate_l = 2 * pillar + gap + 2 * margin
    local plate_w = pillar + 2 * margin
    local x_left, x_right = margin, margin + pillar + gap

    local sections = {}
    for i = 1, n do
        local lines = { "M104 S" .. temps[i] }
        local fan
        if use_fan then
            fan = fan_start + (i - 1) * fan_step
            assert(fan >= 0 and fan <= 100, "Section " .. i .. " fan is out of range: " .. fan .. "%")
            lines[#lines + 1] = "M106 S" .. util.fan_pwm(fan)
        end
        sections[i] = { temp = temps[i], fan = fan, gcode = table.concat(lines, "\n") }
    end

    api.project:clear_layer_custom_steps(bed)
    local volumes = {
        { mesh = api.make_cube(pillar, pillar, n * section_h), type = VolumeType.Solid, translate = { x = x_left, y = margin, z = base_h } },
        { mesh = api.make_cube(pillar, pillar, n * section_h), type = VolumeType.Solid, translate = { x = x_right, y = margin, z = base_h } },
    }
    local line = tower.label_line_height(section_h)
    for i, s in ipairs(sections) do
        local z0 = base_h + (i - 1) * section_h
        api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z0, lh), s.gcode)
        volumes[#volumes + 1] = label.front { text = tostring(s.temp), x = x_left + pillar / 2, z = z0 + section_h / 2, face_y = margin,
            line_height = line, max_width = pillar - 1.5, max_height = section_h - 1.5 }
        volumes[#volumes + 1] = label.front { text = use_fan and (util.fmt(s.fan, 0) .. "%") or tostring(s.temp), x = x_right + pillar / 2, z = z0 + section_h / 2, face_y = margin,
            line_height = line, max_width = pillar - 1.5, max_height = section_h - 1.5 }
    end
    volumes[#volumes + 1] = label.top { text = tag, x = plate_l / 2, y = plate_w / 2, top_z = base_h,
        line_height = math.min(5, plate_w * 0.5), max_width = gap - 4, max_height = plate_w - 2, depth = math.min(0.6, base_h * 0.4) }

    api.project:add_object { mesh = api.make_cube(plate_l, plate_w, base_h), other_volumes = volumes, object_params = { fill_density = "100%" } }

    util.log(string.format("stringing tower for %s: %d sections, %d C (bottom) to %d C (top), fan %s, travel %s mm", tag, n, temps[1], temps[n],
        use_fan and (fan_start .. "% to " .. (fan_start + (n - 1) * fan_step) .. "%") or "left to slicer", util.fmt(gap)))
    if use_fan then
        util.log("the slicer may re-issue its own M106 when its cooling logic changes fan speed; keep the filament's fan settings constant for this test")
    end
    util.data(bed, "string", { tag = tag, values = util.join(temps, 0), sections = n,
        constant = constant, fan_start = fan_start, fan_step = fan_step })
end
