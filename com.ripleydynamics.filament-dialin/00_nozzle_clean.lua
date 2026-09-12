info = {
    id = "nozzle_clean",
    type = "project.plugin",
    title = "Nozzle clean: hot purge with cleaning filament, cold pull, reload test filament",
    menu = "Filament Dial-In/0. Nozzle clean before testing",
    params = {
        { name = "clean_temp", label = "Purge temperature [C] (Prusa's guide: 260 for PLA residue, 280 for PETG/ASA residue)", type = "int", default = 270 },
        { name = "cleaning_filament", label = "Cleaning filament (named in the printer's prompts)", type = "string", default = "Nylon" },
        { name = "purge_mm", label = "Purge length [mm] (extruded in 20 mm chunks)", type = "int", default = 100 },
        { name = "pull_temp", label = "Cold pull temperature [C] (Prusa's manual cold pull pulls at 100)", type = "int", default = 100 },
        { name = "firmware", label = "Firmware: prusa (M601), marlin (M0), klipper (PAUSE), reprap (M226)", type = "string", default = "prusa" },
    },
}

-- Step 0, before any measurement: a nozzle that still holds the last
-- material's residue drags it into every test print. This is Prusa's manual
-- routine (hot purge with a cleaning filament, then a cold pull) written as
-- one custom per-layer G-code entry on the first layer of a small anchor
-- plate, so the printer walks through it with its own prompts:
--   heat, M600 to swap to the cleaning filament, purge it through,
--   cool to the cold-pull temperature, pause while the filament is pulled out,
--   heat back to the print temperature, M600 to load the test filament, purge.
--
-- The plugin API cannot pause or prompt by itself; everything here is the
-- firmware's own filament change (M600) and its pause command, which the user
-- resumes from the printer. Relative extrusion (M83, the Prusa default) is
-- assumed for the purge moves.

local PLATE, PLATE_H = 20, 1
local CHUNK, PURGE_FEED = 20, 150
local RELOAD_PURGE = 40

-- pause: %s is filled with the on-screen message where the command carries one.
-- cool: waits for the nozzle to come DOWN to the given temperature.
local FIRMWARE = {
    prusa = { pause = "M601", cool = "M109 R%d" },
    marlin = { pause = "M0 %s", cool = "M109 R%d" },
    klipper = { pause = "PAUSE", cool = "TEMPERATURE_WAIT SENSOR=extruder MAXIMUM=%d" },
    reprap = { pause = "M226", cool = "M109 R%d" },
}

local function clean_text(value, fallback)
    local s = tostring(value or ""):gsub("[\r\n;]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return fallback
    end
    return s
end

function execute(opts)
    local util = require("lib/util")
    local tower = require("lib/tower")

    local firmware = tostring(opts.firmware or "prusa"):lower():gsub("%s", "")
    local fw = FIRMWARE[firmware]
    assert(fw, "Firmware must be one of prusa, marlin, klipper, reprap")
    local clean_temp = util.int(opts.clean_temp, "purge temperature", 270)
    local pull_temp = util.int(opts.pull_temp, "cold pull temperature", 100)
    local purge_mm = util.int(opts.purge_mm, "purge length", 100)
    local cleaning = clean_text(opts.cleaning_filament, "cleaning filament")
    assert(clean_temp >= 150 and clean_temp <= 300, "Purge temperature must be between 150 and 300 C")
    assert(pull_temp >= 60 and pull_temp <= 160, "Cold pull temperature must be between 60 and 160 C")
    assert(purge_mm >= 20 and purge_mm <= 300, "Purge length must be between 20 and 300 mm")

    local bed = api.project:current_bed()
    local lh = util.layer_height(bed)
    local tag = util.resolve_tag(bed, nil)
    -- Back to the material preset's print temperature for the test filament.
    local reload_temp = util.read_number(bed:material_presets(0), "temperature") or clean_temp
    reload_temp = math.floor(reload_temp + 0.5)
    if reload_temp < 150 or reload_temp > 300 then
        reload_temp = clean_temp
    end

    local g = { "; filament-dialin step 0: nozzle clean (relative extrusion assumed)" }
    local function emit(line, comment)
        g[#g + 1] = line .. " ; " .. comment
    end
    local function message(text, comment)
        emit("M117 " .. text, comment)
    end
    local function pause(text, comment)
        emit(fw.pause:find("%%s") and string.format(fw.pause, text) or fw.pause, comment)
    end
    local function purge(total, what)
        local left, moves = total, 0
        while left > 0.01 do
            local chunk = math.min(CHUNK, left)
            moves = moves + 1
            emit(string.format("G1 E%s F%d", util.fmt(chunk, 2), PURGE_FEED),
                string.format("%s, move %d, %s mm of %s mm", what, moves, util.fmt(chunk, 2), util.fmt(total, 2)))
            left = left - chunk
        end
        return moves
    end

    message("Step 0 nozzle clean", "say what this print is")
    emit("M104 S" .. clean_temp, "start heating to the purge temperature")
    emit("M109 S" .. clean_temp, "wait until it is hot")
    message("Insert " .. cleaning .. " when asked", "the printer asks for it on the next line")
    emit("M600", "the firmware's own filament change: unloads the test filament, prompts for the new one")
    local purge_moves = purge(purge_mm, "purge the cleaning filament through")
    message("Cooling for cold pull", "the pull happens cold, not hot")
    emit("M104 S" .. pull_temp, "cool down to the cold-pull temperature")
    emit(string.format(fw.cool, pull_temp), "wait for the nozzle to come DOWN to it")
    message("Pull the filament out firmly, then resume", "this is the cold pull")
    pause("Pull the filament out firmly, then resume", "pause until the user resumes from the printer")
    emit("M104 S" .. reload_temp, "back up to the test filament's print temperature")
    emit("M109 S" .. reload_temp, "wait until it is hot")
    message("Load the test filament when asked", "the printer asks for it on the next line")
    emit("M600", "second filament change: unloads whatever is left, prompts for the test filament")
    message("Purging test filament", "clear the last of the cleaning filament")
    local reload_moves = purge(RELOAD_PURGE, "purge the test filament through")
    g[#g + 1] = "; step 0 nozzle clean done"

    api.project:clear_layer_custom_steps(bed)
    api.project:insert_layer_custom_gcode(bed, tower.gcode_z(0, lh), table.concat(g, "\n"))

    -- The anchor: a small solid plate so the print has a first layer to carry
    -- the sequence, and something to look at afterwards.
    api.project:add_object {
        mesh = api.make_cube(PLATE, PLATE, util.align(PLATE_H, lh, 2)),
        object_params = util.solid_params(),
    }

    util.log(string.format("nozzle clean for %s (%s): purge %s mm of %s at %d C in %d moves of %d mm, cold pull at %d C, reload and purge %s mm at %d C",
        tag, firmware, util.fmt(purge_mm), cleaning, clean_temp, purge_moves, CHUNK, pull_temp, util.fmt(RELOAD_PURGE), reload_temp))
    util.log("this relies on the firmware's own M600 prompts (unload, insert, load) and on a pause you resume from the printer after pulling the filament out; check the sequence in the G-code preview before printing")
    util.log("CORE One firmware also offers Control > Cold Pull, which walks through the same routine from the printer's menu")
    util.data(bed, "clean", { tag = tag, clean_temp = clean_temp, pull_temp = pull_temp, reload_temp = reload_temp,
        purge_mm = purge_mm, purge_moves = purge_moves, reload_purge_mm = RELOAD_PURGE, reload_moves = reload_moves,
        cleaning_filament = cleaning, firmware = firmware, plate = PLATE })
end
