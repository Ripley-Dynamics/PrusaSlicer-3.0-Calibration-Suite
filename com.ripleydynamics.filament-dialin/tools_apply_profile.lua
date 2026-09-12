info = {
    id = "apply_profile",
    type = "project.plugin",
    title = "Apply the dialed-in values from profile.lua",
    menu = "Filament Dial-In/Tools/Apply values from profile.lua",
    params = {
        { name = "material", label = "Write filament values (temperatures, multiplier, volumetric limit, fan, slowdown)", type = "bool", default = true },
        { name = "print_preset", label = "Write print values (infill overlap, 100% rectilinear infill)", type = "bool", default = true },
    },
}

-- profile.lua is written by the dial-in sheet (or the helper) into the bundle
-- folder. Keys per printer, all optional:
--   tag, temperature, first_layer_temperature, extrusion_multiplier,
--   filament_max_volumetric_speed, pressure_advance, min_fan_speed, max_fan_speed,
--   slowdown_below_layer_time, infill_overlap ("15%" or 0.1),
--   xy_size_compensation, elefant_foot_compensation (informational: per-object)

local MATERIAL_KEYS = {
    { "temperature", "nozzle temperature", "int" },
    { "first_layer_temperature", "first layer temperature", "int" },
    { "extrusion_multiplier", "extrusion multiplier", "number" },
    { "filament_max_volumetric_speed", "filament max volumetric speed", "number" },
    { "pressure_advance_value", "pressure advance value", "number" },
    { "min_fan_speed", "min fan speed", "int" },
    { "max_fan_speed", "max fan speed", "int" },
    { "slowdown_below_layer_time", "slowdown below layer time", "int" },
    { "min_print_speed", "minimum print speed", "number" },
}

function execute(opts)
    local util = require("lib/util")

    local bed = api.project:current_bed()
    local name = util.printer_name(bed)
    local entry = util.profile(bed)
    assert(entry, "profile.lua has no entry for printer '" .. name .. "'. Save the profile from the dial-in sheet first.")

    local changed, skipped = 0, {}
    local function apply(box, key, value, what, kind)
        if value == nil or value == "" then
            return
        end
        if kind == "int" then
            value = util.int(value, what)
        elseif kind == "number" then
            value = util.num(value, what)
        end
        if util.try_set(box, key, value, what) then
            changed = changed + 1
        end
    end

    if opts.material then
        local material = bed:material_presets(0)
        for _, k in ipairs(MATERIAL_KEYS) do
            apply(material, k[1], entry[k[1]], k[2], k[3])
        end
        if entry.pressure_advance ~= nil and entry.pressure_advance ~= "" then
            apply(material, "pressure_advance_value", entry.pressure_advance, "pressure advance value", "number")
            apply(material, "pressure_advance", "enabled", "pressure advance mode")
        end
    end
    if opts.print_preset then
        local print_cfg = bed:print_presets()
        if entry.infill_overlap ~= nil and entry.infill_overlap ~= "" then
            local v, pct = util.number_or_percent(entry.infill_overlap, "infill overlap")
            apply(print_cfg, "infill_overlap", pct and (util.fmt(v, 3) .. "%") or v, "infill overlap")
        end
        apply(print_cfg, "fill_density", "100%", "fill density")
        apply(print_cfg, "fill_pattern", "rectilinear", "fill pattern")
    end
    for _, k in ipairs({ "xy_size_compensation", "elefant_foot_compensation" }) do
        if entry[k] ~= nil then
            skipped[#skipped + 1] = k .. "=" .. tostring(entry[k])
        end
    end

    util.log(changed .. " preset value(s) written for " .. name .. " from profile.lua (tag " .. tostring(entry.tag or "?") .. ")")
    if #skipped > 0 then
        util.log("per-object values are not preset values, set them on the object or in the print preset's Advanced page: " .. table.concat(skipped, ", "))
    end
    util.log("the presets are modified but not saved: save the filament preset under a printer-specific name to keep them")
    util.data(bed, "apply_profile", { printer = name, tag = entry.tag or "", changed = changed })
end
