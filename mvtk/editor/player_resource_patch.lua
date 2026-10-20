-- Edit known geometry inside creator-owned resources, preserving all references.
-- Unsupported/ambiguous shapes fail in staging, before any project writes.
local Text = require "mvtk.editor.resource_text"
local M = {}

function M.patch(kind, content, old_scale, player)
    local ratio = (player.player_scale or 1) / old_scale
    local doc = Text.parse(content)
    if kind == "sprite" then
        local sprites = {}
        for _, entry in ipairs(Text.all(doc.root, "embedded_components")) do
            if Text.value(entry.node, "type") == "sprite" then sprites[#sprites+1] = entry.node end
        end
        assert(#sprites == 1, "Player sprite needs one embedded sprite component for automatic scaling")
        local sprite = sprites[1]
        local data = assert(Text.one(sprite, "data"), "Player sprite data is missing")
        local inner = Text.parse(data.value)
        if Text.value(inner.root, "size_mode") == "SIZE_MODE_MANUAL" then
            assert(Text.one(inner.root, "size"), "Manual sprite size is missing")
            Text.vector(inner, inner.root, "size", ratio, {"x","y"}, 0)
            Text.replace(doc, data, Text.render(inner))
        else Text.vector(doc, sprite, "scale", ratio, {"x","y"}, 1) end
        Text.vector(doc, sprite, "position", ratio, {"x","y"})
    elseif kind == "player_collection" or kind == "spine_collection" then
        -- Both collection kinds live in developer/addons/spine/player. Keep
        -- their creator-authored visual references while changing only scale.
        local found = false
        for _, entry in ipairs(Text.all(doc.root, "instances")) do
            if Text.value(entry.node, "id") == "spine_visual" then
                assert(not found, "Duplicate spine_visual instance")
                Text.vector(doc, entry.node, "scale3", ratio, {"x","y"}, 1)
                found = true
            end
        end
        assert(found, "Spine add-on player collection needs a spine_visual instance for automatic scaling")
    else
        local shape = assert(Text.one(doc.root, "embedded_collision_shape"), "Player collider needs embedded shapes").node
        local data = Text.all(shape, "data")
        local shapes = Text.all(shape, "shapes")
        assert(#shapes > 0 and #data > 0, "Player collider has no geometry")
        for _, entry in ipairs(shapes) do
            local shape_type = Text.value(entry.node, "shape_type")
            assert(shape_type == "TYPE_BOX" or shape_type == "TYPE_SPHERE" or shape_type == "TYPE_CAPSULE",
                "Unsupported player collider shape: " .. tostring(shape_type))
            Text.vector(doc, entry.node, "position", ratio, {"x","y","z"})
        end
        for _, value in ipairs(data) do Text.replace(doc, value, assert(tonumber(value.value)) * ratio) end
        if kind == "main" then
            assert(#shapes == 1 and #data == 3 and Text.value(shapes[1].node, "shape_type") == "TYPE_BOX",
                "Authored body width/height requires a single box player collider")
            Text.replace(doc, data[1], assert(player.collider_half_width) * (player.player_scale or 1))
            Text.replace(doc, data[2], assert(player.collider_half_height) * (player.player_scale or 1))
        end
    end
    local output = Text.render(doc)
    Text.parse(output) -- Validate edited syntax before the transaction publishes it.
    return output
end

return M
