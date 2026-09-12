-- Stacked-section tower builder shared by the temperature, flow, volumetric
-- and stringing commands.
--
-- A tower is one solid block (width x depth x total height) with, per section:
--   * an optional custom G-code entry emitted on the section's first layer,
--   * an optional modifier volume carrying per-region settings,
--   * a label engraved on the front (-Y) face.
-- The printer tag is engraved on the back face of the plinth.

local M = {}

M.MODIFIER_MARGIN = 2 -- mm the modifier boxes overhang the body on every side

-- Z at which a custom G-code entry lands on the first layer of a section that
-- starts at z0. PrusaSlicer assigns an entry to the first layer whose print_z
-- is at or above the entry, so half a layer up is unambiguous whatever the
-- first-layer height is.
function M.gcode_z(z0, layer_height)
    return z0 + layer_height * 0.5
end

function M.label_line_height(section_h)
    return math.max(2.5, math.min(7, section_h * 0.55))
end

-- spec:
--   width, depth        footprint (X, Y) in mm
--   base_height         plinth under the first section (0 allowed)
--   section_height      requested section height, rounded to whole layers
--   layer_height        current layer height
--   sections            list of { label = string?, gcode = string?, params = table? }
--   tag                 text for the back of the plinth (optional)
--   extra_x             extra +X reach the modifiers must cover (wings)
-- Returns an add_object definition with extra fields:
--   total_height, section_height, base_height, section_z (list of z0)
function M.build(bed, spec)
    local util = require("lib/util")
    local label = require("lib/label")

    local n = #spec.sections
    assert(n >= 1, "a tower needs at least one section")
    local lh = spec.layer_height
    assert(lh and lh > 0, "layer height must be positive")

    local w, d = spec.width, spec.depth
    local section_h = util.align(spec.section_height, lh, 2)
    local base_h = spec.base_height > 0 and util.align(spec.base_height, lh, 1) or 0
    local total = base_h + n * section_h
    local margin = M.MODIFIER_MARGIN
    local extra_x = spec.extra_x or 0

    local volumes = {}
    local section_z = {}

    -- Custom G-code is a per-bed list; replace it wholesale so stale entries
    -- from a previous tower cannot linger.
    api.project:clear_layer_custom_steps(bed)

    for i, s in ipairs(spec.sections) do
        local z0 = base_h + (i - 1) * section_h
        section_z[i] = z0

        if s.gcode and s.gcode ~= "" then
            api.project:insert_layer_custom_gcode(bed, M.gcode_z(z0, lh), s.gcode)
        end

        if s.params then
            volumes[#volumes + 1] = {
                mesh = api.make_cube(w + 2 * margin + extra_x, d + 2 * margin, section_h),
                type = VolumeType.Modifier,
                translate = { x = -margin, y = -margin, z = z0 },
                params = util.merge(s.params),
            }
        end

        if s.label and s.label ~= "" then
            volumes[#volumes + 1] = label.front {
                text = s.label,
                x = w / 2,
                z = z0 + section_h / 2,
                face_y = 0,
                line_height = M.label_line_height(section_h),
                max_width = w - 3,
                max_height = section_h - 1.5,
            }
        end
    end

    if spec.tag and spec.tag ~= "" and base_h >= 3 then
        volumes[#volumes + 1] = label.back {
            text = spec.tag,
            x = w / 2,
            z = base_h / 2,
            face_y = d,
            line_height = math.min(6, base_h * 0.6),
            max_width = w - 3,
            max_height = base_h - 1,
        }
    end

    return {
        mesh = api.make_cube(w, d, total),
        other_volumes = volumes,
        total_height = total,
        section_height = section_h,
        base_height = base_h,
        section_z = section_z,
    }
end

-- A slab attached to the +X face of the body, tilted so its underside is an
-- overhang of `angle_deg` from horizontal. The slab is a cube rotated about
-- its own corner (the volume origin), so the geometry is fully predictable:
-- bottom edge rises from (x_face, z0) at the requested angle.
-- Returns the volume definition and how far (mm) the wing reaches in +X.
function M.wing(o)
    local angle = o.angle_deg
    local t = o.thickness or 2
    local rad = math.rad(angle)
    local rise_available = o.section_height - 0.5 - t * math.cos(rad)
    assert(rise_available > 1, "section too short for an overhang wing")
    local length = rise_available / math.sin(rad)
    local wing_depth = o.wing_depth or o.depth * 0.6
    local def = {
        mesh = api.make_cube(length, wing_depth, t),
        type = VolumeType.Solid,
        rotate = { y = -angle },
        translate = { x = o.x_face, y = (o.depth - wing_depth) / 2, z = o.z0 },
    }
    return def, length * math.cos(rad)
end

return M
