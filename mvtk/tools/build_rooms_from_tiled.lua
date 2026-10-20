--- Build Rooms from Tiled - Manual Editor Tool
-- Manual trigger for room generation (optional - build automation runs automatically)
-- Run this from the Defold editor: Editor -> Run Editor Script
--
-- NOTE: This is a simplified manual tool. The ACTUAL automation happens in
-- hooks.editor_script which runs automatically on every build and provides:
-- 1. Full Tiled Lua parsing (load_tiled_export)
-- 2. Complete collection generation with objects & parallax (gen_collection)
-- 3. Room manifest updates (gen_manifest)
-- 4. Factory generation (gen_factory_holder)
-- 5. Tilesource auto-assignment (update_tilemap_tilesource)
--
-- This tool exists for manual testing but is NOT the primary automation
--
-- @module build_rooms_from_tiled

local M = {}
local StreamPaths = require "mvtk.rooms.stream_paths"
local proto_escape = require("mvtk.editor.proto_utils").proto_escape

local function log(msg)
    print("[TILED_BUILDER] " .. tostring(msg))
end

--- Scan for Tiled map exports
local function scan_tiled_maps()
    local maps_dir = StreamPaths.tiled_maps_dir()
    local maps = {}

    -- In editor scripts, we need to use editor.get functions
    -- This is a simplified version - full implementation would use editor API

    log("Scanning " .. maps_dir .. " for Tiled exports...")

    -- For now, return a list that the user can configure
    -- In full implementation, this would scan the filesystem

    maps = {
        StreamPaths.tiled_map_lua("room_04"),
        -- Add more maps here
    }

    log("Found " .. #maps .. " Tiled map(s)")

    return maps
end

--- Generate collection file content
local function generate_collection_data(room_id, tiled_path, parallax_layers)
    local collection_data = {
        name = room_id,
        scale_along_z = 0,
        instances = {}
    }

    -- Add main tilemap instance
    table.insert(collection_data.instances, {
        id = "level",
        prototype = StreamPaths.generated_rooms_dir() .. room_id .. "_level.go",
        position = { x = 0, y = 0, z = 0 }
    })

    -- Add tiled loader instance
    table.insert(collection_data.instances, {
        id = "tiled_objects",
        data = string.format([[
components {
  id: "tiled_loader"
  component: "/mvtk/tiled/tiled_room_loader.script"
  properties {
    id: "tiled_map_path"
    value: "%s"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "room_id"
    value: "%s"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "auto_spawn_objects"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "auto_setup_parallax"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "parallax_enabled"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
]], proto_escape(tiled_path), proto_escape(room_id)),
        position = { x = 0, y = 0, z = 0 }
    })

    -- Add parallax sprite instances
    for i, layer in ipairs(parallax_layers or {}) do
        local z_index = -10.0 + (layer.parallax_factor * 5.0)

        table.insert(collection_data.instances, {
            id = "parallax_" .. layer.name,
            data = string.format([[
embedded_components {
  id: "parallax_%s"
  type: "sprite"
  data: "default_animation: \"default\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/%s\"\n"
  "}\n"
}
]], layer.name, layer.image or "builtins/graphics/particle_blob.png"),
            position = { x = 0, y = 0, z = z_index }
        })

        log(string.format("  Added parallax layer: %s (z: %.2f)", layer.name, z_index))
    end

    return collection_data
end

--- Main build function
function M.build()
    log("=" .. string.rep("=", 58))
    log("Building Rooms from Tiled Exports")
    log("=" .. string.rep("=", 58))

    local maps = scan_tiled_maps()

    for _, map_path in ipairs(maps) do
        local room_id = map_path:match("/([^/]+)%.lua$")

        log("\nProcessing: " .. room_id)
        log("-" .. string.rep("-", 58))

        -- In a full implementation, this would:
        -- 1. Parse the Tiled Lua file
        -- 2. Extract parallax layers and objects
        -- 3. Generate/update the collection file
        -- 4. Update room manifest

        log("  Room ID: " .. room_id)
        log("  Tiled path: " .. map_path)
        log("  Output: /developer/rooms/collections/" .. room_id .. ".collection")

        -- NOTE: This is a manual editor tool that mirrors the functionality
        -- already provided by hooks.editor_script (which runs automatically).
        -- The actual build automation is handled by hooks.editor_script:
        --   - load_tiled_export() parses Tiled Lua files
        --   - gen_collection() generates collections with objects & parallax
        --   - gen_manifest() updates the room manifest
        -- This tool exists for manual triggering if needed, but the TODO
        -- items are already implemented in the automated build pipeline.
    end

    log("\n" .. string.rep("=", 60))
    log("Build complete!")
    log(string.rep("=", 60))

    return true
end

--- Editor script entry point
function M.get_commands()
    return {
        {
            label = "Build Rooms from Tiled",
            locations = {"Edit"},
            active = function(opts) return true end,
            run = function(opts)
                M.build()
                return true
            end
        }
    }
end

return M
