-- Small deterministic contact set for elevator trigger occupants.
-- Defold collision messages may report several game objects for one logical
-- player. A boolean cannot distinguish the first exit from the last one.

local M = {}

local ContactSet = {}
ContactSet.__index = ContactSet

local function key(value)
    if value == nil then return nil end
    return tostring(value)
end

function M.new()
    return setmetatable({ entries = {}, size = 0 }, ContactSet)
end

function ContactSet:add(value)
    local id = key(value)
    if not id or self.entries[id] ~= nil then return false, self.size end
    self.entries[id] = value
    self.size = self.size + 1
    return true, self.size
end

function ContactSet:remove(value)
    local id = key(value)
    if not id or self.entries[id] == nil then return false, self.size end
    self.entries[id] = nil
    self.size = math.max(0, self.size - 1)
    return true, self.size
end

function ContactSet:count()
    return self.size
end

function ContactSet:is_empty()
    return self.size == 0
end

function ContactSet:first()
    local _, value = next(self.entries)
    return value
end

function ContactSet:clear()
    self.entries = {}
    self.size = 0
end

return M
