local Util = require "mvtk.core.util"

local M = {}

function M.configured_room_ids(factories)
    local ids = {}
    local seen = {}
    for room_key in pairs(factories or {}) do
        local room_id = Util.normalize_room_id(room_key)
        if room_id ~= "" and not seen[room_id] then
            seen[room_id] = true
            ids[#ids + 1] = room_id
        end
    end
    table.sort(ids)
    return ids
end

return M
