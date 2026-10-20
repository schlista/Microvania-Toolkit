-- developer/config/gates.lua
-- Gate instance definitions for your game
-- This file provides default example gates for testing and demonstration

local vmath = _G.vmath or { vector4 = function(...) return {...} end }
local ok_tile, Tile = pcall(require, "developer.config.tile_settings")
local TILE_PX = (ok_tile and Tile and Tile.width) or 128

-- IMPORTANT: These are example gates for demonstration purposes.
-- In a real game, you would customize these for your specific rooms and layout.
-- See docs/CREATOR_WORKFLOW.html for the supported Tiled gate workflow.

return {
    -- Example 1: Dash barrier (requires dash ability)
    {
        id = "demo_dash_barrier_01",
        gate_type = "dash_barrier",
        room_id = "room_demo",
        position = {x = 500, y = 300},
        visual = {
            color = vmath.vector4(0.5, 0.8, 1.0, 0.9)
        }
    },

    -- Example 2: Double jump barrier (requires double jump ability)
    {
        id = "demo_double_jump_ledge_01",
        gate_type = "double_jump_ledge",
        room_id = "room_demo",
        position = {x = 800, y = 400},
        visual = {
            color = vmath.vector4(0.8, 1.0, 0.5, 0.9)
        }
    },

    -- Example 3: Red key door (requires red key item)
    {
        id = "demo_red_key_door_01",
        gate_type = "key_door_red",
        room_id = "room_demo",
        position = {x = 640, y = 360}
    },

    -- Example 4: Breakable wall (requires a specific attack or ability)
    {
        id = "demo_breakable_wall_01",
        gate_type = "breakable_wall",
        room_id = "room_demo",
        position = {x = 200, y = 400},
        size = {w = TILE_PX, h = TILE_PX}
    },

    -- Example 5: Energy gate (consumes energy to open)
    {
        id = "demo_energy_gate_01",
        gate_type = "energy_gate",
        room_id = "room_demo",
        position = {x = 1000, y = 300},
        energy_cost = 20
    },

    --[[
    ============================================================================
    HOW TO ADD YOUR OWN GATES:
    ============================================================================

    1. Copy one of the examples above
    2. Change the 'id' to be unique (used for save persistence)
    3. Change 'gate_type' to match one from developer/config/gate_types.lua
    4. Set 'room_id' to match your room's ID
    5. Set 'position' to where you want the gate in world coordinates

    Available gate types (see developer/config/gate_types.lua for full list):
    - Movement: dash_barrier, double_jump_ledge, wall_climb_barrier, grapple_barrier
    - Destructible: breakable_wall, breakable_floor
    - Keys: key_door_red, key_door_blue, key_door_gold, key_door_boss
    - Resource: energy_gate, toll_gate
    - Hazard: lava_barrier, acid_barrier, cold_barrier
    - And many more...

    Example of adding your own gate:

    {
        id = "my_custom_gate_01",
        gate_type = "dash_barrier",
        room_id = "my_room_03",
        position = {x = 500, y = 300},
        -- Optional overrides:
        visual = {
            color = vmath.vector4(1.0, 0.5, 0.5, 0.9),
            sprite = "my_custom_sprite"
        },
        size = {w = 64, h = 128}
    },

    ============================================================================
    --]]
}
