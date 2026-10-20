-- Example: Using bone positions for attack hitboxes
-- This shows how to integrate bone_collision.lua into your player

local BoneCollision = require "mvtk.animation.bone_collision"
local SurfaceClassifier = require "mvtk.core.surface_classifier"
local SpineVisual = require "mvtk.player.spine_visual"

-- Example 1: Punch attack using hand bone
local function do_punch_attack(self)
    local spine_url = SpineVisual.resolve()

    -- Get the attacking hand position
    local hand_pos = BoneCollision.get_bone_position(spine_url, "hand_far")

    if hand_pos then
        -- Create a hitbox at the fist
        local punch_hitbox = {
            position = hand_pos,
            radius = 35,  -- Punch reach
            damage = 10,
            knockback = vmath.vector3(100 * self.facing, 50, 0)
        }

        -- Store for collision checking in update()
        self.active_attack_hitbox = punch_hitbox
        self.attack_hitbox_timer = 0.15  -- Active for 150ms

        print("Punch at:", hand_pos)
    end
end

-- Example 2: Kick attack using foot bone
local function do_kick_attack(self)
    local spine_url = SpineVisual.resolve()

    -- Pick one of the rig's layered feet for this illustrative kick.
    local foot_bone = self.facing > 0 and "foot_near" or "foot_far"
    local foot_pos = BoneCollision.get_bone_position(spine_url, foot_bone)

    if foot_pos then
        local kick_hitbox = {
            position = foot_pos,
            radius = 40,  -- Kick reach
            damage = 15,
            knockback = vmath.vector3(150 * self.facing, 100, 0)
        }

        self.active_attack_hitbox = kick_hitbox
        self.attack_hitbox_timer = 0.2

        print("Kick at:", foot_pos)
    end
end

-- Example 3: Check attack hitbox against enemies (call in update)
local function update_attack_hitbox(self, dt)
    if not self.active_attack_hitbox then return end

    -- Decay timer
    self.attack_hitbox_timer = (self.attack_hitbox_timer or 0) - dt
    if self.attack_hitbox_timer <= 0 then
        self.active_attack_hitbox = nil
        return
    end

    -- Check collisions with enemies near the hitbox
    -- You'd query physics here or check enemy positions
    local hitbox = self.active_attack_hitbox

    -- Example: Broadcast hit to nearby enemies
    msg.post(".", "attack_hitbox_active", {
        position = hitbox.position,
        radius = hitbox.radius,
        damage = hitbox.damage,
        knockback = hitbox.knockback
    })
end

-- Example 4: Foot-based ground detection for landing
local function check_feet_landing(self)
    local spine_url = SpineVisual.resolve()

    -- Check if either foot is near the ground
    local grounded, far_ground, near_ground = BoneCollision.check_feet_grounded(spine_url, 10)

    if grounded and self.vel_y < 0 then
        print("Landed! Far:", far_ground, "Near:", near_ground)
        -- Trigger landing logic
        return true
    end

    return false
end

-- Example 5: Wall grab using hand positions
local function check_wall_grab(self)
    local spine_url = SpineVisual.resolve()
    local far_hand, near_hand = BoneCollision.get_hand_positions(spine_url)

    -- Check if hands are near a wall
    local hand_to_check = self.facing > 0 and near_hand or far_hand

    if hand_to_check then
        -- Raycast from hand toward wall
        local direction = vmath.vector3(self.facing, 0, 0)
        local result = physics.raycast(hand_to_check, hand_to_check + direction * 30, SurfaceClassifier.RAYCAST.WALL)

        if SurfaceClassifier.is_wall_collision(result) then
            print("Hand touching wall at:", hand_to_check)
            return true
        end
    end

    return false
end

-- Integration into player.script:
--
-- In init():
--   self.BoneCollision = require "mvtk.animation.bone_collision"
--
-- In update():
--   update_attack_hitbox(self, dt)
--
-- When triggering attacks:
--   if action == "punch" then
--     do_punch_attack(self)
--   elseif action == "kick" then
--     do_kick_attack(self)
--   end
--
-- For advanced ground detection:
--   if check_feet_landing(self) then
--     -- Handle landing
--   end

return {
    do_punch_attack = do_punch_attack,
    do_kick_attack = do_kick_attack,
    update_attack_hitbox = update_attack_hitbox,
    check_feet_landing = check_feet_landing,
    check_wall_grab = check_wall_grab
}
