-- mvtk/editor/layout_editor/room_registry.lua
-- Small helper to manage layout-editor room records.

local M = {}

local function clone_table(src)
    if type(src) ~= "table" then
        return src
    end
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            out[k] = clone_table(v)
        else
            out[k] = v
        end
    end
    return out
end

local DEFAULT_TAGS = {
    marker = {
        enabled = false,
        type = "custom",
        label = nil,
        offset = { x = 0, y = 0 },
        color = nil,
    },
}

local function merge_default_tags(tags)
    local merged = clone_table(DEFAULT_TAGS)
    tags = tags or {}
    for k, v in pairs(tags) do
        if k ~= "biome" and k ~= "ambience" and k ~= "music" then
            if type(v) == "table" then
                merged[k] = clone_table(v)
            else
                merged[k] = v
            end
        end
    end

    -- Ensure marker sub-table always exists with expected keys
    merged.marker = merged.marker or {}
    merged.marker.enabled = merged.marker.enabled or false
    merged.marker.type = merged.marker.type or "custom"
    merged.marker.label = merged.marker.label or nil
    local offset = merged.marker.offset or {}
    merged.marker.offset = {
        x = tonumber(offset.x) or 0,
        y = tonumber(offset.y) or 0,
    }
    if merged.marker.color and type(merged.marker.color) == "table" then
        merged.marker.color = {
            x = merged.marker.color.x or merged.marker.color[1],
            y = merged.marker.color.y or merged.marker.color[2],
            z = merged.marker.color.z or merged.marker.color[3],
            w = merged.marker.color.w or merged.marker.color[4],
        }
    else
        merged.marker.color = nil
    end
    return merged
end

function M.clone_tags(tags)
    return merge_default_tags(tags)
end

function M.create(room_id, tilemap_path, group, shape, base_pos, opts)
    opts = opts or {}
    local initial_tags = merge_default_tags(opts.tags)
    return {
        id = room_id,
        tilemap_path = tilemap_path,
        group = group,
        shape = shape,
        base_pos = base_pos,
        fill_nodes = {},
        outline_nodes = {},
        door_nodes = {},
        marker_nodes = {},
        key_markers = {},
        label_node = nil,
        selected = false,
        doors_meta = {},
        tags = initial_tags,
    }
end

function M.store(state, entry)
    state.rooms = state.rooms or {}
    print(string.format("[ROOM_REGISTRY] Storing room id=%s", entry.id))
    print(string.format("[ROOM_REGISTRY] Current keys before store: %s", table.concat((function() local k={}; for id,_ in pairs(state.rooms) do k[#k+1]=id end; return k end)(), ", ")))
    state.rooms[entry.id] = entry
    print(string.format("[ROOM_REGISTRY] Current keys after store: %s", table.concat((function() local k={}; for id,_ in pairs(state.rooms) do k[#k+1]=id end; return k end)(), ", ")))
end

return M
