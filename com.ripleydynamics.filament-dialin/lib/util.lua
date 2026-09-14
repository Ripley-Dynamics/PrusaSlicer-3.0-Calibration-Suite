-- Shared helpers for the Filament Dial-In bundle.
-- Discovery-safe: this file only declares functions. Nothing here touches `api`
-- at load time.

local M = {}

M.LOG_PREFIX = "[filament-dialin] "

function M.log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    print(M.LOG_PREFIX .. table.concat(parts, " "))
end

-- PrusaSlicer 3.0.0-alpha11 wires the `int` and `float` dialog controls in
-- reverse: an `int` field may hand execute() a decimal, and a `float` field
-- rounds to a whole number. Every numeric option in this bundle is therefore
-- coerced here instead of trusted, and options where decimals matter (0.95,
-- -0.05, "17.5%") are declared as `string` and parsed with M.decimal().

local function clean_string(v)
    local s = tostring(v)
    s = s:gsub("%s", "")
    s = s:gsub(",", ".")
    return s
end

-- Coerces a dialog value to a number. Blank strings fall back to `default`.
function M.num(v, name, default)
    if v == nil or v == "" then
        v = default
    end
    if type(v) == "string" then
        v = clean_string(v)
    end
    local n = tonumber(v)
    assert(n ~= nil, (name or "value") .. " must be a number, got '" .. tostring(v) .. "'")
    assert(n == n and n ~= math.huge and n ~= -math.huge, (name or "value") .. " must be finite")
    return n
end

-- Coerces a dialog value to a whole number (Lua integer).
function M.int(v, name, default)
    local n = M.num(v, name, default)
    return math.floor(n + 0.5)
end

-- Parses a decimal typed as text. Returns nil for a blank field (meaning
-- "leave this setting alone").
function M.decimal(v, name)
    if v == nil then
        return nil
    end
    if type(v) == "number" then
        return v
    end
    local s = clean_string(v)
    if s == "" then
        return nil
    end
    return M.num(s, name)
end

-- Parses "17.5%" -> 17.5, true and "0.45" -> 0.45, false. Blank -> nil.
function M.number_or_percent(v, name)
    if v == nil then
        return nil, false
    end
    if type(v) == "number" then
        return v, false
    end
    local s = clean_string(v)
    if s == "" then
        return nil, false
    end
    local body = s:match("^(.-)%%$")
    if body then
        return M.num(body, name), true
    end
    return M.num(s, name), false
end

-- Lua integers serialize as "250"; floats as "250.0". Settings declared as
-- integers in PrusaSlicer are safest when handed an actual integer.
function M.whole(n)
    if type(n) == "number" and n == math.floor(n) then
        return math.tointeger(n) or n
    end
    return n
end

-- Formats a number with up to `decimals` places and no trailing zeros.
function M.fmt(n, decimals)
    decimals = decimals or 2
    local s = string.format("%." .. decimals .. "f", n)
    if s:find("%.") then
        s = s:gsub("0+$", "")
        s = s:gsub("%.$", "")
    end
    if s == "-0" then
        s = "0"
    end
    return s
end

-- Rounds `v` to the nearest multiple of `step`, never below `min_steps` steps.
function M.align(v, step, min_steps)
    min_steps = min_steps or 1
    local k = math.floor(v / step + 0.5)
    if k < min_steps then
        k = min_steps
    end
    return k * step
end

-- Cross-section area of one extrusion line (PrusaSlicer's rounded-rectangle
-- model): a stadium of width w and height h.
function M.extrusion_area(width, height)
    return (width - height) * height + math.pi * (height / 2) ^ 2
end

-- Volumetric flow (mm^3/s) -> feed rate (mm/s) for a given line geometry.
function M.flow_to_speed(flow, width, height)
    return flow / M.extrusion_area(width, height)
end

-- Fan percentage -> M106 S value.
function M.fan_pwm(percent)
    local p = math.max(0, math.min(100, percent))
    return math.floor(p * 255 / 100 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Printer and preset readers. All wrapped in pcall so a missing feature or an
-- opaque value never aborts a command after it has started changing things.
-- ---------------------------------------------------------------------------

function M.printer_name(bed)
    local ok, name = pcall(function()
        return bed:printer_config().name
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return "unknown printer"
end

-- "Original Prusa MK4S 0.4 nozzle" -> "MK4S 0.4". Meant to fit on a coupon.
function M.short_printer_tag(name, max_len)
    max_len = max_len or 18
    local s = name
    s = s:gsub("^Original Prusa ", "")
    s = s:gsub("^Prusa ", "")
    s = s:gsub(" nozzle", "")
    s = s:gsub(" Input Shaper", " IS")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s", ""):gsub("%s$", "")
    if #s > max_len then
        s = s:sub(1, max_len)
    end
    if s == "" then
        s = "printer"
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Machine-readable output. The dial-in helper (helper/dialin_helper.py)
-- reads PrusaSlicer's stdout and forwards lines that start with the prefix
-- below to the dial-in sheet. Values are key=value pairs: numbers bare,
-- strings double-quoted with \" and \\ escaped, booleans true/false.
-- ---------------------------------------------------------------------------

local function encode_value(v)
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return tostring(math.tointeger(v) or v)
        end
        return string.format("%.6g", v)
    elseif t == "boolean" then
        return v and "true" or "false"
    else
        local s = tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ")
        return '"' .. s .. '"'
    end
end

-- Preset values every DATA line carries, so the sheet can tell when the
-- printer, layer height or profile changed between steps.
M.BASELINE_KEYS = {
    { "print", "layer_height", "layer_height" },
    { "print", "perimeters", "p_perimeters" },
    { "print", "top_solid_layers", "p_top_solid_layers" },
    { "print", "bottom_solid_layers", "p_bottom_solid_layers" },
    { "print", "perimeter_speed", "p_perimeter_speed" },
    { "print", "infill_speed", "p_infill_speed" },
    { "material", "temperature", "p_temperature" },
    { "material", "first_layer_temperature", "p_first_layer_temperature" },
    { "material", "extrusion_multiplier", "p_extrusion_multiplier" },
    { "material", "filament_max_volumetric_speed", "p_max_volumetric_speed" },
    { "material", "filament_density", "p_density" },
    { "material", "pressure_advance_value", "p_pressure_advance" },
    { "material", "min_fan_speed", "p_min_fan" },
    { "material", "max_fan_speed", "p_max_fan" },
    { "material", "slowdown_below_layer_time", "p_slowdown" },
}

function M.baseline(bed)
    local out = { printer = M.printer_name(bed), nozzle = M.nozzle(bed) }
    local ok_p, print_cfg = pcall(function() return bed:print_presets() end)
    local ok_m, material = pcall(function() return bed:material_presets(0) end)
    for _, k in ipairs(M.BASELINE_KEYS) do
        local box = (k[1] == "print") and (ok_p and print_cfg) or (ok_m and material)
        if box then
            local v = M.read_number(box, k[2])
            if v ~= nil then
                out[k[3]] = v
            end
        end
    end
    if out.layer_height == nil then
        out.layer_height = M.layer_height(bed)
    end
    -- profile.lua may record the layer height and nozzle the earlier steps used.
    local entry = M.profile(bed)
    if entry then
        local mismatch = {}
        if type(entry.layer_height) == "number" and math.abs(entry.layer_height - out.layer_height) > 1e-6 then
            mismatch[#mismatch + 1] = string.format("layer height %s (profile) vs %s (now)", M.fmt(entry.layer_height, 3), M.fmt(out.layer_height, 3))
        end
        if type(entry.nozzle) == "number" and math.abs(entry.nozzle - out.nozzle) > 1e-6 then
            mismatch[#mismatch + 1] = string.format("nozzle %s (profile) vs %s (now)", M.fmt(entry.nozzle, 2), M.fmt(out.nozzle, 2))
        end
        if #mismatch > 0 then
            out.baseline_mismatch = table.concat(mismatch, "; ")
            M.log("WARNING: this print does not match the earlier steps: " .. out.baseline_mismatch .. ". Change one variable at a time.")
        end
    end
    return out
end

function M.data(bed, step, fields)
    fields = M.merge(M.baseline(bed), fields)
    local keys = {}
    for k in pairs(fields) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = { "step=" .. encode_value(step) }
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. encode_value(fields[k])
    end
    print(M.LOG_PREFIX .. "DATA " .. table.concat(parts, " "))
end

-- ---------------------------------------------------------------------------
-- profile.lua: optional file at the bundle root, written by the dial-in
-- sheet. It returns a table keyed by printer name (as PrusaSlicer shows it)
-- with the tag and the dialed-in values for that printer.
-- ---------------------------------------------------------------------------

function M.load_profiles()
    local ok, profiles = pcall(require, "profile")
    if ok and type(profiles) == "table" then
        return profiles
    end
    return {}
end

-- The profile entry for the selected printer, or nil.
function M.profile(bed)
    local name = M.printer_name(bed)
    local profiles = M.load_profiles()
    local entry = profiles[name]
    if entry == nil then
        for key, value in pairs(profiles) do
            if type(key) == "string" and type(value) == "table" and key:lower() == name:lower() then
                entry = value
                break
            end
        end
    end
    if type(entry) == "table" then
        return entry
    end
    return nil
end

-- Uses the typed tag when present, then the profile's tag, then one derived
-- from the printer name.
function M.resolve_tag(bed, typed_tag)
    if type(typed_tag) == "string" then
        local t = typed_tag:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then
            return t
        end
    end
    local entry = M.profile(bed)
    if entry and type(entry.tag) == "string" and entry.tag ~= "" then
        return entry.tag
    end
    return M.short_printer_tag(M.printer_name(bed))
end

function M.nozzle(bed)
    local ok, d = pcall(function()
        return bed:printer_config().tools[1]:nozzle_diameter()
    end)
    if ok and type(d) == "number" and d > 0 then
        return d
    end
    return 0.4
end

-- Reads a preset value and returns it only when it is a plain number.
function M.read_number(box, key)
    local ok, v = pcall(function()
        return box:value(key)
    end)
    if ok and type(v) == "number" then
        return v
    end
    return nil
end

-- Reads a preset value and returns it only when it is a boolean.
function M.read_bool(box, key)
    local ok, v = pcall(function()
        return box:value(key)
    end)
    if ok and type(v) == "boolean" then
        return v
    end
    return nil
end

-- true / false when the printer preset says whether E moves are relative
-- (use_relative_e_distances), nil when it cannot be read. Every command that
-- writes its own G1 E moves sizes them as deltas (M83); on an absolute-E
-- profile they would become metre-long retractions, so callers assert on false.
function M.relative_e(bed)
    local ok, box = pcall(function()
        return bed:printer_presets()
    end)
    if ok and box then
        return M.read_bool(box, "use_relative_e_distances")
    end
    return nil
end

-- Asserts that the printer profile uses relative E; logs when it cannot tell.
function M.require_relative_e(bed, what)
    local rel = M.relative_e(bed)
    assert(rel ~= false, (what or "This command") .. " writes relative E moves (M83), but the printer profile has 'Use relative E distances' off. Turn it on in Printer Settings > General > Advanced, or the G-code would become a huge retraction.")
    if rel == nil then
        M.log("WARNING: could not read use_relative_e_distances from the printer profile; " .. (what or "this command") .. " needs relative E (M83)")
    end
    return rel
end

function M.layer_height(bed)
    local ok, box = pcall(function()
        return bed:print_presets()
    end)
    if ok and box then
        local lh = M.read_number(box, "layer_height")
        if lh and lh > 0 then
            return lh
        end
    end
    return M.nozzle(bed) * 0.5
end

-- Sets a preset value, reads it back when it is readable, and logs the
-- outcome. Returns true when the write is confirmed or unverifiable, false
-- when the read-back disagrees.
function M.try_set(box, key, value, what)
    what = what or key
    -- The setter silently ignores a key the preset does not have, so probe the
    -- key first: the getter raises "Invalid preset item name ... not found" for
    -- an unknown key (a known key with an opaque type raises something else,
    -- and that is fine).
    local probe_ok, probe_err = pcall(function()
        return box:value(key)
    end)
    if not probe_ok and tostring(probe_err):find("not found", 1, true) then
        M.log("WARNING: NOT written, this preset has no setting '" .. key .. "' (" .. what .. ")")
        return false
    end
    local before = probe_ok and probe_err or nil
    local ok, err = pcall(function()
        box:set(key, value)
    end)
    if not ok then
        M.log("could not set " .. what .. ": " .. tostring(err))
        return false
    end
    local actual = M.read_number(box, key)
    if actual == nil then
        -- Enums come back as strings: compare those directly.
        local ok_s, now = pcall(function() return box:value(key) end)
        if ok_s and type(now) == "string" then
            if now == tostring(value) then
                M.log("set " .. what .. " = " .. now)
                return true
            end
            M.log("WARNING: NOT written, " .. what .. " is still '" .. now .. "' after setting '" .. tostring(value) .. "' (not an allowed value?)")
            return false
        end
        M.log("set " .. what .. " = " .. tostring(value) .. " (not readable back, unverified)")
        return true
    end
    local target = tonumber((tostring(value):gsub("%%$", "")))
    if target and math.abs(actual - target) > 1e-6 then
        M.log("WARNING: " .. what .. " read back as " .. tostring(actual) .. " after setting " .. tostring(value))
        return false
    end
    M.log("set " .. what .. " = " .. tostring(actual))
    return true
end

-- Object/volume params must be a fresh table per call (PrusaSlicer iterates it).
function M.merge(...)
    local out = {}
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if t then
            for k, v in pairs(t) do
                out[k] = v
            end
        end
    end
    return out
end

-- Series of values between min and max, chosen either by interval or by
-- number of steps. Returns the list (ascending) and the effective interval.
--   o.min, o.max        bounds (inclusive when the interval divides evenly)
--   o.by_interval       true: use o.interval; false: use o.count
--   o.interval, o.count
--   o.integer           round every value to a whole number
--   o.max_count         safety cap (default 30)
function M.range(o)
    local lo, hi = M.num(o.min, "minimum"), M.num(o.max, "maximum")
    assert(hi > lo, "Maximum must be greater than minimum")
    local values, interval = {}, nil
    if o.by_interval then
        interval = M.num(o.interval, "interval")
        assert(interval > 0, "Interval must be positive")
        local n = math.floor((hi - lo) / interval + 1e-9) + 1
        assert(n >= 2, "The interval must fit at least twice between minimum and maximum")
        assert(n <= (o.max_count or 30), "Too many steps (" .. n .. "); use a larger interval")
        for i = 1, n do
            values[i] = lo + (i - 1) * interval
        end
    else
        local n = M.int(o.count, "number of steps")
        assert(n >= 2 and n <= (o.max_count or 30), "Number of steps must be between 2 and " .. (o.max_count or 30))
        interval = (hi - lo) / (n - 1)
        for i = 1, n do
            values[i] = lo + (i - 1) * interval
        end
    end
    if o.integer then
        for i, v in ipairs(values) do
            values[i] = math.floor(v + 0.5)
        end
    else
        for i, v in ipairs(values) do
            values[i] = math.floor(v * 1000 + 0.5) / 1000
        end
    end
    return values, interval
end

function M.join(values, decimals)
    local parts = {}
    for i, v in ipairs(values) do
        parts[i] = M.fmt(v, decimals or 2)
    end
    return table.concat(parts, ",")
end

-- Standard "make this object print solid" object params.
function M.solid_params()
    return {
        fill_density = "100%",
        fill_pattern = "rectilinear",
    }
end

return M
