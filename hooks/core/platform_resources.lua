-- Bake moving-platform art from the regenerated room tilemap. Reading the
-- Defold cells preserves tilesource-local indices and authored flip/rotation
-- flags, including tile 0 (the first real tile, not an empty placeholder).
local TilemapText = require "hooks.core.elevator_resources"

local M = {}

function M.capture(source_text, opts)
    opts = opts or {}
    local parsed, err = TilemapText.parse_tilemap(source_text)
    if not parsed then return nil, err end
    local tw, th = tonumber(opts.tile_width), tonumber(opts.tile_height)
    if not tw or not th or tw <= 0 or th <= 0 then return nil, "invalid_tile_size" end
    local left, bottom = tonumber(opts.x) or 0, tonumber(opts.y) or 0
    local min_x, min_y = math.floor(left / tw), math.floor(bottom / th)
    local max_x = math.ceil((left + (tonumber(opts.width) or tw)) / tw) - 1
    local max_y = math.ceil((bottom + (tonumber(opts.height) or th)) / th) - 1

    -- Current room art is authored on art/player; old exports used environment.
    -- Tilemap regeneration flattens those group paths to their leaf layer ids.
    local requested = tostring(opts.source_layer or ""):match("([^/]+)$")
    local candidates = requested and requested ~= "" and requested ~= "none"
        and { requested } or { "player", "environment" }
    for _, wanted in ipairs(candidates) do
        for _, layer in ipairs(parsed.layers) do
            if layer.id == wanted then
                local cells = {}
                for _, cell in ipairs(layer.cells) do
                    if cell.x >= min_x and cell.x <= max_x and cell.y >= min_y and cell.y <= max_y then
                        cells[#cells + 1] = {
                            x = cell.x - min_x, y = cell.y - min_y,
                            tile = cell.tile, h_flip = cell.h_flip,
                            v_flip = cell.v_flip, rotate90 = cell.rotate90,
                        }
                    end
                end
                if #cells > 0 then
                    return {
                        tilemap = TilemapText.serialize_tilemap({
                            top_lines = {
                                string.format('tile_set: "%s"', parsed.tile_set),
                                'material: "/builtins/materials/tile_map.material"',
                            },
                            layers = {{
                                pre_lines = { '  id: "solid"', '  z: 0.1',
                                    '  is_visible: ' .. tostring(layer.is_visible or 1) },
                                cells = cells,
                            }},
                        }),
                        source_layer = wanted,
                        x = min_x * tw, y = min_y * th,
                        width = (max_x - min_x + 1) * tw,
                        height = (max_y - min_y + 1) * th,
                        copied_cells = #cells,
                    }
                end
            end
        end
    end
    return nil, requested and ("no_platform_art_on_" .. requested) or "no_platform_art_on_player_or_environment"
end

return M
