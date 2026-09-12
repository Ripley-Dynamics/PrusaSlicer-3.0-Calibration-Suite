info = {
    id = "apply_results",
    type = "project.plugin",
    title = "Apply dialed-in values to the selected presets",
    menu = "Filament Dial-In/10. Apply dialed-in values",
    params = {
        { name = "temperature", label = "Nozzle temperature [C] (0 = keep)", type = "int", default = 0 },
        { name = "first_layer_temperature", label = "First layer temperature [C] (0 = keep)", type = "int", default = 0 },
        { name = "extrusion_multiplier", label = "Extrusion multiplier (e.g. 0.96, blank = keep)", type = "string", default = "" },
        { name = "max_volumetric_speed", label = "Filament max volumetric speed [mm3/s] (blank = keep)", type = "string", default = "" },
        { name = "pressure_advance", label = "Pressure advance (e.g. 0.045, blank = keep; sets the filament's PA mode to enabled)", type = "string", default = "" },
        { name = "infill_overlap", label = "Infill/perimeter overlap (e.g. 20% or 0.1, blank = keep)", type = "string", default = "" },
        { name = "min_fan", label = "Min fan [%] (-1 = keep)", type = "int", default = -1 },
        { name = "max_fan", label = "Max fan [%] (-1 = keep)", type = "int", default = -1 },
        { name = "slowdown_below_layer_time", label = "Slow down below layer time [s] (-1 = keep)", type = "int", default = -1 },
        { name = "solid_print_preset", label = "Also set print preset to 100% rectilinear infill", type = "bool", default = false },
    },
}

function execute(opts)
    local util = require("lib/util")

    local bed = api.project:current_bed()
    local material = bed:material_presets(0)
    local print_cfg = bed:print_presets()

    local temp = util.int(opts.temperature, "temperature", 0)
    local first_temp = util.int(opts.first_layer_temperature, "first layer temperature", 0)
    local em = util.decimal(opts.extrusion_multiplier, "extrusion multiplier")
    local mvs = util.decimal(opts.max_volumetric_speed, "max volumetric speed")
    local pa = util.decimal(opts.pressure_advance, "pressure advance")
    local overlap, overlap_pct = util.number_or_percent(opts.infill_overlap, "infill overlap")
    local min_fan = util.int(opts.min_fan, "min fan", -1)
    local max_fan = util.int(opts.max_fan, "max fan", -1)
    local slowdown = util.int(opts.slowdown_below_layer_time, "slowdown below layer time", -1)

    -- Validate everything first: preset edits are not rolled back on error.
    assert(temp == 0 or (temp >= 150 and temp <= 350), "Nozzle temperature out of range")
    assert(first_temp == 0 or (first_temp >= 150 and first_temp <= 350), "First layer temperature out of range")
    assert(em == nil or (em > 0.5 and em < 1.5), "Extrusion multiplier must be between 0.5 and 1.5")
    assert(mvs == nil or mvs >= 0, "Max volumetric speed must be 0 (unlimited) or positive")
    assert(pa == nil or (pa >= 0 and pa <= 2), "Pressure advance must be between 0 and 2")
    assert(overlap == nil or overlap >= 0, "Infill overlap must be zero or positive")
    assert(min_fan == -1 or (min_fan >= 0 and min_fan <= 100), "Min fan must be 0-100")
    assert(max_fan == -1 or (max_fan >= 0 and max_fan <= 100), "Max fan must be 0-100")
    assert(slowdown == -1 or slowdown >= 0, "Slowdown time must be zero or positive")

    local changed = 0
    local function apply(box, key, value, what)
        if util.try_set(box, key, value, what) then
            changed = changed + 1
        end
    end

    if temp > 0 then apply(material, "temperature", temp, "nozzle temperature") end
    if first_temp > 0 then apply(material, "first_layer_temperature", first_temp, "first layer temperature") end
    if em ~= nil then apply(material, "extrusion_multiplier", em, "extrusion multiplier") end
    if mvs ~= nil then apply(material, "filament_max_volumetric_speed", mvs, "filament max volumetric speed") end
    if pa ~= nil then
        apply(material, "pressure_advance_value", pa, "pressure advance value")
        apply(material, "pressure_advance", "enabled", "pressure advance mode")
    end
    if min_fan >= 0 then apply(material, "min_fan_speed", min_fan, "min fan speed") end
    if max_fan >= 0 then apply(material, "max_fan_speed", max_fan, "max fan speed") end
    if slowdown >= 0 then apply(material, "slowdown_below_layer_time", slowdown, "slowdown below layer time") end
    if overlap ~= nil then
        apply(print_cfg, "infill_overlap", overlap_pct and (util.fmt(overlap, 3) .. "%") or overlap, "infill overlap")
    end
    if opts.solid_print_preset then
        apply(print_cfg, "fill_density", "100%", "fill density")
        apply(print_cfg, "fill_pattern", "rectilinear", "fill pattern")
    end

    util.log(changed .. " preset value(s) written to the selected presets for " .. util.printer_name(bed))
    util.log("the presets are modified but not saved: save the filament preset under a printer-specific name to keep them")
    util.data(bed, "apply", { printer = util.printer_name(bed), tag = util.resolve_tag(bed, ""), changed = changed })
end
