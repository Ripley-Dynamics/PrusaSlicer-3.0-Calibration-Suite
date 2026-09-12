info = {
    id = "volumetric_tower",
    type = "project.plugin",
    title = "Max volumetric flow tower (100% infill)",
    menu = "Filament Dial-In/3. Max volumetric flow tower",
    params = {
        { name = "min_flow", label = "Bottom section flow [mm3/s]", type = "int", default = 6 },
        { name = "max_flow", label = "Top section flow [mm3/s]", type = "int", default = 24 },
        { name = "sections", label = "Number of sections", type = "int", default = 7 },
        { name = "section_height", label = "Section height [mm]", type = "int", default = 10 },
        { name = "width", label = "Tower width X [mm]", type = "int", default = 30 },
        { name = "depth", label = "Tower depth Y [mm]", type = "int", default = 16 },
        { name = "extrusion_width", label = "Extrusion width [mm] (blank = nozzle x 1.125)", type = "string", default = "" },
        { name = "lift_limits", label = "Set preset volumetric/cooling limits to unlimited", type = "bool", default = true },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local tower = require("lib/tower")

    local min_flow = util.num(opts.min_flow, "minimum flow", 6)
    local max_flow = util.num(opts.max_flow, "maximum flow", 24)
    local n = util.int(opts.sections, "sections", 7)
    local section_h = util.num(opts.section_height, "section height", 10)
    local w = util.num(opts.width, "width", 30)
    local d = util.num(opts.depth, "depth", 16)

    assert(n >= 2 and n <= 20, "Number of sections must be between 2 and 20")
    assert(min_flow > 0 and max_flow > min_flow, "Maximum flow must be greater than minimum flow, both positive")
    assert(section_h >= 4, "Section height must be at least 4 mm")
    assert(w >= 10 and d >= 6, "Tower footprint must be at least 10 x 6 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local nozzle = util.nozzle(bed)
    local ew = util.decimal(opts.extrusion_width, "extrusion width") or nozzle * 1.125
    assert(ew > lh, "Extrusion width must be larger than the layer height")
    local tag = util.resolve_tag(bed, opts.tag)

    local sections = {}
    for i = 1, n do
        local flow = min_flow + (max_flow - min_flow) * (i - 1) / (n - 1)
        local speed = util.flow_to_speed(flow, ew, lh)
        sections[i] = {
            label = util.fmt(flow, 1),
            params = {
                perimeter_speed = speed,
                external_perimeter_speed = speed,
                small_perimeter_speed = speed,
                infill_speed = speed,
                solid_infill_speed = speed,
                top_solid_infill_speed = speed,
                gap_fill_speed = speed,
            },
            flow = flow,
            speed = speed,
        }
    end

    -- Prepare everything fallible before touching presets or the project.
    local def = tower.build(bed, {
        width = w,
        depth = d,
        base_height = 5,
        section_height = section_h,
        layer_height = lh,
        sections = sections,
        tag = tag .. " VOL",
    })
    def.object_params = util.merge(util.solid_params(), {
        perimeter_extrusion_width = ew,
        external_perimeter_extrusion_width = ew,
        infill_extrusion_width = ew,
        solid_infill_extrusion_width = ew,
        top_infill_extrusion_width = ew,
    })

    if opts.lift_limits then
        util.log("lifting preset limits so the requested speeds are actually used (presets are modified, not saved)")
        util.try_set(bed:material_presets(0), "filament_max_volumetric_speed", 0, "filament max volumetric speed")
        util.try_set(bed:material_presets(0), "slowdown_below_layer_time", 0, "slowdown below layer time")
        util.try_set(bed:print_presets(), "max_volumetric_speed", 0, "print max volumetric speed")
    end

    api.project:add_object(def)

    util.log(string.format("volumetric tower for %s: line %s x %s mm (area %s mm2)",
        tag, util.fmt(ew, 3), util.fmt(lh, 3), util.fmt(util.extrusion_area(ew, lh), 4)))
    for i, s in ipairs(sections) do
        util.log(string.format("  section %d: %s mm3/s -> %s mm/s", i, util.fmt(s.flow, 2), util.fmt(s.speed, 1)))
    end
    util.data("vol", { printer = util.printer_name(bed), tag = tag, min_flow = min_flow, max_flow = max_flow, sections = n,
        extrusion_width = ew, layer_height = lh, area = util.extrusion_area(ew, lh), nozzle = nozzle })
end
