-- Maps Tiled tileset names to Defold tilesource paths
--
-- When importing from Tiled, use this to map tileset names to the correct Defold tilesource

local M = {}

-- Tileset name (from Tiled) => Tilesource path (in Defold)
-- Add your custom tileset names here; paths should be project-relative and
-- start with a leading slash (Defold resource format).
M.tilesets = {
    ["graveyard_tilemap"] = "/developer/assets/tilesheets/graveyard.tilesource",
    ["gameplay"] = "/developer/assets/tilesheets/graveyard.tilesource",
    ["tiles"] = "/developer/assets/tilesheets/tiles.tilesource",
    ["desert"] = "/developer/assets/tilesheets/desert.tilesource",
    ["forest_tileset"] = "/developer/examples/forest/tiles/forest_tileset.tilesource",
}

-- Discovered tilesets (auto-populated by scanning /developer/assets/tilesheets)
M.discovered = {}

-- Runtime registrations. The importer calls M.register(tiled_name, path) for
-- every tilesource it creates, keyed on the EXACT Tiled tileset name. This is
-- what makes a dev's own tileset resolve even when its name does not match the
-- generated tilesource filename. Re-populated on every Import Assets / Create
-- Rooms run, so it never goes stale.
M.registered = {}

local DEV_HELPERS_MODULE = table.concat({ "developer", "tools", "dev_helpers" }, ".")
local H = require(DEV_HELPERS_MODULE)

-- Normalize a name to the same form the importer uses for tilesource filenames
-- (see sanitize_asset_name in hooks/core/tilesource.lua): lowercase, runs of
-- whitespace/hyphens and any non-word char -> "_", collapsed, trimmed. Keep the
-- two in sync. This lets a Tiled tileset named "Cave Tiles" resolve to a
-- discovered "cave_tiles.tilesource" without a hand-written mapping entry.
local function normalize_key(name)
    local s = tostring(name or ""):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    return s
end

-- Lightweight directory scan to discover .tilesource files automatically.
-- Uses shared helpers for path, directory, and file listing operations.
local function discover_tilesources()
    local found = {}

    local root = H.get_project_root()
    local base = root .. "/developer/assets/tilesheets"

    -- If tilesheets folder is missing, bail out gracefully
    if not H.dir_exists(base) then
        return found
    end

    local files = H.list_files(base, "%.tilesource$")
    for _, file in ipairs(files) do
        local name = file:gsub("%.tilesource$", "")
        local path = "/developer/assets/tilesheets/" .. file
        found[name] = path
        -- Also index under the normalized key so a Tiled tileset name that only
        -- differs by case/spacing/punctuation still resolves.
        found[normalize_key(name)] = path
    end

    return found
end

-- Refresh discovered tilesets (idempotent)
function M.refresh_discovered()
    M.discovered = discover_tilesources()
    return M.discovered
end

-- Register an exact Tiled tileset name -> Defold tilesource path. Called by the
-- importer after it creates/locates a tilesource, so resolution by the exact
-- authored tileset name is guaranteed within the session.
function M.register(tiled_tileset_name, tilesource_path)
    if not tiled_tileset_name or tiled_tileset_name == "" or not tilesource_path then
        return
    end
    M.registered[tiled_tileset_name] = tilesource_path
    M.registered[normalize_key(tiled_tileset_name)] = tilesource_path
end

-- Get Defold tilesource path for a Tiled tileset name.
-- Resolution order (exact first, then normalized fallback):
--   1. runtime registrations (created this session by the importer)
--   2. manual config mappings (M.tilesets)
--   3. auto-discovered tilesource files
--   4-6. the same three, looked up under the normalized key
function M.get_tilesource(tiled_tileset_name)
    if not tiled_tileset_name or tiled_tileset_name == "" then
        return nil
    end

    -- Exact lookups
    if M.registered[tiled_tileset_name] then
        return M.registered[tiled_tileset_name]
    end
    if M.tilesets[tiled_tileset_name] then
        return M.tilesets[tiled_tileset_name]
    end
    if not next(M.discovered) then
        M.refresh_discovered()
    end
    if M.discovered[tiled_tileset_name] then
        return M.discovered[tiled_tileset_name]
    end

    -- Normalized fallback: "Cave Tiles" -> "cave_tiles", etc.
    local key = normalize_key(tiled_tileset_name)
    if key ~= "" then
        if M.registered[key] then return M.registered[key] end
        if M.tilesets[key] then return M.tilesets[key] end
        if M.discovered[key] then return M.discovered[key] end
    end

    return nil
end

-- Get all tileset mappings
function M.get_all()
    if not next(M.discovered) then
        M.refresh_discovered()
    end
    local merged = {}
    for k, v in pairs(M.discovered) do merged[k] = v end
    for k, v in pairs(M.tilesets) do merged[k] = v end
    for k, v in pairs(M.registered) do merged[k] = v end
    return merged
end

return M
