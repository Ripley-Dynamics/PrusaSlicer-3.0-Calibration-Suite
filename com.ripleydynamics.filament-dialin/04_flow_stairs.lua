info = {
    id = "flow_tower",
    type = "project.plugin",
    title = "Flow staircase via M221: one exposed top surface per flow value",
    menu = "Filament Dial-In/4. Flow staircase (M221)",
    params = {
        { name = "min_flow", label = "Lowest flow modifier [%] relative to the current flow (bottom chip); -20 for the two-pass method's first pass", type = "int", default = -5 },
        { name = "max_flow", label = "Highest flow modifier [%] (top chip)", type = "int", default = 5 },
        { name = "by_interval", label = "Choose by interval (on) or by number of chips (off)", type = "bool", default = true },
        { name = "interval", label = "Interval [%] (whole percent: M221 takes integers)", type = "int", default = 1 },
        { name = "sections", label = "Number of chips (when interval is off)", type = "int", default = 11 },
        { name = "tread", label = "Chip length per flow value [mm]", type = "int", default = 16 },
        { name = "width", label = "Staircase width Y [mm]", type = "int", default = 30 },
        { name = "riser_layers", label = "Riser height in layers (minimum 2, so the chips stay flat)", type = "int", default = 3 },
        { name = "solid", label = "Print at 100% infill (off = 15% infill with solid top layers, as the original design prints)", type = "bool", default = true },
        { name = "top_pattern", label = "Top surface pattern: archimedeanchords, monotonic, monotoniclines, rectilinear, alignedrectilinear, concentric, hilbertcurve, octagramspiral", type = "string", default = "archimedeanchords" },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- OrcaSlicer's flow calibration, rebuilt for PrusaSlicer the way Crepmaehn's
-- "Extrusion Multiplier/Flow-Rate Calibration for PrusaSlicer" does it
-- (Printables model 1190404): one wide, flat chip per flow value, all of them
-- on one plate, each printed at its own flow and judged by its top surface.
--
-- Orca prints one patch per flow modifier and engraves the modifier, not the
-- absolute flow: its recommended "YOLO" pass is -5 to +5 in 1% steps on
-- archimedean chords (the pattern that shows over- and under-extrusion most
-- plainly), its "perfectionist" pass -4 to +3.5 in 0.5% steps, and its legacy
-- two-pass method is -20 to +20 in 5% steps followed by -9 to 0 in 1% steps
-- applied to the already-updated flow.
--
-- PrusaSlicer cannot set flow per object, so the chips are the treads of a
-- staircase and M221 changes on each tread's first layer; every tread's top
-- layers print at that tread's flow. The risers are only a few layers tall
-- (Crepmaehn's chips are 3 layers apart), which keeps the whole plate low and
-- fast and puts all the top surfaces at nearly the same height, printed under
-- nearly the same conditions. The engraved label is Orca's relative number
-- (+5, 0, -10); the M221 value is the absolute percentage.

-- PrusaSlicer's serialized top_fill_pattern values.
local TOP_PATTERNS = {
    "rectilinear", "monotonic", "monotoniclines", "alignedrectilinear",
    "concentric", "hilbertcurve", "archimedeanchords", "octagramspiral",
}

local MIN_RISER_LAYERS, MAX_RISER_LAYERS = 2, 20
local LABEL_BAND = 6 -- mm of each chip's front edge kept for its number

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
    local typed = util.range {
        min = opts.min_flow, max = opts.max_flow, by_interval = opts.by_interval,
        interval = opts.interval, count = opts.sections, integer = true, max_count = 20,
    }
    local lowest, highest = typed[1], typed[#typed]
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
    local d = util.num(opts.tread, "chip length", 16)
    local w = util.num(opts.width, "width", 30)
    local riser_layers = util.int(opts.riser_layers, "riser layers", 3)
    assert(d >= 6 and w >= 8, "Chip length must be >= 6 mm and width >= 8 mm")
    assert(riser_layers <= MAX_RISER_LAYERS, "Riser layers must be at most " .. MAX_RISER_LAYERS .. "; the chips are meant to stay flat")
    if riser_layers < MIN_RISER_LAYERS then
        riser_layers = MIN_RISER_LAYERS
        util.log("riser raised to the minimum of " .. MIN_RISER_LAYERS .. " layers, so each chip has a layer of its own under its top")
    end

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local h = riser_layers * lh
    local length = n * d
    -- The risers are thinner than a label is deep, so the numbers are engraved
    -- into the front edge of each chip's top instead of onto a riser face.
    local engrave = math.min(label.DEFAULT_DEPTH, h * 0.5)

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
        volumes[#volumes + 1] = label.top {
            text = labels[i], x = x0 + d / 2, y = LABEL_BAND / 2, top_z = z0 + h,
            line_height = math.min(5, LABEL_BAND - 1.5), max_width = d - 3, max_height = LABEL_BAND - 1.5,
            depth = engrave,
        }
    end
    -- The tag goes in the back band of the lowest chip, away from the surfaces
    -- being judged.
    volumes[#volumes + 1] = label.top {
        text = tag, x = d / 2, y = w - LABEL_BAND / 2, top_z = h,
        line_height = math.min(4, LABEL_BAND - 1.5), max_width = d - 3, max_height = LABEL_BAND - 1.5,
        depth = engrave,
    }

    local fill = opts.solid and util.solid_params()
        or { fill_density = "15%", top_solid_layers = 4, bottom_solid_layers = 3 }
    api.project:add_object {
        mesh = main.mesh,
        translate = main.translate,
        other_volumes = volumes,
        object_params = util.merge(fill, { top_fill_pattern = pattern }),
    }

    local em = util.read_number(bed:material_presets(0), "extrusion_multiplier")
    util.log(string.format("flow staircase for %s: %d chips, M221 %d%% to %d%% (%s to %s relative), %s x %s mm footprint, %d-layer risers (%s mm), %s top surface, %s",
        tag, n, flows[1], flows[n], labels[1], labels[n], util.fmt(length), util.fmt(w), riser_layers, util.fmt(h, 3), pattern,
        opts.solid and "100% infill" or "15% infill with solid top layers"))
    util.log("judge each chip's top surface; new extrusion multiplier = " .. (em and util.fmt(em, 4) or "current") .. " x chosen % / 100")
    util.log("M221 persists on the printer: put 'M221 S100' in the end G-code")
    util.data(bed, "flow", { tag = tag, relative = relative, values = util.join(flows, 0),
        labels = table.concat(labels, ","), steps = n, tread = d, width = w, riser = h, riser_layers = riser_layers,
        top_pattern = pattern, solid = opts.solid and true or false, extrusion_multiplier = em or 0 })
end
