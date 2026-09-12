info = {
    id = "slab",
    type = "project.plugin",
    title = "Solid slab: mass check and endurance (100% infill)",
    menu = "Filament Dial-In/5. Solid slab (mass check, endurance)",
    params = {
        { name = "size_x", label = "Size X [mm]", type = "int", default = 60 },
        { name = "size_y", label = "Size Y [mm]", type = "int", default = 60 },
        { name = "height", label = "Height Z [mm]", type = "int", default = 20 },
        { name = "posts", label = "Add four witness posts on top (catch dropped blobs)", type = "bool", default = true },
        { name = "density", label = "Filament density [g/cm3] (blank = from preset)", type = "string", default = "" },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
        { name = "note", label = "Note engraved on the back (spool, date...)", type = "string", default = "" },
    },
}

-- Witness posts: small square pillars on the top corners. Anything the nozzle
-- carries around and drops tends to land on or knock these.
local POST = 6
local POST_HEIGHT = 12
local POST_INSET = 4

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local X = util.num(opts.size_x, "size X", 60)
    local Y = util.num(opts.size_y, "size Y", 60)
    local Z = util.num(opts.height, "height", 20)
    assert(X >= 20 and Y >= 20 and Z >= 5, "Slab must be at least 20 x 20 x 5 mm")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)
    local material = bed:material_presets(0)

    local density = util.decimal(opts.density, "density")
    local density_source = "typed"
    if density == nil then
        density = util.read_number(material, "filament_density")
        density_source = "filament preset"
    end
    if density == nil or density <= 0 then
        density = 1.27
        density_source = "default for Prusament PETG"
    end
    assert(density > 0.5 and density < 3, "Density must be between 0.5 and 3 g/cm3")

    local volume_mm3 = X * Y * Z
    local volumes = {}
    if opts.posts then
        local h = POST_HEIGHT
        for _, xy in ipairs({ { POST_INSET, POST_INSET }, { X - POST_INSET - POST, POST_INSET },
                              { POST_INSET, Y - POST_INSET - POST }, { X - POST_INSET - POST, Y - POST_INSET - POST } }) do
            volumes[#volumes + 1] = {
                mesh = api.make_cube(POST, POST, h),
                type = VolumeType.Solid,
                translate = { x = xy[1], y = xy[2], z = Z },
            }
        end
        volume_mm3 = volume_mm3 + 4 * POST * POST * h
    end

    local volume_cm3 = volume_mm3 / 1000
    local mass_g = volume_cm3 * density
    local nominal = util.fmt(volume_cm3, 1) .. "cc " .. util.fmt(mass_g, 1) .. "g"

    local line = math.min(6, Z * 0.45)
    volumes[#volumes + 1] = label.front {
        text = nominal,
        x = X / 2,
        z = Z / 2,
        face_y = 0,
        line_height = line,
        max_width = X - 4,
        max_height = Z - 1.5,
    }
    local back_text = tag
    local note = tostring(opts.note or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if note ~= "" then
        back_text = tag .. " " .. note
    end
    volumes[#volumes + 1] = label.back {
        text = back_text,
        x = X / 2,
        z = Z / 2,
        face_y = Y,
        line_height = line,
        max_width = X - 4,
        max_height = Z - 1.5,
    }

    api.project:add_object {
        mesh = api.make_cube(X, Y, Z),
        other_volumes = volumes,
        object_params = util.solid_params(),
    }

    local em = util.read_number(material, "extrusion_multiplier")
    util.log(string.format("solid slab for %s: %s x %s x %s mm%s, nominal volume %s cm3",
        tag, util.fmt(X), util.fmt(Y), util.fmt(Z), opts.posts and " plus four witness posts" or "", util.fmt(volume_cm3, 2)))
    util.log(string.format("expected mass %s g at %s g/cm3 (%s); engraved labels remove well under 0.1 g",
        util.fmt(mass_g, 2), util.fmt(density, 3), density_source))
    util.log(string.format("weigh the printed slab: new extrusion multiplier = %s x %s / measured grams",
        em and util.fmt(em, 4) or "current multiplier", util.fmt(mass_g, 2)))
    util.data("slab", { printer = util.printer_name(bed), tag = tag, x = X, y = Y, z = Z, posts = opts.posts and true or false,
        volume_cm3 = volume_cm3, density = density, density_source = density_source, expected_g = mass_g,
        extrusion_multiplier = em or 0 })
end
