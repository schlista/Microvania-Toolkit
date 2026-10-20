-- mvtk/rooms/layout_io.lua
local M = {}
local Util = require "mvtk.core.util"
local RuntimeLayoutLoader = require "mvtk.rooms.runtime_layout_loader"
local SavePaths = require "mvtk.core.save_paths"

local function fallback_deep_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[fallback_deep_copy(k)] = fallback_deep_copy(v)
    end
    return copy
end

local function require_config(path, fallback)
    if type(Util) == "table" and type(Util.require_config) == "function" then
        return Util.require_config(path, fallback)
    end
    local ok, mod = pcall(require, path)
    if ok and type(mod) == "table" then
        return mod
    end
    return fallback or {}
end

local Debug = require_config("developer.config.debug_config", {})

local layout_signature

local function layout_log(...)
    if (Debug.global and Debug.global.enable) or (Debug.rooms and Debug.rooms.layout_io) then
        print(...)
    end
end

local function room_dump_log(...)
    if (Debug.global and Debug.global.enable) or (Debug.rooms and Debug.rooms.room) then
        print(...)
    end
end

local FILE = "world_layout.json"
-- Bump when changing on-disk semantics
-- v0x6: room positions are saved in collection-root space; adds per-room offsets (ox, oy)
-- v0x7: snap room bases to tile grid, persist tile step (tw, th), and include door metadata
-- v0x8: persist room tag metadata used by layout-derived POI markers
local CURRENT_VERSION = 0x8
-- Runtime layout prefers the local export written by the layout editor
-- and falls back to the bundled module in developer/runtime/layout/world_layout.lua.

-- Forward declaration
local layout_signature

-- Expose version so callers can tag data they write
M.VERSION = CURRENT_VERSION
layout_signature = function(layout)
    if not layout or type(layout.rooms) ~= "table" then return "(no rooms)" end
    local count = #layout.rooms
    local parts = { string.format("rooms=%d", count) }
    local max_samples = math.min(count, 5)
    for i = 1, max_samples do
        local rec = layout.rooms[i]
        if rec then
            parts[#parts + 1] = string.format("%s:(%.1f,%.1f)%.1fx%.1f",
                tostring(rec.id),
                tonumber(rec.x) or 0,
                tonumber(rec.y) or 0,
                tonumber(rec.w) or 0,
                tonumber(rec.h) or 0)
        end
    end
    return table.concat(parts, " | ")
end

M.signature = layout_signature

local function save_path()
    return SavePaths.path(FILE, "layout")
end

local deep_copy = (type(Util) == "table" and type(Util.deep_copy) == "function")
    and Util.deep_copy
    or fallback_deep_copy

local function clone_room_list(src)
    local out = {}
    if type(src) ~= "table" then
        return out
    end
    for _, room in ipairs(src) do
        if type(room) == "table" then
            local copy = {}
            for k, v in pairs(room) do
                copy[k] = deep_copy(v)
            end
            out[#out + 1] = copy
        else
            out[#out + 1] = room
        end
    end
    return out
end

local function load_runtime_layout()
    local runtime, source_or_err = RuntimeLayoutLoader.load({ reload_module = true })
    if type(runtime) ~= "table" then
        layout_log(string.format("DEBUG:SCRIPT: [LayoutIO] Runtime layout load failed: %s", tostring(source_or_err)))
        return nil
    end

    local rooms = clone_room_list(runtime.rooms or {})
    local version = tonumber(runtime.version) or CURRENT_VERSION
    layout_log(string.format("DEBUG:SCRIPT: [LayoutIO] Loaded runtime layout from %s (rooms=%d)", tostring(source_or_err), #rooms))
    layout_log(string.format("DEBUG:SCRIPT: [LayoutIO] Runtime module signature: %s", layout_signature({ rooms = rooms })))
    return { version = version, rooms = rooms, preserve_origin = runtime.preserve_origin, source = runtime.source }
end

local function runtime_or_empty()
    local data = load_runtime_layout()
    if data then
        return data
    end
    layout_log("[LayoutIO] No layout, starting empty")
    return { version = CURRENT_VERSION, rooms = {} }
end

local function should_prefer_runtime(opts)
    if type(opts) ~= "table" then
        return false
    end
    if opts.runtime_preferred == true then
        return true
    end
    local source = opts.source
    if type(source) == "string" then
        local key = source:lower()
        if key == "runtime" or key == "export" then
            return true
        end
    end
    return false
end

local function load_saved_layout(path)
    local ok, data = pcall(sys.load, path)
    if ok and data and type(data) == "table" then
        local rooms = type(data.rooms) == "table" and data.rooms or nil
        local version = tonumber(data.version) or CURRENT_VERSION
        local valid_rooms = rooms and #rooms > 0
        local version_mismatch = version ~= CURRENT_VERSION

        if valid_rooms and not version_mismatch then
            layout_log(("DEBUG:SCRIPT: [LayoutIO] Load <- %s  (rooms=%d)")
                :format(path, #(rooms or {})))
            layout_log(("DEBUG:SCRIPT: [LayoutIO] Loaded signature: %s"):format(layout_signature({ rooms = rooms })))

            -- Debug: print room details
            for i, room in ipairs(rooms) do
                if room and type(room) == "table" then
                    room_dump_log(string.format('[ROOM] %s pos=(%.1f,%.1f) size=(%.1fx%.1f) neighbors=%d',
                        tostring(room.id),
                        room.x or 0, room.y or 0,
                        room.w or 0, room.h or 0,
                        #(room.neighbors or {})))
                else
                    room_dump_log(string.format('[ROOM] invalid room entry at index %d', i))
                end
            end

            return { version = version, rooms = rooms, preserve_origin = data.preserve_origin, source = data.source }
        end

        layout_log(string.format("DEBUG:SCRIPT: [LayoutIO] Ignoring stale layout save (version=%s, rooms=%s); using runtime layout instead",
            tostring(data.version), valid_rooms and "#"..tostring(#rooms) or "nil"))
        return nil
    end

    if not ok then
        layout_log(string.format("DEBUG:SCRIPT: [LayoutIO] sys.load failed for %s: %s", path, tostring(data)))
    else
        layout_log(string.format("DEBUG:SCRIPT: [LayoutIO] sys.load returned unexpected data: %s", type(data)))
    end
    return nil
end

-- Normalize layout so the minimum room origin is at (0,0) to keep runtime spawns sane.
local function normalize_layout_origin(layout)
    if layout and layout.preserve_origin then layout.origin_shift = {x=0,y=0}; return layout end
    if not layout or type(layout.rooms) ~= "table" or #layout.rooms == 0 then
        return layout
    end
    local min_x, min_y = math.huge, math.huge
    for _, room in ipairs(layout.rooms) do
        if room and room.x then min_x = math.min(min_x, room.x) end
        if room and room.y then min_y = math.min(min_y, room.y) end
    end
    -- Record the original offset so other systems (minimap/world map) can
    -- translate runtime-normalised coordinates back into the baked-map space.
    if min_x == math.huge then min_x = 0 end
    if min_y == math.huge then min_y = 0 end
    layout.origin_shift = { x = min_x, y = min_y }
    if min_x ~= 0 or min_y ~= 0 then
        layout_log(string.format("[LayoutIO] Normalizing layout origin by (%.1f, %.1f)", min_x, min_y))
        for _, room in ipairs(layout.rooms) do
            if room then
                room.x = (room.x or 0) - min_x
                room.y = (room.y or 0) - min_y
            end
        end
    end
    return layout
end

function M.save(layout)
    local out = {
        version = CURRENT_VERSION,
        rooms   = (layout and layout.rooms) or {},
        preserve_origin = layout and layout.preserve_origin,
        source = layout and layout.source,
    }
    layout_log(("DEBUG:SCRIPT: [LayoutIO] === SAVE OPERATION START ==="))
    layout_log(("DEBUG:SCRIPT: [LayoutIO] Input layout: %s"):format(layout and "table" or "nil"))
    layout_log(("DEBUG:SCRIPT: [LayoutIO] Input rooms count: %d"):format(#(out.rooms or {})))
    layout_log(("DEBUG:SCRIPT: [LayoutIO] Input signature: %s"):format(layout_signature(out)))
    layout_log(("DEBUG:SCRIPT: [LayoutIO] Save path: %s"):format(save_path()))
    
    local ok = sys.save(save_path(), out)
    layout_log(("DEBUG:SCRIPT: [LayoutIO] sys.save result: %s"):format(tostring(ok)))
    layout_log(("DEBUG:SCRIPT: [LayoutIO] Save -> %s  (ok=%s, rooms=%d)")
    :format(save_path(), tostring(ok), #(out.rooms or {})))
    layout_log(("DEBUG:SCRIPT: [LayoutIO] === SAVE OPERATION END ==="))
    return ok
end

function M.load(opts)
    -- Check if sys module is available (may not be in editor context)
    if not sys or not sys.load then
        layout_log('DEBUG:SCRIPT: [LayoutIO] sys module not available, falling back to runtime module')
        return normalize_layout_origin(runtime_or_empty())
    end

    local path = save_path()
    if should_prefer_runtime(opts) then
        local runtime = load_runtime_layout()
        if runtime and runtime.rooms and #runtime.rooms > 0 then
            layout_log("DEBUG:SCRIPT: [LayoutIO] runtime_preferred=true; using runtime layout module")
            return normalize_layout_origin(runtime)
        end
        if opts and opts.read_only then return {version=CURRENT_VERSION,rooms={}} end
        layout_log("DEBUG:SCRIPT: [LayoutIO] runtime_preferred=true but runtime module unavailable; falling back to save file")
    end

    local saved = load_saved_layout(path)
    if saved then
        return normalize_layout_origin(saved)
    end

    -- Fallback to runtime layout (fresh export) and update save on disk so future loads are correct
    local runtime = runtime_or_empty()
    if runtime and runtime.rooms and #runtime.rooms > 0 and sys and sys.save and not (opts and opts.read_only) then
        M.save(runtime)
    end
    return normalize_layout_origin(runtime)
end

-- Normalize a human-entered id like "/room_4" or "room_4" into
-- canonical "room_04" (zero-padded) or return unchanged for non-numeric suffixes.
-- zero_pad: digits, default 2
function M.normalize_id(id, zero_pad)
    if type(id) ~= "string" then return id end
    local raw = id:gsub("^/+", "")
    local pad_w = tonumber(zero_pad) or 2
    local prefix, num = raw:match("^(.-)_(%d+)$")
    if prefix and num and #num < pad_w then
        return string.format("%s_%0"..pad_w.."d", prefix, tonumber(num))
    end
    return raw
end

-- Helper to produce a resource-ish path used by rooms_config
function M.path_for_id(id)
    if type(id) ~= "string" then return nil end
    local rid = M.normalize_id(id)
    if rid:match('^developer/rooms/') then return rid end
    return 'developer/rooms/' .. rid
end

return M
