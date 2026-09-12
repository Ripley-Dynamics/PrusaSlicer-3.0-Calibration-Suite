info = {
    id = "92_open_sheet",
    type = "project.plugin",
    title = "Open the dial-in sheet in the browser (needs the helper)",
    menu = "Filament Dial-In/Tools/Open the dial-in sheet",
    params = {},
}

-- The Lua sandbox has no file, network or process API, so a plugin cannot open
-- a browser itself. It can print, and when PrusaSlicer was started by
-- helper/dialin_helper.py the helper reads every line of that output: the
-- marker below tells it to open the sheet on whichever port it is serving.
-- With no helper listening the marker is just a line in PrusaSlicer's log.

function execute(opts)
    local util = require("lib/util")

    util.log("OPEN_SHEET http://127.0.0.1:8765/")
    util.log("if the sheet did not open, start it with Dial-In Sheet.cmd and launch PrusaSlicer from it")
end
