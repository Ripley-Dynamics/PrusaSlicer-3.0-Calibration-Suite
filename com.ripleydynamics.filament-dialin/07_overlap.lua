info = {
    id = "overlap",
    type = "project.plugin",
    title = "Infill overlap calibration (row of 100% infill blocks)",
    menu = "Filament Dial-In/7. Infill overlap calibration",
    params = {
        { name = "min_value", label = "Lowest overlap (first block), e.g. 10%", type = "string", default = "10%" },
        { name = "max_value", label = "Highest overlap (last block), e.g. 35%", type = "string", default = "35%" },
        { name = "by_interval", label = "Choose by interval (on) or by number of blocks (off)", type = "bool", default = true },
        { name = "interval", label = "Interval, e.g. 5%", type = "string", default = "5%" },
        { name = "blocks", label = "Number of blocks (when interval is off)", type = "int", default = 6 },
        { name = "block_size", label = "Block size X/Y [mm]", type = "int", default = 25 },
        { name = "block_height", label = "Block height [mm]", type = "int", default = 8 },
        { name = "gap", label = "Gap between blocks [mm]", type = "int", default = 6 },
        { name = "setting", label = "Advanced: per-region setting to sweep instead", type = "string", default = "infill_overlap" },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- Method (after flow is right, never before): each block is solid, so its
-- top layer is solid infill meeting the perimeters. Too little overlap leaves
-- a visible gap or a row of pinholes just inside the innermost perimeter;
-- too much pushes the infill into the walls, which shows as ridges next to
-- the perimeters on top and as a slight bulge on the sides. Pick the lowest
-- value with no gap. PrusaSlicer's overlap is a percentage of the infill
-- extrusion width (default 25%).

local INTEGER_SETTINGS = { perimeters = true, top_solid_layers = true, bottom_solid_layers = true, infill_every_layers = true }

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")

    local key = tostring(opts.setting or "infill_overlap"):gsub("^%s+", ""):gsub("%s+$", "")
    assert(key:match("^[%a_][%w_]*$"), "Setting key must be a PrusaSlicer config key such as infill_overlap")
    local lo, lo_pct = util.number_or_percent(opts.min_value, "lowest value")
    local hi, hi_pct = util.number_or_percent(opts.max_value, "highest value")
    local step, step_pct = util.number_or_percent(opts.interval, "interval")
    assert(lo ~= nil and hi ~= nil, "Lowest and highest values are required")
    local as_percent = lo_pct or hi_pct or step_pct

    local values = util.range {
        min = lo, max = hi, by_interval = opts.by_interval, interval = step, count = opts.blocks,
        integer = INTEGER_SETTINGS[key] or false, max_count = 12,
    }
    local n = #values
    local size = util.num(opts.block_size, "block size", 25)
    local height = util.num(opts.block_height, "block height", 8)
    local gap = util.num(opts.gap, "gap", 6)
    assert(size >= 8 and height >= 2 and gap >= 0, "Block size must be >= 8 mm, height >= 2 mm, gap >= 0")

    local bed = api.project:current_bed()
    local tag = util.resolve_tag(bed, opts.tag)

    local params, texts = {}, {}
    for i, v in ipairs(values) do
        if as_percent then
            texts[i] = util.fmt(v, 2) .. "%"
            params[i] = texts[i]
        elseif INTEGER_SETTINGS[key] then
            params[i] = util.whole(v)
            texts[i] = tostring(params[i])
        else
            params[i] = v
            texts[i] = util.fmt(v, 3)
        end
    end

    local pitch = size + gap
    local volumes = {}
    local m = 1
    for i = 1, n do
        local x0 = (i - 1) * pitch
        if i > 1 then
            volumes[#volumes + 1] = { mesh = api.make_cube(size, size, height), type = VolumeType.Solid, translate = { x = x0 } }
        end
        volumes[#volumes + 1] = {
            mesh = api.make_cube(size + 2 * m, size + 2 * m, height + 2 * m), type = VolumeType.Modifier,
            translate = { x = x0 - m, y = -m, z = -m }, params = { [key] = params[i] },
        }
        volumes[#volumes + 1] = label.front {
            text = texts[i], x = x0 + size / 2, z = height / 2, face_y = 0,
            line_height = math.min(6, height * 0.6), max_width = size - 3, max_height = height - 1.2,
        }
    end
    if height >= 3 then
        volumes[#volumes + 1] = label.back { text = tag, x = size / 2, z = height / 2, face_y = size,
            line_height = math.min(6, height * 0.6), max_width = size - 3, max_height = height - 1.2 }
        if n >= 2 then
            volumes[#volumes + 1] = label.back { text = key, x = pitch + size / 2, z = height / 2, face_y = size,
                line_height = math.min(4, height * 0.5), max_width = size - 3, max_height = height - 1.2 }
        end
    end

    api.project:add_object {
        mesh = api.make_cube(size, size, height),
        other_volumes = volumes,
        object_params = util.solid_params(),
    }

    util.log(string.format("%s calibration for %s: %s to %s across %d blocks (%s mm wide)",
        key, tag, texts[1], texts[n], n, util.fmt(n * size + (n - 1) * gap)))
    util.log("judge the top layer where infill meets the innermost perimeter: gap or pinholes = too little, ridges and side bulge = too much")
    util.data(bed, "overlap", { tag = tag, setting = key, values = table.concat(texts, ","), blocks = n, block_size = size, block_height = height })
end
