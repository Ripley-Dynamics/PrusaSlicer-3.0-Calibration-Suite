info = {
    id = "flow_tower",
    type = "project.plugin",
    title = "Flow staircase via M221: one exposed top surface per flow value",
    menu = "Filament Dial-In/3. Flow staircase (M221)",
    params = {
        { name = "min_flow", label = "Lowest flow [%] (bottom step)", type = "int", default = 80 },
        { name = "max_flow", label = "Highest flow [%] (top step)", type = "int", default = 120 },
        { name = "by_interval", label = "Choose by interval (on) or by number of steps (off)", type = "bool", default = true },
        { name = "interval", label = "Interval [%] (pass 1: 5, pass 2: 1)", type = "int", default = 5 },
        { name = "steps", label = "Number of steps (when interval is off)", type = "int", default = 9 },
        { name = "tread", label = "Tread depth per step [mm]", type = "int", default = 12 },
        { name = "width", label = "Staircase width Y [mm]", type = "int", default = 20 },
        { name = "riser", label = "Step height [mm]", type = "int", default = 5 },
        { name = "tag", label = "Printer tag (blank = profile.lua or printer name)", type = "string", default = "" },
    },
}

-- Same idea as OrcaSlicer's flow calibration: pass 1 sweeps -20..+20% in 5%
-- steps, pass 2 sweeps 1% steps around the pass-1 winner, and you judge the
-- top surface of each patch. PrusaSlicer cannot set flow per object, so the
-- patches are the treads of a staircase and M221 changes on each step's
-- first layer; every tread's top layers are printed at that step's flow.

function execute(opts)
    local util = require("lib/util")
    local label = require("lib/label")
    local tower = require("lib/tower")

    local flows = util.range {
        min = opts.min_flow, max = opts.max_flow, by_interval = opts.by_interval,
        interval = opts.interval, count = opts.steps, integer = true, max_count = 20,
    }
    for _, f in ipairs(flows) do
        assert(f >= 50 and f <= 150, "Flow out of range: " .. f .. "%")
    end
    local n = #flows
    local d = util.num(opts.tread, "tread depth", 12)
    local w = util.num(opts.width, "width", 20)
    local riser_req = util.num(opts.riser, "step height", 5)
    assert(d >= 6 and w >= 8 and riser_req >= 2, "Tread must be >= 6 mm, width >= 8 mm, step height >= 2 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, opts.tag)
    local h = util.align(riser_req, lh, 4)
    local length = n * d

    api.project:clear_layer_custom_steps(bed)
    local volumes = {}
    local main
    for i, f in ipairs(flows) do
        local z0 = (i - 1) * h
        local x0 = (i - 1) * d
        local slab = { mesh = api.make_cube(length - x0, w, h), type = VolumeType.Solid, translate = { x = x0, z = z0 } }
        if i == 1 then main = slab else volumes[#volumes + 1] = slab end
        api.project:insert_layer_custom_gcode(bed, tower.gcode_z(z0, lh), "M221 S" .. f)
        volumes[#volumes + 1] = label.front {
            text = f .. "%", x = x0 + d / 2, z = z0 + h / 2, face_y = 0,
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
        object_params = util.solid_params(),
    }

    local em = util.read_number(bed:material_presets(0), "extrusion_multiplier")
    util.log(string.format("flow staircase for %s: %d treads, M221 %d%% to %d%%, %s x %s mm footprint, %s mm per step",
        tag, n, flows[1], flows[n], util.fmt(length), util.fmt(w), util.fmt(h)))
    util.log("judge each tread's top surface; new extrusion multiplier = " .. (em and util.fmt(em, 4) or "current") .. " x chosen % / 100")
    util.log("M221 persists on the printer: put 'M221 S100' in the end G-code")
    util.data(bed, "flow", { tag = tag, values = util.join(flows, 0), steps = n, tread = d, width = w, riser = h, extrusion_multiplier = em or 0 })
end
