-- developer/tools/relink_rooms.lua
-- One-click relink for tilemaps after path/tilesource changes.
--
-- Usage:
--   lua developer/tools/relink_rooms.lua
--   lua developer/tools/relink_rooms.lua /developer/assets/tilesheets/tiles.tilesource
--
-- What it does:
--   * Scans developer/assets/tiled/maps/*.tilemap
--   * Ensures tile_set points at the given tilesource (defaults to tilesheets/tiles.tilesource)
--   * Fixes old path prefixes (developer/assets/tiles -> developer/assets/tilesheets)

local H = require "developer.tools.dev_helpers"

-- Detect project root (allow CLI override via arg[0])
local ROOT
if arg and arg[0] and arg[0] ~= "" then
    ROOT = arg[0]:gsub("[/\\\\]developer[/\\\\].*$", "")
end
if not ROOT or ROOT == "" then
    ROOT = H.get_project_root()
end

-- Debug output
print("[DEBUG] ROOT = " .. tostring(ROOT))

local TILEMAP_DIR = ROOT .. "/developer/assets/tiled/maps"
local DEFAULT_TILESET = "/developer/assets/tilesheets/tiles.tilesource"

-- Map biome names to tilesources
local BIOME_TILESOURCES = {
    ["graveyard"] = "/developer/assets/tilesheets/graveyard.tilesource",
    ["forest"] = "/developer/assets/tilesheets/forest.tilesource",
    ["cave"] = "/developer/assets/tilesheets/cave.tilesource",
    -- Add more biomes as needed
}

-- Function to load Tiled Lua export and extract biome
local function get_biome_from_tiled_lua(room_id)
    local lua_path = TILEMAP_DIR .. "/" .. room_id .. ".lua"
    local fh = io.open(lua_path, "rb")
    if not fh then
        return nil
    end

    local content = fh:read("*a")
    fh:close()

    -- Try to execute the Lua file to get the data
    local load_fn = loadstring or load
    local chunk, err = load_fn(content, "@" .. lua_path)
    if not chunk then
        print("[DEBUG] Failed to load Tiled export " .. lua_path .. ": " .. tostring(err))
        return nil
    end

    local ok, tiled_data = pcall(chunk)
    if not ok or type(tiled_data) ~= "table" then
        print("[DEBUG] Failed to execute Tiled export " .. lua_path)
        return nil
    end

    -- Extract biome from properties
    if tiled_data.properties and tiled_data.properties.biome then
        return tiled_data.properties.biome
    end

    return nil
end

-- Function to determine tilesource for a room
local function get_tilesource_for_room(room_id)
    -- Check if command line argument was provided
    if arg and arg[1] then
        return arg[1]
    end

    -- Try to get biome from Tiled Lua export
    local biome = get_biome_from_tiled_lua(room_id)
    if biome and BIOME_TILESOURCES[biome] then
        return BIOME_TILESOURCES[biome]
    end

    -- Fall back to default
    return DEFAULT_TILESET
end

local function relink_tilemap(path, room_id)
    local data = H.read_file(path)
    if not data then
        print("[WARN] Could not read " .. path)
        return false
    end

    local updated = data
    local before = data

    -- Determine the correct tilesource for this room
    local target_tileset = get_tilesource_for_room(room_id)
    print("[DEBUG] Room '" .. room_id .. "' -> tilesource: " .. target_tileset)

    -- Fix old prefix
    updated = updated:gsub("/developer/assets/tiles/", "/developer/assets/tilesheets/")

    -- Remove ALL existing tile_set lines (including empty ones)
    updated = updated:gsub('tile_set:%s*"[^"]*"\n?', '')

    -- Add the correct tile_set at the beginning
    updated = 'tile_set: "' .. target_tileset .. '"\n' .. updated

    if updated ~= before then
        assert(H.write_file(path, updated))
        print("[OK] Relinked tile_set -> " .. target_tileset .. " in " .. path)
        return true
    end
    return false
end

local function main()
    local dir = TILEMAP_DIR
    local any = false
    local files = H.list_files(dir, "%.tilemap$")

    print("[INFO] Found " .. #files .. " tilemap files in " .. dir)
    for _, file in ipairs(files) do
        print("[DEBUG] Processing: " .. file)
        local room_id = file:gsub("%.tilemap$", "")
        local path = dir .. "/" .. file
        local changed = relink_tilemap(path, room_id)
        any = any or changed
    end

    if not any then
        print("[OK] No changes needed; tilemaps already point to correct tilesources")
    end
    print("[Tip] Rebuild rooms/manifest in the editor after relinking to refresh caches.")
end

main()
