info = {
    id = "hole_fit_gauge",
    type = "project.plugin",
    title = "Hole and fit gauge: hole sizes, pegs, and clearance holes with a pin",
    menu = "Filament Dial-In/9. Hole and fit gauge",
    params = {
        { name = "pin", label = "Pin diameter [mm]", type = "int", default = 6 },
        { name = "min_clearance", label = "Lowest clearance [mm], e.g. 0.0", type = "string", default = "0.0" },
        { name = "max_clearance", label = "Highest clearance [mm], e.g. 0.5", type = "string", default = "0.5" },
        { name = "clearance_step", label = "Clearance step [mm]", type = "string", default = "0.1" },
        { name = "thickness", label = "Plate thickness [mm]", type = "int", default = 6 },
        { name = "size_row", label = "Add a row of 3 to 20 mm holes and 4 to 10 mm pegs", type = "bool", default = true },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- Layout after leotrax3d's tolerance test (MIT), extended with a hole-size row
-- and pegs. Everything is one object so the loose pins print beside the plate
-- instead of being centred onto it.
local HOLE_SIZES = { 3, 4, 5, 6, 8, 10, 12, 15, 20 }
local PEG_SIZES = { 4, 6, 8, 10 }
local MARGIN, LABEL_ROW = 4, 6

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local pin = util.num(opts.pin, "pin diameter", 6)
    local t = util.num(opts.thickness, "thickness", 6)
    local clearances = util.range { min = util.decimal(opts.min_clearance, "lowest clearance"), max = util.decimal(opts.max_clearance, "highest clearance"),
        by_interval = true, interval = util.decimal(opts.clearance_step, "clearance step"), max_count = 12 }
    assert(pin >= 3 and pin <= 20 and t >= 3, "Pin must be 3 to 20 mm and the plate at least 3 mm thick")
    assert(clearances[1] >= 0, "Clearance cannot be negative")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)
    local volumes = {}

    -- Row 1: clearance holes for the pin.
    local pitch = pin + clearances[#clearances] + MARGIN
    local row1_w = pitch * #clearances
    local row1_d = pin + clearances[#clearances] + MARGIN * 2 + LABEL_ROW
    local plate_w, plate_d = row1_w, row1_d
    for i, c in ipairs(clearances) do
        local cx = pitch * (i - 0.5)
        volumes[#volumes + 1] = { mesh = api.make_cylinder((pin + c) / 2, t + 2, 2), type = VolumeType.Negative, translate = { x = cx, y = LABEL_ROW + (row1_d - LABEL_ROW) / 2, z = -1 } }
        volumes[#volumes + 1] = label.top { text = "+" .. util.fmt(c, 2), x = cx, y = LABEL_ROW / 2, top_z = t, line_height = 3.2, max_width = pitch - 1.5, max_height = LABEL_ROW - 1 }
    end

    -- Row 2: hole sizes 3..20 mm, and pegs standing beside the plate.
    if opts.size_row then
        local x = MARGIN
        local row2_d = 20 + MARGIN * 2 + LABEL_ROW
        local y_c = row1_d + LABEL_ROW + (row2_d - LABEL_ROW) / 2
        for _, d in ipairs(HOLE_SIZES) do
            local cx = x + d / 2
            volumes[#volumes + 1] = { mesh = api.make_cylinder(d / 2, t + 2, 2), type = VolumeType.Negative, translate = { x = cx, y = y_c, z = -1 } }
            volumes[#volumes + 1] = label.top { text = tostring(d), x = cx, y = row1_d + LABEL_ROW / 2, top_z = t, line_height = 3.2, max_width = d + MARGIN - 1, max_height = LABEL_ROW - 1 }
            x = x + d + MARGIN
        end
        plate_w = math.max(plate_w, x)
        plate_d = row1_d + row2_d
    end

    -- Loose pieces beside the plate: two pins and the pegs.
    local px = plate_w + 8
    for k = 1, 2 do
        volumes[#volumes + 1] = { mesh = api.make_cylinder(pin / 2, t * 2, 2), type = VolumeType.Solid, translate = { x = px + pin / 2, y = 6 + (k - 1) * (pin + 6) } }
    end
    if opts.size_row then
        local y = 6 + 2 * (pin + 6) + 4
        for _, d in ipairs(PEG_SIZES) do
            volumes[#volumes + 1] = { mesh = api.make_cylinder(d / 2, t * 2, 2), type = VolumeType.Solid, translate = { x = px + d / 2, y = y + d / 2 } }
            y = y + d + 5
        end
    end
    volumes[#volumes + 1] = label.front { text = tag, x = plate_w / 2, z = t / 2, face_y = 0, line_height = math.min(4, t * 0.55), max_width = plate_w - 6, max_height = t - 1.2 }

    api.project:add_object {
        mesh = api.make_cube(plate_w, plate_d, t),
        other_volumes = volumes,
        object_params = util.merge(util.solid_params(), { perimeters = 3 }),
    }

    util.log(string.format("hole and fit gauge for %s: %d clearance holes for a %s mm pin (%s to %s mm)%s, plate %s x %s x %s mm",
        tag, #clearances, util.fmt(pin), util.fmt(clearances[1], 2), util.fmt(clearances[#clearances], 2),
        opts.size_row and ", hole sizes 3 to 20 mm with 4/6/8/10 mm pegs" or "", util.fmt(plate_w), util.fmt(plate_d), util.fmt(t)))
    util.log("first hole the pin enters without force = your sliding-fit clearance; measure the size-row holes and pegs to see how much small holes shrink beyond the XY compensation")
    util.data(bed, "gauge", { tag = tag, pin = pin, clearances = util.join(clearances, 2), thickness = t, size_row = opts.size_row and true or false,
        hole_sizes = table.concat(HOLE_SIZES, ","), peg_sizes = table.concat(PEG_SIZES, ",") })
end
