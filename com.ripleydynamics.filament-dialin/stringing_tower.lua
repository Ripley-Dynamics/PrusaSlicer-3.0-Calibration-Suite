info = {
    id = "stringing_tower",
    type = "project.plugin",
    title = "Stringing tower (temperature and fan steps)",
    menu = "Filament Dial-In/8. Stringing tower",
    params = {
        { name = "start_temp", label = "Bottom section temperature [C]", type = "int", default = 250 },
        { name = "temp_step", label = "Temperature drop per section [C] (0 = constant)", type = "int", default = 5 },
        { name = "fan_start", label = "Bottom section fan [%] (-1 = leave fan to slicer)", type = "int", default = -1 },
        { name = "fan_step", label = "Fan increase per section [%]", type = "int", default = 0 },
        { name = "sections", label = "Number of sections", type = "int", default = 6 },
        { name = "section_height", label = "Section height [mm]", type = "int", default = 8 },
        { name = "pillar", label = "Pillar size [mm]", type = "int", default = 8 },
        { name = "gap", label = "Gap between pillars [mm]", type = "int", default = 50 },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local start = util.int(opts.start_temp, "start temperature", 250)
    local step = util.int(opts.temp_step, "temperature step", 5)
    local fan_start = util.int(opts.fan_start, "fan start", -1)
    local fan_step = util.int(opts.fan_step, "fan step", 0)
    local n = util.int(opts.sections, "sections", 6)
    local section_req = util.num(opts.section_height, "section height", 8)
    local pillar = util.num(opts.pillar, "pillar size", 8)
    local gap = util.num(opts.gap, "gap", 50)

    assert(n >= 2 and n <= 20, "Number of sections must be between 2 and 20")
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

    -- Validate every section before touching the bed's G-code list.
    local sections = {}
    for i = 1, n do
        local t = start - (i - 1) * step
        assert(t >= 150 and t <= 350, "Section " .. i .. " temperature is out of range: " .. t)
        local lines = { "M104 S" .. t }
        local fan
        if use_fan then
            fan = fan_start + (i - 1) * fan_step
            assert(fan >= 0 and fan <= 100, "Section " .. i .. " fan is out of range: " .. fan .. "%")
            lines[#lines + 1] = "M106 S" .. util.fan_pwm(fan)
        end
        -- PrusaSlicer keeps one custom entry per layer, so both commands go in one entry.
        sections[i] = { temp = t, fan = fan, gcode = table.concat(lines, "\n") }
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
        volumes[#volumes + 1] = label.front {
            text = tostring(s.temp),
            x = x_left + pillar / 2,
            z = z0 + section_h / 2,
            face_y = margin,
            line_height = line,
            max_width = pillar - 1.5,
            max_height = section_h - 1.5,
        }
        volumes[#volumes + 1] = label.front {
            text = use_fan and (util.fmt(s.fan, 0) .. "%") or tostring(s.temp),
            x = x_right + pillar / 2,
            z = z0 + section_h / 2,
            face_y = margin,
            line_height = line,
            max_width = pillar - 1.5,
            max_height = section_h - 1.5,
        }
    end

    volumes[#volumes + 1] = label.top {
        text = tag,
        x = plate_l / 2,
        y = plate_w / 2,
        top_z = base_h,
        line_height = math.min(5, plate_w * 0.5),
        max_width = gap - 4,
        max_height = plate_w - 2,
        depth = math.min(0.6, base_h * 0.4),
    }

    api.project:add_object {
        mesh = api.make_cube(plate_l, plate_w, base_h),
        other_volumes = volumes,
        object_params = { fill_density = "100%" },
    }

    util.log(string.format("stringing tower for %s: %d sections, %d C down to %d C, fan %s, travel %s mm",
        tag, n, start, start - (n - 1) * step,
        use_fan and (fan_start .. "% to " .. (fan_start + (n - 1) * fan_step) .. "%") or "left to slicer",
        util.fmt(gap)))
    if use_fan then
        util.log("the slicer may re-issue its own M106 when its cooling logic changes fan speed; keep the filament's fan settings constant for this test")
    end
    util.data("string", { printer = util.printer_name(bed), tag = tag, start_temp = start, temp_step = step,
        fan_start = fan_start, fan_step = fan_step, sections = n })
end
