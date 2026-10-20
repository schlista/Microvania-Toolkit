-- tools/migrate_config_files.lua
-- Helper script to migrate config files from /developer/config/ to /developer/config/

local DevHelpers = require "developer.tools.dev_helpers"

local file_exists = DevHelpers.file_exists
local read_file = DevHelpers.read_file

local function write_file(path, content)
    DevHelpers.ensure_dir(path, true)
    local ok, err = DevHelpers.write_file(path, content, "w")
    if not ok then
        print("ERROR: Could not write to " .. path .. " (" .. tostring(err) .. ")")
        return false
    end
    return true
end

-- Configuration: Define where each file should go
local migrations = {
    -- Gameplay configs
    {from = "developer/config/gameplay_constants.lua", to = "developer/config/gameplay/gameplay_constants.lua"},
    {from = "developer/config/player_settings.lua", to = "developer/config/gameplay/player_settings.lua"},
    {from = "developer/config/player_actions.lua", to = "developer/config/gameplay/player_actions.lua"},
    {from = "developer/config/abilities.lua", to = "developer/config/gameplay/abilities.lua"},

    -- Enemy configs
    {from = "developer/config/enemy_settings.lua", to = "developer/config/enemies/enemy_settings.lua"},
    {from = "developer/config/enemy_types.lua", to = "developer/config/enemies/enemy_types.lua"},
    {from = "developer/config/boss_types.lua", to = "developer/config/enemies/boss_types.lua"},
    {from = "developer/config/boss_arenas.lua", to = "developer/config/enemies/boss_arenas.lua"},

    -- World configs
    {from = "developer/config/rooms_config.lua", to = "developer/config/world/rooms_config.lua"},
    {from = "developer/config/room_enemies.lua", to = "developer/config/world/room_enemies.lua"},
    {from = "developer/config/room_collectibles.lua", to = "developer/config/world/room_collectibles.lua"},
    {from = "developer/config/biomes.lua", to = "developer/config/world/biomes.lua"},
    {from = "developer/config/secret_rooms.lua", to = "developer/config/world/secret_rooms.lua"},
    {from = "developer/config/gates.lua", to = "developer/config/world/gates.lua"},
    {from = "developer/config/gate_types.lua", to = "developer/config/world/gate_types.lua"},
    {from = "developer/config/camera_zones.lua", to = "developer/config/world/camera_zones.lua"},
    {from = "developer/config/poi.lua", to = "developer/config/world/poi.lua"},
    {from = "developer/config/water_zones.lua", to = "developer/config/world/water_zones.lua"},
    {from = "developer/config/stream_settings.lua", to = "developer/config/world/stream_settings.lua"},
    {from = "developer/config/tile_settings.lua", to = "developer/config/world/tile_settings.lua"},
    {from = "developer/config/locked_door_settings.lua", to = "developer/config/world/locked_door_settings.lua"},

    -- Item configs
    {from = "developer/config/items.lua", to = "developer/config/items/items.lua"},
    {from = "developer/config/collectible_types.lua", to = "developer/config/items/collectible_types.lua"},

    -- Narrative configs
    {from = "developer/config/narrative/dialogues.lua", to = "developer/config/narrative/dialogues.lua"},
    {from = "developer/config/narrative/cutscenes.lua", to = "developer/config/narrative/cutscenes.lua"},

    -- UI configs
    {from = "developer/config/hud_layout.lua", to = "developer/config/ui/hud_layout.lua"},
    {from = "developer/config/hud_layout_examples.lua", to = "developer/config/ui/hud_layout_examples.lua"},
    {from = "developer/config/ui_theme.lua", to = "developer/config/ui/ui_theme.lua"},
    {from = "developer/config/ui_theme_examples.lua", to = "developer/config/ui/ui_theme_examples.lua"},
    {from = "developer/config/minimap_settings.lua", to = "developer/config/ui/minimap_settings.lua"},
    {from = "developer/config/world_map_settings.lua", to = "developer/config/ui/world_map_settings.lua"},

    -- System configs
    {from = "developer/config/resolved_config.lua", to = "developer/config/system/resolved_config.lua"},
    {from = "developer/config/default_bindings.lua", to = "developer/config/system/default_bindings.lua"},
    {from = "developer/config/ambience_tracks.lua", to = "developer/config/system/ambience_tracks.lua"},
    {from = "developer/config/debug_config.lua", to = "developer/config/system/debug_config.lua"},
    {from = "developer/config/layout_editor_settings.lua", to = "developer/config/system/layout_editor_settings.lua"},
}

-- Files that need their require() statements updated
local files_to_update = {
    "mvtk/developer/game/main.script",
    "mvtk/player/player.script",
    "mvtk/enemies/enemy.script",
    "mvtk/enemies/enemy_manager.lua",
    "mvtk/bosses/boss.script",
    "mvtk/developer/rooms/stream_manager.script",
    "mvtk/developer/rooms/room_manager.lua",
    "mvtk/core/settings.lua",
    "mvtk/core/inventory.lua",
    "mvtk/core/narrative.lua",
    "mvtk/developer/ui/menu_manager.lua",
    "boot/simple_manager.script",
    "developer/ui/game/minimap.gui_script",
    "developer/ui/menus/world_map.gui_script",
    "developer/ui/menus/settings_menu.gui_script",
    "developer/ui/shared/mode_hud.gui_script",
    "editor/gdeveloper/ui/layout_editor.gui_script",
}

-- Main migration function
local function migrate()
    print("=" .. string.rep("=", 70))
    print("MV Toolkit - Config File Migration Script")
    print("=" .. string.rep("=", 70))
    print()

    local stats = {
        total = #migrations,
        success = 0,
        skipped = 0,
        failed = 0,
    }

    -- Phase 1: Copy files
    print("Phase 1: Migrating config files...")
    print()

    for i, migration in ipairs(migrations) do
        local from = migration.from
        local to = migration.to

        print(string.format("[%d/%d] %s", i, #migrations, from))
        print("     -> " .. to)

        -- Check if source exists
        if not file_exists(from) then
            print("     [SKIP] Source file doesn't exist")
            stats.skipped = stats.skipped + 1
        else
            -- Read source
            local content = read_file(from)
            if not content then
                print("     [ERROR] Could not read source file")
                stats.failed = stats.failed + 1
            else
                -- Write to destination
                if write_file(to, content) then
                    print("     [OK] Migrated successfully")
                    stats.success = stats.success + 1
                else
                    print("     [ERROR] Could not write destination file")
                    stats.failed = stats.failed + 1
                end
            end
        end
        print()
    end

    -- Phase 2: Update require() statements
    print()
    print("=" .. string.rep("=", 70))
    print("Phase 2: Updating require() statements...")
    print("=" .. string.rep("=", 70))
    print()
    print("FILES TO UPDATE:")
    for _, file in ipairs(files_to_update) do
        print("  - " .. file)
    end
    print()
    print("SEARCH/REPLACE PATTERNS:")
    print('  require("developer.config.XXX")  →  require("game_config.gameplay.XXX")')
    print('  require("developer.config.XXX")  →  require("game_config.enemies.XXX")')
    print('  require("developer.config.XXX")  →  require("game_config.world.XXX")')
    print('  etc.')
    print()
    print("NOTE: This phase requires manual work or a more sophisticated script.")
    print("Recommend using your text editor's find/replace feature.")
    print()

    -- Summary
    print()
    print("=" .. string.rep("=", 70))
    print("MIGRATION SUMMARY")
    print("=" .. string.rep("=", 70))
    print(string.format("Total files:     %d", stats.total))
    print(string.format("Migrated:        %d", stats.success))
    print(string.format("Skipped:         %d", stats.skipped))
    print(string.format("Failed:          %d", stats.failed))
    print()

    if stats.failed > 0 then
        print("❌ MIGRATION INCOMPLETE - Some files failed to migrate")
        print("   Please check errors above and fix manually.")
    elseif stats.skipped > 0 then
        print("⚠️  MIGRATION PARTIAL - Some files were skipped")
        print("   This is normal if files don't exist yet.")
    else
        print("✅ MIGRATION COMPLETE - All files migrated successfully!")
    end
    print()

    print("NEXT STEPS:")
    print("1. Review migrated files in /developer/config/")
    print("2. Update require() statements in framework files")
    print("3. Test the game to ensure everything works")
    print("4. Delete old /developer/config/ folder after verification")
    print()
    print("=" .. string.rep("=", 70))
end

-- Run migration
migrate()
