-- Engraved text volumes.
--
-- api.emboss_text() produces a 1 mm thick mesh (alpha11 ignores `depth`) lying
-- in the XY plane, extruded toward +Z, centred on its origin by PrusaSlicer's
-- default text alignment. Text meshes carry valid bounds (unlike primitives),
-- which this module uses to centre and fit each label. If bounds ever come
-- back empty the label is still placed, relying on the default centring.

local M = {}

M.DEFAULT_DEPTH = 0.6 -- mm the negative volume sinks into the part

local function emboss(font, text, line_height)
    local mesh = api.emboss_text {
        font = font,
        text = text,
        line_height = line_height,
    }
    local b = mesh:bounds()
    return mesh, b, b.max_x - b.min_x, b.max_y - b.min_y
end

-- Builds a text mesh that fits inside max_width x max_height, centred on the
-- origin. Returns mesh, final line height, measured width, measured height.
function M.text_mesh(text, line_height, max_width, max_height, font)
    assert(type(text) == "string" and text ~= "", "label text must be a non-empty string")
    font = font or api.get_default_font()
    local mesh, b, w, h = emboss(font, text, line_height)
    if w > 0 and h > 0 then
        local scale = 1
        if max_width and w > max_width then
            scale = math.min(scale, max_width / w)
        end
        if max_height and h > max_height then
            scale = math.min(scale, max_height / h)
        end
        if scale < 1 then
            line_height = line_height * scale * 0.97
            mesh, b, w, h = emboss(font, text, line_height)
        end
        if w > 0 and h > 0 then
            mesh:translate(-(b.min_x + b.max_x) / 2, -(b.min_y + b.max_y) / 2, 0)
        end
    else
        print("[filament-dialin] text bounds unavailable for '" .. text .. "', relying on default centring")
    end
    return mesh, line_height, w, h
end

-- Engraving on a face whose outward normal is -Y (the front), lying in the
-- plane y = face_y. Rotating +90 deg about X stands the text upright and
-- makes its 1 mm thickness point toward -Y, so translating by +depth sinks
-- exactly `depth` mm into the part.
function M.front(o)
    local depth = o.depth or M.DEFAULT_DEPTH
    local mesh = M.text_mesh(o.text, o.line_height, o.max_width, o.max_height, o.font)
    return {
        mesh = mesh,
        type = VolumeType.Negative,
        rotate = { x = 90 },
        translate = { x = o.x, y = (o.face_y or 0) + depth, z = o.z },
    }
end

-- Engraving on a face whose outward normal is +Y (the back) at y = face_y,
-- readable when looking at the part from behind. Rotation order is X then Z.
function M.back(o)
    local depth = o.depth or M.DEFAULT_DEPTH
    local mesh = M.text_mesh(o.text, o.line_height, o.max_width, o.max_height, o.font)
    return {
        mesh = mesh,
        type = VolumeType.Negative,
        rotate = { x = 90, z = 180 },
        translate = { x = o.x, y = o.face_y - depth, z = o.z },
    }
end

-- Engraving into a horizontal top face at z = top_z, readable from above.
function M.top(o)
    local depth = o.depth or M.DEFAULT_DEPTH
    local mesh = M.text_mesh(o.text, o.line_height, o.max_width, o.max_height, o.font)
    return {
        mesh = mesh,
        type = VolumeType.Negative,
        translate = { x = o.x, y = o.y, z = o.top_z - depth },
    }
end

return M
