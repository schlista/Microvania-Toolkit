-- Tiled feedback contract shared by the room baker and runtime registration.
-- Defaults are generated from boss.tx, keeping class defaults and baking equal.
local Groups = require "mvtk.tiled.property_groups"
local M = { number_fields = {}, hash_fields = {}, bool_fields = {}, defaults = {} }

for _, group in ipairs({ "boss_hit_feedback", "player_hit_feedback" }) do
    for name, member in pairs(Groups.groups[group].members) do
        local value = member.default
        M.defaults[name] = value
        local fields = type(value) == "boolean" and M.bool_fields
            or type(value) == "number" and M.number_fields or M.hash_fields
        fields[#fields + 1] = name
    end
end
table.sort(M.number_fields)
table.sort(M.hash_fields)
table.sort(M.bool_fields)

local function enabled(value)
    return value == true or value == 1 or value == "true"
end

local function color(value)
    -- Tiled native colors export as #AARRGGBB; accept #RRGGBB too.
    local hex = type(value) == "string" and value:match("^#(%x+)$")
    if not hex or (#hex ~= 6 and #hex ~= 8) then return nil end
    local alpha = 255
    if #hex == 8 then alpha, hex = tonumber(hex:sub(1, 2), 16), hex:sub(3) end
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255, alpha / 255 }
end

local function value(props, name)
    if props[name] ~= nil then return props[name] end
    return M.defaults[name]
end

local function optional_name(raw)
    local name = tostring(raw or ""):match("^%s*(.-)%s*$")
    if name == "" or name:lower() == "none" then return false end
    return name
end

local function profile(props, prefix)
    local out = { screen_shake = false } -- Numeric shake is the sole shake owner.
    for _, field in ipairs({ "hitstop", "flash_duration", "shake", "rumble" }) do
        out[field] = math.max(0, tonumber(value(props, prefix .. field)) or 0)
    end
    out.rumble = math.min(1, out.rumble)
    out.sfx = optional_name(value(props, prefix .. "hurt_sfx"))
    out.flash_color = color(value(props, prefix .. "flash_color"))
    return out
end

function M.apply(props, config)
    -- Zero disables contact recoil/recovery. -1 (new template default) inherits.
    -- Keep contact tuning independent from whether damage itself was overridden.
    for _, field in ipairs({ "contact_knockback_x", "contact_knockback_y", "contact_stun_t" }) do
        local n = tonumber(props[field])
        if n and n >= 0 then config[field] = n end
    end
    if enabled(props.override_boss_feedback) then
        config.boss_hit_feedback = profile(props, "boss_")
    end
    if enabled(props.override_player_feedback) then
        local player = profile(props, "player_")
        player.stun_t = math.max(0, tonumber(value(props, "player_stun_t")) or 0)
        player.hurt_decel = math.max(0, tonumber(value(props, "player_hurt_decel")) or 0)
        player.animation = optional_name(value(props, "player_hurt_animation"))
        player.interrupt_attack = enabled(value(props, "player_interrupt_attack"))
        config.player_hit_feedback = player
    end
end

return M
