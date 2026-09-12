-- A stand-in for PrusaSlicer 3.0's `api` / `VolumeType` globals, faithful to the
-- alpha11 behaviour that matters for this bundle:
--   * primitives report all-zero bounds (the cached box is stale in alpha11),
--   * text meshes report real bounds, centred on the origin,
--   * ConfigBox:set silently ignores unknown keys and unsupported types,
--   * ConfigBox:value raises on unknown keys and returns an opaque value for
--     percentages / float-or-percent settings,
--   * custom G-code entries must be appended in ascending Z.
-- Everything a command does is recorded so tests can assert on it.

local Mock = {}

local function is_finite_number(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Mesh -----------------------------------------------------------------------
local Mesh = {}
Mesh.__index = Mesh
Mesh.__name = "Mesh"

local function new_mesh(kind, dims, bounds)
    return setmetatable({ kind = kind, dims = dims, b = bounds, shift = { 0, 0, 0 } }, Mesh)
end

function Mesh:translate(x, y, z)
    assert(is_finite_number(x) and is_finite_number(y) and is_finite_number(z), "Mesh:translate needs three numbers")
    self.shift[1] = self.shift[1] + x
    self.shift[2] = self.shift[2] + y
    self.shift[3] = self.shift[3] + z
    -- alpha11: bounds are NOT refreshed by translate. Keep the cached box.
end

function Mesh:bounds()
    local b = self.b
    return { min_x = b[1], min_y = b[2], min_z = b[3], max_x = b[4], max_y = b[5], max_z = b[6] }
end

-- True extents after translation, for geometry assertions in tests.
function Mesh:true_box()
    local d = self.dims
    local s = self.shift
    return {
        min_x = d.min_x + s[1], min_y = d.min_y + s[2], min_z = d.min_z + s[3],
        max_x = d.max_x + s[1], max_y = d.max_y + s[2], max_z = d.max_z + s[3],
    }
end

local ZERO = { 0, 0, 0, 0, 0, 0 }

local function positive(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        assert(is_finite_number(v) and v > 0, "primitive dimension " .. i .. " must be a positive finite number, got " .. tostring(v))
    end
end

-- Font -----------------------------------------------------------------------
local Font = {}
Font.__index = Font
Font.__name = "Font"
local default_font = setmetatable({ name = "Mock Sans" }, Font)

-- ConfigBox -------------------------------------------------------------------
local ConfigBox = {}
ConfigBox.__index = ConfigBox
ConfigBox.__name = "ConfigBox"

local Opaque = {}
Opaque.__name = "FloatOrPercentage"

local function new_box(label, defs)
    -- defs: key -> { kind = "double"|"int"|"percent"|"float_or_percent"|"enum"|"bool"|"string", value = ..., allowed = {...} }
    return setmetatable({ label = label, defs = defs, set_log = {} }, ConfigBox)
end

function ConfigBox:value(name)
    local d = self.defs[name]
    if not d then
        error("Invalid preset item name '" .. tostring(name) .. "': not found")
    end
    if d.kind == "percent" or d.kind == "float_or_percent" then
        return setmetatable({}, Opaque)
    end
    if d.kind == "vec2" then
        error("Unsupported config type")
    end
    return d.value
end

local function parse_pct(s)
    local body = s:match("^(.-)%%$")
    if body then
        return tonumber(body), true
    end
    return tonumber(s), false
end

function ConfigBox:set(name, value)
    local d = self.defs[name]
    if not d then
        return -- unknown key: silently ignored, exactly like alpha11
    end
    local kind = d.kind
    if kind == "double" then
        assert(type(value) == "number", self.label .. "." .. name .. ": double setter given " .. type(value))
        d.value = value
    elseif kind == "int" then
        assert(type(value) == "number", self.label .. "." .. name .. ": int setter given " .. type(value))
        local r = value >= 0 and math.floor(value + 0.5) or -math.floor(-value + 0.5)
        d.value = r
    elseif kind == "percent" then
        if type(value) == "string" then
            local v = parse_pct(value)
            assert(v, "bad percentage string " .. value)
            d.value = v
        else
            assert(type(value) == "number")
            d.value = value
        end
    elseif kind == "float_or_percent" then
        if type(value) == "string" then
            local v, is_pct = parse_pct(value)
            assert(v, "bad float-or-percent string " .. value)
            d.value = v
            d.is_percent = is_pct
        else
            assert(type(value) == "number")
            d.value = value
            d.is_percent = false
        end
    elseif kind == "enum" then
        assert(type(value) == "string", "enum setter needs a string")
        local ok = false
        for _, a in ipairs(d.allowed) do
            if a == value then ok = true end
        end
        if not ok then
            Mock.log("Unknown enum value " .. value .. " for " .. name)
            return
        end
        d.value = value
    else
        return -- bool / string / vector: unsupported, stored value unchanged
    end
    self.set_log[#self.set_log + 1] = { key = name, value = value }
end

-- Bed --------------------------------------------------------------------------
local Bed = {}
Bed.__index = Bed
Bed.__name = "BedInstRef"

function Bed:printer_config()
    return self.hw
end
function Bed:printer_presets()
    return self.printer
end
function Bed:print_presets()
    return self.print
end
function Bed:tool_print_presets(i)
    assert(i == 0, "tool index out of range")
    return self.tool
end
function Bed:material_presets(i)
    assert(i == 0, "material index out of range")
    return self.material
end

local function speed_defs()
    return {
        layer_height = { kind = "double", value = 0.2 },
        first_layer_height = { kind = "float_or_percent", value = 0.2 },
        fill_density = { kind = "percent", value = 15 },
        fill_pattern = { kind = "enum", value = "gyroid", allowed = { "rectilinear", "monotonic", "gyroid", "cubic", "grid" } },
        top_fill_pattern = { kind = "enum", value = "monotonic", allowed = { "rectilinear", "monotonic", "monotoniclines",
            "alignedrectilinear", "concentric", "hilbertcurve", "archimedeanchords", "octagramspiral" } },
        brim_type = { kind = "enum", value = "no_brim", allowed = { "no_brim", "outer_only", "inner_only", "outer_and_inner" } },
        brim_width = { kind = "double", value = 0 },
        perimeters = { kind = "int", value = 2 },
        top_solid_layers = { kind = "int", value = 5 },
        bottom_solid_layers = { kind = "int", value = 4 },
        infill_overlap = { kind = "float_or_percent", value = 25, is_percent = true },
        infill_speed = { kind = "double", value = 80 },
        solid_infill_speed = { kind = "float_or_percent", value = 80 },
        top_solid_infill_speed = { kind = "float_or_percent", value = 40 },
        perimeter_speed = { kind = "double", value = 60 },
        external_perimeter_speed = { kind = "float_or_percent", value = 30 },
        small_perimeter_speed = { kind = "float_or_percent", value = 25 },
        gap_fill_speed = { kind = "double", value = 40 },
        max_volumetric_speed = { kind = "double", value = 0 },
        xy_size_compensation = { kind = "double", value = 0 },
        elefant_foot_compensation = { kind = "double", value = 0.2 },
        extrusion_width = { kind = "float_or_percent", value = 0.45 },
        perimeter_extrusion_width = { kind = "float_or_percent", value = 0.45 },
        external_perimeter_extrusion_width = { kind = "float_or_percent", value = 0.45 },
        infill_extrusion_width = { kind = "float_or_percent", value = 0.45 },
        solid_infill_extrusion_width = { kind = "float_or_percent", value = 0.45 },
        top_infill_extrusion_width = { kind = "float_or_percent", value = 0.4 },
        thick_bridges = { kind = "bool", value = false },
        output_filename_format = { kind = "string", value = "x.gcode" },
    }
end

local function material_defs()
    return {
        temperature = { kind = "int", value = 250 },
        first_layer_temperature = { kind = "int", value = 240 },
        extrusion_multiplier = { kind = "double", value = 1.0 },
        filament_density = { kind = "double", value = 1.27 },
        pressure_advance = { kind = "enum", value = "disabled", allowed = { "disabled", "enabled", "automatic_calibration" } },
        pressure_advance_value = { kind = "double", value = 0 },
        filament_diameter = { kind = "double", value = 1.75 },
        filament_max_volumetric_speed = { kind = "double", value = 8 },
        slowdown_below_layer_time = { kind = "int", value = 20 },
        min_print_speed = { kind = "double", value = 15 },
        min_fan_speed = { kind = "int", value = 30 },
        max_fan_speed = { kind = "int", value = 50 },
        bridge_fan_speed = { kind = "int", value = 50 },
        overhang_fan_speed_0 = { kind = "int", value = 0 },
        overhang_fan_speed_1 = { kind = "int", value = 0 },
        overhang_fan_speed_2 = { kind = "int", value = 0 },
        overhang_fan_speed_3 = { kind = "int", value = 0 },
        fan_below_layer_time = { kind = "int", value = 100 },
        full_fan_speed_layer = { kind = "int", value = 5 },
        disable_fan_first_layers = { kind = "int", value = 3 },
        enable_dynamic_fan_speeds = { kind = "bool", value = true },
        cooling = { kind = "bool", value = true },
        fan_always_on = { kind = "bool", value = true },
        filament_notes = { kind = "string", value = "" },
    }
end

function Mock.new(options)
    options = options or {}
    local self = { objects = {}, log_lines = {} }
    local recorder = self

    local tool = {
        _features = { nozzle_diameter = options.no_nozzle and nil or (options.nozzle or 0.4), name = "nozzle" },
    }
    function tool:feature(name)
        return self._features[name]
    end
    function tool:nozzle_diameter()
        return self._features.nozzle_diameter
    end

    local bed = setmetatable({
        hw = { name = options.printer_name or "Original Prusa MK4S 0.4 nozzle", tool_count = 1, tools = { tool } },
        printer = new_box("printer", { nozzle_diameter = { kind = "vec2", value = 0.4 } }),
        print = new_box("print", speed_defs()),
        tool = new_box("tool_print", {}),
        material = new_box("material", material_defs()),
        gcodes = {},
        cleared = 0,
    }, Bed)
    if options.layer_height then
        bed.print.defs.layer_height.value = options.layer_height
    end
    self.bed = bed

    function Mock.log(line)
        self.log_lines[#self.log_lines + 1] = line
    end

    local api = {}

    function api.make_cube(w, h, d)
        positive(w, h, d)
        return new_mesh("cube", { min_x = 0, min_y = 0, min_z = 0, max_x = w, max_y = h, max_z = d }, ZERO)
    end
    function api.make_cylinder(r, h, fa)
        positive(r, h)
        assert(fa == nil or fa > 0, "facet angle must be positive")
        return new_mesh("cylinder", { min_x = -r, min_y = -r, min_z = 0, max_x = r, max_y = r, max_z = h }, ZERO)
    end
    function api.make_sphere(r, fa)
        positive(r)
        return new_mesh("sphere", { min_x = -r, min_y = -r, min_z = -r, max_x = r, max_y = r, max_z = r }, ZERO)
    end
    function api.make_cone(r, h, fa)
        positive(r, h)
        return new_mesh("cone", { min_x = -r, min_y = -r, min_z = 0, max_x = r, max_y = r, max_z = h }, ZERO)
    end
    function api.make_prism(w, l, h)
        positive(w, l, h)
        return new_mesh("prism", { min_x = -w / 2, min_y = -l / 2, min_z = 0, max_x = w / 2, max_y = l / 2, max_z = h }, ZERO)
    end
    function api.make_pyramid(b, h)
        positive(b, h)
        return new_mesh("pyramid", { min_x = -b / 2, min_y = -b / 2, min_z = 0, max_x = b / 2, max_y = b / 2, max_z = h }, ZERO)
    end
    function api.make_torus(R, r)
        positive(R, r)
        return new_mesh("torus", { min_x = -R - r, min_y = -R - r, min_z = -r, max_x = R + r, max_y = R + r, max_z = r }, ZERO)
    end
    -- Assets: bounds measured from the real files shipped in assets/, the fan
    -- test model included. `missing_assets` simulates a file that is absent
    -- (someone removed the CC BY-NC model, say).
    local ASSETS = {
        ["assets/prusa/temp_tower-base.stl"] = { min_x = -40, min_y = -5, min_z = -1, max_x = 40, max_y = 5, max_z = 0 },
        ["assets/prusa/temp_tower-step.stl"] = { min_x = -40, min_y = -5, min_z = 0, max_x = 40, max_y = 5.5, max_z = 10 },
        ["assets/fan/ultimate-fan-test-v3.stl"] = { min_x = -21.0, min_y = -12, min_z = 0, max_x = 67.46, max_y = 12, max_z = 99.98 },
    }
    local MISSING = options.missing_assets or {}
    local function check_path(path)
        assert(type(path) == "string", "asset path must be a string")
        assert(not path:find("%.%.") and path:sub(1, 1) ~= "/", "asset path escapes the sandbox: " .. path)
    end
    function api.load_stl(path)
        check_path(path)
        local b = ASSETS[path]
        if MISSING[path] or not b then error("Cannot safely load file: " .. path) end
        -- Loaded assets carry valid bounds (unlike primitives).
        return new_mesh("stl", b, { b.min_x, b.min_y, b.min_z, b.max_x, b.max_y, b.max_z })
    end
    function api.emboss_svg(path, depth)
        check_path(path)
        assert(is_finite_number(depth) and depth > 0, "emboss_svg depth must be positive")
        if path ~= "assets/prusa/hreben.svg" then
            return new_mesh("svg", { min_x = 0, min_y = 0, min_z = 0, max_x = 0, max_y = 0, max_z = 0 }, ZERO)
        end
        -- The comb path spans x 20..180 and y 50..150 in a 200 mm viewBox.
        local b = { min_x = 20, min_y = 50, min_z = 0, max_x = 180, max_y = 150, max_z = depth }
        return new_mesh("svg", b, { b.min_x, b.min_y, b.min_z, b.max_x, b.max_y, b.max_z })
    end

    function api.fonts()
        return { default_font }
    end
    function api.get_default_font()
        return default_font
    end
    function api.get_font(sub)
        assert(type(sub) == "string")
        return default_font
    end

    function api.emboss_text(o)
        assert(type(o) == "table", "emboss_text needs a table")
        assert(getmetatable(o.font) == Font, "emboss_text: font must come from api.get_font/get_default_font")
        assert(type(o.text) == "string", "emboss_text: text must be a string")
        local lh = o.line_height or 10
        assert(is_finite_number(lh) and lh > 0, "emboss_text: line_height must be positive")
        if o.text == "" then
            return new_mesh("text", { min_x = 0, min_y = 0, min_z = 0, max_x = 0, max_y = 0, max_z = 0 }, ZERO)
        end
        -- Rough glyph metrics: width ~0.62 em per char, cap height ~0.72 em, centred on the origin.
        local w = 0.62 * lh * #o.text
        local h = 0.72 * lh
        local m = new_mesh("text", { min_x = -w / 2, min_y = -h / 2, min_z = 0, max_x = w / 2, max_y = h / 2, max_z = 1 },
            { -w / 2, -h / 2, 0, w / 2, h / 2, 1 })
        m.text = o.text
        m.line_height = lh
        return m
    end

    local project = {}
    function project:current_bed()
        return bed
    end
    function project:clear_layer_custom_steps(b)
        assert(b == bed, "clear_layer_custom_steps: invalid bed reference")
        bed.gcodes = {}
        bed.cleared = bed.cleared + 1
    end
    function project:insert_layer_custom_gcode(b, z, gcode)
        assert(b == bed, "insert_layer_custom_gcode: invalid bed reference")
        assert(is_finite_number(z) and z > 0, "insert_layer_custom_gcode: z must be positive")
        assert(type(gcode) == "string" and gcode ~= "", "insert_layer_custom_gcode: gcode must be a non-empty string")
        local last = bed.gcodes[#bed.gcodes]
        assert(not last or z > last.z, "custom G-code must be inserted in ascending Z order")
        bed.gcodes[#bed.gcodes + 1] = { z = z, gcode = gcode }
    end

    local function check_xyz(t, what)
        if t == nil then return end
        assert(type(t) == "table", what .. " must be a table")
        for k, v in pairs(t) do
            assert(k == "x" or k == "y" or k == "z", what .. " has unknown axis " .. tostring(k))
            assert(is_finite_number(v), what .. "." .. k .. " must be a finite number")
        end
    end

    local function check_params(p, what)
        if p == nil then return end
        assert(type(p) == "table", what .. " must be a table")
        for k, v in pairs(p) do
            assert(type(k) == "string", what .. " keys must be strings")
            local tv = type(v)
            assert(tv == "number" or tv == "string", what .. "." .. k .. " must be a number or string, got " .. tv)
        end
    end

    function project:add_object(def)
        assert(type(def) == "table", "add_object needs a definition table")
        assert(getmetatable(def.mesh) == Mesh, "add_object: mesh must be a Mesh")
        check_xyz(def.translate, "translate")
        check_xyz(def.rotate, "rotate")
        check_params(def.params, "params")
        check_params(def.object_params, "object_params")
        local vols = {}
        if def.other_volumes ~= nil then
            assert(type(def.other_volumes) == "table", "other_volumes must be a list")
            for i, v in ipairs(def.other_volumes) do
                assert(type(v) == "table", "volume " .. i .. " must be a table")
                assert(getmetatable(v.mesh) == Mesh, "volume " .. i .. ": mesh must be a Mesh")
                check_xyz(v.translate, "volume " .. i .. " translate")
                check_xyz(v.rotate, "volume " .. i .. " rotate")
                check_params(v.params, "volume " .. i .. " params")
                local vtype = v.type
                if vtype == nil then
                    vtype = v.params ~= nil and Mock.VolumeType.Modifier or Mock.VolumeType.Solid
                end
                assert(Mock.VolumeTypeName[vtype], "volume " .. i .. ": unknown VolumeType")
                assert(vtype ~= Mock.VolumeType.Invalid, "volume " .. i .. ": VolumeType.Invalid")
                vols[#vols + 1] = { mesh = v.mesh, type = vtype, translate = v.translate or {}, rotate = v.rotate or {}, params = v.params }
            end
        end
        recorder.objects[#recorder.objects + 1] = {
            mesh = def.mesh,
            translate = def.translate or {},
            rotate = def.rotate or {},
            params = def.params,
            object_params = def.object_params,
            volumes = vols,
        }
        return { type = 1 }
    end

    api.project = project
    self.api = api
    self.VolumeType = Mock.VolumeType
    return self
end

Mock.VolumeType = { Invalid = 0, Solid = 1, Negative = 2, Modifier = 3, SupportBlocker = 4, SupportEnforcer = 5 }
Mock.VolumeTypeName = {}
for k, v in pairs(Mock.VolumeType) do
    Mock.VolumeTypeName[v] = k
end
Mock.Mesh = Mesh

return Mock
