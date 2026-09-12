info = {
    id = "flow_tower",
    type = "project.plugin",
    title = "Flow staircase via M221: one exposed top surface per flow value",
    menu = "Filament Dial-In/3. Flow staircase (M221)",
    params = {
        { name = "range", label = "Range (relative to current flow): -5 to +5 step 1 (Orca YOLO); -20 to +20 step 5 then -9 to 0 step 1 for the two-pass method", type = "string", default = "-5 to +5 step 1" },
        { name = "tread", label = "Tread depth per step [mm]", type = "int", default = 10 },
        { name = "width", label = "Staircase width Y [mm]", type = "int", default = 16 },
        { name = "riser", label = "Step height [mm]", type = "int", default = 4 },
        { name = "top_pattern", label = "Top surface pattern: archimedeanchords, monotonic, monotoniclines, rectilinear, alignedrectilinear, concentric, hilbertcurve, octagramspiral", type = "string", default = "archimedeanchords" },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- OrcaSlicer's flow calibration, rebuilt for PrusaSlicer. Orca prints one
-- patch per flow modifier and engraves the modifier, not the absolute flow:
-- its recommended "YOLO" pass is -5 to +5 in 1% steps on archimedean chords
-- (the pattern that shows over- and under-extrusion most plainly), its
-- "perfectionist" pass -4 to +3.5 in 0.5% steps, and its legacy two-pass
-- method is -20 to +20 in 5% steps followed by -9 to 0 in 1% steps applied to
-- the already-updated flow.
--
-- PrusaSlicer cannot set flow per object, so the patches are the treads of a
-- staircase and M221 changes on each tread's first layer; every tread's top
-- layers print at that tread's flow. The engraved label is Orca's relative
-- number (+5, 0, -10); the M221 value is the absolute percentage.

-- PrusaSlicer's serialized top_fill_pattern values.
local TOP_PATTERNS = {
    "rectilinear", "monotonic", "monotoniclines", "alignedrectilinear",
    "concentric", "hilbertcurve", "archimedeanchords", "octagramspiral",
}

-- "+5", "0", "-10": Orca's modifier, sign always shown except on zero.
local function relative_label(util, absolute)
    local rel = absolute - 100
    if math.abs(rel) < 1e-9 then
        return "0"
    end
    local text = util.fmt(rel, 2)
    if rel > 0 then
        text = "+" .. text
    end
    return text
end

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local pattern = tostring(opts.top_pattern or ""):lower():gsub("%s", "")
    local allowed = false
    for _, p in ipairs(TOP_PATTERNS) do
        if p == pattern then allowed = true end
    end
    assert(allowed, "Top surface pattern must be one of " .. table.concat(TOP_PATTERNS, ", "))

    -- Orca types the sweep relative to the current flow, so -20..+20 means
    -- 80..120% of it; absolute percentages are accepted too.
    local typed = util.parse_range(opts.range, { integer = true, max_count = 20, what = "Flow range" })
    local lowest, highest = typed[1], typed[1]
    for _, v in ipairs(typed) do
        lowest = math.min(lowest, v)
        highest = math.max(highest, v)
    end
    local relative = lowest >= -50 and highest <= 50
    assert(relative or (lowest >= 50 and highest <= 150),
        "Flow range out of range: type it relative to the current flow (-50 to +50, added to 100) or as absolute percentages (50 to 150)")
    local flows = {}
    for i, v in ipairs(typed) do
        flows[i] = relative and (v + 100) or v
    end
    for _, f in ipairs(flows) do
        assert(f >= 50 and f <= 150, "Flow out of range: " .. f .. "%")
    end
    local n = #flows
    assert(n >= 2, "A flow staircase needs at least two treads")
    local d = util.num(opts.tread, "tread depth", 10)
    local w = util.num(opts.width, "width", 16)
    local riser_req = util.num(opts.riser, "step height", 4)
    assert(d >= 6 and w >= 8 and riser_req >= 2, "Tread must be >= 6 mm, width >= 8 mm, step height >= 2 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local h = util.align(riser_req, lh, 4)
    local length = n * d

    api.project:clear_layer_custom_steps(bed)
    local volumes = {}
    local main
    local labels = {}
    for i, f in ipairs(flows) do
        local z0 = (i - 1) * h
        local x0 = (i - 1) * d
        local slab = { mesh = api.make_cube(length - x0, w, h), type = VolumeType.Solid, translate = { x = x0, z = z0 } }
        if i == 1 then main = slab else volumes[#volumes + 1] = slab end
        api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z0, lh), "M221 S" .. f)
        labels[i] = relative_label(util, f)
        volumes[#volumes + 1] = label.front {
            text = labels[i], x = x0 + d / 2, z = z0 + h / 2, face_y = 0,
            line_height = math.min(5, h * 0.6), max_width = d - 1.5, max_height = h - 1.2,
        }
    end
    volumes[#volumes + 1] = label.back {
        text = tag, x = length / 2, z = h / 2, face_y = w,
        line_height = math.min(5, h * 0.6), max_width = length - 4, max_height = h - 1.2,
    }

    api.project:add_object {
        mesh = main.mesh,
        translate = main.translate,
        other_volumes = volumes,
        object_params = util.merge(util.solid_params(), { top_fill_pattern = pattern }),
    }

    local em = util.read_number(bed:material_presets(0), "extrusion_multiplier")
    util.log(string.format("flow staircase for %s: %d treads, M221 %d%% to %d%% (%s to %s relative), %s x %s mm footprint, %s mm per step, %s top surface",
        tag, n, flows[1], flows[n], labels[1], labels[n], util.fmt(length), util.fmt(w), util.fmt(h), pattern))
    util.log("judge each tread's top surface; new extrusion multiplier = " .. (em and util.fmt(em, 4) or "current") .. " x chosen % / 100")
    util.log("M221 persists on the printer: put 'M221 S100' in the end G-code")
    util.data(bed, "flow", { tag = tag, range = tostring(opts.range), relative = relative, values = util.join(flows, 0),
        labels = table.concat(labels, ","), steps = n, tread = d, width = w, riser = h, top_pattern = pattern,
        extrusion_multiplier = em or 0 })
end
