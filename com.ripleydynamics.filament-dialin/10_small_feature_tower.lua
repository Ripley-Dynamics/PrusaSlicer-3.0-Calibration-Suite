info = {
    id = "small_feature_tower",
    type = "project.plugin",
    title = "Small-feature tower: pyramid, cone and thin pillars for short layer times",
    menu = "Filament Dial-In/10. Small-feature tower",
    params = {
        { name = "height", label = "Feature height [mm]", type = "int", default = 40 },
        { name = "pyramid_base", label = "Pyramid base [mm]", type = "int", default = 20 },
        { name = "cone_diameter", label = "Cone base diameter [mm]", type = "int", default = 16 },
        { name = "pillars", label = "Add 3, 5 and 8 mm pillars", type = "bool", default = true },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- As the pyramid and cone narrow, layer time falls until the slicer's
-- "slow down below layer time" and fan rules take over; PETG tips that melt,
-- round off or drag show that those settings need more time or more fan on
-- this printer. The pillars are constant short layers at three sizes.
local PILLAR_SIZES = { 3, 5, 8 }
local PLATE_H = 2

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local H = util.num(opts.height, "height", 40)
    local base = util.num(opts.pyramid_base, "pyramid base", 20)
    local cone_d = util.num(opts.cone_diameter, "cone diameter", 16)
    assert(H >= 15 and base >= 8 and cone_d >= 6, "Height >= 15 mm, pyramid base >= 8 mm, cone >= 6 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local plate_h = util.align(PLATE_H, lh, 2)
    local gap = 8
    local x = gap
    local volumes = {}

    -- pyramid: make_pyramid is centred on X/Y with its base at Z 0
    volumes[#volumes + 1] = { mesh = api.make_pyramid(base, H), type = VolumeType.Solid, translate = { x = x + base / 2, y = gap + base / 2, z = plate_h } }
    x = x + base + gap
    volumes[#volumes + 1] = { mesh = api.make_cone(cone_d / 2, H, 2), type = VolumeType.Solid, translate = { x = x + cone_d / 2, y = gap + base / 2, z = plate_h } }
    x = x + cone_d + gap
    if opts.pillars then
        for _, d in ipairs(PILLAR_SIZES) do
            volumes[#volumes + 1] = { mesh = api.make_cylinder(d / 2, H, 2), type = VolumeType.Solid, translate = { x = x + d / 2, y = gap + base / 2, z = plate_h } }
            x = x + d + gap
        end
    end
    local plate_w, plate_d = x, base + 2 * gap
    volumes[#volumes + 1] = label.front { text = tag, x = plate_w / 2, z = plate_h / 2, face_y = 0,
        line_height = math.min(2.5, plate_h * 0.6), max_width = plate_w - 4, max_height = plate_h - 0.6 }

    api.project:add_object {
        mesh = api.make_cube(plate_w, plate_d, plate_h),
        other_volumes = volumes,
        object_params = util.solid_params(),
    }

    local material = bed:material_presets(0)
    local slow = util.read_number(material, "slowdown_below_layer_time")
    local minspeed = util.read_number(material, "min_print_speed")
    util.log(string.format("small-feature tower for %s: %s mm tall pyramid (%s base), cone (%s), pillars %s; preset slows layers under %s s down to %s mm/s",
        tag, util.fmt(H), util.fmt(base), util.fmt(cone_d), opts.pillars and "3/5/8 mm" or "none", slow and util.fmt(slow, 0) or "?", minspeed and util.fmt(minspeed, 0) or "?"))
    util.log("tips that melt, round off or get dragged mean the layer-time slowdown or fan needs more on this printer; note the height where each feature degrades")
    util.data(bed, "small", { tag = tag, height = H, pyramid_base = base, cone_diameter = cone_d, pillars = opts.pillars and true or false,
        slowdown = slow or 0, min_print_speed = minspeed or 0 })
end
