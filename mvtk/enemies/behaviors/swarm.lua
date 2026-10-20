-- mvtk/enemies/behaviors/swarm.lua
-- Fast swarmers that coordinate target focus.

local Detection = require "mvtk.enemies.detection"

local M = {}

function M.init(self, config)
    self.swarm = {
        speed = config.speed or 90,
        cohesion = config.cohesion or 0.6,
        separation = config.separation or 24,
        target_weight = config.target_weight or 1.2,
    }
    self.state = "swarm"
    self.facing = 1
end

local function steer_to_player(pos, player_pos)
    local dir = vmath.normalize(player_pos - pos)
    return dir
end

local function separation_force(self, pos)
    local neighbors = self.neighbors or {}
    local accum = vmath.vector3()
    local count = 0
    for _, npos in ipairs(neighbors) do
        local delta = pos - npos
        local dist = vmath.length(delta)
        if dist > 0 and dist < self.swarm.separation then
            accum = accum + (delta / dist)
            count = count + 1
        end
    end
    if count > 0 then
        accum = accum / count
    end
    return accum
end

function M.update(self, dt)
    local pos = go.get_position()
    local player_pos = Detection.get_player_position()
    if not player_pos then return end

    local target_dir = steer_to_player(pos, player_pos) * self.swarm.target_weight
    local sep = separation_force(self, pos) * self.swarm.cohesion

    local vel = (target_dir + sep) * self.swarm.speed
    go.set_position(pos + vel * dt)
    self.facing = vel.x >= 0 and 1 or -1
end

return M
