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
    max_len = max_len or 14
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

-- Uses the typed tag when present, otherwise derives one from the printer.
function M.resolve_tag(bed, typed_tag)
    if type(typed_tag) == "string" then
        local t = typed_tag:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then
            return t
        end
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
    local ok, err = pcall(function()
        box:set(key, value)
    end)
    if not ok then
        M.log("could not set " .. what .. ": " .. tostring(err))
        return false
    end
    local actual = M.read_number(box, key)
    if actual == nil then
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

-- Standard "make this object print solid" object params.
function M.solid_params()
    return {
        fill_density = "100%",
        fill_pattern = "rectilinear",
    }
end

return M
