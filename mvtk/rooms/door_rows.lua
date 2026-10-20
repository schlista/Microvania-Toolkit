-- Convert runtime tile rows to door markers without changing row-major order.
local M = {}

function M.markers(rows, min_tx, min_ty, width, height, origin, tile_width, tile_height)
    local markers = {}
    if type(rows) ~= "table" then return markers end
    for ty = min_ty, min_ty + height - 1 do
        local row = rows[ty] or {}
        for tx = min_tx, min_tx + width - 1 do
            if (row[tx] or 0) ~= 0 then
                markers[#markers + 1] = {
                    tx = tx, ty = ty,
                    x = origin.x + (tx - min_tx + 0.5) * tile_width,
                    y = origin.y + (ty - min_ty + 0.5) * tile_height,
                }
            end
        end
    end
    return markers
end

return M
