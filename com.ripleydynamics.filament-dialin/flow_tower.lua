info = {
    id = "flow_tower",
    type = "project.plugin",
    title = "Flow tower via M221 (100% infill)",
    menu = "Filament Dial-In/2. Flow tower (M221)",
    params = {
        { name = "start_flow", label = "Bottom section flow [%]", type = "int", default = 104 },
        { name = "flow_step", label = "Flow drop per section [%]", type = "int", default = 2 },
        { name = "sections", label = "Number of sections", type = "int", default = 7 },
        { name = "section_height", label = "Section height [mm]", type = "int", default = 10 },
        { name = "width", label = "Tower width X [mm]", type = "int", default = 30 },
        { name = "depth", label = "Tower depth Y [mm]", type = "int", default = 16 },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local tower = require("lib/tower")

    local start = util.int(opts.start_flow, "start flow", 104)
    local step = util.int(opts.flow_step, "flow step", 2)
    local n = util.int(opts.sections, "sections", 7)
    local section_h = util.num(opts.section_height, "section height", 10)
    local w = util.num(opts.width, "width", 30)
    local d = util.num(opts.depth, "depth", 16)

    assert(n >= 2 and n <= 20, "Number of sections must be between 2 and 20")
    assert(section_h >= 4, "Section height must be at least 4 mm")
    assert(w >= 10 and d >= 6, "Tower footprint must be at least 10 x 6 mm")

    local sections = {}
    for i = 1, n do
        local f = start - (i - 1) * step
        assert(f >= 50 and f <= 150, "Section " .. i .. " flow is out of range: " .. f .. "%")
        sections[i] = { label = f .. "%", gcode = "M221 S" .. f }
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
        tag = tag .. " FLOW",
    })
    def.object_params = util.solid_params()

    api.project:add_object(def)

    util.log(string.format(
        "flow tower for %s: %d sections, M221 from %d%% down to %d%%, footprint %s x %s mm (measure each band against these)",
        tag, n, start, start - (n - 1) * step, util.fmt(w), util.fmt(d)))
    util.log("M221 persists on the printer after this print: put 'M221 S100' in your end G-code or start G-code")
    util.data("flow", { printer = util.printer_name(bed), tag = tag, start_flow = start, flow_step = step, sections = n,
        section_height = def.section_height, width = w, depth = d,
        extrusion_multiplier = util.read_number(bed:material_presets(0), "extrusion_multiplier") or 0 })
end
