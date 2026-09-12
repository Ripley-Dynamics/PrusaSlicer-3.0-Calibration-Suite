info = {
    id = "sweep_plate",
    type = "project.plugin",
    title = "Solid-infill setting sweep (row of 100% infill blocks)",
    menu = "Filament Dial-In/4. Setting sweep plate",
    params = {
        { name = "setting", label = "Setting key (per-region, numeric)", type = "string", default = "infill_overlap" },
        { name = "start", label = "First value (e.g. 15% or 0.45)", type = "string", default = "10%" },
        { name = "step", label = "Step between blocks", type = "string", default = "5%" },
        { name = "samples", label = "Number of blocks", type = "int", default = 6 },
        { name = "block_size", label = "Block size X/Y [mm]", type = "int", default = 25 },
        { name = "block_height", label = "Block height [mm]", type = "int", default = 8 },
        { name = "gap", label = "Gap between blocks [mm]", type = "int", default = 6 },
        { name = "tag", label = "Printer tag (blank = from printer name)", type = "string", default = "" },
    },
}

-- Settings PrusaSlicer stores as integers; anything else is passed as a float.
local INTEGER_SETTINGS = {
    perimeters = true,
    top_solid_layers = true,
    bottom_solid_layers = true,
    infill_every_layers = true,
    solid_infill_every_layers = true,
}

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local key = tostring(opts.setting or ""):gsub("^%s+", ""):gsub("%s+$", "")
    assert(key:match("^[%a_][%w_]*$"), "Setting key must be a PrusaSlicer config key such as infill_overlap")

    local start, start_pct = util.number_or_percent(opts.start, "first value")
    local step, step_pct = util.number_or_percent(opts.step, "step")
    assert(start ~= nil, "First value is required")
    step = step or 0
    local as_percent = start_pct or step_pct

    local n = util.int(opts.samples, "number of blocks", 6)
    local size = util.num(opts.block_size, "block size", 25)
    local height = util.num(opts.block_height, "block height", 8)
    local gap = util.num(opts.gap, "gap", 6)
    assert(n >= 1 and n <= 12, "Number of blocks must be between 1 and 12")
    assert(size >= 8 and height >= 2 and gap >= 0, "Block size must be >= 8 mm, height >= 2 mm, gap >= 0")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)

    local values, texts = {}, {}
    for i = 1, n do
        local v = start + (i - 1) * step
        if as_percent then
            values[i] = util.fmt(v, 2) .. "%"
            texts[i] = values[i]
        elseif INTEGER_SETTINGS[key] then
            assert(math.abs(v - math.floor(v + 0.5)) < 1e-9, key .. " needs whole numbers; got " .. util.fmt(v, 3))
            values[i] = util.whole(math.floor(v + 0.5))
            texts[i] = tostring(values[i])
        else
            values[i] = v
            texts[i] = util.fmt(v, 3)
        end
    end

    local pitch = size + gap
    local volumes = {}
    local m = 1 -- modifier margin

    for i = 1, n do
        local x0 = (i - 1) * pitch
        if i > 1 then
            volumes[#volumes + 1] = {
                mesh = api.make_cube(size, size, height),
                type = VolumeType.Solid,
                translate = { x = x0 },
            }
        end
        volumes[#volumes + 1] = {
            mesh = api.make_cube(size + 2 * m, size + 2 * m, height + 2 * m),
            type = VolumeType.Modifier,
            translate = { x = x0 - m, y = -m, z = -m },
            params = { [key] = values[i] },
        }
        volumes[#volumes + 1] = label.front {
            text = texts[i],
            x = x0 + size / 2,
            z = height / 2,
            face_y = 0,
            line_height = math.min(6, height * 0.6),
            max_width = size - 3,
            max_height = height - 1.2,
        }
    end

    -- Printer tag on the back of the first block, the swept key on the second.
    if height >= 3 then
        volumes[#volumes + 1] = label.back {
            text = tag,
            x = size / 2,
            z = height / 2,
            face_y = size,
            line_height = math.min(6, height * 0.6),
            max_width = size - 3,
            max_height = height - 1.2,
        }
        if n >= 2 then
            volumes[#volumes + 1] = label.back {
                text = key,
                x = pitch + size / 2,
                z = height / 2,
                face_y = size,
                line_height = math.min(4, height * 0.5),
                max_width = size - 3,
                max_height = height - 1.2,
            }
        end
    end

    api.project:add_object {
        mesh = api.make_cube(size, size, height),
        other_volumes = volumes,
        object_params = util.solid_params(),
    }

    util.log(string.format("sweep plate for %s: %s = %s ... %s across %d blocks (%s mm wide)",
        tag, key, texts[1], texts[n], n, util.fmt(n * size + (n - 1) * gap)))
    util.log("an unknown or non-numeric key is silently ignored by PrusaSlicer; check the per-volume settings in the object list")
end
