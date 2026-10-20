-- Pure requirement evaluation shared by runtime gates and authoring analysis.
-- Callbacks read live state; table fields provide a side-effect-free snapshot.
local M = {}
function M.evaluate(req, state)
    req, state = req or {}, state or {}
    local missing = {}
    for id in pairs(req.abilities or {}) do
        local has
        if state.has_ability then has=state.has_ability(id) else has=(state.abilities or {})[id] end
        if not has then missing[#missing+1] = "ability: " .. id end
    end
    for id, amount in pairs(req.items or {}) do
        local has = state.has_item and state.has_item(id, amount)
        if not state.has_item then has = ((state.items or {})[id] or 0) >= amount end
        if not has then missing[#missing+1] = "item: " .. id .. " x" .. amount end
    end
    for id, expected in pairs(req.flags or {}) do
        local value = (state.flags or {})[id]
        if expected == true then value = value ~= nil and value ~= false
        elseif value == nil then value = false end
        if value ~= expected then missing[#missing+1] = "flag: " .. id .. "=" .. tostring(expected) end
    end
    for id, amount in pairs(req.resources or {}) do
        if ((state.resources or {})[id] or 0) < amount then missing[#missing+1] = "resource: " .. id .. " x" .. amount end
    end
    table.sort(missing)
    return #missing == 0, missing
end
return M
