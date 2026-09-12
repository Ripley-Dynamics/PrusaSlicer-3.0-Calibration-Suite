info = {
    id = "shrink_bar",
    type = "project.plugin",
    title = "Shrinkage and XY growth bar",
    menu = "Filament Dial-In/7. Shrinkage and growth bar",
    params = {
        { name = "length", label = "Bar length X [mm]", type = "int", default = 150 },
        { name = "width", label = "Bar width Y [mm]", type = "int", default = 20 },
        { name = "height", label = "Bar height Z [mm]", type = "int", default = 8 },
        { name = "hole", label = "Hole diameter [mm]", type = "int", default = 6 },
        { name = "hole_inset", label = "Hole centre distance from each end [mm]", type = "int", default = 10 },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
    },
}

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local L = util.num(opts.length, "length", 150)
    local W = util.num(opts.width, "width", 20)
    local H = util.num(opts.height, "height", 8)
    local d = util.num(opts.hole, "hole diameter", 6)
    local inset = util.num(opts.hole_inset, "hole inset", 10)
    assert(L >= 60 and W >= 10 and H >= 3, "Bar must be at least 60 x 10 x 3 mm")
    assert(d >= 2 and d <= W - 4, "Hole must leave at least 2 mm of wall on each side")
    assert(inset >= d / 2 + 2 and inset * 2 + d < L, "Hole inset must keep the holes inside the bar")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)
    local centre_distance = L - 2 * inset

    local volumes = {}
    for _, cx in ipairs({ inset, L - inset }) do
        volumes[#volumes + 1] = {
            mesh = api.make_cylinder(d / 2, H + 2, 2),
            type = VolumeType.Negative,
            translate = { x = cx, y = W / 2, z = -1 },
        }
    end

    local line = math.min(5, H * 0.5)
    volumes[#volumes + 1] = label.front {
        text = "C " .. util.fmt(centre_distance, 2) .. " W " .. util.fmt(W, 2) .. " D " .. util.fmt(d, 2),
        x = L / 2,
        z = H / 2,
        face_y = 0,
        line_height = line,
        max_width = L - 2 * inset - d - 8,
        max_height = H - 1.5,
    }
    volumes[#volumes + 1] = label.back {
        text = tag,
        x = L / 2,
        z = H / 2,
        face_y = W,
        line_height = line,
        max_width = L - 2 * inset - d - 8,
        max_height = H - 1.5,
    }

    api.project:add_object {
        mesh = api.make_cube(L, W, H),
        other_volumes = volumes,
        object_params = util.solid_params(),
    }

    util.log(string.format("shrinkage bar for %s: %s x %s x %s mm, holes %s mm, centres %s mm apart",
        tag, util.fmt(L), util.fmt(W), util.fmt(H), util.fmt(d), util.fmt(centre_distance, 2)))
    util.log("measure hole centre distance C as (near-edge gap + far-edge gap) / 2: growth cancels, so shrinkage = 1 - C / " .. util.fmt(centre_distance, 2))
    util.log("measure width Wm and hole diameter Dm: XY growth per side = (Wm - " .. util.fmt(W, 2) .. " x (1 - shrinkage)) / 2, cross-check with (" .. util.fmt(d, 2) .. " x (1 - shrinkage) - Dm) / 2")
    util.data(bed, "bar", { printer = util.printer_name(bed), tag = tag, length = L, width = W, height = H, hole = d, c0 = centre_distance })
end
