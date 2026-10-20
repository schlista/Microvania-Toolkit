-- mvtk/editor/collectible_prefab_generator.lua
--
-- Produces a room-local collectible prefab from the shared generic prefab when
-- a Tiled object needs an atlas other than gameplay_visuals. Keeping the full
-- shared prefab preserves its particle effects and trigger collision while
-- baking the sprite resource before component init.

local M = {}

local DEFAULT_ATLAS = "/developer/assets/atlas/gameplay_visuals.atlas"

local function resource_path(value)
    local path = tostring(value or ""):gsub("\\", "/")
    if path == "" then
        return nil
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

function M.generate(template_text, atlas_path, default_animation)
    if type(template_text) ~= "string" or template_text == "" then
        return nil, "collectible prefab template is empty"
    end

    local atlas = resource_path(atlas_path)
    local animation = tostring(default_animation or "")
    if not atlas or animation == "" then
        return nil, "collectible atlas and default animation are required"
    end

    local out, atlas_count = template_text:gsub(DEFAULT_ATLAS, atlas, 1)
    if atlas_count ~= 1 then
        return nil, "collectible prefab template has no gameplay_visuals sprite atlas"
    end

    local animation_count
    out, animation_count = out:gsub("prop_base", animation, 1)
    if animation_count ~= 1 then
        return nil, "collectible prefab template has no prop_base default animation"
    end

    local property_count
    out, property_count = out:gsub(
        '(id:%s*"sprite_atlas"%s*\r?\n%s*value:%s*")[^"]*(")',
        function(prefix, suffix)
            return prefix .. atlas .. suffix
        end,
        1
    )
    if property_count ~= 1 then
        return nil, "collectible prefab template has no sprite_atlas property"
    end

    return out
end

return M
