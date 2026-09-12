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
    check(#commands == 17, "expected 17 commands, found " .. #commands)
end)

test("command metadata is valid for alpha11 and the menu reads 0..13 in filename order", function()
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
        -- "Filament Dial-In/3. Pressure advance/Line test" is step 3; a whole
        -- submenu of entries under one numbered step counts as that step once.
        local prefix, num = info.menu:match("^(.-/(%d+)%.[^/]*)")
        if num then
            num = tonumber(num)
            local last = numbered[#numbered]
            if last and last.num == num then
                check(last.prefix == prefix, f .. ": step " .. num .. " appears under two different submenus")
            else
                numbered[#numbered + 1] = { num = num, prefix = prefix, file = f }
            end
        else
            check(info.menu:find("/Tools/", 1, true), f .. ": unnumbered command must be under Tools")
        end
    end
    -- `commands` is sorted by filename, which is the order PrusaSlicer shows
    for i, e in ipairs(numbered) do check(e.num == i - 1, "menu number " .. e.num .. " appears at position " .. i .. " (" .. e.file .. ")") end
    check(#numbered == 14, "fourteen numbered steps, 0 to 13")
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
test("0 nozzle clean before testing", function()
    local mock = run_command(cmd("nozzle_clean"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 20 and obj.mesh.dims.max_y == 20 and near(obj.mesh.dims.max_z, 1), "20 x 20 x 1 mm anchor plate")
    check(obj.object_params.fill_density == "100%", "solid plate")
    check(#mock.bed.gcodes == 1 and near(mock.bed.gcodes[1].z, 0.1), "one entry on the plate's first layer")
    local lines = {}
    for l in mock.bed.gcodes[1].gcode:gmatch("[^\n]+") do lines[#lines + 1] = l end
    local at, purges, messages = {}, 0, 0
    for i, l in ipairs(lines) do
        local function mark(key)
            at[key] = at[key] or {}
            at[key][#at[key] + 1] = i
        end
        if l:match("^M600") then mark("change") end
        if l:match("^M601") then mark("pause") end
        if l:match("^M109 R130") then mark("cool") end
        if l:match("^M109 S270") then mark("hot") end
        if l:match("^M109 S250") then mark("reload") end
        if l:match("^G1 E20 F150") then purges = purges + 1 end
        if l:match("^M117 ") then messages = messages + 1 end
    end
    check(at.change and #at.change == 2, "M600 twice: cleaning filament in, test filament back")
    check(at.pause and #at.pause == 1, "exactly one pause (M601 on Prusa)")
    check(at.hot and at.hot[1] < at.change[1], "heats to the purge temperature before the first filament change")
    check(at.cool and at.cool[1] < at.pause[1] and at.pause[1] < at.change[2], "the pause sits between the cooldown and the second filament change")
    check(at.reload and #at.reload == 1 and at.reload[1] > at.pause[1], "reload temperature 250 comes from the material preset, after the pull")
    check(purges == 7, "100 mm in five 20 mm chunks plus two for the 40 mm reload purge, got " .. purges)
    check(messages == 6, "six M117 messages: start, insert cleaner, cooling, pull, load test filament, purging; got " .. messages)
    for _, l in ipairs(lines) do check(l:find(";", 1, true), "every line carries a comment: " .. l) end
    check(lines[#lines]:find("nozzle clean done", 1, true), "ends with the done comment")
    local d = parse_data(data_line(mock))
    check(d.step == "clean" and d.clean_temp == 270 and d.pull_temp == 130 and d.reload_temp == 250 and d.purge_mm == 100 and d.firmware == "prusa", "DATA")
    check(d.material == "nylon" and d.cleaning_filament == "nylon", "nylon by default, purge 270 and cold pull 130")
    local note = false
    for _, l in ipairs(mock.prints) do if l:find("Cold Pull", 1, true) then note = true end end
    check(note, "logs the CORE One Control > Cold Pull note")
    -- firmware variants
    local klipper = run_command(cmd("nozzle_clean"), { firmware = "klipper" }).bed.gcodes[1].gcode
    check(klipper:find("TEMPERATURE_WAIT SENSOR=extruder MAXIMUM=130", 1, true) and klipper:find("PAUSE ; pause", 1, true)
        and not klipper:find("M109 R", 1, true), "klipper waits for cooling and pauses with PAUSE")
    local marlin = run_command(cmd("nozzle_clean"), { firmware = "marlin" }).bed.gcodes[1].gcode
    check(marlin:find("M0 Pull the filament out firmly, then resume ;", 1, true) and marlin:find("M109 R130", 1, true), "marlin pauses with M0 plus the message")
    local reprap = run_command(cmd("nozzle_clean"), { firmware = "reprap" }).bed.gcodes[1].gcode
    check(reprap:find("M226 ; pause", 1, true), "reprap pauses with M226")
    -- purge chunking
    local short_purge = run_command(cmd("nozzle_clean"), { purge_mm = 50 }).bed.gcodes[1].gcode
    local chunks, tail = 0, false
    for l in short_purge:gmatch("[^\n]+") do
        if l:match("^G1 E20 F150") then chunks = chunks + 1 end
        if l:match("^G1 E10 F150") then tail = true end
    end
    check(chunks == 4 and tail, "50 mm purges as 20 + 20 + 10, plus two 20 mm reload chunks: " .. chunks)
    -- the cleaning material chooses the temperatures
    local pla = run_command(cmd("nozzle_clean"), { cleaning_filament = "PLA" })
    local pg = pla.bed.gcodes[1].gcode
    check(pg:find("M109 S270", 1, true) and pg:find("M109 R100", 1, true), "PLA purges at 270 and is pulled at 100")
    check(pg:find("M117 Insert PLA when asked", 1, true) and pg:find("M117 Cooling for the PLA cold pull", 1, true), "the messages name the material")
    local dp = parse_data(data_line(pla))
    check(dp.material == "pla" and dp.cleaning_filament == "PLA" and dp.clean_temp == 270 and dp.pull_temp == 100, "PLA DATA")
    check(parse_data(data_line(run_command(cmd("nozzle_clean"), { cleaning_filament = "  pla " }))).pull_temp == 100, "the material name is case-insensitive")
    -- any other word is a free name and gets nylon's temperatures
    local other = run_command(cmd("nozzle_clean"), { cleaning_filament = "eSun cleaning" })
    local dother = parse_data(data_line(other))
    check(dother.material == "esun cleaning" and dother.cleaning_filament == "eSun cleaning" and dother.pull_temp == 130, "a free name uses the nylon defaults")
    check(other.bed.gcodes[1].gcode:find("M117 Insert eSun cleaning when asked", 1, true), "and is named in the prompts")
    local noted = false
    for _, l in ipairs(other.prints) do if l:find("not one of nylon or pla", 1, true) then noted = true end end
    check(noted, "logs that the nylon temperatures are used")
    -- a typed temperature overrides the material's default
    local over = run_command(cmd("nozzle_clean"), { clean_temp = 285, pull_temp = 120 })
    local dov = parse_data(data_line(over))
    check(dov.clean_temp == 285 and dov.pull_temp == 120, "non-zero values override the material defaults")
    check(over.bed.gcodes[1].gcode:find("M109 S285", 1, true) and over.bed.gcodes[1].gcode:find("M109 R120", 1, true), "and reach the G-code")
    must_fail(cmd("nozzle_clean"), { clean_temp = 320 }, "between 150 and 300")
    must_fail(cmd("nozzle_clean"), { pull_temp = 40 }, "between 60 and 160")
    must_fail(cmd("nozzle_clean"), { purge_mm = 5 }, "between 20 and 300")
    must_fail(cmd("nozzle_clean"), { firmware = "duet" }, "Firmware must be")
end)

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
    check(gcode_lines(mock2)[2] == "M104 S252" and #gcode_lines(mock2) == 4, "by count: " .. table.concat(gcode_lines(mock2), " "))
    check(single_object(mock2).object_params == nil, "preset infill kept")
    must_fail(cmd("temp_tower"), { max_temp = 400, min_temp = 380 }, "out of range")
    must_fail(cmd("temp_tower"), { max_temp = 230 }, "greater than")
    must_fail(cmd("temp_tower"), { interval = 1 }, "Too many")
end)

test("2 max volumetric flow: Prusa comb", function()
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

test("4 flow staircase, Orca's chips built as Crepmaehn's staircase", function()
    local mock = run_command(cmd("flow_tower"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 176 and obj.mesh.dims.max_y == 30 and near(obj.mesh.dims.max_z, 0.6),
        "bottom chip 176 x 30 x 0.6 (11 chips of 16 mm, risers of 3 layers at 0.2 mm)")
    local slabs = volumes_of(obj, VT.Solid, "cube")
    check(#slabs == 10, "ten more slabs")
    for i, sl in ipairs(slabs) do
        check(near(sl.translate.x, i * 16) and near(sl.translate.z, i * 0.6) and near(sl.mesh.dims.max_x, 176 - i * 16), "slab " .. (i + 1) .. " forms a chip")
    end
    local g = gcode_lines(mock)
    check(#g == 11 and g[1] == "M221 S95" and g[6] == "M221 S100" and g[11] == "M221 S105", "Orca YOLO sweep, absolute M221: " .. table.concat(g, " "))
    check(near(mock.bed.gcodes[1].z, 0.1) and near(mock.bed.gcodes[2].z, 0.7) and near(mock.bed.gcodes[11].z, 6.1), "M221 on each chip's first layer, 0.6 mm apart")
    for _, t in ipairs({ "-5", "-1", "0", "+1", "+5" }) do check(has_text(obj, t), "relative label " .. t) end
    check(not has_text(obj, "95") and not has_text(obj, "105"), "absolute percentages are not engraved")
    check(has_text(obj, "MK4S 0.4"), "tag")
    -- The risers are lower than a label is deep, so every label is engraved
    -- into a chip top: the numbers in the front band, the tag in the back one.
    local front_band, back_band = 0, 0
    for _, v in ipairs(volumes_of(obj, VT.Negative, "text")) do
        check(next(v.rotate) == nil, "engraved into a top face, not into a riser")
        if near(v.translate.y, 3) then front_band = front_band + 1 end
        if near(v.translate.y, 27) then back_band = back_band + 1 end
    end
    check(front_band == 11 and back_band == 1, "a number on every chip plus the tag: " .. front_band .. "/" .. back_band)
    local first
    for _, v in ipairs(volumes_of(obj, VT.Negative, "text")) do if v.mesh.text == "-5" then first = v end end
    check(first and near(first.translate.x, 8) and near(first.translate.z, 0.3), "the first chip's number is sunk half a riser (0.3 mm) into its top")
    check(obj.object_params.top_fill_pattern == "archimedeanchords" and obj.object_params.fill_density == "100%", "solid, archimedean chords on top")
    local d = parse_data(data_line(mock))
    check(d.values == "95,96,97,98,99,100,101,102,103,104,105" and d.labels == "-5,-4,-3,-2,-1,0,+1,+2,+3,+4,+5", "DATA keeps absolute values and the labels")
    check(d.relative == "true" and d.top_pattern == "archimedeanchords" and near(d.extrusion_multiplier, 1), "DATA")
    check(d.steps == 11 and near(d.tread, 16) and near(d.width, 30) and near(d.riser, 0.6) and d.riser_layers == 3 and d.solid == "true", "DATA geometry")
    -- 15% infill with solid top layers, the way the original design prints
    local loose = run_command(cmd("flow_tower"), { solid = false })
    local lo = single_object(loose)
    check(lo.object_params.fill_density == "15%" and lo.object_params.top_solid_layers == 4 and lo.object_params.bottom_solid_layers == 3, "15% infill, 4 top and 3 bottom solid layers")
    check(lo.object_params.top_fill_pattern == "archimedeanchords" and parse_data(data_line(loose)).solid == "false", "top pattern kept, DATA records it")
    -- risers are counted in layers, never fewer than two
    local thin = run_command(cmd("flow_tower"), { riser_layers = 1 })
    check(near(thin.bed.gcodes[2].z, 0.5) and parse_data(data_line(thin)).riser_layers == 2, "one layer is raised to the two-layer minimum")
    local thick = run_command(cmd("flow_tower"), { riser_layers = 5 })
    check(near(thick.bed.gcodes[2].z, 1.1) and near(single_object(thick).mesh.dims.max_z, 1), "five layers make 1 mm risers")
    -- the legacy two-pass method, and absolute percentages
    local mock2 = run_command(cmd("flow_tower"), { min_flow = -20, max_flow = 20, interval = 5, top_pattern = "monotonic" })
    local g2 = gcode_lines(mock2)
    check(#g2 == 9 and g2[1] == "M221 S80" and g2[9] == "M221 S120", "pass 1 of the two-pass method: " .. table.concat(g2, " "))
    check(has_text(single_object(mock2), "-20") and has_text(single_object(mock2), "+20"), "relative labels on pass 1")
    check(single_object(mock2).object_params.top_fill_pattern == "monotonic", "Orca's legacy pattern")
    local mock3 = run_command(cmd("flow_tower"), { min_flow = 96, max_flow = 104, interval = 1 })
    local d3 = parse_data(data_line(mock3))
    check(#gcode_lines(mock3) == 9 and gcode_lines(mock3)[1] == "M221 S96" and d3.relative == "false", "absolute percentages taken as typed")
    check(has_text(single_object(mock3), "-4") and has_text(single_object(mock3), "+4"), "absolute values still engraved relative")
    must_fail(cmd("flow_tower"), { min_flow = -60, max_flow = 20, interval = 5 }, "out of range")
    must_fail(cmd("flow_tower"), { min_flow = 40, max_flow = 120, interval = 5 }, "out of range")
    must_fail(cmd("flow_tower"), { top_pattern = "gyroid" }, "Top surface pattern")
    must_fail(cmd("flow_tower"), { riser_layers = 40 }, "at most 20")
    must_fail(cmd("flow_tower"), { tread = 4 }, "Chip length must be")
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

test("6 cooling tower, built-in model", function()
    local mock = run_command(cmd("cooling_tower"))
    local obj = generic_checks(mock)
    check(obj.mesh.dims.max_x == 20 and near(obj.mesh.dims.max_z, 3 + 6 * 8), "20 mm tower, 3 mm base, six 8 mm bands")
    local solids = volumes_of(obj, VT.Solid, "cube")
    local pillar, wings = nil, 0
    for _, v in ipairs(solids) do if v.rotate.y then wings = wings + 1 else pillar = v end end
    check(pillar and near(pillar.translate.x, 35) and near(pillar.mesh.dims.max_x, 6) and near(pillar.mesh.dims.max_z, 51), "6 mm pillar 15 mm away, full height")
    check(wings == 6, "one wing per band")
    local g = mock.bed.gcodes
    check(#g == 6 * 40, "an M106 on every layer of every band: " .. #g)
    check(g[1].gcode == "M107" and near(g[1].z, 3.1) and g[40].gcode == "M107" and g[41].gcode == "M106 S51" and g[#g].gcode == "M106 S255", "0% then 20%.. up to 100%")
    for _, t in ipairs({ "0%", "20%", "100%", "MK4S 0.4" }) do check(has_text(obj, t), "label " .. t) end
    local m = set_values(mock.bed.material)
    check(m.min_fan_speed == 0 and m.max_fan_speed == 0 and m.bridge_fan_speed == 0 and m.overhang_fan_speed_3 == 0, "fan values pinned equal")
    check(m.fan_below_layer_time == 0 and m.slowdown_below_layer_time == 0 and m.full_fan_speed_layer == 0 and m.disable_fan_first_layers == 1, "layer-time rules off")
    local warned = false
    for _, l in ipairs(mock.prints) do if l:find("dynamic fan speeds", 1, true) then warned = true end end
    check(warned, "warns about dynamic fan speeds being on")
    check(parse_data(data_line(mock)).values == "0,20,40,60,80,100", "DATA")
    check(parse_data(data_line(mock)).model == "tower", "DATA names the model")
    local mock2 = run_command(cmd("cooling_tower"), { own_fan = false, overhang_angle = 0, by_interval = false, sections = 3, min_fan = 30, max_fan = 50 })
    check(#mock2.bed.material.set_log == 0, "presets untouched when own_fan is off")
    check(#volumes_of(single_object(mock2), VT.Solid, "cube") == 1 and #mock2.bed.gcodes == 3 * 40 and mock2.bed.gcodes[41].gcode == "M106 S102", "three bands 30/40/50, no wings")
    must_fail(cmd("cooling_tower"), { max_fan = 120 }, "Fan out of range")
    must_fail(cmd("cooling_tower"), { model = "banana" }, "Model must be")
end)

test("6 cooling tower, the Ultimate Fan Speed Test V3 model", function()
    local STL = "assets/fan/ultimate-fan-test-v3.stl"
    local mock = run_command(cmd("cooling_tower"), { model = "abyss" })
    local obj = generic_checks(mock)
    check(obj.mesh.kind == "stl" and near(obj.mesh.dims.max_z, 99.98), "the 100 mm model is the object")
    check(near(obj.translate.z, -obj.mesh:bounds().min_z), "the object translate lifts the STL onto the bed")
    -- 1% of fan per mm of height, on every layer from the bed to the top
    local g = mock.bed.gcodes
    check(#g == 499, "one entry per 0.2 mm layer over the model's 99.98 mm: " .. #g)
    check(g[1].gcode == "M107" and g[2].gcode == "M107" and g[3].gcode == "M107", "fan off below 0.5 mm")
    check(near(g[1].z, 0.1) and near(g[2].z, 0.3), "one per layer, half a layer up")
    check(g[4].gcode == "M106 S3", "1% from 0.6 mm: " .. g[4].gcode)
    check(g[#g].gcode == "M106 S255" and near(g[#g].z, 99.7), "100% at the top: " .. g[#g].gcode)
    check(g[251].gcode == "M106 S128", "50% at 50 mm: " .. g[251].gcode)
    -- the tag plate beside the model, solid, with the tag engraved on its top
    local plates = volumes_of(obj, VT.Solid, "cube")
    check(#plates == 1 and near(plates[1].mesh.dims.max_x, 12) and near(plates[1].mesh.dims.max_y, 30) and near(plates[1].mesh.dims.max_z, 3), "12 x 30 x 3 mm tag plate")
    check(near(plates[1].translate.x, 67.46 + 5) and near(plates[1].translate.y, -15) and near(plates[1].translate.z, 0), "beside the model at max_x + 5, centred in Y, on the bed")
    local mods = volumes_of(obj, VT.Modifier, "cube")
    check(#mods == 1 and mods[1].params.fill_density == "100%", "the plate prints solid")
    check(has_text(obj, "MK4S 0.4"), "the tag is engraved on it")
    local tag_vol = volumes_of(obj, VT.Negative, "text")[1]
    check(near(tag_vol.translate.z, 3 - 0.6) and tag_vol.rotate.z == 90, "engraved 0.6 mm into the plate top, reading along it")
    check(obj.object_params == nil, "the model prints with the preset's own settings")
    -- own_fan pins the preset to 0% so only our M106 speaks
    local m = set_values(mock.bed.material)
    check(m.min_fan_speed == 0 and m.max_fan_speed == 0 and m.bridge_fan_speed == 0 and m.fan_below_layer_time == 0, "preset fan pinned to 0%")
    local told = false
    for _, l in ipairs(mock.prints) do if l:find("1% per mm of height", 1, true) then told = true end end
    check(told, "logs that the height in mm of the best band is the fan percentage")
    local named = false
    for _, l in ipairs(mock.prints) do if l:find(STL, 1, true) then named = true end end
    check(named, "logs which model was used")
    local d = parse_data(data_line(mock))
    check(d.step == "cooling" and d.model == "abyss" and d.sections == 499 and near(d.height, 99.98) and d.own_fan == "true", "DATA")
    local off = run_command(cmd("cooling_tower"), { model = "abyss", own_fan = false })
    check(#off.bed.material.set_log == 0, "presets untouched when own_fan is off")
    check(#off.bed.gcodes == 499, "the fan ramp is still inserted")
    -- the model ships with the bundle, but a commercial repackaging may have
    -- removed it: the error still has to say what to do
    local _, _, err = run_command(cmd("cooling_tower"), { model = "abyss" }, { missing_assets = { [STL] = true } })
    check(err, "a missing model must fail")
    check(tostring(err):find(STL, 1, true), "the error names the path: " .. tostring(err))
    check(tostring(err):find("200347", 1, true), "the error names the Printables model: " .. tostring(err))
    check(not tostring(err):find("not in this bundle", 1, true), "and does not claim the model is unshipped: " .. tostring(err))
end)
test("7 infill overlap calibration", function()
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

test("8 shrink bar", function()
    local mock = run_command(cmd("shrink_bar"))
    local obj = generic_checks(mock)
    local holes = volumes_of(obj, VT.Negative, "cylinder")
    check(#holes == 2 and near(holes[1].translate.x, 10) and near(holes[2].translate.x, 140), "holes 130 mm apart")
    check(has_text(obj, "C 130 W 20 D 6"), "nominals engraved")
    check(parse_data(data_line(mock)).c0 == 130, "DATA")
end)

test("9 hole and fit gauge", function()
    local mock = run_command(cmd("hole_fit_gauge"))
    local obj = generic_checks(mock)
    local holes = volumes_of(obj, VT.Negative, "cylinder")
    check(#holes == 6 + 9, "six clearance holes and nine size holes: " .. #holes)
    check(near(holes[1].mesh.dims.max_x, 3) and near(holes[6].mesh.dims.max_x, 3.25), "clearance holes 6.0 to 6.5 mm")
    check(near(holes[7].mesh.dims.max_x, 1.5) and near(holes[15].mesh.dims.max_x, 10), "size holes 3 to 20 mm")
    local pins = volumes_of(obj, VT.Solid, "cylinder")
    check(#pins == 2 + 4, "two pins and four pegs")
    for _, pin in ipairs(pins) do check(pin.translate.x > obj.mesh.dims.max_x + 5, "loose pieces beside the plate") end
    check(has_text(obj, "+0.2") and has_text(obj, "20") and has_text(obj, "MK4S 0.4"), "labels")
    check(obj.object_params.perimeters == 3 and obj.object_params.fill_density == "100%", "solid, three perimeters")
    local d = parse_data(data_line(mock))
    check(d.step == "gauge" and d.clearances == "0,0.1,0.2,0.3,0.4,0.5" and d.hole_sizes == "3,4,5,6,8,10,12,15,20", "DATA")
    local mock2 = run_command(cmd("hole_fit_gauge"), { size_row = false, clearance_step = "0.25" })
    check(#volumes_of(single_object(mock2), VT.Negative, "cylinder") == 3 and #volumes_of(single_object(mock2), VT.Solid, "cylinder") == 2, "clearance row only")
    must_fail(cmd("hole_fit_gauge"), { min_clearance = "-0.1" }, "negative")
end)

test("10 small-feature tower", function()
    local mock = run_command(cmd("small_feature_tower"))
    local obj = generic_checks(mock)
    check(#volumes_of(obj, VT.Solid, "pyramid") == 1 and #volumes_of(obj, VT.Solid, "cone") == 1 and #volumes_of(obj, VT.Solid, "cylinder") == 3, "pyramid, cone, three pillars")
    for _, v in ipairs(obj.volumes) do if v.type == VT.Solid then check(near(v.translate.z, 2), "features stand on the plate") end end
    check(has_text(obj, "MK4S 0.4"), "tag")
    local d = parse_data(data_line(mock))
    check(d.step == "small" and d.slowdown == 20 and d.min_print_speed == 15, "DATA carries the preset's slowdown rules")
    check(#volumes_of(single_object(run_command(cmd("small_feature_tower"), { pillars = false })), VT.Solid, "cylinder") == 0, "pillars optional")
end)

test("11 reference coupon with wing and fins", function()
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

test("12 stringing tower", function()
    local mock = run_command(cmd("stringing_tower"))
    local obj = generic_checks(mock)
    local g = gcode_lines(mock)
    check(#g == 6 and g[1] == "M104 S250" and g[6] == "M104 S225", "250 down to 225 by 5")
    check(#volumes_of(obj, VT.Solid, "cube") == 2, "two pillars")
    local mock2 = run_command(cmd("stringing_tower"), { fan_start = 30, fan_step = 10 })
    check(gcode_lines(mock2)[1] == "M104 S250\nM106 S77", "temperature and fan in one entry")
    local mock3 = run_command(cmd("stringing_tower"), { interval = 0, sections = 4 })
    check(#gcode_lines(mock3) == 4 and gcode_lines(mock3)[4] == "M104 S250", "interval 0 means a constant temperature, sections from the count")
    check(parse_data(data_line(mock3)).constant == "true", "DATA marks the constant-temperature run")
    local mock4 = run_command(cmd("stringing_tower"), { by_interval = false, sections = 3 })
    check(table.concat(gcode_lines(mock4), " ") == "M104 S250 M104 S238 M104 S225", "by sections: " .. table.concat(gcode_lines(mock4), " "))
    must_fail(cmd("stringing_tower"), { fan_start = 60, fan_step = 10 }, "fan is out of range")
end)

test("13 apply results", function()
    local mock = run_command(cmd("apply_results"))
    check(#mock.objects == 0 and #mock.bed.material.set_log == 0, "defaults change nothing")
    local mock2 = run_command(cmd("apply_results"), { temperature = 245, extrusion_multiplier = "0,96", infill_overlap = "20%", pressure_advance = "0.045", min_print_speed = 10, solid_print_preset = true })
    local m = set_values(mock2.bed.material)
    check(m.temperature == 245 and near(m.extrusion_multiplier, 0.96) and set_values(mock2.bed.print).infill_overlap == "20%", "values written")
    check(near(m.pressure_advance_value, 0.045) and m.pressure_advance == "enabled", "pressure advance value written and mode enabled")
    check(m.min_print_speed == 10, "minimum print speed written")
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
    local expected_step = { nozzle_clean = "clean", temp_tower = "temp", cooling_tower = "cooling", flow_tower = "flow", pa_line = "pa", pa_tower = "pa", volumetric_tower = "vol", slab = "slab", overlap = "overlap",
        hole_fit_gauge = "gauge", small_feature_tower = "small",
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
