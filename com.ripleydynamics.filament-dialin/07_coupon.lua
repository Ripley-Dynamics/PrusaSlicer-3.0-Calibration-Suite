info = {
    id = "coupon",
    type = "project.plugin",
    title = "Reference coupon: thick solid body, hole, overhang wing, thin fins",
    menu = "Filament Dial-In/7. Reference coupon",
    params = {
        { name = "length", label = "Length X [mm]", type = "int", default = 50 },
        { name = "width", label = "Width Y [mm]", type = "int", default = 25 },
        { name = "height", label = "Height Z [mm]", type = "int", default = 10 },
        { name = "hole", label = "Through-hole diameter [mm] (0 = none)", type = "int", default = 10 },
        { name = "overhang_angle", label = "Overhang wing angle from horizontal [deg] (0 = none)", type = "int", default = 45 },
        { name = "fins", label = "Thin-wall fins on top (0.8 / 1.2 / 1.6 mm)", type = "bool", default = true },
        { name = "perimeters", label = "Perimeters", type = "int", default = 2 },
        { name = "xy_compensation", label = "XY size compensation [mm] (blank = preset)", type = "string", default = "" },
        { name = "elephant_foot", label = "Elephant foot compensation [mm] (blank = preset)", type = "string", default = "" },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
        { name = "note", label = "Note engraved on the back (spool, date...)", type = "string", default = "" },
    },
}

-- What each feature tests:
--   the body     thick solid plastic: dimensions, top finish, heat soak
--   the hole     inner-diameter accuracy (XY growth shrinks holes)
--   the wing     an overhang at the chosen angle on the +X end
--   the fins     thin walls of 2, 3 and 4 line widths: gap fill and thin-wall handling
local FIN_THICKNESSES = { 0.8, 1.2, 1.6 }
local FIN_LENGTH, FIN_HEIGHT = 10, 8

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local L = util.num(opts.length, "length", 50)
    local W = util.num(opts.width, "width", 25)
    local H = util.num(opts.height, "height", 10)
    local hole = util.num(opts.hole, "hole diameter", 10)
    local angle = util.num(opts.overhang_angle, "overhang angle", 45)
    local perimeters = util.int(opts.perimeters, "perimeters", 2)
    local xy = util.decimal(opts.xy_compensation, "XY compensation")
    local foot = util.decimal(opts.elephant_foot, "elephant foot compensation")

    assert(L >= 30 and W >= 12 and H >= 4, "Coupon must be at least 30 x 12 x 4 mm")
    assert(hole >= 0 and hole < W - 2 and hole < L * 0.4, "Hole must fit inside the coupon")
    assert(angle == 0 or (angle >= 20 and angle <= 80), "Overhang angle must be 0 or between 20 and 80 degrees")
    assert(perimeters >= 1 and perimeters <= 20, "Perimeters must be between 1 and 20")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)

    local volumes = {}
    if hole > 0 then
        volumes[#volumes + 1] = { mesh = api.make_cylinder(hole / 2, H + 2, 2), type = VolumeType.Negative, translate = { x = L * 0.72, y = W / 2, z = -1 } }
    end
    local reach = 0
    if angle > 0 then
        local wing
        wing, reach = tower.wing { x_face = L, depth = W, z0 = 0, section_height = H, angle_deg = angle, thickness = 2, wing_depth = W * 0.6 }
        volumes[#volumes + 1] = wing
    end
    if opts.fins then
        local x = 4
        for _, t in ipairs(FIN_THICKNESSES) do
            volumes[#volumes + 1] = { mesh = api.make_cube(FIN_LENGTH, t, FIN_HEIGHT), type = VolumeType.Solid, translate = { x = x, y = W - 3 - t, z = H } }
            x = x + FIN_LENGTH + 4
        end
    end

    local line = math.min(6, H * 0.55)
    volumes[#volumes + 1] = label.front { text = tag, x = L / 2, z = H / 2, face_y = 0, line_height = line, max_width = L - 4, max_height = H - 1.2 }
    local note = tostring(opts.note or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if note ~= "" then
        volumes[#volumes + 1] = label.back { text = note, x = L / 2, z = H / 2, face_y = W, line_height = line, max_width = L - 4, max_height = H - 1.2 }
    end

    local params = util.merge(util.solid_params(), { perimeters = util.whole(perimeters) })
    if xy ~= nil then params.xy_size_compensation = xy end
    if foot ~= nil then params.elefant_foot_compensation = foot end

    api.project:add_object { mesh = api.make_cube(L, W, H), other_volumes = volumes, object_params = params }

    util.log(string.format("coupon for %s: %s x %s x %s mm, hole %s mm, wing %s, fins %s, %d perimeters, xy %s, foot %s",
        tag, util.fmt(L), util.fmt(W), util.fmt(H), util.fmt(hole), angle > 0 and (util.fmt(angle, 0) .. " deg reaching " .. util.fmt(reach, 1) .. " mm") or "none",
        opts.fins and "0.8/1.2/1.6 mm" or "none", perimeters, xy and util.fmt(xy, 3) or "preset", foot and util.fmt(foot, 3) or "preset"))
    util.log("each run centres a new coupon on the bed: press A (arrange) after adding several")
    util.data(bed, "coupon", { tag = tag, length = L, width = W, height = H, hole = hole, overhang_angle = angle,
        fins = opts.fins and true or false, perimeters = perimeters, xy = xy or 0, foot = foot or 0 })
end
