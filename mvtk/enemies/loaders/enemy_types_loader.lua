-- mvtk/enemies/loaders/enemy_types_loader.lua
-- Loader for `developer/config/enemy_types.lua` with three fallbacks:
--   1. Plain `require "developer.config.enemy_types"` (preferred, fastest).
--   2. `sys.load_resource("/developer/config/enemy_types.lua")` —
--      survives `package.path` mishaps in bundled builds.
--   3. `require "mvtk.enemies.default_enemy_types"` — built-in defaults
--      so the toolkit boots even when a project ships without a config.
--
-- This used to live inline in `enemy_manager.lua` as a local function. It
-- was extracted so the resolution chain can be unit-tested and reused by
-- other tools (validators, tests) without dragging the whole manager in.
--
-- Behaviour-preserving: every `print()` warning, every fallback ordering,
-- and every return value matches the previous inline implementation.

local M = {}

-- The extracted function takes a single `log` callback so it can keep the
-- original `[ENEMY_MGR]` prefix without coupling to the manager module.
-- `log` is optional; when nil, warnings are silently dropped (useful for
-- headless test contexts).
local function warn(log, msg, ...)
    if not log then return end
    log(msg, ...)
end

--- Load the `enemy_types` table. Returns the table on success, or nil if
-- every fallback failed.
-- @param log function|nil Optional `print`-shaped callback for warnings.
-- @param sys_loader function|nil Optional override for `sys.load_resource`
--        (tests inject a stub so we don't need the Defold runtime).
function M.load(log, sys_loader)
    local ok_types, types = pcall(require, "developer.config.enemy_types")
    if ok_types and type(types) == "table" and next(types) ~= nil then
        return types
    end

    if ok_types and type(types) == "table" and next(types) == nil then
        warn(log, "[ENEMY_MGR] WARNING: developer.config.enemy_types loaded but empty")
    elseif not ok_types then
        warn(log, "[ENEMY_MGR] WARNING: require developer.config.enemy_types failed:", tostring(types))
    end

    -- Fallback: load as Defold resource (guards against package.path issues
    -- in bundled builds where lua-side `require` can't see project files).
    local resolver = sys_loader or (sys and sys.load_resource)
    if resolver then
        local data
        local ok_res, res = pcall(resolver, "/developer/config/enemy_types.lua")
        if ok_res and res and res ~= "" then
            data = res
        else
            -- Try without leading slash (some build setups).
            local ok_res2, res2 = pcall(resolver, "developer/config/enemy_types.lua")
            if ok_res2 and res2 and res2 ~= "" then
                data = res2
            end
        end

        if data then
            local loader = loadstring or load
            if loader then
                local chunk, load_err = loader(data)
                if chunk then
                    local ok_exec, tbl = pcall(chunk)
                    if ok_exec and type(tbl) == "table" and next(tbl) ~= nil then
                        warn(log, "[ENEMY_MGR] Loaded enemy_types via sys.load_resource fallback")
                        return tbl
                    end
                    warn(log, "[ENEMY_MGR] WARNING: enemy_types resource execute failed:", tostring(tbl))
                else
                    warn(log, "[ENEMY_MGR] WARNING: enemy_types resource compile failed:", tostring(load_err))
                end
            else
                warn(log, "[ENEMY_MGR] WARNING: loadstring/load unavailable; cannot eval enemy_types resource")
            end
        else
            warn(log, "[ENEMY_MGR] WARNING: enemy_types resource not found via sys.load_resource")
        end
    else
        warn(log, "[ENEMY_MGR] WARNING: sys.load_resource unavailable; cannot fallback-load enemy_types")
    end

    local ok_defaults, defaults = pcall(require, "mvtk.enemies.default_enemy_types")
    if ok_defaults and type(defaults) == "table" and next(defaults) ~= nil then
        warn(log, "[ENEMY_MGR] Using default enemy types fallback (mvtk.enemies.default_enemy_types)")
        return defaults
    end
    if not ok_defaults then
        warn(log, "[ENEMY_MGR] WARNING: require mvtk.enemies.default_enemy_types failed:", tostring(defaults))
    else
        warn(log, "[ENEMY_MGR] WARNING: mvtk.enemies.default_enemy_types loaded but empty")
    end

    return nil
end

return M
