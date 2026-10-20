-- mvtk/core/safe_require.lua
--
-- Centralized require helper for optional dependencies.
--
-- Use this in place of:
--     local ok, Mod = pcall(require, "mvtk.some.module")
--
-- It preserves the same return shape, while logging failures with caller
-- context so missing optional integrations do not fail silently.

local M = {}

local original_require = require

local function infer_context()
    if not debug or not debug.getinfo then
        return "unknown"
    end

    for level = 3, 8 do
        local info = debug.getinfo(level, "S")
        if not info then
            break
        end

        local source = info.short_src or info.source or ""
        if not source:match("mvtk/core/safe_require%.lua$") then
            return source ~= "" and source or "unknown"
        end
    end

    return "unknown"
end

local function normalize_context(context)
    if type(context) == "string" and context ~= "" then
        return context
    end

    if type(context) == "table" then
        return context.context
            or context.caller
            or context.module
            or context.module_name
            or infer_context()
    end

    return infer_context()
end

local function fallback_logger(module_name)
    return {
        warn = function(fmt, ...)
            print("[WARN] [" .. tostring(module_name) .. "] " .. string.format(fmt, ...))
        end,
        error = function(fmt, ...)
            print("[ERROR] [" .. tostring(module_name) .. "] " .. string.format(fmt, ...))
        end,
    }
end

local function get_logger(module_name)
    local ok_debug, DebugLogger = pcall(original_require, "mvtk.debug.logger")
    if ok_debug and DebugLogger and DebugLogger.get_logger then
        return DebugLogger.get_logger(module_name)
    end

    local ok_core, CoreLogger = pcall(original_require, "mvtk.core.logger")
    if ok_core and CoreLogger and CoreLogger.get_logger then
        return CoreLogger.get_logger(module_name)
    end

    return fallback_logger(module_name)
end

local function table_has_key(tbl, key)
    return type(tbl) == "table" and tbl[key] ~= nil
end

local function safe_require(module_path, context)
    local caller = normalize_context(context)
    local ok, result = pcall(original_require, module_path)

    if not ok then
        get_logger(caller).warn("require failed: module=%q err=%s",
            tostring(module_path),
            tostring(result))

        if table_has_key(context, "default") then
            return false, context.default
        end

        return false, result
    end

    if type(context) == "table" and context.expect_table and type(result) ~= "table" then
        local err = string.format(
            "module %q returned %s, expected table",
            tostring(module_path),
            type(result))

        get_logger(caller).warn("require validation failed: %s", err)

        if table_has_key(context, "default") then
            return false, context.default
        end

        return false, err
    end

    return true, result
end

function M.safe_require(module_path, context)
    return safe_require(module_path, context)
end

function M.quiet(module_path, context)
    local ok, result = pcall(original_require, module_path)
    if ok then
        return true, result
    end

    if table_has_key(context, "default") then
        return false, context.default
    end

    return false, result
end

function M.strict_require(module_path, context)
    local ok, result = safe_require(module_path, context)
    if not ok then
        error(tostring(result), 2)
    end
    return result
end

function M.require_or_default(module_path, default, context)
    local options
    if type(context) == "table" then
        options = {}
        for key, value in pairs(context) do
            options[key] = value
        end
        options.default = default
    else
        options = { context = context, default = default }
    end

    local _, result = safe_require(module_path, options)
    return result
end

function M.override_global_require()
    _G.require = function(module_path)
        return M.strict_require(module_path, infer_context())
    end
end

function M.restore_global_require()
    _G.require = original_require
end

setmetatable(M, {
    __call = function(_, module_path, context)
        return safe_require(module_path, context)
    end,
})

return M
