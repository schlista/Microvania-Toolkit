-- mvtk/combat/damage_payload.lua
-- Shared helpers for building and normalizing combat payloads.

local Util = require "mvtk.core.util"

local M = {}

local function clone(tbl)
    return Util.deep_copy(tbl or {})
end

local function number_or(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function bool_or(value, fallback)
    if value == nil then
        return fallback and true or false
    end
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    local s = tostring(value):lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then
        return true
    end
    if s == "false" or s == "0" or s == "no" or s == "off" then
        return false
    end
    return fallback and true or false
end

local function string_or_nil(value)
    if value == nil then
        return nil
    end
    local s = Util.normalize_hash_string(value, { keep_unknown = true })
    if s == nil then
        s = tostring(value)
    end
    s = tostring(s)
    if s == "" or s:find("<unknown", 1, true) then
        return nil
    end
    return s
end

function M.build(spec)
    local payload = clone(spec)
    local amount = number_or(payload.amount or payload.damage, 0)
    local damage_type = string_or_nil(payload.damage_type or payload.dtype) or "physical"
    local source_attack = string_or_nil(payload.source_attack or payload.attack_id)
    local action_tag = string_or_nil(payload.attack_type)
    if action_tag == nil then
        local normalized = string_or_nil(payload.action_tag)
        if normalized and normalized ~= "" then
            action_tag = normalized
        end
    end

    payload.amount = amount
    payload.damage = amount
    payload.dtype = damage_type
    payload.damage_type = damage_type
    payload.source_actor = payload.source_actor or payload.source or payload.owner
    payload.source = payload.source_actor or payload.source
    payload.source_attack = source_attack
    payload.reaction_type = string_or_nil(payload.reaction_type)
    payload.parryable = bool_or(payload.parryable, false)
    payload.kx = number_or(payload.kx, 0)
    payload.ky = number_or(payload.ky, 0)
    payload.stun_t = number_or(payload.stun_t, 0)
    payload.attack_type = action_tag
    return payload
end

function M.normalize(message, sender)
    local payload = M.build(message or {})
    if payload.source_actor == nil then
        payload.source_actor = sender
        payload.source = sender
    end
    if payload.source_attack == nil then
        payload.source_attack = string_or_nil(payload.attack_type)
    end

    if (payload.kx == 0 and payload.ky == 0) and message then
        local knockback = number_or(message.knockback, 0)
        local dir = number_or(message.dir, 1)
        if knockback ~= 0 then
            payload.kx = knockback * ((dir >= 0) and 1 or -1)
        end
    end

    return payload
end

function M.with_reaction(message, reaction_type)
    local payload = M.normalize(message)
    payload.reaction_type = string_or_nil(reaction_type) or payload.reaction_type
    return payload
end

return M
