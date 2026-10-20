-- mvtk/player/spine_visual.lua
-- Prefix-safe addressing for the player's collection-level Spine visual.

local M = {}

M.INSTANCE_ID = "spine_visual"
M.COMPONENT_ID = "spine"

--- Resolve the dedicated player Spine visual within the current collection
--- naming context. go.get_id() preserves collectionfactory instance prefixes.
--- Returns component_url, game_object_id, or nil when unavailable.
function M.resolve_sibling()
    if not (go and go.get_id and msg and msg.url) then return nil end

    local ok_id, visual_id = pcall(go.get_id, M.INSTANCE_ID)
    if not ok_id or not visual_id then return nil end

    local ok_url, visual_url = pcall(msg.url, nil, visual_id, M.COMPONENT_ID)
    if not ok_url or not visual_url then return nil end

    -- go.get_id() can hash a relative id even when a legacy/custom collection
    -- has no such instance. If the runtime exposes go.exists(), distinguish
    -- that case so old same-GO Spine prefabs retain their fallback.
    if go.exists then
        local ok_exists, exists = pcall(go.exists, visual_id)
        if ok_exists and not exists then return nil end
    end

    return visual_url, visual_id
end

--- Resolve the player Spine component, falling back to the historical
--- same-game-object #spine address for custom/legacy prefabs.
function M.resolve()
    local visual_url, visual_id = M.resolve_sibling()
    if visual_url then return visual_url, visual_id, true end
    if msg and msg.url then
        return msg.url("#spine"), nil, false
    end
    return nil, nil, false
end

return M
