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

local function must_fail(path, overrides, pattern, mock_opts)
    local mock, _, err = run_command(path, overrides, mock_opts)
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

local function generic_checks(mock)
    local obj = single_object(mock)
    check(obj.mesh:true_box().min_z + (obj.translate.z or 0) >= -1e-9, "main mesh below the bed")
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

local command_ids = {}
for _, f in ipairs(commands) do
    local env = base_env()
    load_in(f, env)
    command_ids[env.info.id] = f
end
local function cmd(id)
    return command_ids[id] or error("no command with id " .. id)
end

print("Discovery")
test("every file evaluates without api/require (discovery scan)", function()
    for _, m in ipairs(modules) do
        check(m.ok, m.path .. " failed at discovery: " .. tostring(m.err))
    end
    check(#commands == 13, "expected 13 commands, found " .. #commands)
end)

test("command metadata is valid for alpha11 and the menu reads 1..9 in filename order", function()
    local seen_ids, seen_menus = {}, {}
    local types = { string = "string", int = "number", float = "number", bool = "boolean" }
    local numbered = {}
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
        local num = info.menu:match("/(%d+)%. ")
        if num then numbered[#numbered + 1] = tonumber(num)
        elseif info.menu:match("/%d+b%. ") then -- alternative method, sorts right after its step
        else check(info.menu:find("/Tools/", 1, true), f .. ": unnumbered command must be under Tools") end
    end
    -- `commands` is sorted by filename, which is the order PrusaSlicer shows
    for i, n in ipairs(numbered) do check(n == i, "menu number " .. n .. " appears at position " .. i) end
    check(#numbered == 10, "ten numbered steps")
end)

print("Library")
test("util helpers", function()
    local mock = Mock.new()
    local env = exec_env(mock, bundle_dir .. "/x.lua")
    local util = env.require("lib/util")
    check(util.fmt(100, 0) == "100" and util.fmt(12.50, 2) == "12.5" and util.fmt(-0.0001, 2) == "0", "fmt")
    check(util.int("6.4", "x") == 6 and util.int(6.6, "x") == 7 and math.type(util.int(6.0)) == "integer", "int")
    check(util.decimal("") == nil and near(util.decimal("0,96"), 0.96), "decimal")
    local v, pct = util.number_or_percent("17.5%"); check(near(v, 17.5) and pct == true, "percent parse")
    check(near(util.align(8.05, 0.2, 2), 8) and near(util.align(0.1, 0.2, 2), 0.4), "align")
    check(util.short_printer_tag("Original Prusa MK4S 0.4 nozzle") == "MK4S 0.4", "short tag")
    check(util.short_printer_tag("CORE One 0.4 HF") == "CORE One 0.4 HF", "short tag keeps a 15-char name whole")
    check(#util.short_printer_tag(string.rep("Z", 40)) == 18, "short tag length cap")
    check(util.resolve_tag(mock.bed, "  P7 ") == "P7" and util.resolve_tag(mock.bed, "") == "MK4S 0.4", "resolve tag")
    check(near(util.extrusion_area(0.45, 0.2), 0.0814159, 1e-6), "extrusion area")
    check(util.fan_pwm(50) == 128 and util.fan_pwm(100) == 255, "fan pwm")
    -- range selector
    local r = util.range { min = 235, max = 260, by_interval = true, interval = 5, integer = true }
    check(#r == 6 and r[1] == 235 and r[6] == 260, "range by interval")
    r = util.range { min = 235, max = 260, by_interval = false, count = 4, integer = true }
    check(#r == 4 and r[1] == 235 and r[2] == 243 and r[3] == 252 and r[4] == 260, "range by count rounds to whole numbers: " .. table.concat(r, ","))
    r = util.range { min = 6, max = 24, by_interval = false, count = 7 }
    check(#r == 7 and near(r[2], 9) and near(r[7], 24), "range by count, decimals")
    r = util.range { min = 10, max = 33, by_interval = true, interval = 5 }
    check(#r == 5 and r[5] == 30, "range by interval stops below max when it does not divide")
    check(not pcall(util.range, { min = 10, max = 5, by_interval = true, interval = 1 }), "range rejects max <= min")
    check(not pcall(util.range, { min = 0, max = 100, by_interval = true, interval = 1 }), "range rejects too many steps")
    check(not pcall(util.range, { min = 0, max = 100, by_interval = false, count = 1 }), "range rejects a single step")
    -- baseline snapshot
    local b = util.baseline(mock.bed)
    check(near(b.layer_height, 0.2) and near(b.nozzle, 0.4) and b.p_temperature == 250 and near(b.p_extrusion_multiplier, 1) and b.p_perimeters == 2, "baseline fields")
    check(b.baseline_mismatch == nil, "no mismatch without a profile")
end)

test("label placement conventions", function()
    local mock = Mock.new()
    local env = exec_env(mock, bundle_dir .. "/x.lua")
    local label = env.require("lib/label")
    local front = label.front { text = "250", x = 13, z = 9, face_y = 0, line_height = 4, max_width = 23, max_height = 6.5 }
    check(front.type == VT.Negative and front.rotate.x == 90 and near(front.translate.y, 0.6), "front placement")
    local back = label.back { text = "MK4S", x = 13, z = 2.5, face_y = 14, line_height = 3, max_width = 23, max_height = 4 }
    check(back.rotate.x == 90 and back.rotate.z == 180 and near(back.translate.y, 13.4), "back placement")
    local top = label.top { text = "T", x = 1, y = 2, top_z = 2, line_height = 3 }
    check(top.rotate == nil and near(top.translate.z, 1.4), "top placement")
    local long = label.front { text = "Original Prusa XL", x = 0, z = 0, line_height = 5, max_width = 20, max_height = 6 }
    check(text_width(long) <= 20 + 1e-6 and long.mesh.line_height < 5, "label shrunk to max width")
end)

test("tower builder", function()
    local mock = Mock.new({ layer_height = 0.15 })
    local env = exec_env(mock, bundle_dir .. "/x.lua")
    local tower = env.require("lib/tower")
    local def = tower.build(mock.bed, { width = 20, depth = 10, base_height = 5, section_height = 8, layer_height = 0.15,
        sections = { { label = "A", gcode = "M104 S1", params = { perimeter_speed = 10 } }, { label = "B", gcode = "M104 S2" } }, tag = "T" })
    check(near(def.section_height, 7.95) and near(def.base_height, 4.95) and near(def.total_height, 4.95 + 2 * 7.95), "rounded to whole layers")
    check(#mock.bed.gcodes == 2 and near(mock.bed.gcodes[1].z, 4.95 + 0.075), "gcode on first layer of section")
    local wing, reach = tower.wing { x_face = 20, depth = 10, z0 = 4.95, section_height = 7.95, angle_deg = 45, thickness = 2 }
    check(wing.rotate.y == -45 and wing.translate.x == 20 and reach > 0, "wing")
end)

print("Commands")
test("1 temperature tower on Prusa's model", function()
    local mock = run_command(cmd("temp_tower"))
    local obj = generic_checks(mock)
    check(obj.mesh.kind == "stl" and near(obj.translate.z, 1), "Prusa base as main mesh, lifted onto the bed")
    local steps = volumes_of(obj, VT.Solid, "stl")
    check(#steps == 6, "six Prusa steps")
    for i, st in ipairs(steps) do check(near(st.translate.z, 1 + (i - 1) * 10), "step " .. i .. " stacked") end
    local g = gcode_lines(mock)
    check(#g == 6 and g[1] == "M104 S260" and g[6] == "M104 S235", "hottest at the bottom: " .. table.concat(g, " "))
    check(near(mock.bed.gcodes[1].z, 1.1) and near(mock.bed.gcodes[2].z, 11.1), "changes on each step's first layer")
    for _, t in ipairs({ "260", "255", "250", "245", "240", "235" }) do check(has_text(obj, t), "label " .. t) end
    for _, v in ipairs(volumes_of(obj, VT.Negative, "text")) do
        check(near(v.translate.y, -5 + 0.6), "labels sunk into the front face at y=-5")
        check(v.translate.x == -16 or v.translate.x == 30, "labels in the flat zones")
    end
    check(has_text(obj, "MK4S 0.4"), "tag")
    check(obj.object_params.fill_density == "100%", "solid")
    local d = parse_data(data_line(mock))
    check(d.values == "260,255,250,245,240,235" and d.sections == 6 and near(d.section_height, 10), "DATA values")
    local mock2 = run_command(cmd("temp_tower"), { by_interval = false, sections = 4, solid = false })
    check(gcode_lines(mock2)[2] == "M104 S252" and #gcode_lines(mock2) == 4, "by sections: " .. table.concat(gcode_lines(mock2), " "))
    check(single_object(mock2).object_params == nil, "preset infill kept")
    must_fail(cmd("temp_tower"), { max_temp = 400, min_temp = 380 }, "out of range")
    must_fail(cmd("temp_tower"), { max_temp = 230 }, "greater than")
    must_fail(cmd("temp_tower"), { interval = 1 }, "Too many")
end)

test("2 flow staircase", function()
    local mock = run_command(cmd("flow_tower"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 108 and obj.mesh.dims.max_y == 20 and near(obj.mesh.dims.max_z, 5), "bottom slab 108 x 20 x 5")
    local slabs = volumes_of(obj, VT.Solid, "cube")
    check(#slabs == 8, "eight more slabs")
    for i, sl in ipairs(slabs) do
        check(near(sl.translate.x, i * 12) and near(sl.translate.z, i * 5) and near(sl.mesh.dims.max_x, 108 - i * 12), "slab " .. (i + 1) .. " forms a tread")
    end
    local g = gcode_lines(mock)
    check(#g == 9 and g[1] == "M221 S80" and g[5] == "M221 S100" and g[9] == "M221 S120", "pass-1 sweep: " .. table.concat(g, " "))
    check(near(mock.bed.gcodes[1].z, 0.1) and near(mock.bed.gcodes[2].z, 5.1), "M221 on each step's first layer")
    check(has_text(obj, "80%") and has_text(obj, "120%") and has_text(obj, "MK4S 0.4"), "labels")
    local d = parse_data(data_line(mock))
    check(d.values == "80,85,90,95,100,105,110,115,120" and near(d.extrusion_multiplier, 1), "DATA")
    local mock2 = run_command(cmd("flow_tower"), { min_flow = 96, max_flow = 104, interval = 1 })
    check(#gcode_lines(mock2) == 9 and gcode_lines(mock2)[1] == "M221 S96", "pass 2 in 1% steps")
    must_fail(cmd("flow_tower"), { min_flow = 40 }, "out of range")
end)

test("3 pressure advance line test", function()
    local mock = run_command(cmd("pa_line"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 10 and near(obj.mesh.dims.max_z, 1) and obj.object_params.fill_density == "100%", "small solid anchor plate")
    check(#mock.bed.gcodes == 1 and near(mock.bed.gcodes[1].z, 0.1), "one entry on the first layer")
    local g = mock.bed.gcodes[1].gcode
    local lines = {}
    for l in g:gmatch("[^\n]+") do lines[#lines + 1] = l end
    local pa_cmds, fast, slow = 0, 0, 0
    for _, l in ipairs(lines) do
        if l:match("^M572 S") then pa_cmds = pa_cmds + 1 end
        if l:find("F6000", 1, true) then fast = fast + 1 end
        if l:match("^G1 .*F1200$") then slow = slow + 1 end
    end
    check(pa_cmds == 17, "0.00 to 0.08 by 0.005 = 17 PA commands, got " .. pa_cmds)
    check(fast == 17, "one fast run per line, got " .. fast)
    check(slow > 34, "two slow runs per line plus digit strokes, got " .. slow)
    check(g:find("M572 S0\n", 1, true) and g:find("M572 S0.08\n", 1, true), "first and last values")
    check(g:find("G0 X85 Y115 F9000", 1, true), "pattern starts left of the MK4 bed centre, above the plate")
    check(g:find("G1 X105 Y115 E0.7269 F1200", 1, true), "20 mm slow run extrudes 0.7269 mm at 0.48 x 0.2 mm, 1.75 filament")
    check(lines[2] == "G90" and lines[3] == "G1 E0.8 F2400" and lines[#lines - 1] == "G1 E-0.8 F2400", "unretract first, retract last")
    check(not g:find("G92", 1, true) and not g:find("M83", 1, true), "never touches the E mode")
    local d = parse_data(data_line(mock))
    check(d.step == "pa" and d.method == "line" and d.bed_x == 125 and d.bed_y == 105 and d.sections == 17, "DATA")
    local mock2 = run_command(cmd("pa_line"), { firmware = "klipper", bed_x = 100, bed_y = 100, min_pa = "0.02", max_pa = "0.06", interval = "0.02", retract = "0" }, { printer_name = "Voron 2.4" })
    local g2 = mock2.bed.gcodes[1].gcode
    check(g2:find("SET_PRESSURE_ADVANCE ADVANCE=0.04", 1, true) and g2:find("G0 X60 Y110 F9000", 1, true) and not g2:find("E0.8", 1, true), "klipper, explicit bed centre, no retract")
    must_fail(cmd("pa_line"), nil, "Bed centre unknown", { printer_name = "Voron 2.4" })
    must_fail(cmd("pa_line"), { spacing = 2 }, "Line spacing")
    must_fail(cmd("pa_line"), { fast_speed = 10 }, "greater than slow")
end)

test("3b pressure advance tower", function()
    local mock = run_command(cmd("pa_tower"))
    local obj = generic_checks(mock)
    local g = gcode_lines(mock)
    check(#g == 11 and g[1] == "M572 S0" and g[2] == "M572 S0.01" and g[11] == "M572 S0.1", "0.00 to 0.10 by 0.01 as M572: " .. table.concat(g, " "))
    check(near(mock.bed.gcodes[1].z, 5.1) and near(mock.bed.gcodes[2].z, 10.1), "first change above the plinth, then every band")
    check(obj.mesh.dims.max_x == 40 and obj.mesh.dims.max_y == 20 and near(obj.mesh.dims.max_z, 5), "plinth 40 x 20 x 5")
    check(obj.object_params.perimeters == 2 and obj.object_params.fill_density == "0%" and obj.object_params.top_solid_layers == 0, "hollow two-perimeter body")
    local solids = volumes_of(obj, VT.Solid, "cube")
    check(#solids == 2 and near(solids[1].mesh.dims.max_z, 55) and near(solids[1].translate.z, 5), "body and spine, 11 bands of 5 mm")
    local notch = volumes_of(obj, VT.Negative, "cube")
    check(#notch == 1 and near(notch[1].translate.x, 14) and near(notch[1].translate.y, -1), "notch in the front")
    local speed_mods, solid_mods = 0, 0
    for _, m in ipairs(volumes_of(obj, VT.Modifier)) do
        if m.params.external_perimeter_speed == 120 then speed_mods = speed_mods + 1 elseif m.params.fill_density == "100%" then solid_mods = solid_mods + 1 end
    end
    check(speed_mods == 11 and solid_mods == 2, "one speed modifier per band, solid spine and plinth: " .. speed_mods .. "/" .. solid_mods)
    for _, v in ipairs({ "0.000", "0.050", "0.100", "MK4S 0.4" }) do check(has_text(obj, v), "label " .. v) end
    local d = parse_data(data_line(mock))
    check(d.step == "pa" and d.values == "0,0.01,0.02,0.03,0.04,0.05,0.06,0.07,0.08,0.09,0.1" and d.firmware == "prusa" and d.p_pressure_advance == 0, "DATA")
    local mock2 = run_command(cmd("pa_tower"), { firmware = "klipper", by_interval = false, sections = 3, min_pa = "0.02", max_pa = "0.06" })
    check(table.concat(gcode_lines(mock2), " | ") == "SET_PRESSURE_ADVANCE ADVANCE=0.02 | SET_PRESSURE_ADVANCE ADVANCE=0.04 | SET_PRESSURE_ADVANCE ADVANCE=0.06", "klipper by sections: " .. table.concat(gcode_lines(mock2), " | "))
    check(gcode_lines(run_command(cmd("pa_tower"), { firmware = "marlin", max_pa = "0.02" }))[3] == "M900 K0.02", "marlin")
    must_fail(cmd("pa_tower"), { firmware = "rrf" }, "Firmware must be")
    must_fail(cmd("pa_tower"), { max_pa = "3", interval = "1" }, "between 0 and 2")
end)

test("4 max volumetric flow: Prusa comb", function()
    local mock = run_command(cmd("volumetric_tower"))
    local obj = generic_checks(mock)
    check(obj.mesh.kind == "svg" and near(obj.mesh.dims.max_z, 42) and near(obj.translate.z, 0), "comb extruded to 7 x 6 mm")
    check(obj.object_params.perimeters == 1 and obj.object_params.fill_density == "0%" and near(obj.object_params.external_perimeter_extrusion_width, 0.7), "single wall at nozzle x 1.75")
    local spine = volumes_of(obj, VT.Solid, "cube")
    check(#spine == 1 and near(spine[1].translate.x, 183) and near(spine[1].mesh.dims.max_z, 42), "label spine beside the comb")
    local mods = volumes_of(obj, VT.Modifier)
    local speed_mods, ticks, spine_mods = 0, 0, 0
    for _, m in ipairs(mods) do
        if m.params.perimeter_speed then speed_mods = speed_mods + 1
        elseif m.params.external_perimeter_extrusion_width then ticks = ticks + 1
        elseif m.params.fill_density then spine_mods = spine_mods + 1 end
    end
    check(speed_mods == 7 and ticks == 6 and spine_mods == 1, "7 speed bands, 6 ticks, 1 solid spine override: " .. speed_mods .. "/" .. ticks .. "/" .. spine_mods)
    local area = 0.5 * 0.2 + math.pi * 0.01
    local first
    for _, m in ipairs(mods) do if m.params.perimeter_speed and near(m.translate.z, 0) then first = m end end
    check(first and near(first.params.perimeter_speed, 6 / area, 1e-6), "first band speed from 6 mm3/s at 0.7 x 0.2")
    check(has_text(obj, "6") and has_text(obj, "24") and has_text(obj, "MK4S 0.4"), "labels")
    check(#mock.bed.material.set_log == 0, "presets untouched by default")
    local warned = false
    for _, l in ipairs(mock.prints) do if l:find("WARNING: the filament preset caps", 1, true) then warned = true end end
    check(warned, "warns that the preset's 8 mm3/s cap is below the top band")
    local mock2 = run_command(cmd("volumetric_tower"), { comb = false, lift_limits = true, by_interval = true, interval = 6 })
    local obj2 = single_object(mock2)
    check(obj2.mesh.kind == "cube" and obj2.mesh.dims.max_x == 30, "solid block variant")
    check(#volumes_of(obj2, VT.Modifier) == 4, "6,12,18,24 by interval")
    check(set_values(mock2.bed.material).filament_max_volumetric_speed == 0 and set_values(mock2.bed.print).max_volumetric_speed == 0, "limits lifted on request")
    must_fail(cmd("volumetric_tower"), { extrusion_width = "0.1" }, "larger than the layer height")
end)

test("5 slab mass check", function()
    local mock = run_command(cmd("slab"))
    local obj = generic_checks(mock)
    check(#volumes_of(obj, VT.Solid, "cube") == 4 and has_text(obj, "73.7cc 93.6g"), "posts and nominal engraved")
    local d = parse_data(data_line(mock))
    check(near(d.expected_g, 93.6346, 1e-3) and near(d.p_density, 1.27) and near(d.layer_height, 0.2), "DATA with baseline")
    local mock2 = run_command(cmd("slab"), { posts = false, density = "1.3", note = "lot 42" })
    check(has_text(single_object(mock2), "72cc 93.6g") and has_text(single_object(mock2), "MK4S 0.4 lot 42"), "typed density, note")
    must_fail(cmd("slab"), { density = "9" }, "between 0.5 and 3")
end)

test("6 infill overlap calibration", function()
    local mock = run_command(cmd("overlap"))
    local obj = generic_checks(mock)
    local mods = volumes_of(obj, VT.Modifier)
    local expected = { "10%", "15%", "20%", "25%", "30%", "35%" }
    check(#mods == 6, "six blocks")
    for i, m in ipairs(mods) do
        check(m.params.infill_overlap == expected[i] and has_text(obj, expected[i]), "block " .. i .. ": " .. tostring(m.params.infill_overlap))
        check(near(m.translate.x, (i - 1) * 31 - 1), "modifier over block " .. i)
    end
    check(has_text(obj, "infill_overlap") and has_text(obj, "MK4S 0.4"), "key and tag engraved")
    local d = parse_data(data_line(mock))
    check(d.step == "overlap" and d.values == "10%,15%,20%,25%,30%,35%", "DATA")
    local mock2 = run_command(cmd("overlap"), { by_interval = false, blocks = 4 })
    local m2 = volumes_of(single_object(mock2), VT.Modifier)
    check(#m2 == 4 and m2[2].params.infill_overlap == "18.33%", "by block count: " .. tostring(m2[2].params.infill_overlap))
    local mock3 = run_command(cmd("overlap"), { setting = "perimeters", min_value = "2", max_value = "5", interval = "1" })
    local m3 = volumes_of(single_object(mock3), VT.Modifier)
    check(#m3 == 4 and m3[4].params.perimeters == 5 and math.type(m3[4].params.perimeters) == "integer", "integer setting")
    must_fail(cmd("overlap"), { min_value = "abc" }, "must be a number")
    must_fail(cmd("overlap"), { setting = "bad key!" }, "config key")
end)

test("7 shrink bar", function()
    local mock = run_command(cmd("shrink_bar"))
    local obj = generic_checks(mock)
    local holes = volumes_of(obj, VT.Negative, "cylinder")
    check(#holes == 2 and near(holes[1].translate.x, 10) and near(holes[2].translate.x, 140), "holes 130 mm apart")
    check(has_text(obj, "C 130 W 20 D 6"), "nominals engraved")
    check(parse_data(data_line(mock)).c0 == 130, "DATA")
end)

test("8 reference coupon with wing and fins", function()
    local mock = run_command(cmd("coupon"), { xy_compensation = "-0.05", elephant_foot = "0.15", note = "PETG lot 42" })
    local obj = generic_checks(mock)
    check(#volumes_of(obj, VT.Negative, "cylinder") == 1, "hole")
    local solids = volumes_of(obj, VT.Solid, "cube")
    local wing, fins = nil, {}
    for _, v in ipairs(solids) do if v.rotate.y then wing = v else fins[#fins + 1] = v end end
    check(wing and wing.rotate.y == -45 and wing.translate.x == 50 and near(wing.translate.z, 0), "45 deg wing on the +X end")
    check(#fins == 3 and near(fins[1].mesh.dims.max_y, 0.8) and near(fins[2].mesh.dims.max_y, 1.2) and near(fins[3].mesh.dims.max_y, 1.6), "0.8/1.2/1.6 mm fins")
    for _, fin in ipairs(fins) do check(near(fin.translate.z, 10) and fin.translate.y + fin.mesh.dims.max_y <= 25 - 3 + 1e-9, "fins stand on top along the back edge") end
    check(near(obj.object_params.xy_size_compensation, -0.05) and near(obj.object_params.elefant_foot_compensation, 0.15), "compensation")
    check(has_text(obj, "MK4S 0.4") and has_text(obj, "PETG lot 42"), "tag and note")
    local mock2 = run_command(cmd("coupon"), { overhang_angle = 0, fins = false, hole = 0 })
    check(#volumes_of(single_object(mock2), VT.Solid) == 0 and #volumes_of(single_object(mock2), VT.Negative, "cylinder") == 0, "features optional")
    must_fail(cmd("coupon"), { overhang_angle = 10 }, "between 20 and 80")
end)

test("9 stringing tower", function()
    local mock = run_command(cmd("stringing_tower"))
    local obj = generic_checks(mock)
    local g = gcode_lines(mock)
    check(#g == 6 and g[1] == "M104 S250" and g[6] == "M104 S225", "250 down to 225 by 5")
    check(#volumes_of(obj, VT.Solid, "cube") == 2, "two pillars")
    local mock2 = run_command(cmd("stringing_tower"), { fan_start = 30, fan_step = 10 })
    check(gcode_lines(mock2)[1] == "M104 S250\nM106 S77", "temperature and fan in one entry")
    local mock3 = run_command(cmd("stringing_tower"), { interval = 0, sections = 4 })
    check(#gcode_lines(mock3) == 4 and gcode_lines(mock3)[4] == "M104 S250", "constant temperature with 4 sections")
    local mock4 = run_command(cmd("stringing_tower"), { by_interval = false, sections = 3 })
    check(table.concat(gcode_lines(mock4), " ") == "M104 S250 M104 S238 M104 S225", "by sections: " .. table.concat(gcode_lines(mock4), " "))
    must_fail(cmd("stringing_tower"), { fan_start = 60, fan_step = 10 }, "fan is out of range")
end)

test("10 apply results", function()
    local mock = run_command(cmd("apply_results"))
    check(#mock.objects == 0 and #mock.bed.material.set_log == 0, "defaults change nothing")
    local mock2 = run_command(cmd("apply_results"), { temperature = 245, extrusion_multiplier = "0,96", infill_overlap = "20%", pressure_advance = "0.045", solid_print_preset = true })
    local m = set_values(mock2.bed.material)
    check(m.temperature == 245 and near(m.extrusion_multiplier, 0.96) and set_values(mock2.bed.print).infill_overlap == "20%", "values written")
    check(near(m.pressure_advance_value, 0.045) and m.pressure_advance == "enabled", "pressure advance value written and mode enabled")
    local mock3 = must_fail(cmd("apply_results"), { temperature = 245, extrusion_multiplier = "2" }, "between 0.5 and 1.5")
    check(#mock3.bed.material.set_log == 0, "validation before any write")
end)

test("tools: nozzle wipe", function()
    local mock = run_command(cmd("nozzle_wipe"))
    check(#mock.objects == 0 and #mock.bed.gcodes == 50 and near(mock.bed.gcodes[1].z, 5.1), "50 wipes")
    local g = mock.bed.gcodes[1].gcode
    check(g:find("G1 X240 Y-3 F9000", 1, true) and g:find("G1 X210 F3000", 1, true) and g:sub(-17) == "; end nozzle wipe", "wipe routine")
end)

test("every command prints one DATA line with the baseline", function()
    local expected_step = { temp_tower = "temp", flow_tower = "flow", pa_line = "pa", pa_tower = "pa", volumetric_tower = "vol", slab = "slab", overlap = "overlap",
        shrink_bar = "bar", coupon = "coupon", stringing_tower = "string", apply_results = "apply" }
    for id, step in pairs(expected_step) do
        local mock = run_command(cmd(id))
        local line = data_line(mock)
        check(line, id .. " printed no DATA line")
        local d = parse_data(line)
        check(d.step == step and d.printer == "Original Prusa MK4S 0.4 nozzle" and d.tag == "MK4S 0.4", id .. " step/printer/tag: " .. line)
        check(near(d.layer_height, 0.2) and near(d.nozzle, 0.4) and d.p_temperature == 250 and d.p_perimeters == 2, id .. " baseline fields")
        local count = 0
        for _, l in ipairs(mock.prints) do if l:find("DATA ", 1, true) then count = count + 1 end end
        check(count == 1, id .. " printed " .. count .. " DATA lines")
    end
end)

test("profile.lua: tag, apply, and baseline mismatch warning", function()
    local profile = { ["Original Prusa MK4S 0.4 nozzle"] = { tag = "MK4S #3", temperature = 245, first_layer_temperature = 235,
        extrusion_multiplier = 0.9752, filament_max_volumetric_speed = 15.3, infill_overlap = "15%", pressure_advance = 0.045, layer_height = 0.2, nozzle = 0.4 } }
    local mock = run_command(cmd("temp_tower"), nil, { modules = { profile = profile } })
    check(has_text(single_object(mock), "MK4S #3"), "tag from profile")
    check(parse_data(data_line(mock)).baseline_mismatch == nil, "matching baseline, no warning")
    local mock2 = run_command(cmd("temp_tower"), nil, { modules = { profile = profile }, layer_height = 0.25 })
    local d2 = parse_data(data_line(mock2))
    check(d2.baseline_mismatch and d2.baseline_mismatch:find("layer height 0.2 (profile) vs 0.25 (now)", 1, true), "layer height mismatch reported: " .. tostring(d2.baseline_mismatch))
    local warned = false
    for _, l in ipairs(mock2.prints) do if l:find("WARNING: this print does not match the earlier steps", 1, true) then warned = true end end
    check(warned, "mismatch warning logged")
    local mock3 = run_command(cmd("apply_profile"), nil, { modules = { profile = profile } })
    local m = set_values(mock3.bed.material)
    check(m.temperature == 245 and near(m.extrusion_multiplier, 0.9752) and set_values(mock3.bed.print).infill_overlap == "15%", "apply from profile")
    check(near(m.pressure_advance_value, 0.045) and m.pressure_advance == "enabled", "pressure advance from profile")
    must_fail(cmd("apply_profile"), nil, "no entry for printer")
end)

test("every command tolerates a printer without nozzle feature", function()
    for _, f in ipairs(commands) do
        local mock, _, err = run_command(f, f:find("pa_line", 1, true) and { bed_x = 100, bed_y = 100 } or nil, { no_nozzle = true, printer_name = "", modules = { profile = { ["unknown printer"] = { tag = "X", temperature = 240 } } } })
        check(err == nil, f .. " failed: " .. tostring(err))
    end
end)

print()
print(string.format("%d passed, %d failed", passes, #failures))
if #failures > 0 then
    os.exit(1)
end
