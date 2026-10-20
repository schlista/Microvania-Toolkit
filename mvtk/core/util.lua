-- mvtk/core/util.lua
-- ============================================================================
-- Utility Functions
-- ============================================================================
-- Shared utility helpers for common framework patterns.
-- Provides table pooling, deep copying, and safe message posting.
--
-- Table Pooling:
--   Use acquire_table() / release_table() to reuse tables and reduce GC pressure.
--   Especially useful for frequently created/destroyed data structures.
--
-- Deep Copy:
--   Creates independent copies of nested tables, handling circular references.
--
-- Safe Post:
--   Sends messages with error handling to prevent crashes from invalid URLs.

local Util = {}
local SafeRequire = require "mvtk.core.safe_require"
local config_warning_once = {}

local function log_config_warning_once(path, message)
    local key = tostring(path or "") .. "::" .. tostring(message or "")
    if config_warning_once[key] then
        return
    end
    config_warning_once[key] = true
    print(string.format("[CONFIG] %s: %s", tostring(path or "unknown"), tostring(message or "warning")))
end

local function load_config_resource(path)
    if not (sys and sys.load_resource) then
        return nil, "sys.load_resource unavailable"
    end
    local resource_path = "/" .. tostring(path or ""):gsub("%.", "/") .. ".lua"
    local ok_res, src = pcall(sys.load_resource, resource_path)
    if (not ok_res) or type(src) ~= "string" or src == "" then
        return nil, ok_res and "resource missing or empty" or src
    end
    -- Lua 5.1 provides loadstring; Lua 5.2+ folds the same use case into load.
    local loader = loadstring or load
    if not loader then
        return nil, "Lua loader unavailable"
    end
    local chunk, load_err = loader(src, "@" .. resource_path)
    if not chunk then
        return nil, load_err
    end
    local ok_chunk, mod = pcall(chunk)
    if ok_chunk and type(mod) == "table" then
        return mod, nil
    end
    return nil, ok_chunk and "resource did not return a table" or mod
end

-- ============================================================================
-- TABLE POOLING
-- ============================================================================

-- Pool of reusable tables to reduce garbage collection pressure
local table_pool = {}
local EMPTY_HASH = (type(hash) == "function") and hash("") or nil

local function escape_lua_pattern(s)
    return (tostring(s or ""):gsub("(%W)", "%%%1"))
end

-- Clear all keys from a table (makes it empty but reusable)
-- t: The table to clear
-- Returns: The same table (now empty), or original value if not a table
function Util.clear_table(t)
    if type(t) ~= "table" then
        return t
    end
    -- Remove all key-value pairs
    for k in pairs(t) do
        t[k] = nil
    end
    return t
end

-- Acquire a table from the pool (or create new if pool empty)
-- Returns: An empty table ready for use
--
-- Use this instead of {} to reuse tables and reduce GC:
--   local temp = Util.acquire_table()
--   -- ... use temp ...
--   Util.release_table(temp)
function Util.acquire_table()
    local t = table.remove(table_pool)
    if t then
        -- Reuse pooled table (already cleared)
        return Util.clear_table(t)
    end
    -- Pool empty, create new table
    return {}
end

-- Return a table to the pool for reuse
-- t: The table to release (will be cleared)
--
-- After releasing, don't use the table anymore - it may be reused elsewhere.
-- Releasing non-tables is safe (does nothing).
function Util.release_table(t)
    if type(t) ~= "table" then
        return
    end
    Util.clear_table(t)
    table.insert(table_pool, t)
end

-- ============================================================================
-- DEEP COPY
-- ============================================================================

-- Internal recursive function for deep copying with circular reference handling
-- value: The value to copy (table or primitive)
-- visited: Table tracking already-copied tables (prevents infinite loops)
-- Returns: A deep copy of the value
local function deep_copy_internal(value, visited)
    -- Primitive values (numbers, strings, booleans) are copied directly
    if type(value) ~= "table" then
        return value
    end

    -- If we've already copied this table, return the existing copy
    -- (this handles circular references)
    if visited[value] then
        return visited[value]
    end

    -- Create new table and mark as visited
    local copy = {}
    visited[value] = copy

    -- Recursively copy all keys and values (including nested tables)
    for k, v in pairs(value) do
        copy[deep_copy_internal(k, visited)] = deep_copy_internal(v, visited)
    end

    return copy
end

-- Create a deep copy of a value (independent copy of nested tables)
-- value: Any Lua value (table, number, string, etc.)
-- Returns: A deep copy of the value
--
-- Use this to create independent copies of configuration tables or data structures:
--   local original = {a = 1, b = {c = 2}}
--   local copy = Util.deep_copy(original)
--   copy.b.c = 999  -- doesn't affect original.b.c
--
-- Handles circular references safely (won't infinite loop).
function Util.deep_copy(value)
    return deep_copy_internal(value, {})
end

-- ============================================================================
-- SHALLOW COPY
-- ============================================================================

-- Create a shallow copy of a table (only top-level keys are copied)
-- src: Source table (nil-safe - returns empty table if nil)
-- Returns: A new table with the same top-level key-value pairs
--
-- Use when you need a quick copy without nested table independence:
--   local copy = Util.shallow_copy(original)
--   copy.x = 999  -- doesn't affect original.x
--   copy.nested.y = 1  -- DOES affect original.nested.y (shared reference)
function Util.shallow_copy(src)
    local out = {}
    if not src then return out end
    for k, v in pairs(src) do
        out[k] = v
    end
    return out
end

-- ============================================================================
-- DEEP MERGE
-- ============================================================================

-- Recursively merge source table into destination table (mutates dst)
-- dst: Destination table (modified in-place)
-- src: Source table to merge from (nil-safe)
-- Returns: dst with merged values
--
-- Tables are merged recursively; non-table values overwrite:
--   local base = {a = 1, b = {c = 2, d = 3}}
--   Util.deep_merge(base, {b = {c = 99}, e = 5})
--   -- base is now {a = 1, b = {c = 99, d = 3}, e = 5}
function Util.deep_merge(dst, src)
    for k, v in pairs(src or {}) do
        if type(v) == "table" and type(dst[k]) == "table" then
            Util.deep_merge(dst[k], v)
        else
            if type(v) == "table" then
                -- A table override replaces a scalar rather than indexing it.
                dst[k] = {}
                Util.deep_merge(dst[k], v)
            else
                dst[k] = v
            end
        end
    end
    return dst
end

-- Shallow merge two tables into a new table (does not mutate inputs)
-- a: First table (nil-safe)
-- b: Second table, values override a (nil-safe)
-- Returns: New table with merged key-value pairs
--
--   local combined = Util.merge({x=1, y=2}, {y=3, z=4})
--   -- combined is {x=1, y=3, z=4}
function Util.merge(a, b)
    local out = {}
    for k, v in pairs(a or {}) do out[k] = v end
    for k, v in pairs(b or {}) do out[k] = v end
    return out
end

-- Count top-level keys in a table
-- t: Source table
-- Returns: Number of keys (0 for nil/non-table)
function Util.count_keys(t)
    if type(t) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- MATH UTILITIES
-- ============================================================================

-- Clamp a number between min and max bounds
-- x: Value to clamp
-- lo: Lower bound
-- hi: Upper bound
-- Returns: x constrained to [lo, hi]
--
--   Util.clamp(150, 0, 100) --> 100
--   Util.clamp(-5, 0, 100) --> 0
function Util.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- Clamp a number to [0, 1] range
-- x: Value to clamp (nil-safe, defaults to 0)
-- Returns: x constrained to [0, 1]
function Util.clamp01(x)
    return math.max(0, math.min(1, tonumber(x) or 0))
end

-- Clamp a number to non-negative (>= 0)
-- v: Value to clamp (nil-safe, defaults to 0)
-- Returns: v constrained to >= 0
function Util.clamp_nonneg(v)
    return math.max(0, tonumber(v) or 0)
end

-- Linearly interpolate between two values
-- a: Start value
-- b: End value
-- t: Interpolation factor (0 = a, 1 = b)
-- Returns: Interpolated value
--
--   Util.lerp(0, 100, 0.5) --> 50
function Util.lerp(a, b, t)
    return a + (b - a) * t
end

-- Get the sign of a number
-- x: Input number
-- Returns: -1, 0, or 1
function Util.sign(x)
    if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end
end

-- ============================================================================
-- STRING UTILITIES
-- ============================================================================

-- Trim leading and trailing whitespace from a string
-- s: Input string (nil-safe, returns "" for nil/non-string)
-- Returns: Trimmed string
--
--   Util.trim("  hello world  ") --> "hello world"
--   Util.trim(nil) --> ""
function Util.trim(s)
    if not s then return "" end
    return (tostring(s):match("^%s*(.-)%s*$"))
end

-- Extract a debug wrapper only for callers that explicitly handle engine hashes.
-- TriggerBus also uses this to preserve its existing hexadecimal registry keys.
function Util.hash_wrapper_inner(value)
    return tostring(value or ""):match("^hash:%s*%[(.-)%]$")
end

-- Normalize authored text, or a readable debug hash name. Opaque hashes never
-- become display text or saved text identities. Strings remain authored text.
-- opts.keep_zero: retain "0000000000000000".
-- opts.unknown_as_value: retain the original opaque userdata for runtime registries.
function Util.normalize_hash_string(value, opts)
    if value == nil then return nil end
    opts = opts or {}
    local is_hash = type(value) == "userdata"
    local s = is_hash and Util.hash_wrapper_inner(value) or nil
    if is_hash and s == nil then return nil end
    if not is_hash then s = tostring(value or "") end
    s = Util.trim(s)
    if s == "" then return nil end
    if s:find("<unknown", 1, true) then
        if is_hash and opts.unknown_as_value then return value end
        return nil
    end
    if not opts.keep_zero and s == "0000000000000000" then return nil end
    return s
end

function Util.hash_text(value, default)
    return Util.normalize_hash_string(value) or default
end

-- GO ids can be reversed only when the engine has retained their debug names.
-- A nil result leaves each caller's existing fallback in control.
function Util.go_id_text(id)
    if id == nil then return nil end
    local text = Util.hash_wrapper_inner(id)
    if text == nil then
        if type(id) ~= "string" then return nil end
        text = id
    end
    return Util.normalize_hash_string(text)
end

-- Resolve a property value (hash or string) to a usable ID key.
-- Returns nil for unset/empty/zero hashes while preserving unknown userdata
-- values for systems that need a stable per-instance key.
function Util.resolve_id(value, opts)
    local s = Util.normalize_hash_string(value, opts)
    if s then return s end
    if value == nil then return nil end
    if EMPTY_HASH and value == EMPTY_HASH then return nil end
    local t = tostring(value or "")
    if t == "" or t == "hash: [0000000000000000]" then return nil end
    return value
end

-- Convenience wrapper used by registries that must preserve unknown hash IDs.
function Util.normalize_hash_string_keep_unknown(value)
    return Util.normalize_hash_string(value, {
        unknown_as_value = true,
    })
end

-- Normalize IDs and strip an optional known prefix.
-- Example: normalize_prefixed_id("ability_double_jump", "ability_") => "double_jump"
function Util.normalize_prefixed_id(value, prefix, opts)
    local id = Util.normalize_hash_string(value, opts)
    if not id then
        return nil
    end

    local p = tostring(prefix or "")
    if p ~= "" then
        local stripped = id:match("^" .. escape_lua_pattern(p) .. "(.+)$")
        if stripped and stripped ~= "" then
            id = stripped
        end
    end

    id = Util.trim(id)
    if id == "" then
        return nil
    end
    return id
end

-- Normalize ability IDs from strings/hashes and strip "ability_" prefix.
function Util.normalize_ability_id(value)
    return Util.normalize_prefixed_id(value, "ability_")
end

-- Parse mixed bool-like values from configs/properties.
-- Supports true/false, 1/0, yes/no, on/off.
function Util.to_bool(value, default)
    if value == nil then return default end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    local lower = tostring(value):lower()
    if lower == "true" or lower == "1" or lower == "yes" or lower == "on" then return true end
    if lower == "false" or lower == "0" or lower == "no" or lower == "off" then return false end
    return default
end

-- Convert snake_case or other ID-like strings into a compact display label.
function Util.title_case_id(id)
    local s = tostring(id or ""):gsub("_", " ")
    return (s:gsub("(%a)([%w']*)", function(a, b)
        return string.upper(a) .. string.lower(b)
    end))
end

-- Normalize either (x, y) numbers or a table-like point.
-- Accepts {x=..., y=...} or { [1]=x, [2]=y }.
function Util.normalize_xy(x, y)
    if type(x) == "table" then
        local t = x
        return tonumber(t.x) or tonumber(t[1]), tonumber(t.y) or tonumber(t[2])
    end
    return tonumber(x), tonumber(y)
end

-- Chest and wall identities retain their historical hexadecimal hash form.
-- Authored text is hashed exactly as supplied; display text never uses this helper.
function Util.hash_key_hex(value)
    if type(value) == "string" then
        if value == "" then return nil end
        return hash_to_hex(hash(value))
    end
    if type(value) == "userdata" then
        local ok, key = pcall(hash_to_hex, value)
        if ok then return key end
    end
    return nil
end

-- Convert Defold hash/userdata into a stable string key.
function Util.hash_to_stable_string(h)
    if h == nil then return "" end
    if type(h) == "string" then return h end
    if EMPTY_HASH and h == EMPTY_HASH then return "" end
    if type(h) == "userdata" then
        local name = Util.hash_wrapper_inner(h)
        if name and not name:find("<unknown", 1, true) then return name end
        if hash_to_hex then
            local ok, hex = pcall(hash_to_hex, h)
            if ok and type(hex) == "string" then return hex end
        end
        return ""
    end
    return Util.trim(h)
end

-- ============================================================================
-- SAFE GAME OBJECT HELPERS
-- ============================================================================

-- Safely check if a game object exists (wraps go.exists in pcall)
-- url: URL to check
-- Returns: true if the game object exists, false otherwise
--
-- Use this for URLs that might be invalid or from unloaded collections:
--   if Util.safe_exists(url) then msg.post(url, "my_message") end
function Util.safe_exists(url)
    if not url then return false end
    local ok, exists = pcall(go.exists, url)
    return ok and exists
end

-- Safely resolve strings into msg.url values while preserving existing URL
-- userdata. Returns nil for invalid or unset values.
function Util.resolve_url(value)
    if value == nil then return nil end
    if type(value) == "userdata" then return value end
    if not msg or not msg.url then return nil end
    local ok, out = pcall(msg.url, value)
    return ok and out or nil
end

function Util.resolve_first_url(...)
    for i = 1, select("#", ...) do
        local url = Util.resolve_url(select(i, ...))
        if url then
            return url
        end
    end
    return nil
end

-- ============================================================================
-- SAFE MESSAGE POSTING
-- ============================================================================

-- Safely post a message with error handling
-- target_url: URL, hash, or string identifying the target
-- message_id: Hash of the message to send
-- message: Optional payload table
-- on_error_or_opts: Either a legacy on_error(err) function, OR an opts table:
--   {
--     on_error = function(err) ... end, -- optional callback on post failure
--     check_exists = true,              -- if true, skip post unless safe_exists(url)
--     logger = <logger>,                -- optional logger (Logger.get_logger result)
--                                       -- failures route to logger.warn when on_error is nil
--   }
-- Returns: true if message sent successfully, false otherwise
--
-- Examples:
--   Util.safe_post(C.URL.PLAYER, hash("take_damage"), { amount = 10 })
--   Util.safe_post(url, hash("foo"), {}, function(err) print(err) end)
--   Util.safe_post(url, hash("foo"), {}, { check_exists = true, logger = log })
function Util.safe_post(target_url, message_id, message, on_error_or_opts)
    if not target_url or not message_id then
        return false
    end

    -- Resolve legacy function arg vs new opts-table arg.
    local on_error, opts
    if type(on_error_or_opts) == "table" then
        opts = on_error_or_opts
        on_error = opts.on_error
    else
        on_error = on_error_or_opts
    end

    -- Optional pre-flight existence check.
    if opts and opts.check_exists and not Util.safe_exists(target_url) then
        if opts.logger and opts.logger.warn then
            opts.logger.warn("safe_post: target does not exist: %s",
                tostring(target_url))
        end
        return false
    end

    local payload = message or {}
    local ok, err = pcall(msg.post, target_url, message_id, payload)

    if not ok then
        if on_error then
            pcall(on_error, err)
        elseif opts and opts.logger and opts.logger.warn then
            opts.logger.warn("safe_post failed: %s -> %s: %s",
                tostring(target_url), tostring(message_id), tostring(err))
        end
    end

    return ok
end

-- ============================================================================
-- DEBUG LOG FACTORY
-- ============================================================================

-- Create a tagged debug logging function with a custom condition check
-- tag: String prefix for log messages (e.g., "[ENEMY_MGR]")
-- check_fn: Function returning true when logging should be active
-- Returns: Function that prints tag + args when check_fn() is true
--
-- This replaces the common pattern of defining per-module log functions:
--   local enemy_log = Util.make_debug_log("[ENEMY_MGR]", function()
--       return Debug.global.enable or (Debug.gameplay and Debug.gameplay.enemies)
--   end)
--   enemy_log("Spawned %d enemies", count)  -- prints: [ENEMY_MGR] Spawned 5 enemies
function Util.make_debug_log(tag, check_fn)
    return function(...)
        if check_fn() then
            print(tag, ...)
        end
    end
end

-- ============================================================================
-- CONFIG LOADING HELPER
-- ============================================================================

-- Require a config module, failing loudly unless the caller provides a fallback.
-- path: Module path string (e.g., "developer.config.player_settings")
-- fallback: Optional value to return if module is missing or not a table.
--           Omit this argument for required configs.
-- Returns: The loaded module, or the explicit fallback.
--
-- Replaces the common pattern:
--   local ok, Config = pcall(require, "developer.config.foo")
--   if not ok or type(Config) ~= "table" then Config = {} end
-- With:
--   local Config = Util.require_config("developer.config.foo")
function Util.require_config(path, ...)
    local has_fallback = select("#", ...) > 0
    local fallback = select(1, ...)
    local ok, mod = pcall(require, path)
    if ok and type(mod) == "table" then
        return mod
    end
    local resource_mod, resource_err = load_config_resource(path)
    if type(resource_mod) == "table" then
        log_config_warning_once(path, "require() failed, loaded resource fallback")
        return resource_mod
    end
    local failure
    if not ok then
        failure = "require() failed and resource fallback failed: " .. tostring(resource_err or mod)
    elseif type(mod) ~= "table" then
        failure = "module did not return a table and resource fallback failed: " .. tostring(resource_err)
    else
        failure = "resource fallback failed: " .. tostring(resource_err)
    end
    if has_fallback then
        log_config_warning_once(path, failure .. "; using explicit fallback")
        return fallback
    end
    error(string.format("Missing required config %s: %s", tostring(path), failure), 2)
end

-- ============================================================================
-- DOT-PATH TABLE TRAVERSAL
-- ============================================================================

-- Traverse a nested table using a dot-separated path string
-- tbl: Root table to traverse
-- path: Dot-separated path (e.g., "a.b.c" traverses tbl.a.b.c)
-- Returns: Value at path, or nil if any segment is missing
--
--   Util.get_nested({a = {b = {c = 42}}}, "a.b.c") --> 42
--   Util.get_nested({a = 1}, "a.b.c") --> nil
function Util.get_nested(tbl, path)
    local node = tbl
    for token in string.gmatch(tostring(path or ""), "[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[token]
    end
    return node
end

-- ============================================================================
-- DISTANCE UTILITIES
-- ============================================================================

-- Squared distance between two points (avoids sqrt for comparisons)
-- x1, y1: First point
-- x2, y2: Second point
-- Returns: Squared Euclidean distance
--
-- Use for distance comparisons instead of vmath.length which computes sqrt:
--   if Util.dist_sq(ax, ay, bx, by) < range * range then ...
function Util.dist_sq(x1, y1, x2, y2)
    local dx = (x2 or 0) - (x1 or 0)
    local dy = (y2 or 0) - (y1 or 0)
    return dx * dx + dy * dy
end

-- ============================================================================
-- CHECKPOINT REGISTRATION HELPER
-- ============================================================================

-- Register a module as a checkpoint save/load provider with standard boilerplate
-- id: String identifier for this provider (e.g., "flags", "bank", "inventory")
-- provider: Table with capture(), apply(data), defaults(), and optional version/order/mirror_key/description
--
-- Eliminates the repeated pattern of pcall(require, "mvtk.core.checkpoint") + register_provider
-- found in flags.lua, inventory.lua, bank.lua, fast_travel.lua, etc.
function Util.register_checkpoint_provider(id, provider)
    local ok, Checkpoint = SafeRequire("mvtk.core.checkpoint", "mvtk.core.util.register_checkpoint_provider")
    if not ok or not Checkpoint or not Checkpoint.register_provider then
        return false
    end
    Checkpoint.register_provider(id, provider)
    return true
end

-- ============================================================================
-- COMPONENT PRESENCE
-- ============================================================================

-- Does a component exist on this game object?
--
-- `pcall(msg.post, "#sprite", "disable")` does NOT protect against a missing
-- component: msg.post only queues, and the engine logs
--   ERROR:GAMEOBJECT: Component '...#sprite' could not be found when
--   dispatching message 'disable'
-- later in the frame, long after pcall returned success. Baked room objects
-- routinely omit the sprite (the Tiled tile layer owns the art), so each such
-- post spams the console on every toggle.
--
-- go.get IS synchronous, so a pcall around it is a real existence probe.
-- Sprites/models/labels all expose `tint`. Probe each time: relative URLs such
-- as #sprite resolve against the calling object, while this module is shared
-- across all scripts. Even absolute URLs may be reused after a room unload.
function Util.component_exists(url, probe_property)
    if url == nil then return false end
    if go and go.get then
        return pcall(go.get, url, probe_property or "tint") and true or false
    end
    return false
end

-- Components a script has turned OFF, keyed by instance ("socket|path") then
-- fragment. RoomManager hides and shows streamed rooms by posting "enable" /
-- "disable" to every game object, and a game-object-level "enable" turns ALL
-- of its components back on (an open door's collision, a hidden sprite...).
-- RoomManager calls Util.reapply_disabled_components after showing a room so
-- scripted state survives. Only disabled components are recorded.
local disabled_components = {}

local function component_record_key(url)
    if not (msg and msg.url) then return nil end
    local ok, resolved = pcall(msg.url, url)
    if not ok or resolved == nil then return nil end
    local fragment = resolved.fragment
    if fragment == nil then return nil end
    return tostring(resolved.socket) .. "|" .. tostring(resolved.path), tostring(fragment), resolved
end

-- Remember the desired enabled state of a component for room re-enables.
function Util.record_component_enabled(url, enabled)
    local key, fragment, resolved = component_record_key(url)
    if not key then return end
    local entry = disabled_components[key]
    if enabled then
        if entry then
            entry[fragment] = nil
            if next(entry) == nil then disabled_components[key] = nil end
        end
    else
        if not entry then
            entry = {}
            disabled_components[key] = entry
        end
        entry[fragment] = resolved
    end
end

-- Enable/disable a component the caller knows exists (collision objects have
-- no `tint` to probe). Records the state for room re-enables.
function Util.post_component_enabled(url, enabled)
    Util.record_component_enabled(url, enabled)
    msg.post(url, enabled and "enable" or "disable")
    return true
end

-- Re-post "disable" to every recorded component of one game object. Returns
-- the number of components re-disabled.
function Util.reapply_disabled_components(go_url)
    if not (msg and msg.url) then return 0 end
    local ok, resolved = pcall(msg.url, go_url)
    if not ok or not resolved then return 0 end
    local key = tostring(resolved.socket) .. "|" .. tostring(resolved.path)
    local entry = disabled_components[key]
    if not entry then return 0 end
    -- Room creation lists outlive enemies/pickups deleted during play.
    -- msg.post only queues a message; pcall cannot catch dispatch to a dead GO.
    if not Util.safe_exists(resolved) then
        disabled_components[key] = nil
        return 0
    end
    local count = 0
    for _, component_url in pairs(entry) do
        if pcall(msg.post, component_url, "disable") then count = count + 1 end
    end
    return count
end

-- Drop recorded state for a deleted game object (room unload).
function Util.forget_component_states(go_url)
    if not (msg and msg.url) then return end
    local ok, resolved = pcall(msg.url, go_url)
    if not ok or not resolved then return end
    disabled_components[tostring(resolved.socket) .. "|" .. tostring(resolved.path)] = nil
end

-- Enable/disable a component only when it actually exists.
-- Returns true when the message was posted.
function Util.set_component_enabled(url, enabled, probe_property)
    if not Util.component_exists(url, probe_property) then
        return false
    end
    Util.record_component_enabled(url, enabled)
    msg.post(url, enabled and "enable" or "disable")
    return true
end

-- ============================================================================
-- OPTIONAL MODULE LOADING
-- ============================================================================

-- Safely require an optional module, returning nil on failure.
-- Unlike require_config (which returns a fallback table), this is for modules
-- that expose functions/methods (Audio, FX, ScreenShake, etc.) where a nil
-- check is the natural guard.
--
-- Replaces the common pattern:
--   local ok, Audio = pcall(require, "mvtk.audio.audio")
--   if not ok then Audio = nil end
-- With:
--   local Audio = Util.require_module("mvtk.audio.audio")
function Util.require_module(path)
    local ok, mod = SafeRequire(path, "mvtk.core.util.require_module")
    if ok then return mod end
    return nil
end

-- ============================================================================
-- ROOM ID NORMALIZATION
-- ============================================================================

-- Normalize a room identifier into a canonical short form.
-- Strips leading slashes, "developer/rooms/" prefixes, ".collection" suffixes,
-- backslash-to-slash conversion, and dot-notation prefixes.
--
-- Consolidates 13+ inline gsub chains scattered across the codebase:
--   room_manager, game_manager, tiled_room_registry, minimap_outline, etc.
--
-- Examples:
--   Util.normalize_room_id("/developer/rooms/graveyard.collection") --> "graveyard"
--   Util.normalize_room_id("developer.rooms.graveyard")            --> "graveyard"
--   Util.normalize_room_id("graveyard")                            --> "graveyard"
--   Util.normalize_room_id(nil)                                    --> ""
function Util.normalize_room_id(room_id)
    if room_id == nil then return "" end
    local s = tostring(room_id)
    if s == "" then return "" end
    s = s:gsub("\\", "/")
    s = s:gsub("^/+", "")
    s = s:gsub("^developer/rooms/", "")
    s = s:gsub("^developer%.rooms%.", "")
    s = s:gsub("%.collection$", "")
    s = s:gsub("%.tilemap$", "")
    -- If a path separator remains, take only the basename
    if s:find("/", 1, true) then
        s = s:match("([^/]+)$") or s
    end
    return s
end

-- ============================================================================
-- CSV / PROPERTY PARSING
-- ============================================================================

-- Parse a comma-separated string into a list of trimmed, non-empty strings.
-- Empty input, nil, or tables are handled safely (nil/empty => empty list;
-- existing list => returned unchanged after ipairs copy for safety).
--
--   Util.parse_csv_list("fire, ice ,  ") --> {"fire", "ice"}
--   Util.parse_csv_list(nil)             --> {}
function Util.parse_csv_list(value)
    local out = {}
    if value == nil then return out end
    if type(value) == "table" then
        for _, v in ipairs(value) do
            local s = Util.trim(tostring(v or ""))
            if s ~= "" then table.insert(out, s) end
        end
        return out
    end
    local s = tostring(value)
    for token in string.gmatch(s, "[^,]+") do
        local trimmed = Util.trim(token)
        if trimmed ~= "" then
            table.insert(out, trimmed)
        end
    end
    return out
end

-- Parse a string/table of IDs into a de-duplicated list of normalized IDs.
-- Accepts comma, semicolon, and whitespace separated string values.
function Util.parse_id_list(value)
    local out = {}
    local seen = {}

    local function add(raw)
        local id = Util.normalize_hash_string(raw)
        if id and id ~= "" and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end

    if type(value) == "table" then
        for _, id in ipairs(value) do
            add(id)
        end
        return out
    end

    local s = Util.normalize_hash_string(value)
    if not s then return out end
    for token in s:gmatch("[^,%s;]+") do
        add(token)
    end
    return out
end

-- Parse requirement fields from config. A single string remains one
-- requirement; arrays are copied after trimming empty entries.
function Util.parse_requirements(value)
    if type(value) == "string" then
        local s = Util.trim(value)
        if s == "" then return nil end
        return { s }
    end
    if type(value) ~= "table" then return nil end

    local out = {}
    for _, id in ipairs(value) do
        local s = Util.trim(tostring(id or ""))
        if s ~= "" then
            out[#out + 1] = s
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Parse a phase specifier ("1,3,5" or "1-3" or "2") into a set of ints.
-- Used by arena boundaries / hazards / weak points to know which phases
-- they are active in. Returns empty table for nil/empty input (caller
-- decides if "empty set" means "all phases" or "no phases").
--
--   Util.parse_phase_set("1,3")   --> {[1]=true, [3]=true}
--   Util.parse_phase_set("2-4")   --> {[2]=true, [3]=true, [4]=true}
--   Util.parse_phase_set("")      --> {}
function Util.parse_phase_set(value)
    local set = {}
    if value == nil or value == "" then return set end
    if type(value) == "number" then
        set[math.floor(value)] = true
        return set
    end
    local s = tostring(value)
    for token in string.gmatch(s, "[^,%s]+") do
        local lo, hi = token:match("^(%-?%d+)%s*%-%s*(%-?%d+)$")
        if lo and hi then
            local a, b = tonumber(lo), tonumber(hi)
            if a and b then
                if a > b then a, b = b, a end
                for i = a, b do set[i] = true end
            end
        else
            local n = tonumber(token)
            if n then set[math.floor(n)] = true end
        end
    end
    return set
end

-- Resolve a Tiled override against a config preset.
-- Encodes the toolkit convention that `0` or `""` on a Tiled property means
-- "use the preset value". Call sites can opt out by passing zero_means_preset=false
-- when a literal 0 is a meaningful value (e.g. damage=0 for a healing attack).
--
--   Util.resolve_preset_or_override(0, 100)   --> 100  (0 means "use preset")
--   Util.resolve_preset_or_override(50, 100)  --> 50
--   Util.resolve_preset_or_override("", "x")  --> "x"
--   Util.resolve_preset_or_override(nil, "x") --> "x"
function Util.resolve_preset_or_override(override, preset, zero_means_preset)
    if zero_means_preset == nil then zero_means_preset = true end
    if override == nil then return preset end
    if type(override) == "string" then
        if Util.trim(override) == "" then return preset end
        return override
    end
    if type(override) == "number" then
        if zero_means_preset and override == 0 then return preset end
        return override
    end
    return override
end

-- Build a sanitized room key suitable for use in stable IDs.
-- Strips path components and replaces non-alphanumeric chars with underscores.
--
-- Replaces the repeated pattern in object_spawner.lua:
--   local room_key = tostring(room_id or "room")
--       :gsub("^.*/", ""):gsub("%.collection$", ""):gsub("[^%w_]+", "_")
--
-- Examples:
--   Util.room_key("developer/rooms/graveyard.collection") --> "graveyard"
--   Util.room_key(nil)                                     --> "room"
function Util.room_key(room_id)
    local s = Util.normalize_room_id(room_id)
    s = s:gsub("[^%w_]+", "_")
    if s == "" then s = "room" end
    return s
end

return Util
