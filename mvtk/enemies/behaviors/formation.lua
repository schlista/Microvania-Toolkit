-- mvtk/enemies/behaviors/formation.lua
-- ============================================================================
-- Formation Behavior
-- ============================================================================
-- Enemy behavior where multiple enemies maintain fixed offsets from a leader
-- anchor point. Useful for creating coordinated enemy groups that move together.
--
-- Behavior Pattern:
-- - Each enemy maintains a fixed offset from an anchor position
-- - Enemies smoothly move to stay at their formation position
-- - If player approaches the formation anchor, all enemies face the player
--
-- Configuration:
--   {
--     anchor = vmath.vector3(x, y, z),     -- Formation leader position
--     offset = vmath.vector3(x, y, z),     -- This enemy's offset from anchor
--     follow_speed = 120                   -- Speed to return to formation position
--   }
--
-- Usage:
-- - Set anchor to leader enemy position (updated each frame by leader)
-- - Give each formation member a unique offset for their position
-- - All enemies will maintain formation as anchor moves
--
-- Example:
-- - Leader at (100, 100), follower_1 offset (20, 0), follower_2 offset (-20, 0)
-- - Creates a horizontal line formation with leader in center

local Detection = require "mvtk.enemies.detection"

local M = {}

-- ============================================================================
-- LIFECYCLE FUNCTIONS
-- ============================================================================

-- Initialize formation behavior
-- self: Enemy script instance
-- config: Behavior configuration table
--
-- Sets up formation tracking with anchor point and offset.
function M.init(self, config)
    self.formation = {
        anchor = config.anchor or vmath.vector3(),      -- Leader position (updated externally)
        offset = config.offset or vmath.vector3(),      -- Fixed offset from anchor
        follow_speed = config.follow_speed or 120,      -- Pixels per second to return to formation
    }
    self.state = "formation"  -- Always in formation state
end

-- Update formation behavior each frame
-- self: Enemy script instance
-- dt: Delta time in seconds
--
-- Moves enemy toward their formation position (anchor + offset).
-- Updates facing direction toward player if player is near anchor.
function M.update(self, dt)
    local pos = go.get_position()

    -- Calculate target position (anchor + offset)
    local target = self.formation.anchor + self.formation.offset
    local delta = target - pos
    local dist = vmath.length(delta)

    -- Move toward formation position if not close enough
    if dist > 2 then  -- 2 pixel threshold to prevent jittering
        local dir = delta / dist  -- Normalize direction
        go.set_position(pos + dir * self.formation.follow_speed * dt)
        self.facing = dir.x >= 0 and 1 or -1  -- Face movement direction
    end

    -- If player approaches formation anchor, face toward player
    -- This makes formation enemies alert and ready to attack
    local player_pos = Detection.get_player_position()
    if player_pos and vmath.length(player_pos - target) < 120 then  -- 120 pixel alert radius
        self.facing = player_pos.x >= pos.x and 1 or -1  -- Face player
    end
end

return M
