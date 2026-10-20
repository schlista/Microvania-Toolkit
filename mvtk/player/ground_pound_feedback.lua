-- mvtk/player/ground_pound_feedback.lua
-- Ground Pound presentation: the pose shown while slamming and the landing
-- impact (dust, camera shake, freeze-frame, controller rumble). Every value is
-- read from developer/config/player_actions.lua `ground_pound.feedback`; an
-- empty string or 0 turns that part off. Calls are guarded so a missing
-- system (or a headless test) never affects the slam itself.
local Actions = require "developer.config.player_actions"

local M = {}

local function feedback()
    local gp = type(Actions) == "table" and Actions.ground_pound or nil
    local f = type(gp) == "table" and gp.feedback or nil
    return type(f) == "table" and f or {}
end

-- Animation state shown instead of the airborne jump/fall pose, or nil.
function M.slam_pose()
    local pose = feedback().slam_animation
    if type(pose) == "string" and pose ~= "" then return pose end
    return nil
end

local function effect_list(value)
    if type(value) == "string" then return value ~= "" and { value } or {} end
    if type(value) == "table" then return value end
    return {}
end

-- Called once when a slam lands; a cancelled slam gets no impact.
function M.landed(pos)
    local f = feedback()
    local effects = effect_list(f.impact_fx)
    if #effects > 0 then
        local ok, Fx = pcall(require, "mvtk.fx.fx")
        if ok and type(Fx) == "table" and Fx.play then
            for _, fx_type in ipairs(effects) do pcall(Fx.play, fx_type, pos) end
        end
    end
    local shake = tonumber(f.impact_shake) or 0
    local hitstop = tonumber(f.impact_hitstop) or 0
    local rumble = tonumber(f.impact_rumble) or 0
    if shake > 0 or hitstop > 0 or rumble > 0 then
        local ok, Feel = pcall(require, "mvtk.core.gamefeel")
        if ok and type(Feel) == "table" and Feel.impact then
            pcall(Feel.impact, 1, {
                shake = shake, shake_dur = tonumber(f.impact_shake_time) or 0.15,
                hitstop = hitstop, rumble = rumble, rumble_ms = tonumber(f.impact_rumble_ms) or 100,
            })
        end
    end
end

return M
