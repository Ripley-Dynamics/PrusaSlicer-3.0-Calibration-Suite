info = {
    id = "coupon",
    type = "project.plugin",
    title = "100% infill reference coupon",
    menu = "Filament Dial-In/7. Reference coupon (100% infill)",
    params = {
        { name = "length", label = "Length X [mm]", type = "int", default = 50 },
        { name = "width", label = "Width Y [mm]", type = "int", default = 25 },
        { name = "height", label = "Height Z [mm]", type = "int", default = 10 },
        { name = "hole", label = "Through-hole diameter [mm] (0 = none)", type = "int", default = 10 },
        { name = "perimeters", label = "Perimeters", type = "int", default = 2 },
        { name = "xy_compensation", label = "XY size compensation [mm] (blank = preset)", type = "string", default = "" },
        { name = "elephant_foot", label = "Elephant foot compensation [mm] (blank = preset)", type = "string", default = "" },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
        { name = "note", label = "Note engraved on the back (spool, date...)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local L = util.num(opts.length, "length", 50)
    local W = util.num(opts.width, "width", 25)
    local H = util.num(opts.height, "height", 10)
    local hole = util.num(opts.hole, "hole diameter", 10)
    local perimeters = util.int(opts.perimeters, "perimeters", 2)
    local xy = util.decimal(opts.xy_compensation, "XY compensation")
    local foot = util.decimal(opts.elephant_foot, "elephant foot compensation")

    assert(L >= 10 and W >= 6 and H >= 2, "Coupon must be at least 10 x 6 x 2 mm")
    assert(hole >= 0 and hole < W - 2 and hole < L * 0.5, "Hole must fit inside the coupon")
    assert(perimeters >= 1 and perimeters <= 20, "Perimeters must be between 1 and 20")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)

    local volumes = {}
    if hole > 0 then
        local cyl = api.make_cylinder(hole / 2, H + 2, 2)
        volumes[#volumes + 1] = {
            mesh = cyl,
            type = VolumeType.Negative,
            translate = { x = L * 0.72, y = W / 2, z = -1 },
        }
    end

    local line = math.min(6, H * 0.55)
    volumes[#volumes + 1] = label.front {
        text = tag,
        x = L / 2,
        z = H / 2,
        face_y = 0,
        line_height = line,
        max_width = L - 4,
        max_height = H - 1.2,
    }
    local note = tostring(opts.note or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if note ~= "" then
        volumes[#volumes + 1] = label.back {
            text = note,
            x = L / 2,
            z = H / 2,
            face_y = W,
            line_height = line,
            max_width = L - 4,
            max_height = H - 1.2,
        }
    end

    local params = util.merge(util.solid_params(), { perimeters = util.whole(perimeters) })
    if xy ~= nil then
        params.xy_size_compensation = xy
    end
    if foot ~= nil then
        params.elefant_foot_compensation = foot
    end

    api.project:add_object {
        mesh = api.make_cube(L, W, H),
        other_volumes = volumes,
        object_params = params,
    }

    util.log(string.format("coupon for %s: %s x %s x %s mm, hole %s mm, %d perimeters, xy %s, foot %s",
        tag, util.fmt(L), util.fmt(W), util.fmt(H), util.fmt(hole), perimeters,
        xy and util.fmt(xy, 3) or "preset", foot and util.fmt(foot, 3) or "preset"))
    util.log("each run centres a new coupon on the bed: press A (arrange) after adding several")
    util.data("coupon", { printer = util.printer_name(bed), tag = tag, length = L, width = W, height = H, hole = hole,
        perimeters = perimeters, xy = xy or 0, foot = foot or 0 })
end
