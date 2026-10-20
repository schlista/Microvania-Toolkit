-- Shared passenger-carry helper for moving platform style prefabs.

local C = require "mvtk.core.constants"

local M = {}
local Carrier = {}
Carrier.__index = Carrier

local MSG_PLATFORM_DELTA = hash("platform_delta")

function M.new()
    return setmetatable({
        passengers = {},
    }, Carrier)
end

function Carrier:add(url, group)
    if not url then
        return
    end
    self.passengers[url] = { group = group }
end

function Carrier:remove(url)
    if not url then
        return
    end
    self.passengers[url] = nil
end

function Carrier:clear()
    for url in pairs(self.passengers) do
        self.passengers[url] = nil
    end
end

function Carrier:any()
    for _ in pairs(self.passengers) do
        return true
    end
    return false
end

function Carrier:apply_delta(dx, dy, opts)
    dx = tonumber(dx) or 0
    dy = tonumber(dy) or 0
    opts = opts or {}

    for url, info in pairs(self.passengers) do
        if go.exists(url) then
            local group = info and info.group
            if group == C.GROUPS.PLAYER or group == C.GROUPS.ENEMY then
                local should_carry = true
                if group == C.GROUPS.PLAYER and opts.carry_player == false then
                    should_carry = false
                elseif group == C.GROUPS.ENEMY and opts.carry_enemies == false then
                    should_carry = false
                end
                if should_carry then
                    msg.post(url, MSG_PLATFORM_DELTA, { dx = dx, dy = dy })
                end
            else
                local pos = go.get_position(url)
                pos.x = pos.x + dx
                pos.y = pos.y + dy
                go.set_position(pos, url)
            end
        else
            self.passengers[url] = nil
        end
    end
end

return M
