-- mvtk/world/trigger_bus.lua
-- Lightweight registry to route trigger events by id.

local M = {}
local Util = require "mvtk.core.util"

local registry = {}

local function is_hex_hash_string(s)
    return type(s) == "string" and #s == 16 and s:match("^[0-9a-fA-F]+$") ~= nil
end

local function normalize_hash_string_key(value)
    if type(value) ~= "string" then
        return nil
    end

    local s = value
    local inner = Util.hash_wrapper_inner(s)
    if inner and inner ~= "" then
        s = inner
    end

    if s == "" or s == "0000000000000000" then
        return nil
    end

    if is_hex_hash_string(s) then
        return s:lower()
    end

    if (type(hash) == "function") and hash_to_hex and not s:find("<unknown", 1, true) then
        local ok_hash, h = pcall(hash, s)
        if ok_hash and type(h) == "userdata" then
            local ok_hex, hex = pcall(hash_to_hex, h)
            if ok_hex and type(hex) == "string" and hex ~= "" then
                return hex:lower()
            end
        end
    end

    return s
end

local function normalize_hash_userdata(value)
    if type(value) ~= "userdata" then
        return nil
    end

    if hash_to_hex then
        local ok, hex = pcall(hash_to_hex, value)
        if ok and type(hex) == "string" and hex ~= "" then
            return hex:lower()
        end
    end

    local s = tostring(value or "")
    return normalize_hash_string_key(s)
end

local function normalize_id(id)
    if id == nil then
        return nil
    end

    if type(id) == "userdata" then
        return normalize_hash_userdata(id)
    end

    -- Preserve the registry's existing text/hex/unknown keys independently of
    -- authored-property normalization, which deliberately rejects unknown text.
    local key = Util.trim(tostring(id or ""))
    local inner = Util.hash_wrapper_inner(key)
    if inner and inner ~= "" then key = inner end

    return normalize_hash_string_key(key)
end

local function url_go_exists(url)
    if not url then
        return false
    end

    local ok_parsed, parsed = pcall(msg.url, url)
    if not ok_parsed or not parsed then
        return false
    end

    local go_url = msg.url(parsed.socket, parsed.path, nil)
    local ok_exists, exists = pcall(go.exists, go_url)
    if ok_exists then
        return exists == true
    end

    -- If existence checks are unavailable for some reason, keep existing behavior.
    return true
end

function M.register(id, url)
    local key = normalize_id(id)
    if not key or key == "" or not url then
        return false
    end
    local bucket = registry[key]
    if not bucket then
        bucket = {}
        registry[key] = bucket
    end
    bucket[url] = true
    return true
end

function M.unregister(id, url)
    local key = normalize_id(id)
    if not key or not registry[key] then
        return false
    end
    if url then
        registry[key][url] = nil
    end
    if not next(registry[key]) then
        registry[key] = nil
    end
    return true
end

function M.emit(id, message_id, payload)
    local key = normalize_id(id)
    if not key then
        return 0
    end
    local bucket = registry[key]
    if not bucket then
        return 0
    end
    local count = 0
    local stale = nil
    for url, _ in pairs(bucket) do
        if url and url_go_exists(url) then
            local ok = pcall(msg.post, url, message_id, payload)
            if ok then
                count = count + 1
            else
                -- Track stale URLs for removal after iteration
                if not stale then stale = {} end
                stale[#stale + 1] = url
            end
        else
            if not stale then stale = {} end
            stale[#stale + 1] = url
        end
    end
    -- Remove stale URLs that failed to receive messages
    if stale then
        for _, url in ipairs(stale) do
            bucket[url] = nil
        end
        if not next(bucket) then
            registry[key] = nil
        end
    end
    return count
end

function M.clear()
    registry = {}
end

return M
