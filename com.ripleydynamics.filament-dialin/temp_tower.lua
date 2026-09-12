info = {
    id = "temp_tower",
    type = "project.plugin",
    title = "Temperature tower (100% infill)",
    menu = "Filament Dial-In/1. Temperature tower",
    params = {
        { name = "start_temp", label = "Bottom section temperature [C]", type = "int", default = 260 },
        { name = "temp_step", label = "Temperature drop per section [C]", type = "int", default = 5 },
        { name = "sections", label = "Number of sections", type = "int", default = 6 },
        { name = "section_height", label = "Section height [mm]", type = "int", default = 10 },
        { name = "width", label = "Tower width X [mm]", type = "int", default = 30 },
        { name = "depth", label = "Tower depth Y [mm]", type = "int", default = 16 },
        { name = "solid", label = "Print at 100% infill", type = "bool", default = true },
        { name = "overhangs", label = "Add overhang wings", type = "bool", default = true },
        { name = "overhang_angle", label = "Wing overhang angle from horizontal [deg]", type = "int", default = 45 },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local tower = require("lib/tower")

    local start = util.int(opts.start_temp, "start temperature", 260)
    local step = util.int(opts.temp_step, "temperature step", 5)
    local n = util.int(opts.sections, "sections", 6)
    local section_h = util.num(opts.section_height, "section height", 10)
    local w = util.num(opts.width, "width", 30)
    local d = util.num(opts.depth, "depth", 16)
    local angle = util.num(opts.overhang_angle, "overhang angle", 45)

    assert(n >= 2 and n <= 20, "Number of sections must be between 2 and 20")
    assert(section_h >= 4, "Section height must be at least 4 mm")
    assert(w >= 10 and d >= 6, "Tower footprint must be at least 10 x 6 mm")
    assert(angle >= 20 and angle <= 80, "Overhang angle must be between 20 and 80 degrees")

    local sections = {}
    for i = 1, n do
        local t = start - (i - 1) * step
        assert(t >= 150 and t <= 350, "Section " .. i .. " temperature is out of range: " .. t)
        sections[i] = { label = tostring(t), gcode = "M104 S" .. t }
    end

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)

    local def = tower.build(bed, {
        width = w,
        depth = d,
        base_height = 5,
        section_height = section_h,
        layer_height = lh,
        sections = sections,
        tag = tag .. " TEMP",
    })

    if opts.overhangs then
        for i = 1, n do
            local wing = tower.wing {
                x_face = w,
                depth = d,
                z0 = def.section_z[i],
                section_height = def.section_height,
                angle_deg = angle,
                thickness = 2,
            }
            def.other_volumes[#def.other_volumes + 1] = wing
        end
    end

    if opts.solid then
        def.object_params = util.solid_params()
    end

    api.project:add_object(def)

    util.log(string.format(
        "temperature tower for %s: %d sections of %s mm, %d C down to %d C, %s mm tall, layer %s mm",
        tag, n, util.fmt(def.section_height), start, start - (n - 1) * step, util.fmt(def.total_height), util.fmt(lh, 3)))
    util.log("the plinth prints at the preset temperature; M104 changes land on each section's first layer")
end
