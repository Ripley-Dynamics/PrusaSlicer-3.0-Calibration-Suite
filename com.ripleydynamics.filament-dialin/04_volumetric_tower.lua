info = {
    id = "volumetric_tower",
    type = "project.plugin",
    title = "Max volumetric flow: Prusa's single-wall comb, or a solid block",
    menu = "Filament Dial-In/4. Max volumetric flow",
    params = {
        { name = "min_flow", label = "Lowest flow [mm3/s] (bottom)", type = "int", default = 6 },
        { name = "max_flow", label = "Highest flow [mm3/s] (top)", type = "int", default = 24 },
        { name = "by_interval", label = "Choose by interval (on) or by number of sections (off)", type = "bool", default = false },
        { name = "interval", label = "Interval [mm3/s]", type = "int", default = 3 },
        { name = "sections", label = "Number of sections (when interval is off)", type = "int", default = 7 },
        { name = "section_height", label = "Section height [mm]", type = "int", default = 6 },
        { name = "comb", label = "Prusa single-wall comb (on) or solid 30 x 16 block (off)", type = "bool", default = true },
        { name = "extrusion_width", label = "Extrusion width [mm] (blank = comb: nozzle x 1.75, block: nozzle x 1.125)", type = "string", default = "" },
        { name = "lift_limits", label = "Write 0 into the preset's volumetric and slowdown limits (else set them yourself)", type = "bool", default = false },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

local SPINE_W, SPINE_D = 14, 8 -- solid label column beside the comb

local function speed_params(speed)
    return {
        perimeter_speed = speed, external_perimeter_speed = speed, small_perimeter_speed = speed,
        infill_speed = speed, solid_infill_speed = speed, top_solid_infill_speed = speed, gap_fill_speed = speed,
    }
end

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local flows = util.range {
        min = opts.min_flow, max = opts.max_flow, by_interval = opts.by_interval,
        interval = opts.interval, count = opts.sections, max_count = 20,
    }
    local n = #flows
    assert(flows[1] > 0, "Flow must be positive")
    local section_req = util.num(opts.section_height, "section height", 6)
    assert(section_req >= 3, "Section height must be at least 3 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local nozzle = util.nozzle(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local ew = util.decimal(opts.extrusion_width, "extrusion width") or (opts.comb and nozzle * 1.75 or nozzle * 1.125)
    assert(ew > lh, "Extrusion width must be larger than the layer height")
    local section_h = util.align(section_req, lh, 2)
    local total = n * section_h
    local speeds = {}
    for i, f in ipairs(flows) do
        speeds[i] = util.flow_to_speed(f, ew, lh)
    end

    local def
    if opts.comb then
        local comb = api.emboss_svg("assets/prusa/hreben.svg", total)
        local bb = comb:bounds()
        local cw, cd = bb.max_x - bb.min_x, bb.max_y - bb.min_y
        assert(cw > 0 and cd > 0, "Prusa comb SVG did not load")
        local spine_x = bb.max_x + 3
        local volumes = {
            { mesh = api.make_cube(SPINE_W, SPINE_D, total), type = VolumeType.Solid, translate = { x = spine_x, y = bb.min_y, z = bb.min_z } },
            { mesh = api.make_cube(SPINE_W + 2, SPINE_D + 2, total + 2), type = VolumeType.Modifier, translate = { x = spine_x - 1, y = bb.min_y - 1, z = bb.min_z - 1 },
              params = { perimeters = 2, fill_density = "100%", top_solid_layers = 3, bottom_solid_layers = 3 } },
        }
        for i = 1, n do
            local z0 = bb.min_z + (i - 1) * section_h
            volumes[#volumes + 1] = {
                mesh = api.make_cube(cw + SPINE_W + 6, cd + 2, section_h), type = VolumeType.Modifier,
                translate = { x = bb.min_x - 1, y = bb.min_y - 1, z = z0 }, params = speed_params(speeds[i]),
            }
            if i > 1 then -- Prusa's tick: one fatter external perimeter layer marks each band boundary
                volumes[#volumes + 1] = {
                    mesh = api.make_cube(cw + 2, cd + 2, lh), type = VolumeType.Modifier,
                    translate = { x = bb.min_x - 1, y = bb.min_y - 1, z = z0 }, params = { external_perimeter_extrusion_width = ew * 1.5 },
                }
            end
            volumes[#volumes + 1] = label.front {
                text = util.fmt(flows[i], 1), x = spine_x + SPINE_W / 2, z = z0 - bb.min_z + section_h / 2, face_y = bb.min_y,
                line_height = math.min(5, section_h * 0.55), max_width = SPINE_W - 2, max_height = section_h - 1.5,
            }
        end
        volumes[#volumes + 1] = label.back {
            text = tag, x = spine_x + SPINE_W / 2, z = section_h / 2, face_y = bb.min_y + SPINE_D,
            line_height = math.min(4, section_h * 0.5), max_width = SPINE_W - 2, max_height = section_h - 1.5,
        }
        def = {
            mesh = comb, other_volumes = volumes, translate = { z = -bb.min_z },
            object_params = { fill_density = "0%", top_solid_layers = 0, bottom_solid_layers = 0, perimeters = 1,
                external_perimeter_extrusion_width = ew, perimeter_extrusion_width = ew },
        }
    else
        local sections = {}
        for i = 1, n do
            sections[i] = { label = util.fmt(flows[i], 1), params = speed_params(speeds[i]) }
        end
        def = tower.build(bed, { width = 30, depth = 16, base_height = 5, section_height = section_h, layer_height = lh, sections = sections, tag = tag .. " VOL" })
        def.object_params = util.merge(util.solid_params(), {
            perimeter_extrusion_width = ew, external_perimeter_extrusion_width = ew, infill_extrusion_width = ew,
            solid_infill_extrusion_width = ew, top_infill_extrusion_width = ew,
        })
    end

    if opts.lift_limits then
        util.log("writing 0 (unlimited) into the preset's volumetric and slowdown limits (presets are modified, not saved)")
        util.try_set(bed:material_presets(0), "filament_max_volumetric_speed", 0, "filament max volumetric speed")
        util.try_set(bed:material_presets(0), "slowdown_below_layer_time", 0, "slowdown below layer time")
        util.try_set(bed:print_presets(), "max_volumetric_speed", 0, "print max volumetric speed")
    else
        local cap = util.read_number(bed:material_presets(0), "filament_max_volumetric_speed")
        if cap and cap > 0 and cap < flows[n] then
            util.log(string.format("WARNING: the filament preset caps volumetric flow at %s mm3/s; bands above that will not print faster. Set Filament > Advanced > Max volumetric speed to 0 for this test.", util.fmt(cap, 1)))
        end
    end

    api.project:add_object(def)

    util.log(string.format("max volumetric flow for %s (%s): line %s x %s mm, area %s mm2",
        tag, opts.comb and "Prusa comb" or "solid block", util.fmt(ew, 3), util.fmt(lh, 3), util.fmt(util.extrusion_area(ew, lh), 4)))
    for i = 1, n do
        util.log(string.format("  band %d: %s mm3/s -> %s mm/s", i, util.fmt(flows[i], 2), util.fmt(speeds[i], 1)))
    end
    util.data(bed, "vol", { tag = tag, values = util.join(flows, 2), sections = n, comb = opts.comb and true or false,
        extrusion_width = ew, area = util.extrusion_area(ew, lh), section_height = section_h })
end
