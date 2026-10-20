-- Configuration-only policy. Flags belong to the checkpoint provider; room
-- streaming and map stations must never unlock a secret by themselves.
local Util = require "mvtk.core.util"
local M = {}

function M.normalize_room(id)
    if type(id) ~= "string" then return nil end
    return id:gsub("^developer/rooms/", ""):gsub("%.lua$", "")
end

function M.wall_flag(wall_id)
    -- Match the wall component's durable hexadecimal identity.
    return "wall_broken_" .. (Util.hash_key_hex(wall_id) or "")
end

-- World concealment is opt-in independently of map discovery. Existing callers
-- retain the map policy unless they explicitly request the world field.
function M.compile(config, visibility_field)
    visibility_field = visibility_field or "hidden_on_map"
    local rooms = {}
    for id, entry in pairs(config or {}) do
        if type(entry) == "table" and entry[visibility_field] == true then
            local room = M.normalize_room(entry.room_id)
            if room and room ~= "" then
                local flag = entry.reveal_flag
                if type(flag) ~= "string" or flag == "" then
                    flag = type(entry.wall_id) == "string" and entry.wall_id ~= ""
                        and M.wall_flag(entry.wall_id) or "secret_" .. tostring(id)
                end
                rooms[room] = rooms[room] or {}
                rooms[room][#rooms[room] + 1] = {
                    flag = flag, reveal = entry.reveal_on_unlock ~= false,
                    padding = type(entry.map_padding) == "table" and entry.map_padding or {},
                }
            end
        end
    end
    return rooms
end

function M.bounds(room, entries)
    local padding = { left = 0, right = 0, bottom = 0, top = 0 }
    for _, entry in ipairs(entries) do
        for side, value in pairs(padding) do
            padding[side] = math.max(value, tonumber(entry.padding[side]) or 0)
        end
    end
    return { min_x = room.min_x - padding.left, max_x = room.max_x + padding.right,
        min_y = room.min_y - padding.bottom, max_y = room.max_y + padding.top }
end

-- Multiple entrances to the same room use OR semantics: either can reveal it.
function M.status(entries, flags)
    local unlocked, reveal = false, false
    for _, entry in ipairs(entries) do
        if flags.has(entry.flag) then
            unlocked = true
            reveal = reveal or entry.reveal
        end
    end
    return not unlocked, reveal
end

return M
