-- Headless test runner for the Filament Dial-In bundle.
--
-- Usage: lua5.4 test/run_tests.lua <bundle dir> <every .lua file in the bundle>
--
-- Stage 1 mirrors PrusaSlicer's discovery scan: each file is evaluated in a
-- state with only the base/table/math/string libraries and must not error.
-- Stage 2 mirrors execution: the entry file is re-evaluated with `api`,
-- `VolumeType` and the restricted `require`, then execute(opts) runs against
-- the mock API and the results are checked.

local bundle_dir = arg[1]
assert(bundle_dir, "usage: run_tests.lua <bundle dir> <lua files...>")
local files = {}
for i = 2, #arg do
    files[#files + 1] = arg[i]
end
assert(#files > 0, "no bundle files given")

package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
local Mock = require("mock_api")

local failures, passes = {}, 0
local current = "?"

local function check(cond, msg)
    if not cond then
        error("CHECK FAILED: " .. tostring(msg), 2)
    end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-6)
end

local function test(name, fn)
    current = name
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passes = passes + 1
        io.write("  ok   ", name, "\n")
    else
        failures[#failures + 1] = name .. "\n" .. tostring(err)
        io.write("  FAIL ", name, "\n", tostring(err), "\n")
    end
end

-- Sandbox ----------------------------------------------------------------------
local function base_env()
    return {
        assert = assert, error = error, ipairs = ipairs, pairs = pairs, pcall = pcall,
        print = function(...) end, tonumber = tonumber, tostring = tostring, type = type,
        select = select, next = next, rawget = rawget, rawset = rawset, rawequal = rawequal,
        setmetatable = setmetatable, getmetatable = getmetatable, unpack = table.unpack,
        table = table, math = math, string = string, _VERSION = _VERSION,
    }
end

local function load_in(path, env)
    local chunk, err = loadfile(path, "t", env)
    assert(chunk, err)
    return chunk()
end

local function entry_dir(path)
    return path:gsub("[^/]+$", "")
end

local function exec_env(mock, entry_path, virtual)
    local env = base_env()
    env.api = mock.api
    env.VolumeType = mock.VolumeType
    mock.prints = mock.prints or {}
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        mock.prints[#mock.prints + 1] = table.concat(parts, "\t")
    end
    local cache = {}
    local dir = entry_dir(entry_path)
    env.require = function(name)
        assert(type(name) == "string", "require needs a string")
        assert(not name:find("%.%."), "require: parent traversal rejected: " .. name)
        assert(name:sub(1, 1) ~= "/", "require: absolute path rejected: " .. name)
        if cache[name] ~= nil then
            return cache[name]
        end
        if virtual and virtual[name] ~= nil then
            cache[name] = virtual[name]
            return virtual[name]
        end
        local r = load_in(dir .. name .. ".lua", env)
        if r == nil then r = true end
        cache[name] = r
        return r
    end
    return env
end

local function defaults_from(info, overrides)
    local opts = {}
    for _, p in ipairs(info.params or {}) do
        opts[p.name] = p.default
    end
    for k, v in pairs(overrides or {}) do
        assert(opts[k] ~= nil, "override for unknown parameter " .. k)
        opts[k] = v
    end
    return opts
end

-- Runs one command with the mock. Returns mock, env, err (err nil on success).
local function run_command(path, overrides, mock_opts)
    local mock = Mock.new(mock_opts)
    local env = exec_env(mock, path, mock_opts and mock_opts.modules)
    load_in(path, env)
    assert(type(env.info) == "table" and type(env.execute) == "function", path .. " is not a command")
    local opts = defaults_from(env.info, overrides)
    local ok, err = pcall(env.execute, opts)
    return mock, env, (not ok) and err or nil
end

local function must_fail(path, overrides, pattern)
    local mock, _, err = run_command(path, overrides)
    check(err ~= nil, "expected failure for " .. path .. " with overrides, but it succeeded")
    if pattern then
        check(tostring(err):find(pattern, 1, true), "expected error containing '" .. pattern .. "', got: " .. tostring(err))
    end
    return mock
end

-- Result helpers ---------------------------------------------------------------
local VT = Mock.VolumeType

local function single_object(mock)
    check(#mock.objects == 1, "expected exactly one add_object call, got " .. #mock.objects)
    return mock.objects[1]
end

local function volumes_of(obj, vtype, kind)
    local out = {}
    for _, v in ipairs(obj.volumes) do
        if v.type == vtype and (kind == nil or v.mesh.kind == kind) then
            out[#out + 1] = v
        end
    end
    return out
end

local function texts(obj)
    local out = {}
    for _, v in ipairs(volumes_of(obj, VT.Negative, "text")) do
        out[#out + 1] = v.mesh.text
    end
    return out
end

local function has_text(obj, s)
    for _, t in ipairs(texts(obj)) do
        if t == s then return true end
    end
    return false
end

local function text_width(v)
    return 0.62 * v.mesh.line_height * #v.mesh.text
end

local function gcode_lines(mock)
    local out = {}
    for _, g in ipairs(mock.bed.gcodes) do
        out[#out + 1] = g.gcode
    end
    return out
end

local function set_values(box)
    local out = {}
    for _, s in ipairs(box.set_log) do
        out[s.key] = s.value
    end
    return out
end

-- Every unrotated solid must sit on or above the bed, and no volume may have
-- a nil mesh; modifiers must carry at least one param.
local function generic_checks(mock)
    local obj = single_object(mock)
    check(obj.mesh:true_box().min_z >= -1e-9, "main mesh below the bed")
    for i, v in ipairs(obj.volumes) do
        if v.type == VT.Solid and next(v.rotate) == nil then
            local z = (v.translate.z or 0) + v.mesh:true_box().min_z
            check(z >= -1e-9, "solid volume " .. i .. " below the bed (z=" .. z .. ")")
        end
        if v.type == VT.Modifier then
            check(v.params and next(v.params) ~= nil, "modifier " .. i .. " has no params")
        end
        if v.mesh.kind == "text" then
            check(v.type == VT.Negative, "text volume " .. i .. " should be engraved (Negative)")
            check(v.mesh.text ~= "", "text volume " .. i .. " is empty")
        end
    end
    for i = 2, #mock.bed.gcodes do
        check(mock.bed.gcodes[i].z > mock.bed.gcodes[i - 1].z, "G-code not ascending")
    end
    return obj
end

-- Find files -----------------------------------------------------------------
local commands, modules = {}, {}
for _, f in ipairs(files) do
    local env = base_env()
    local ok, err = pcall(load_in, f, env)
    if ok and type(env.info) == "table" and type(env.execute) == "function" then
        commands[#commands + 1] = f
    else
        modules[#modules + 1] = { path = f, ok = ok, err = err }
    end
end
table.sort(commands)

local function cmd(id)
    for _, f in ipairs(commands) do
        if f:match("/" .. id .. "%.lua$") then return f end
    end
    error("no command file for " .. id)
end

print("Discovery")
test("every file evaluates without api/require (discovery scan)", function()
    for _, m in ipairs(modules) do
        check(m.ok, m.path .. " failed at discovery: " .. tostring(m.err))
    end
    check(#commands == 11, "expected 11 commands, found " .. #commands)
end)

test("command metadata is valid for alpha11", function()
    local seen_ids, seen_menus = {}, {}
    local types = { string = "string", int = "number", float = "number", bool = "boolean" }
    for _, f in ipairs(commands) do
        local env = base_env()
        load_in(f, env)
        local info = env.info
        check(type(info.id) == "string" and info.id:match("^[%w_]+$"), f .. ": bad id")
        check(not seen_ids[info.id], f .. ": duplicate id " .. info.id)
        seen_ids[info.id] = true
        check(info.type == "project.plugin", f .. ": type must be project.plugin")
        check(type(info.menu) == "string" and info.menu ~= "", f .. ": menu is required in alpha11")
        check(not info.menu:match("^/") and not info.menu:match("/$") and not info.menu:match("//"), f .. ": bad menu path")
        check(not seen_menus[info.menu], f .. ": duplicate menu " .. info.menu)
        seen_menus[info.menu] = true
        check(type(info.title) == "string", f .. ": title missing")
        local names = {}
        for _, p in ipairs(info.params or {}) do
            check(type(p.name) == "string" and not names[p.name], f .. ": bad or duplicate param name " .. tostring(p.name))
            names[p.name] = true
            check(types[p.type], f .. ": unsupported param type " .. tostring(p.type) .. " for " .. p.name)
            check(type(p.default) == types[p.type], f .. ": default for " .. p.name .. " must be a " .. types[p.type])
            check(type(p.label) == "string", f .. ": label missing for " .. p.name)
            check(p.type ~= "float", f .. ": avoid float params (alpha11 rounds them); use int or string")
        end
    end
end)

print("Library")
test("util helpers", function()
    local mock = Mock.new()
    local env = exec_env(mock, bundle_dir .. "/x.lua")
    local util = env.require("lib/util")
    check(util.fmt(100, 0) == "100", "fmt 100")
    check(util.fmt(12.50, 2) == "12.5", "fmt 12.5")
    check(util.fmt(0.4499999, 3) == "0.45", "fmt rounding")
    check(util.fmt(-0.0001, 2) == "0", "fmt negative zero")
    check(util.int("6.4", "x") == 6, "int from decimal string")
    check(util.int(6.6, "x") == 7, "int rounds")
    check(math.type(util.int(6.0)) == "integer", "int returns a Lua integer")
    check(util.decimal("") == nil and util.decimal("  ") == nil, "decimal blank")
    check(near(util.decimal("0,96"), 0.96), "decimal comma")
    local v, pct = util.number_or_percent("17.5%")
    check(near(v, 17.5) and pct == true, "percent parse")
    v, pct = util.number_or_percent("0.45")
    check(near(v, 0.45) and pct == false, "number parse")
    check(near(util.align(8, 0.2, 2), 8), "align exact")
    check(near(util.align(8.05, 0.2, 2), 8), "align nearest")
    check(near(util.align(0.1, 0.2, 2), 0.4), "align minimum steps")
    check(util.short_printer_tag("Original Prusa MK4S 0.4 nozzle") == "MK4S 0.4", "short tag")
    check(util.short_printer_tag("Original Prusa XL 5T Input Shaper 0.6 nozzle") == "XL 5T IS 0.6", "short tag IS")
    check(#util.short_printer_tag(string.rep("Z", 40)) == 14, "short tag length cap")
    check(util.resolve_tag(mock.bed, "  P7 ") == "P7", "typed tag wins")
    check(util.resolve_tag(mock.bed, "") == "MK4S 0.4", "blank tag falls back to printer")
    check(near(util.extrusion_area(0.45, 0.2), 0.0814159, 1e-6), "extrusion area")
    check(math.type(util.whole(3.0)) == "integer" and util.whole(3.5) == 3.5, "whole")
    check(near(util.layer_height(mock.bed), 0.2), "layer height read")
    check(util.fan_pwm(50) == 128 and util.fan_pwm(100) == 255 and util.fan_pwm(0) == 0, "fan pwm")
    local ok = util.try_set(mock.bed:material_presets(0), "temperature", 245, "t")
    check(ok and mock.bed:material_presets(0):value("temperature") == 245, "try_set verified")
    check(util.try_set(mock.bed:print_presets(), "fill_density", "100%", "fd") == true, "try_set opaque is unverified but ok")
    check(util.try_set(mock.bed:print_presets(), "no_such_key", 1, "x") == true, "try_set unknown key does not raise")
end)

test("label placement conventions", function()
    local mock = Mock.new()
    local env = exec_env(mock, bundle_dir .. "/x.lua")
    local label = env.require("lib/label")
    local front = label.front { text = "250", x = 13, z = 9, face_y = 0, line_height = 4, max_width = 23, max_height = 6.5 }
    check(front.type == VT.Negative and front.rotate.x == 90 and front.rotate.z == nil, "front rotation")
    check(near(front.translate.y, 0.6) and front.translate.x == 13 and front.translate.z == 9, "front translate")
    local back = label.back { text = "MK4S", x = 13, z = 2.5, face_y = 14, line_height = 3, max_width = 23, max_height = 4 }
    check(back.rotate.x == 90 and back.rotate.z == 180 and near(back.translate.y, 13.4), "back placement")
    local top = label.top { text = "T", x = 1, y = 2, top_z = 2, line_height = 3 }
    check(top.rotate == nil and near(top.translate.z, 1.4), "top placement")
    -- fitting: a long string must be shrunk to the width limit
    local long = label.front { text = "Original Prusa XL", x = 0, z = 0, line_height = 5, max_width = 20, max_height = 6 }
    check(text_width(long) <= 20 + 1e-6, "label shrunk to max width, got " .. text_width(long))
    check(long.mesh.line_height < 5, "line height reduced")
    local tall = label.front { text = "9", x = 0, z = 0, line_height = 10, max_width = 100, max_height = 3 }
    check(0.72 * tall.mesh.line_height <= 3 + 1e-6, "label shrunk to max height")
    local ok = pcall(label.front, { text = "", x = 0, z = 0, line_height = 3 })
    check(not ok, "empty text rejected")
end)

test("tower builder", function()
    local mock = Mock.new({ layer_height = 0.15 })
    local env = exec_env(mock, bundle_dir .. "/x.lua")
    local tower = env.require("lib/tower")
    local def = tower.build(mock.bed, {
        width = 20, depth = 10, base_height = 5, section_height = 8, layer_height = 0.15,
        sections = { { label = "A", gcode = "M104 S1", params = { perimeter_speed = 10 } }, { label = "B", gcode = "M104 S2" } },
        tag = "T",
    })
    check(near(def.section_height, 7.95), "section rounded to whole layers (53 x 0.15)")
    check(near(def.base_height, 4.95), "base rounded to whole layers (33 x 0.15)")
    check(near(def.total_height, 4.95 + 2 * 7.95), "total height")
    check(near(def.section_z[2], 4.95 + 7.95), "section z")
    check(#mock.bed.gcodes == 2 and near(mock.bed.gcodes[1].z, 4.95 + 0.075), "gcode on first layer of section")
    check(mock.bed.cleared == 1, "custom gcode list cleared once")
    local mods, labels = 0, 0
    for _, v in ipairs(def.other_volumes) do
        if v.type == VT.Modifier then
            mods = mods + 1
            check(near(v.translate.x, -2) and near(v.translate.y, -2) and near(v.translate.z, 4.95), "modifier placement")
            check(v.mesh.dims.max_x == 24 and v.mesh.dims.max_y == 14, "modifier covers body plus margin")
        elseif v.mesh.kind == "text" then
            labels = labels + 1
        end
    end
    check(mods == 1 and labels == 3, "one modifier, two labels plus tag; got " .. mods .. "/" .. labels)
    local wing, reach = tower.wing { x_face = 20, depth = 10, z0 = 4.95, section_height = 7.95, angle_deg = 45, thickness = 2 }
    check(wing.type == VT.Solid and wing.rotate.y == -45 and wing.translate.x == 20 and near(wing.translate.z, 4.95), "wing placement")
    local rise = wing.mesh.dims.max_x * math.sin(math.rad(45)) + 2 * math.cos(math.rad(45))
    check(rise <= 7.95 - 0.5 + 1e-9, "wing stays inside its section")
    check(reach > 0 and reach < 7.95, "wing reach")
end)

print("Commands")
test("temp_tower defaults", function()
    local mock = run_command(cmd("temp_tower"))
    local obj = generic_checks(mock)
    local g = gcode_lines(mock)
    check(#g == 6 and g[1] == "M104 S260" and g[6] == "M104 S235", "temperature G-code sequence")
    check(near(mock.bed.gcodes[1].z, 5.1), "first change on the first layer above the plinth")
    check(near(mock.bed.gcodes[2].z, 15.1), "second change one section up")
    local d = obj.mesh.dims
    check(d.max_x == 30 and d.max_y == 16 and near(d.max_z, 65), "body 30 x 16 x 65")
    for _, t in ipairs({ "260", "255", "250", "245", "240", "235" }) do
        check(has_text(obj, t), "label " .. t)
    end
    check(has_text(obj, "MK4S 0.4 TEMP"), "printer tag engraved on the plinth")
    local wings = volumes_of(obj, VT.Solid, "cube")
    check(#wings == 6, "six overhang wings")
    for i, w in ipairs(wings) do
        check(w.rotate.y == -45 and w.translate.x == 30 and near(w.translate.z, 5 + (i - 1) * 10), "wing " .. i .. " placement")
    end
    for _, v in ipairs(volumes_of(obj, VT.Negative, "text")) do
        if v.rotate.z == nil then
            check(text_width(v) <= 27 + 1e-6, "front label fits the face")
            check(v.translate.x == 15 and near(v.translate.y, 0.6), "front label centred and sunk 0.6 mm")
        end
    end
    check(obj.object_params.fill_density == "100%" and obj.object_params.fill_pattern == "rectilinear", "solid object params")
end)

test("temp_tower with alpha11-style numeric values and options off", function()
    local mock = run_command(cmd("temp_tower"), { start_temp = 260.0, sections = 6.4, temp_step = 5.0, overhangs = false, solid = false, tag = "P7" })
    local obj = generic_checks(mock)
    check(#gcode_lines(mock) == 6 and gcode_lines(mock)[1] == "M104 S260", "decimal-typed ints still produce clean G-code")
    check(#volumes_of(obj, VT.Solid) == 0, "no wings")
    check(obj.object_params == nil, "preset infill left alone")
    check(has_text(obj, "P7 TEMP"), "typed tag used")
end)

test("temp_tower rejects bad input before touching the project", function()
    local mock = must_fail(cmd("temp_tower"), { sections = 1 }, "between 2 and 20")
    check(#mock.objects == 0 and mock.bed.cleared == 0, "nothing changed")
    must_fail(cmd("temp_tower"), { start_temp = 400 }, "out of range")
    must_fail(cmd("temp_tower"), { start_temp = 200, temp_step = 20, sections = 6 }, "out of range")
    must_fail(cmd("temp_tower"), { start_temp = "abc" }, "must be a number")
    must_fail(cmd("temp_tower"), { section_height = 2 }, "at least 4")
end)

test("flow_tower", function()
    local mock = run_command(cmd("flow_tower"))
    local obj = generic_checks(mock)
    local g = gcode_lines(mock)
    check(#g == 7 and g[1] == "M221 S104" and g[7] == "M221 S92", "M221 sequence")
    check(has_text(obj, "104%") and has_text(obj, "92%") and has_text(obj, "MK4S 0.4 FLOW"), "labels")
    check(obj.object_params.fill_density == "100%", "solid")
    must_fail(cmd("flow_tower"), { start_flow = 160 }, "out of range")
    must_fail(cmd("flow_tower"), { sections = 25 }, "between 2 and 20")
end)

test("volumetric_tower", function()
    local mock = run_command(cmd("volumetric_tower"))
    local obj = generic_checks(mock)
    check(#mock.bed.gcodes == 0, "no custom G-code needed")
    local mods = volumes_of(obj, VT.Modifier)
    check(#mods == 7, "one modifier per section")
    local area = 0.25 * 0.2 + math.pi * 0.01
    local expected_first = 6 / area
    check(near(mods[1].params.perimeter_speed, expected_first, 1e-6), "first section speed from 6 mm3/s")
    check(near(mods[7].params.solid_infill_speed, 24 / area, 1e-6), "last section speed from 24 mm3/s")
    for i = 2, 7 do
        check(mods[i].params.infill_speed > mods[i - 1].params.infill_speed, "speeds increase")
    end
    for _, k in ipairs({ "perimeter_speed", "external_perimeter_speed", "small_perimeter_speed", "infill_speed", "solid_infill_speed", "top_solid_infill_speed", "gap_fill_speed" }) do
        check(mods[1].params[k] ~= nil, "modifier sets " .. k)
    end
    check(has_text(obj, "6") and has_text(obj, "24") and has_text(obj, "9"), "flow labels")
    check(near(obj.object_params.solid_infill_extrusion_width, 0.45), "extrusion width from nozzle")
    local m = set_values(mock.bed.material)
    check(m.filament_max_volumetric_speed == 0 and m.slowdown_below_layer_time == 0, "material limits lifted")
    check(set_values(mock.bed.print).max_volumetric_speed == 0, "print limit lifted")
end)

test("volumetric_tower with explicit width, 0.6 nozzle and limits kept", function()
    local mock = run_command(cmd("volumetric_tower"), { extrusion_width = "0.5", lift_limits = false }, { nozzle = 0.6, layer_height = 0.3 })
    local obj = generic_checks(mock)
    check(near(obj.object_params.perimeter_extrusion_width, 0.5), "typed width used")
    check(#mock.bed.material.set_log == 0 and #mock.bed.print.set_log == 0, "presets untouched")
    local mock2 = run_command(cmd("volumetric_tower"), { lift_limits = false }, { nozzle = 0.6, layer_height = 0.3 })
    check(near(single_object(mock2).object_params.perimeter_extrusion_width, 0.675), "auto width from 0.6 nozzle")
    must_fail(cmd("volumetric_tower"), { min_flow = 10, max_flow = 10 }, "greater than")
    must_fail(cmd("volumetric_tower"), { extrusion_width = "0.1" }, "larger than the layer height")
end)

test("sweep_plate defaults (infill_overlap percent sweep)", function()
    local mock = run_command(cmd("sweep_plate"))
    local obj = generic_checks(mock)
    local mods = volumes_of(obj, VT.Modifier)
    check(#mods == 6, "six modifiers")
    local expected = { "10%", "15%", "20%", "25%", "30%", "35%" }
    for i, m in ipairs(mods) do
        check(m.params.infill_overlap == expected[i], "block " .. i .. " overlap " .. tostring(m.params.infill_overlap))
        check(near(m.translate.x, (i - 1) * 31 - 1) and near(m.translate.y, -1) and near(m.translate.z, -1), "modifier covers block " .. i)
        check(has_text(obj, expected[i]), "label " .. expected[i])
    end
    check(#volumes_of(obj, VT.Solid) == 5, "five extra solid blocks plus the main one")
    check(has_text(obj, "MK4S 0.4") and has_text(obj, "infill_overlap"), "tag and key engraved")
    check(obj.object_params.fill_density == "100%", "solid")
end)

test("sweep_plate integer and float settings", function()
    local mock = run_command(cmd("sweep_plate"), { setting = "perimeters", start = "2", step = "1", samples = 4 })
    local mods = volumes_of(single_object(mock), VT.Modifier)
    check(#mods == 4 and mods[1].params.perimeters == 2 and mods[4].params.perimeters == 5, "perimeter values")
    check(math.type(mods[1].params.perimeters) == "integer", "integer setting gets a Lua integer")
    check(has_text(single_object(mock), "5"), "integer label")
    local mock2 = run_command(cmd("sweep_plate"), { setting = "solid_infill_extrusion_width", start = "0.4", step = "0.05", samples = 3 })
    local mods2 = volumes_of(single_object(mock2), VT.Modifier)
    check(near(mods2[3].params.solid_infill_extrusion_width, 0.5), "float values")
    check(has_text(single_object(mock2), "0.5") and has_text(single_object(mock2), "0.45"), "float labels")
    local mock3 = run_command(cmd("sweep_plate"), { samples = 1, block_height = 2 })
    check(#volumes_of(single_object(mock3), VT.Modifier) == 1, "single block")
    must_fail(cmd("sweep_plate"), { start = "abc" }, "must be a number")
    must_fail(cmd("sweep_plate"), { samples = 0 }, "between 1 and 12")
    must_fail(cmd("sweep_plate"), { setting = "bad key!" }, "config key")
    must_fail(cmd("sweep_plate"), { setting = "perimeters", start = "2.5", step = "1" }, "whole numbers")
end)

test("coupon", function()
    local mock = run_command(cmd("coupon"), { xy_compensation = "-0.05", elephant_foot = "0.15", note = "PETG lot 42" })
    local obj = generic_checks(mock)
    local holes = volumes_of(obj, VT.Negative, "cylinder")
    check(#holes == 1 and near(holes[1].mesh.dims.max_x, 5) and near(holes[1].translate.z, -1) and holes[1].mesh.dims.max_z == 12, "10 mm through-hole pierces both faces")
    check(has_text(obj, "MK4S 0.4") and has_text(obj, "PETG lot 42"), "tag and note")
    check(near(obj.object_params.xy_size_compensation, -0.05) and near(obj.object_params.elefant_foot_compensation, 0.15), "compensation values")
    check(obj.object_params.perimeters == 2 and math.type(obj.object_params.perimeters) == "integer", "perimeters")
    local mock2 = run_command(cmd("coupon"), { hole = 0 })
    local obj2 = single_object(mock2)
    check(#volumes_of(obj2, VT.Negative, "cylinder") == 0, "no hole")
    check(obj2.object_params.xy_size_compensation == nil and obj2.object_params.elefant_foot_compensation == nil, "blank compensation leaves preset values")
    check(#texts(obj2) == 1, "no note, only the tag")
    must_fail(cmd("coupon"), { hole = 24 }, "fit inside")
    must_fail(cmd("coupon"), { xy_compensation = "x" }, "must be a number")
end)

test("stringing_tower", function()
    local mock = run_command(cmd("stringing_tower"))
    local obj = generic_checks(mock)
    local g = gcode_lines(mock)
    check(#g == 6 and g[1] == "M104 S250" and g[6] == "M104 S225", "temperature only")
    check(#volumes_of(obj, VT.Solid, "cube") == 2, "two pillars")
    local pillars = volumes_of(obj, VT.Solid, "cube")
    check(near(pillars[1].translate.z, 2) and near(pillars[2].translate.x, 60), "pillars on the plate, 50 mm apart")
    check(has_text(obj, "250") and has_text(obj, "225") and has_text(obj, "MK4S 0.4"), "labels")
    local mock2 = run_command(cmd("stringing_tower"), { fan_start = 30, fan_step = 10 })
    local g2 = gcode_lines(mock2)
    check(g2[1] == "M104 S250\nM106 S77" and g2[6] == "M104 S225\nM106 S204", "temperature and fan in one entry per layer")
    check(has_text(single_object(mock2), "30%") and has_text(single_object(mock2), "80%"), "fan labels")
    must_fail(cmd("stringing_tower"), { fan_start = 60, fan_step = 10 }, "fan is out of range")
    must_fail(cmd("stringing_tower"), { gap = 5 }, "apart")
end)

test("apply_results", function()
    local mock = run_command(cmd("apply_results"))
    check(#mock.objects == 0 and #mock.bed.material.set_log == 0 and #mock.bed.print.set_log == 0, "defaults change nothing")
    local mock2 = run_command(cmd("apply_results"), {
        temperature = 245, first_layer_temperature = 240.0, extrusion_multiplier = "0,96", max_volumetric_speed = "12",
        infill_overlap = "20%", min_fan = 20, max_fan = 40, slowdown_below_layer_time = 8, solid_print_preset = true,
    })
    local m = set_values(mock2.bed.material)
    check(m.temperature == 245 and m.first_layer_temperature == 240, "temperatures")
    check(near(m.extrusion_multiplier, 0.96) and near(m.filament_max_volumetric_speed, 12), "flow values")
    check(m.min_fan_speed == 20 and m.max_fan_speed == 40 and m.slowdown_below_layer_time == 8, "cooling values")
    local p = set_values(mock2.bed.print)
    check(p.infill_overlap == "20%" and p.fill_density == "100%" and p.fill_pattern == "rectilinear", "print values")
    check(mock2.bed.material:value("extrusion_multiplier") == 0.96, "material box really updated")
    local mock3 = must_fail(cmd("apply_results"), { temperature = 245, extrusion_multiplier = "2" }, "between 0.5 and 1.5")
    check(#mock3.bed.material.set_log == 0, "validation happens before any write")
    local mock4 = run_command(cmd("apply_results"), { infill_overlap = "0.1" })
    check(near(set_values(mock4.bed.print).infill_overlap, 0.1), "overlap as millimetres")
end)

test("slab mass check", function()
    local mock = run_command(cmd("slab"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 60 and obj.mesh.dims.max_z == 20, "60 x 60 x 20 body")
    local posts = volumes_of(obj, VT.Solid, "cube")
    check(#posts == 4, "four witness posts")
    for _, p in ipairs(posts) do
        check(near(p.translate.z, 20) and p.mesh.dims.max_z == 12, "posts stand on the top face")
        check(p.translate.x >= 0 and p.translate.x + 6 <= 60 and p.translate.y >= 0 and p.translate.y + 6 <= 60, "posts inside the footprint")
    end
    check(has_text(obj, "73.7cc 93.6g"), "nominal volume and mass from preset density engraved; texts: " .. table.concat(texts(obj), " | "))
    check(has_text(obj, "MK4S 0.4"), "tag on the back")
    check(obj.object_params.fill_density == "100%", "solid")
    local mock2 = run_command(cmd("slab"), { posts = false, density = "1.3", note = "lot 42" })
    local obj2 = single_object(mock2)
    check(#volumes_of(obj2, VT.Solid) == 0, "no posts")
    check(has_text(obj2, "72cc 93.6g"), "typed density used; texts: " .. table.concat(texts(obj2), " | "))
    check(has_text(obj2, "MK4S 0.4 lot 42"), "note appended to the tag")
    must_fail(cmd("slab"), { size_x = 10 }, "at least 20")
    must_fail(cmd("slab"), { density = "9" }, "between 0.5 and 3")
end)

test("shrink_bar", function()
    local mock = run_command(cmd("shrink_bar"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 150 and obj.mesh.dims.max_y == 20 and obj.mesh.dims.max_z == 8, "150 x 20 x 8 bar")
    local holes = volumes_of(obj, VT.Negative, "cylinder")
    check(#holes == 2 and near(holes[1].translate.x, 10) and near(holes[2].translate.x, 140), "holes 130 mm apart")
    check(near(holes[1].mesh.dims.max_x, 3) and holes[1].mesh.dims.max_z == 10 and near(holes[1].translate.z, -1), "6 mm through-holes")
    check(has_text(obj, "C 130 W 20 D 6"), "nominal numbers engraved; texts: " .. table.concat(texts(obj), " | "))
    check(has_text(obj, "MK4S 0.4"), "tag")
    must_fail(cmd("shrink_bar"), { hole = 18 }, "wall")
    must_fail(cmd("shrink_bar"), { hole_inset = 80 }, "inside the bar")
    must_fail(cmd("shrink_bar"), { length = 40 }, "at least 60")
end)

test("nozzle_wipe", function()
    local mock = run_command(cmd("nozzle_wipe"))
    check(#mock.objects == 0, "adds no object")
    check(mock.bed.cleared == 1, "replaces the custom G-code list")
    check(#mock.bed.gcodes == 50, "5 mm to 250 mm every 5 mm = 50 wipes, got " .. #mock.bed.gcodes)
    check(near(mock.bed.gcodes[1].z, 5.1) and near(mock.bed.gcodes[50].z, 250.1), "first and last wipe heights")
    local g = mock.bed.gcodes[1].gcode
    check(g:find("G1 E-0.8 F2400", 1, true) and g:find("G1 E0.8 F2400", 1, true), "retract and unretract")
    check(g:find("G91\nG1 Z2 F600\nG90", 1, true) and g:find("G91\nG1 Z-2 F600\nG90", 1, true), "lift and lower")
    check(g:find("G1 X240 Y-3 F9000", 1, true), "travel to brush")
    local _, strokes = g:gsub("G1 X210 F3000", "")
    check(strokes == 3 and g:find("G1 X240 F3000", 1, true), "three strokes of 30 mm toward -X")
    check(g:sub(-17) == "; end nozzle wipe", "ends cleanly with absolute positioning restored")
    local mock2 = run_command(cmd("nozzle_wipe"), { along_y = true, stroke = 25, retract = "0", lift = 0, first = 10, last = 20, every = 10 })
    local g2 = mock2.bed.gcodes[1].gcode
    check(#mock2.bed.gcodes == 2, "two wipes")
    check(g2:find("G1 Y22 F3000", 1, true) and not g2:find("G91", 1, true) and not g2:find("E", 1, true), "Y strokes, no lift, no retract")
    must_fail(cmd("nozzle_wipe"), { stroke = 0 }, "non-zero")
    must_fail(cmd("nozzle_wipe"), { every = 0.1, first = 1, last = 250 }, "at least 0.5")
    must_fail(cmd("nozzle_wipe"), { last = 1 }, "last >= first")
end)

local function data_line(mock)
    for _, l in ipairs(mock.prints or {}) do
        if l:find("[filament-dialin] DATA ", 1, true) then return l end
    end
    return nil
end
local function parse_data(line)
    local out = {}
    local body = line:match("DATA (.*)$")
    for k, v in body:gmatch('([%w_]+)=("[^"]*")') do out[k] = v:sub(2, -2) end
    for k, v in body:gmatch('([%w_]+)=([^" ]+)') do if out[k] == nil then out[k] = tonumber(v) or v end end
    return out
end

test("every command prints one machine-readable DATA line", function()
    local expected_step = { temp_tower = "temp", flow_tower = "flow", volumetric_tower = "vol", sweep_plate = "sweep", slab = "slab",
        shrink_bar = "bar", coupon = "coupon", stringing_tower = "string", apply_results = "apply" }
    for _, f in ipairs(commands) do
        local id = f:match("([%w_]+)%.lua$")
        if expected_step[id] then
            local mock = run_command(f)
            local line = data_line(mock)
            check(line, id .. " printed no DATA line")
            local d = parse_data(line)
            check(d.step == expected_step[id], id .. " step field: " .. tostring(d.step))
            check(d.printer == "Original Prusa MK4S 0.4 nozzle", id .. " printer field")
            check(d.tag == "MK4S 0.4", id .. " tag field: " .. tostring(d.tag))
            local count = 0
            for _, l in ipairs(mock.prints) do if l:find("DATA ", 1, true) then count = count + 1 end end
            check(count == 1, id .. " printed " .. count .. " DATA lines")
        end
    end
    local d = parse_data(data_line(run_command(cmd("slab"))))
    check(near(d.expected_g, 93.6346, 1e-3) and near(d.volume_cm3, 73.728, 1e-6) and d.posts == "true", "slab numbers in DATA: " .. data_line(run_command(cmd("slab"))))
    local d2 = parse_data(data_line(run_command(cmd("slab"), { note = 'lot "A" \\ 42' })))
    check(d2.step == "slab", "quotes and backslashes in strings do not break the line")
    local d3 = parse_data(data_line(run_command(cmd("shrink_bar"))))
    check(d3.c0 == 130 and d3.hole == 6, "bar nominals in DATA")
end)

test("profile.lua supplies the tag and apply_profile writes the values", function()
    local profile = { ["Original Prusa MK4S 0.4 nozzle"] = { tag = "MK4S #3", temperature = 245, first_layer_temperature = 235,
        extrusion_multiplier = 0.9752, filament_max_volumetric_speed = 15.3, infill_overlap = "15%", xy_size_compensation = -0.07 } }
    local mock = run_command(cmd("temp_tower"), nil, { modules = { profile = profile } })
    check(has_text(single_object(mock), "MK4S #3 TEMP"), "tag from profile")
    local mock2 = run_command(cmd("temp_tower"), { tag = "P9" }, { modules = { profile = profile } })
    check(has_text(single_object(mock2), "P9 TEMP"), "typed tag still wins")
    local mock3 = run_command(cmd("apply_profile"), nil, { modules = { profile = profile } })
    local m = set_values(mock3.bed.material)
    check(m.temperature == 245 and m.first_layer_temperature == 235 and near(m.extrusion_multiplier, 0.9752) and near(m.filament_max_volumetric_speed, 15.3), "material values from profile")
    check(m.min_fan_speed == nil, "absent keys are left alone")
    local p = set_values(mock3.bed.print)
    check(p.infill_overlap == "15%" and p.fill_density == "100%", "print values from profile")
    check(#mock3.objects == 0, "adds no object")
    local d = parse_data(data_line(mock3))
    check(d.step == "apply_profile" and d.tag == "MK4S #3" and d.changed == 7, "apply_profile DATA line: " .. data_line(mock3))
    local mock4 = run_command(cmd("apply_profile"), { print_preset = false }, { modules = { profile = profile } })
    check(#mock4.bed.print.set_log == 0, "print values skipped when unchecked")
    must_fail(cmd("apply_profile"), nil, "no entry for printer")
    local lower = { ["original prusa mk4s 0.4 nozzle"] = { tag = "LC" } }
    check(has_text(single_object(run_command(cmd("coupon"), nil, { modules = { profile = lower } })), "LC"), "printer name match is case-insensitive")
    local mock5 = run_command(cmd("coupon"))
    check(has_text(single_object(mock5), "MK4S 0.4"), "no profile.lua at all falls back to the derived tag")
end)

test("every command tolerates a printer without nozzle feature", function()
    for _, f in ipairs(commands) do
        local mock, _, err = run_command(f, nil, { no_nozzle = true, printer_name = "", modules = { profile = { ["unknown printer"] = { tag = "X", temperature = 240 } } } })
        check(err == nil, f .. " failed: " .. tostring(err))
    end
end)

print()
print(string.format("%d passed, %d failed", passes, #failures))
if #failures > 0 then
    os.exit(1)
end
