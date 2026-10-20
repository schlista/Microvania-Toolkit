-- mvtk/enemies/enemy_type_overlay.lua
--
-- Resolves enemy_type ids against authored enemy_types.lua entries plus the
-- generated enemy skin manifest. Skin-only enemy types inherit starter stats
-- from DEFAULT_SKIN_BASE_TYPE until the author adds a matching enemy_types.lua
-- entry.

local M = {}

M.DEFAULT_SKIN_BASE_TYPE = "slime"

local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deep_copy(v)
    end
    return out
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function skin_value_is_unset(value)
    if value == nil then
        return true
    end
    local s = trim(value)
    return s == "" or s:lower() == "none"
end

local function get_skins_table(manifest)
    if type(manifest) ~= "table" then
        return {}
    end
    if type(manifest.skins) == "table" then
        return manifest.skins
    end
    return manifest
end

local function cache_get(cache, key)
    if type(cache) ~= "table" then
        return nil, false
    end
    local value = cache[key]
    if value ~= nil then
        return value ~= false and value or nil, true
    end
    return nil, false
end

local function cache_put(cache, key, value)
    if type(cache) == "table" then
        cache[key] = value or false
    end
    return value
end

local function log_synthesized(opts, enemy_type, base_type)
    local logger = opts and opts.logger
    if type(logger) == "function" then
        logger(string.format("enemy_type '%s' synthesized from '%s' (skin-only type)",
            tostring(enemy_type), tostring(base_type)))
    end
end

function M.resolve(enemy_type, base_types, skins_manifest, opts)
    local key = trim(enemy_type)
    if key == "" or type(base_types) ~= "table" then
        return nil
    end

    local cached, hit = cache_get(opts and opts.cache, key)
    if hit then
        return cached
    end

    local skins = get_skins_table(skins_manifest)
    local has_skin = type(skins[key]) == "table"

    local base_cfg = base_types[key]
    if type(base_cfg) == "table" then
        local cfg = deep_copy(base_cfg)
        if has_skin and skin_value_is_unset(cfg.skin) then
            cfg.skin = key
        end
        return cache_put(opts and opts.cache, key, cfg)
    end

    if has_skin then
        local fallback = base_types[M.DEFAULT_SKIN_BASE_TYPE]
        if type(fallback) == "table" then
            local cfg = deep_copy(fallback)
            cfg.skin = key
            cfg.color = nil
            cfg._synthesized_from = M.DEFAULT_SKIN_BASE_TYPE
            log_synthesized(opts, key, M.DEFAULT_SKIN_BASE_TYPE)
            return cache_put(opts and opts.cache, key, cfg)
        end
    end

    return cache_put(opts and opts.cache, key, nil)
end

return M
