-- mvtk/map/streaming/room_manager.lua
-- Room streaming manager for loading/unloading rooms

local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")
local Config = Util.require_config("developer.config.resolved_config")
local C = require "mvtk.core.constants"
local StreamS = Util.require_config("developer.config.stream_settings")
local Geometry = require("mvtk.rooms.tilemap_geometry")
local LockCfg = Util.require_config("developer.config.locked_door_settings")
local Debug = Util.require_config("developer.config.debug_config", { global = {}, rooms = {} })
local AmbienceConfig = Util.require_config("developer.config.ambience_tracks")
local MusicTracks = Util.require_config("developer.config.music_tracks_generated", { tracks = {}, ids = {} })
local GameplayConstants = Util.require_module("developer.config.gameplay_constants")
local FrameWatch = require "mvtk.core.frame_watch"
local FactoryResources = require "mvtk.map.streaming.factory_resources"
local WorldProperties = require "mvtk.tiled.world_properties"

-- Phase 5 step 32: pure helper extractions. These submodules hold the
-- stateless geometry / color / normalization helpers that used to live as
-- file-locals in this manager. The manager keeps the streaming lifecycle
-- and shared mutable state.
local RoomGeom = require "mvtk.map.streaming.room_geometry"
local RoomColors = require "mvtk.map.streaming.room_colors"
local RoomLookahead = require "mvtk.map.streaming.room_lookahead"
local StartupResources = require "mvtk.map.streaming.startup_resources"
local SecretVisibility = require "mvtk.map.secret_visibility"
local world_secrets = SecretVisibility.compile(require "developer.config.secret_rooms", "hidden_in_world")

local M = {}
local seam_log = Util.make_debug_log("[SEAM]", function()
    return (Debug.global and Debug.global.enable) or (Debug.rooms and Debug.rooms.seam)
        or (LockCfg and LockCfg.debug and LockCfg.debug.prints)
end)

local room_log = Util.make_debug_log("[ROOM]", function()
    return Debug.global.enable or Debug.rooms.room_manager
end)

local align_log = Util.make_debug_log("[ALIGN]", function()
    return Debug.global.enable or Debug.rooms.align
end)

local transition_log = Util.make_debug_log("[TRANSITION]", function()
    return Debug.global.enable or Debug.rooms.transitions
end)

local function get_tiled_room_metadata(room_id)
    if not room_id then
        return {}
    end
    local ok_reg, Registry = pcall(require, "mvtk.tiled.tiled_room_registry")
    if ok_reg and Registry and Registry.get_room_metadata then
        local meta = Registry.get_room_metadata(room_id)
        if type(meta) == "table" then
            return meta
        end
    end
    return {}
end

local function resolve_room_environment(room_id, room_data)
    if not room_id then
        return nil
    end

    local meta = get_tiled_room_metadata(room_id)
    local tags = type(room_data and room_data.tags) == "table" and room_data.tags or nil

    local biome = meta.biome
    if (not biome or biome == "") and tags then
        biome = tags.biome
    end

    local ambience = meta.music or meta.ambience
    if (not ambience or ambience == "") and tags then
        ambience = tags.ambience or tags.music
    end

    if (not biome or biome == "") and (not ambience or ambience == "") and not meta.ambient_sound then
        return nil
    end

    return {
        biome = biome,
        ambience = ambience,
        music_raw = meta.music_raw or ambience,
        ambient_sound = meta.ambient_sound,
        world_music_enabled = meta.world_music_enabled,
    }
end

local function is_registered_music_track(track_id)
    local id = tostring(track_id or "")
    if id == "" or type(MusicTracks) ~= "table" then
        return false
    end
    local tracks = MusicTracks.tracks
    if type(tracks) == "table" and tracks[id] ~= nil then
        return true
    end
    local ids = MusicTracks.ids
    if type(ids) == "table" then
        for _, value in ipairs(ids) do
            if tostring(value) == id then
                return true
            end
        end
    end
    return MusicTracks[id] == true or type(MusicTracks[id]) == "table"
end

local missing_music_warned = {}

local function warn_missing_music_track(room_id, raw_value, track_key)
    local key = tostring(room_id or "") .. "|" .. tostring(track_key or "")
    if missing_music_warned[key] then
        return
    end
    missing_music_warned[key] = true
    print(string.format(
        "[ROOM_MANAGER] Room '%s' requested music '%s' (raw '%s'), but that track is not registered. Run Project > Prepare & Check.",
        tostring(room_id), tostring(track_key), tostring(raw_value or "")))
end

local current_room_id = nil
local pending_current_room_id = nil
local room_runtime = {}
local current_music_track = nil  -- Track currently playing music to avoid restarting
local current_ambient_sound = nil
local last_room_transition_time = 0  -- Prevent rapid room bouncing
local pending_music_room_id = nil
local last_transition_clock = 0
local last_transition_frame = -1
local room_positions = {}
local room_graph = {}
local room_doors = {}
local room_geometry = {}
local player_url = nil
local pending_unloads = {}
local transition_grace_t = 0
local room_frame = 0
local room_clock = 0
local rooms_to_promote = {}
local next_room_generation = 0
local next_unload_token = 0
local load_queue = {}
local load_queued = {}
local unload_queue = {}
local unload_queued = {}
local desired_rooms = {}
local streaming_dirty = true
local streaming_safety_elapsed = 0
local streaming_reconcile_count = 0
local lookahead_room_id = nil
local previous_player_position = nil
local previous_player_room = nil
local startup_resources = nil
local secret_flags_revision = nil
local hidden_world_rooms = {}
-- Controlled traversal (for example, a cross-room elevator) needs stronger
-- guarantees than the ordinary player-proximity streamer provides. Pins keep
-- route rooms loaded, and selected pins also keep the room enabled while a
-- handoff is in progress. The opaque handoff token contains an epoch and a
-- generation so a delayed message from an older ride cannot affect a newer
-- one.
local room_pins = {}
local handoffs = {}
local active_handoff_token = nil
local handoff_epoch = 0
local next_handoff_generation = 0

local ROOM_STATE_LOADING = "loading"
local ROOM_STATE_PREPARING = "preparing"
local ROOM_STATE_READY = "ready"
local ROOM_STATE_CURRENT = "current"
local ROOM_STATE_UNLOADING = "unloading"

local keep_all_loaded = (StreamS and StreamS.room and StreamS.room.keep_all_loaded) or false
local DEFAULT_PRELOAD_DISTANCE = 1
local function get_preload_distance()
    if keep_all_loaded then
        return math.huge
    end
    local room_settings = StreamS and StreamS.room or {}
    local configured = tonumber(room_settings.preload_distance)
    if configured ~= nil then
        return math.max(0, math.floor(configured))
    end
    local preload_x = tonumber(room_settings.preload_x)
    local preload_y = tonumber(room_settings.preload_y)
    if preload_x ~= nil or preload_y ~= nil then
        return math.max(0, math.floor(math.max(preload_x or 1, preload_y or 1)))
    end
    return DEFAULT_PRELOAD_DISTANCE
end
local LOAD_BUDGET_PER_FRAME = math.max(0, math.floor(tonumber(
    StreamS and StreamS.room and StreamS.room.load_budget_per_frame) or 1))
local UNLOAD_BUDGET_PER_FRAME = math.max(0, math.floor(tonumber(
    StreamS and StreamS.room and StreamS.room.unload_budget_per_frame) or 1))
local UNLOAD_DELETE_CHUNK_SIZE = math.max(1, math.floor(tonumber(
    StreamS and StreamS.room and StreamS.room.unload_delete_chunk_size) or 24))
local STREAMING_SAFETY_INTERVAL = 0.5
local TRANSITION_THRESHOLD = 50 -- Distance from room edge to trigger transition
local DOOR_PROX_THRESHOLD = 256 -- Require proximity to a door before auto-transition
local SPAWN_GRACE_TIME = 0.45   -- seconds to ignore transitions right after spawn/load
local MUSIC_SETTLE_TIME = 1.0
-- Creation runs script init immediately; registration/messages and a physics
-- update must finish before any arrival can use the room.
local ROOM_READY_DELAY_FRAMES = 2
local resources = nil
local arrival_pins = {}
local next_arrival_pin = 0
local create_failures = 0
local max_create_seconds = 0
local ROOM_LINGER_TIME = 0.35
if GameplayConstants and GameplayConstants.rooms then
    TRANSITION_THRESHOLD = GameplayConstants.rooms.transition_threshold or TRANSITION_THRESHOLD
    ROOM_LINGER_TIME = tonumber(GameplayConstants.rooms.room_linger_time) or ROOM_LINGER_TIME
end

local room_events = {
    on_room_spawned = {},
    on_room_ready = {},
    on_room_enter = {},
    on_room_exit = {},
    on_room_loaded = {},
    on_room_unloaded = {}
}

local DEFAULT_TILE_W = (StreamS and StreamS.room and StreamS.room.tile_w) or Tile.width
local DEFAULT_TILE_H = (StreamS and StreamS.room and StreamS.room.tile_h) or Tile.height

-- Color helpers now live in mvtk/map/streaming/room_colors.lua. Local
-- aliases keep the rest of this file readable without sprinkling
-- RoomColors. everywhere.
local make_color4 = RoomColors.make_color4
local copy_color4 = RoomColors.copy_color4
local get_default_render_clear_color = RoomColors.get_default_render_clear_color

local function apply_room_clear_color(room_id)
    local meta = get_tiled_room_metadata(room_id)
    local color = copy_color4(meta.background_color) or get_default_render_clear_color()
    local ok, err = pcall(msg.post, "@render:", hash("clear_color"), { color = color })
    if ok then
        room_log(string.format("[ROOM_MANAGER] Applied clear color for room '%s' (custom=%s)",
            tostring(room_id), tostring(meta.background_color ~= nil)))
    else
        room_log(string.format("[ROOM_MANAGER] Failed to apply clear color for room '%s': %s",
            tostring(room_id), tostring(err)))
    end
end

local function next_generation()
    next_room_generation = next_room_generation + 1
    return next_room_generation
end

local function room_is_loaded(entry)
    if not entry then
        return false
    end
    return entry.state == ROOM_STATE_LOADING
        or entry.state == ROOM_STATE_READY
        or entry.state == ROOM_STATE_CURRENT
end

local function room_is_ready(entry)
    if not entry then
        return false
    end
    return entry.state == ROOM_STATE_READY or entry.state == ROOM_STATE_CURRENT
end

local promote_room_ready
local refresh_room_visibility

local function mark_streaming_dirty()
    streaming_dirty = true
end

local function room_is_concealed(room_id)
    local entries = world_secrets[room_id]
    if not entries then return false end
    -- Lazy require avoids the checkpoint/discovery registration cycle at module
    -- load. World and map concealment share the wall's existing durable flag.
    return SecretVisibility.status(entries, require "mvtk.core.flags")
end

local function refresh_secret_visibility()
    if next(world_secrets) == nil then return end
    local flags = require "mvtk.core.flags"
    local revision = flags.revision()
    if revision == secret_flags_revision then return end
    secret_flags_revision = revision
    for room_id, entries in pairs(world_secrets) do
        local concealed = SecretVisibility.status(entries, flags)
        if hidden_world_rooms[room_id] ~= concealed then
            hidden_world_rooms[room_id] = concealed
            -- Save-slot resets/imports must conceal an already-created room,
            -- including a loading generation whose bookkeeping is still false.
            if concealed then M.set_room_visible(room_id, false, true) end
            mark_streaming_dirty()
        end
    end
end

local function room_pin_bucket(room_id, create)
    local bucket = room_id and room_pins[room_id] or nil
    if not bucket and create and room_id then
        bucket = {}
        room_pins[room_id] = bucket
    end
    return bucket
end

local function room_has_load_pin(room_id)
    local bucket = room_pin_bucket(room_id, false)
    return bucket ~= nil and next(bucket) ~= nil
end

local function room_has_visibility_pin(room_id)
    local bucket = room_pin_bucket(room_id, false)
    if not bucket then return false end
    for _, pin in pairs(bucket) do
        if pin.visible then return true end
    end
    return false
end

local function add_room_pin(token, room_id, visible)
    local bucket = room_pin_bucket(room_id, true)
    bucket[token] = {
        token = token,
        visible = visible and true or false,
    }
end

local function set_room_pin_visible(token, room_id, visible)
    local bucket = room_pin_bucket(room_id, false)
    local pin = bucket and bucket[token] or nil
    if pin then
        pin.visible = visible and true or false
    end
end

local function remove_room_pin(token, room_id)
    local bucket = room_pin_bucket(room_id, false)
    if not bucket then return end
    bucket[token] = nil
    if next(bucket) == nil then
        room_pins[room_id] = nil
    end
end

local function reset_runtime_state()
    if startup_resources then startup_resources.release_all(); startup_resources = nil end
    if current_ambient_sound then
        require("mvtk.audio.audio").stop_ambience(current_ambient_sound)
        current_ambient_sound = nil
    end
    WorldProperties.set_layout(nil)
    for room_id in pairs(room_runtime) do
        M.unload_room(room_id, { force = true })
    end
    -- Keep pending deletions and resource leases across layout resets. Their
    -- callbacks release the old generation without touching the new layout.
    handoff_epoch = handoff_epoch + 1
    current_room_id = nil
    pending_current_room_id = nil
    room_runtime = {}
    room_positions = {}
    room_graph = {}
    room_doors = {}
    room_geometry = {}
    current_music_track = nil
    missing_music_warned = {}
    last_room_transition_time = 0
    pending_music_room_id = nil
    last_transition_clock = 0
    last_transition_frame = -1
    player_url = nil
    transition_grace_t = 0
    room_frame = 0
    room_clock = 0
    load_queue = {}
    load_queued = {}
    unload_queue = {}
    unload_queued = {}
    desired_rooms = {}
    streaming_dirty = true
    streaming_safety_elapsed = 0
    streaming_reconcile_count = 0
    secret_flags_revision = nil
    hidden_world_rooms = {}
    lookahead_room_id = nil
    previous_player_position = nil
    previous_player_room = nil
    room_pins = {}
    handoffs = {}
    active_handoff_token = nil
    arrival_pins = {}
end

local function get_world_position(url)
    if not url then return nil end
    local ok, pos = pcall(go.get_world_position, url)
    if ok and pos then
        return pos
    end
    local ok_id, go_id = pcall(go.get_id, url)
    if ok_id and go_id then
        local go_url = msg.url(url.socket, url.path, go_id)
        ok, pos = pcall(go.get_world_position, go_url)
        if ok and pos then
            return pos
        end
        ok, pos = pcall(go.get_position, go_url)
        if ok and pos then
            return pos
        end
    end
    return nil
end

function M.set_player_url(url)
    if not url then return end
    room_log(string.format("[ROOM_MANAGER] set_player_url called with %s", tostring(url)))
    player_url = url
    if C then
        C.URL = C.URL or {}
        C.URL.PLAYER = url
    end
    local pos = get_world_position(url)
    if pos then
        M.check_room_transitions(pos)
    end
    mark_streaming_dirty()
    transition_grace_t = SPAWN_GRACE_TIME
end

local compute_spawn_xy = RoomGeom.compute_spawn_xy

local function log_spawn_offset(tag, room_id, room)
    if not room then return end
    local spawn_x, spawn_y = compute_spawn_xy(room)
    local base_x = tonumber(room.x) or 0
    local base_y = tonumber(room.y) or 0
    local off_x = tonumber(room.ox) or 0
    local off_y = tonumber(room.oy) or 0
    local dx = spawn_x - base_x
    local dy = spawn_y - base_y
    if math.abs(dx) > 0.01 or math.abs(dy) > 0.01 then
        align_log(string.format('[ROOM_ALIGN] %s %s authored=(%.1f,%.1f) offset=(%.1f,%.1f) spawn=(%.1f,%.1f)',
            tostring(tag), tostring(room_id), base_x, base_y, off_x, off_y, spawn_x, spawn_y))
    end
end

local function log_geometry_shift(room_id, original, updated)
    if not (original and updated) then return end
    local dx = (tonumber(updated.x) or 0) - (tonumber(original.x) or 0)
    local dy = (tonumber(updated.y) or 0) - (tonumber(original.y) or 0)
    if math.abs(dx) > 0.01 or math.abs(dy) > 0.01 then
        align_log(string.format('[ROOM_ALIGN] geometry_rebuild %s delta=(%.1f,%.1f) authored=(%.1f,%.1f) new=(%.1f,%.1f)',
            tostring(room_id), dx, dy,
            tonumber(original.x) or 0, tonumber(original.y) or 0,
            tonumber(updated.x) or 0, tonumber(updated.y) or 0))
    end
end

local normalize_room_id = RoomGeom.normalize_room_id

local normalize_side = RoomGeom.normalize_side

local canonical_side = RoomGeom.canonical_side

local function make_room_bounds(room_data)
    if type(room_data) ~= "table" then
        return nil
    end
    return room_data.bounds or RoomGeom.make_room_bounds(room_data)
end

local point_in_bounds = RoomGeom.point_in_bounds

local function point_near_room_edge(point, bounds, margin)
    if not point or not bounds then
        return false
    end
    local m = math.max(0, tonumber(margin) or 0)
    local width = math.max(0, (tonumber(bounds.max_x) or 0) - (tonumber(bounds.min_x) or 0))
    local height = math.max(0, (tonumber(bounds.max_y) or 0) - (tonumber(bounds.min_y) or 0))
    local max_x_margin = math.max(0, (width * 0.5) - 1)
    local max_y_margin = math.max(0, (height * 0.5) - 1)
    local mx = math.min(m, max_x_margin)
    local my = math.min(m, max_y_margin)
    local px = tonumber(point.x) or 0
    local py = tonumber(point.y) or 0
    return px <= ((tonumber(bounds.min_x) or 0) + mx)
        or px >= ((tonumber(bounds.max_x) or 0) - mx)
        or py <= ((tonumber(bounds.min_y) or 0) + my)
        or py >= ((tonumber(bounds.max_y) or 0) - my)
end

local function find_room_containing_point(point, exclude_room_id)
    local excluded = normalize_room_id(exclude_room_id)
    for room_id, room_data in pairs(room_positions) do
        if room_id ~= excluded then
            local bounds = make_room_bounds(room_data)
            if point_in_bounds(point, bounds) then
                return room_id, bounds
            end
        end
    end
    return nil, nil
end

function M.get_keep_all_loaded()
    return keep_all_loaded
end

function M.set_keep_all_loaded(flag)
    local desired = flag and true or false
    if desired == keep_all_loaded then
        return
    end
    keep_all_loaded = desired
    room_log(string.format("[ROOM_MANAGER] keep_all_loaded=%s", tostring(keep_all_loaded)))
    mark_streaming_dirty()
end

local function clone_door_meta(src)
    if type(src) ~= "table" then return nil end
    return {
        side = normalize_side(src.side),
        cx   = tonumber(src.cx) or 0,
        cy   = tonumber(src.cy) or 0,
        len  = tonumber(src.len or src.len_px) or 0,
    }
end

local function opposite_side(side)
    local s = normalize_side(side)
    if s == "left" then return "right" end
    if s == "right" then return "left" end
    if s == "up" then return "down" end
    if s == "down" then return "up" end
    return s
end

local function door_world_pos(door, room_data)
    if not (door and room_data) then return nil end
    local base_x = tonumber(room_data.x) or 0
    local base_y = tonumber(room_data.y) or 0
    local ox = tonumber(room_data.ox) or 0
    local oy = tonumber(room_data.oy) or 0
    local cx = tonumber(door.cx) or 0
    local cy = tonumber(door.cy) or 0
    return base_x + ox + cx, base_y + oy + cy
end

local function door_pos_for_side(room_id, side)
    local doors = room_doors[room_id]
    if not doors then return nil end
    local want = normalize_side(side)
    for _, d in ipairs(doors) do
        if normalize_side(d.side) == want then
            local rx, ry = door_world_pos(d, room_positions[room_id])
            if rx and ry then return rx, ry end
        end
    end
end

-- Try to recover door markers by parsing the room's tilemap file when the
-- layout lacks explicit door metadata. This uses the editor-side parser which
-- reads door_* layers directly from the tilemap text.
-- Debug helpers for seam/placement state
local function dbg_dump_positions(tag, layout_rooms, positions)
    local label = tag or 'pre'
    seam_log(string.format('[SEAM_DBG] dump %s: rooms=%d', label, (layout_rooms and #layout_rooms or 0)))
    if type(layout_rooms) ~= 'table' then return end
    for i, rec in ipairs(layout_rooms) do
        local id = normalize_room_id(rec.id)
        local p = id and positions[id]
        if p then
            seam_log(string.format('[SEAM_DBG] %2d %-10s pos=(%.1f,%.1f) size=(%.1f,%.1f) off=(%.1f,%.1f)'
                , i, tostring(id), p.x or 0, p.y or 0, p.w or 0, p.h or 0, p.ox or 0, p.oy or 0))
        else
            seam_log(string.format('[SEAM_DBG] %2d %-10s pos=<nil>', i, tostring(id)))
        end
    end
end

local function deepcopy_position(pos)
    if not pos then return nil end
    return {
        x = pos.x,
        y = pos.y,
        w = pos.w,
        h = pos.h,
        ox = pos.ox,
        oy = pos.oy,
        collection_offset_x = pos.collection_offset_x,
        collection_offset_y = pos.collection_offset_y,
        tags = pos.tags,  -- Preserve layout marker/custom tag data
    }
end

local function select_best_door_pair(anchor_id, neighbor_id, side, positions, originals)
    local anchor_geom = room_geometry[anchor_id]
    local neighbor_geom = room_geometry[neighbor_id]
    if not (anchor_geom and neighbor_geom) then return nil end

    local anchor_side = canonical_side(side)
    local anchor_doors = (anchor_geom.doors and anchor_geom.doors[anchor_side]) or {}
    local opp = canonical_side(opposite_side(side))
    local neighbor_doors = (neighbor_geom.doors and neighbor_geom.doors[opp]) or {}
    if #anchor_doors == 0 or #neighbor_doors == 0 then
        return nil
    end

    local anchor_pos = positions[anchor_id] or originals[anchor_id]
    local neighbor_orig = originals[neighbor_id]
    if not (anchor_pos and neighbor_orig) then return nil end

    local anchor_base_x = (anchor_pos.x or 0) + (anchor_pos.ox or 0)
    local anchor_base_y = (anchor_pos.y or 0) + (anchor_pos.oy or 0)

    local neighbor_off_x = neighbor_orig.ox or 0
    local neighbor_off_y = neighbor_orig.oy or 0

    local best = nil
    local best_align = math.huge
    local best_pos = math.huge

    local function evaluate(a_door, b_door)
        local base_x, base_y
        if side == 'right' then
            local anchor_edge = a_door.seam
            local neighbor_edge = b_door.seam
            base_x = anchor_base_x + anchor_edge - neighbor_edge
            base_y = anchor_base_y + a_door.cy - b_door.cy
        elseif side == 'left' then
            local anchor_edge = a_door.seam
            local neighbor_edge = b_door.seam -- neighbor side == right
            base_x = anchor_base_x + anchor_edge - neighbor_edge
            base_y = anchor_base_y + a_door.cy - b_door.cy
        elseif side == 'up' or side == 'top' then
            local anchor_edge = a_door.seam
            local neighbor_edge = b_door.seam
            base_y = anchor_base_y + anchor_edge - neighbor_edge
            base_x = anchor_base_x + a_door.cx - b_door.cx
        elseif side == 'down' or side == 'bottom' then
            local anchor_edge = a_door.seam
            local neighbor_edge = b_door.seam
            base_y = anchor_base_y + anchor_edge - neighbor_edge
            base_x = anchor_base_x + a_door.cx - b_door.cx
        else
            return
        end

        local pos_x = base_x - neighbor_off_x
        local pos_y = base_y - neighbor_off_y

        local dx = pos_x - (neighbor_orig.x or 0)
        local dy = pos_y - (neighbor_orig.y or 0)
        local pos_err = dx * dx + dy * dy

        -- Door center alignment error along the seam axis
        local canon = canonical_side(normalize_side(side))
        local align_err
        if canon == 'left' or canon == 'right' then
            local d = (a_door.cy or 0) - (b_door.cy or 0)
            align_err = d * d
        elseif canon == 'top' or canon == 'bottom' then
            local d = (a_door.cx or 0) - (b_door.cx or 0)
            align_err = d * d
        else
            align_err = 0
        end

        local len_a = tonumber(a_door.len or a_door.len_px) or 0
        local len_b = tonumber(b_door.len or b_door.len_px) or 0
        local len_d = len_a - len_b
        local len_err = len_d * len_d

        -- Primary: minimize seam-axis alignment error.
        -- Tie-breaker: minimize position delta from authored placement.
        local score_align = align_err
        local score_pos   = pos_err

        -- Verbose candidate scoring to help diagnose multi-door choices
        seam_log(string.format(
            "[SEAM_DBG] candidate %s -> %s side=%s a(cx=%.1f,cy=%.1f,seam=%.1f) b(cx=%.1f,cy=%.1f,seam=%.1f) pos=(%.1f,%.1f) align_err=%.1f pos_err=%.1f len_err=%.1f",
            tostring(anchor_id), tostring(neighbor_id), tostring(side),
            a_door.cx or 0, a_door.cy or 0, a_door.seam or 0,
            b_door.cx or 0, b_door.cy or 0, b_door.seam or 0,
            pos_x, pos_y, align_err, pos_err, len_err))

        local eps = 0.5  -- treat sub-pixel differences as equal
        if (score_align + eps) < best_align or (math.abs(score_align - best_align) <= eps and score_pos < best_pos) then
            best_align = score_align
            best_pos = score_pos
            best = {
                pos_x = pos_x,
                pos_y = pos_y,
                base_x = base_x,
                base_y = base_y,
                anchor_door = a_door,
                neighbor_door = b_door,
                pos_err = pos_err,
                align_err = align_err,
                len_err = len_err,
                score = score_align,
            }
        end
    end

    for _, a_door in ipairs(anchor_doors) do
        for _, b_door in ipairs(neighbor_doors) do
            evaluate(a_door, b_door)
        end
    end

    if best then
        best.error = best_align
        seam_log(string.format(
            "[SEAM_DBG] choose %s -> %s side=%s pos=(%.1f,%.1f) (align=%.1f pos=%.1f len=%.1f)",
            tostring(anchor_id), tostring(neighbor_id), tostring(side),
            best.pos_x or 0, best.pos_y or 0,
            best.align_err or -1, best.pos_err or -1, best.len_err or -1))
    end
    return best
end


-- === Door-hint aware alignment helpers ======================================

local function door_side_is_valid_for_edge(hint_side, edge_side, is_neighbor)
    -- edge_side is the 'from' side of anchor; neighbor must be opposite.
    -- If hint has no .side, accept and infer from the edge.
    if not hint_side then return true end
    hint_side = canonical_side(normalize_side(hint_side))
    edge_side = canonical_side(normalize_side(edge_side))
    if is_neighbor then
        return hint_side == canonical_side(opposite_side(edge_side))
    else
        return hint_side == canonical_side(edge_side)
    end
end

local function resolve_door_from_hint(room_id, side, hint)
    -- Find the geometry door entry in room_geometry[room_id] that is closest to the hint (cx,cy) on the given side.
    if not (room_id and side and hint) then return nil end
    local geom = room_geometry[room_id]
    if not (geom and geom.doors) then return nil end
    local s = canonical_side(normalize_side(side))
    local list = geom.doors[s]
    if not (list and #list > 0) then return nil end

    -- Both hints (from layout editor) and geometry doors are stored in bounds-relative
    -- pixel coordinates, so we can match them directly without conversion.
    local hx = tonumber(hint.cx) or 0
    local hy = tonumber(hint.cy) or 0

    local best, best_d2 = nil, math.huge
    for _, entry in ipairs(list) do
        local dx = (entry.cx or 0) - hx
        local dy = (entry.cy or 0) - hy
        local d2 = dx*dx + dy*dy
        if d2 < best_d2 then
            best = entry
            best_d2 = d2
        end
    end
    if best then
        seam_log(string.format(
            "[SEAM_DBG] hint match room=%s side=%s -> geom(cx=%.1f,cy=%.1f,seam=%.1f) from hint(cx=%.1f,cy=%.1f)",
            tostring(room_id), tostring(side), best.cx or 0, best.cy or 0, best.seam or 0, hx, hy))
    else
        seam_log(string.format(
            "[SEAM_DBG] hint match FAILED room=%s side=%s from hint(cx=%.1f,cy=%.1f)",
            tostring(room_id), tostring(side), hx, hy))
    end
    return best
end

local function compute_neighbor_position_from_doors(anchor_id, neighbor_id, side, positions, originals, a_door, b_door)
    if not (a_door and b_door) then return nil end
    local anchor_pos = positions[anchor_id] or originals[anchor_id]
    local neighbor_orig = originals[neighbor_id]
    if not (anchor_pos and neighbor_orig) then return nil end

    local anchor_base_x = (anchor_pos.x or 0) + (anchor_pos.ox or 0)
    local anchor_base_y = (anchor_pos.y or 0) + (anchor_pos.oy or 0)
    local neighbor_off_x = neighbor_orig.ox or 0
    local neighbor_off_y = neighbor_orig.oy or 0

    local s = canonical_side(normalize_side(side))
    local base_x, base_y
    if s == 'right' then
        base_x = anchor_base_x + (a_door.seam or 0) - (b_door.seam or 0)
        base_y = anchor_base_y + (a_door.cy or 0)   - (b_door.cy or 0)
    elseif s == 'left' then
        base_x = anchor_base_x + (a_door.seam or 0) - (b_door.seam or 0)
        base_y = anchor_base_y + (a_door.cy or 0)   - (b_door.cy or 0)
    elseif s == 'top' then
        base_y = anchor_base_y + (a_door.seam or 0) - (b_door.seam or 0)
        base_x = anchor_base_x + (a_door.cx or 0)   - (b_door.cx or 0)
    elseif s == 'bottom' then
        base_y = anchor_base_y + (a_door.seam or 0) - (b_door.seam or 0)
        base_x = anchor_base_x + (a_door.cx or 0)   - (b_door.cx or 0)
    else
        return nil
    end

    return {
        pos_x = (base_x or 0) - (neighbor_off_x or 0),
        pos_y = (base_y or 0) - (neighbor_off_y or 0),
        base_x = base_x, base_y = base_y,
        anchor_door = a_door, neighbor_door = b_door,
        used_hints = true,
    }
end

local function select_door_pair_with_hints(anchor_id, neighbor_id, side, positions, originals, graph)
    -- If the edge contains explicit door hints, resolve them to geometry doors and compute position.
    local neighbors = (graph and graph[anchor_id]) or {}
    for _, e in ipairs(neighbors) do
        local bid = normalize_room_id(e.id)
        local eside = normalize_side(e.side)
        if bid == neighbor_id and normalize_side(side) == eside then
            local a_hint = e.door
            local b_hint = e.mate or e.target or e.peer

            -- Resolve any available hints to actual geometry doors
            local a_door = (a_hint and door_side_is_valid_for_edge(a_hint.side, side, false))
                and resolve_door_from_hint(anchor_id, side, a_hint) or nil
            local b_door = (b_hint and door_side_is_valid_for_edge(b_hint.side, side, true))
                and resolve_door_from_hint(neighbor_id, opposite_side(side), b_hint) or nil

            if a_door and b_door then
                local pos = compute_neighbor_position_from_doors(anchor_id, neighbor_id, side, positions, originals, a_door, b_door)
                if pos then return pos end
            elseif a_door or b_door then
                -- If only one side provided a hint, pick the best match on the opposite side by seam-axis proximity.
                local s = canonical_side(normalize_side(side))
                if a_door and not b_door then
                    local n_geom = room_geometry[neighbor_id]
                    local n_list = n_geom and n_geom.doors and n_geom.doors[canonical_side(opposite_side(side))] or {}
                    local best_b, best_d2 = nil, math.huge
                    for _, cand in ipairs(n_list or {}) do
                        local d
                        if s == 'left' or s == 'right' then d = (a_door.cy or 0) - (cand.cy or 0) else d = (a_door.cx or 0) - (cand.cx or 0) end
                        local d2 = d*d
                        if d2 < best_d2 then best_d2 = d2; best_b = cand end
                    end
                    b_door = best_b
                elseif b_door and not a_door then
                    local a_geom = room_geometry[anchor_id]
                    local a_list = a_geom and a_geom.doors and a_geom.doors[s] or {}
                    local best_a, best_d2 = nil, math.huge
                    for _, cand in ipairs(a_list or {}) do
                        local d
                        if s == 'left' or s == 'right' then d = (cand.cy or 0) - (b_door.cy or 0) else d = (cand.cx or 0) - (b_door.cx or 0) end
                        local d2 = d*d
                        if d2 < best_d2 then best_d2 = d2; best_a = cand end
                    end
                    a_door = best_a
                end
                if a_door and b_door then
                    local pos = compute_neighbor_position_from_doors(anchor_id, neighbor_id, side, positions, originals, a_door, b_door)
                    if pos then return pos end
                end
            end
            break
        end
    end
    return nil
end

local function rebuild_positions_with_geometry(layout_rooms, graph, original_positions)
    if type(layout_rooms) ~= 'table' or #layout_rooms == 0 then
        return original_positions
    end

    local anchor_id = normalize_room_id(layout_rooms[1].id)
    if not anchor_id then
        return original_positions
    end

    local new_positions = {}
    for id, pos in pairs(original_positions) do
        new_positions[id] = deepcopy_position(pos)
    end

    local visited = { [anchor_id] = true }
    local queue = { anchor_id }

    while #queue > 0 do
        local aid = table.remove(queue, 1)
        local neighbors = graph[aid] or {}
        for _, entry in ipairs(neighbors) do
            local bid = normalize_room_id(entry.id)
            local side = normalize_side(entry.side)
            if bid and side and not visited[bid] then
                local choice = select_door_pair_with_hints(aid, bid, side, new_positions, original_positions, graph)
                if not choice then
                    choice = select_best_door_pair(aid, bid, side, new_positions, original_positions)
                end
                if choice then
                    local pos = new_positions[bid] or deepcopy_position(original_positions[bid]) or { ox = 0, oy = 0 }
                    pos.x = choice.pos_x
                    pos.y = choice.pos_y
                    new_positions[bid] = pos
                    if choice.used_hints then
                        seam_log(string.format('[SEAM_DBG] hint align %s -> %s side=%s pos=(%.1f,%.1f)',
                            tostring(aid), tostring(bid), tostring(side), pos.x or 0, pos.y or 0))
                    else
                        local ad = choice.anchor_door or {}
                        local bd = choice.neighbor_door or {}
                        seam_log(string.format('[SEAM_DBG] geom align %s -> %s side=%s pos=(%.1f,%.1f) err=%.1f  a(cx=%.1f,cy=%.1f) b(cx=%.1f,cy=%.1f)',
                            tostring(aid), tostring(bid), tostring(side), pos.x or 0, pos.y or 0, choice.error or 0,
                            ad.cx or 0, ad.cy or 0, bd.cx or 0, bd.cy or 0))
                    end
                else
                    new_positions[bid] = deepcopy_position(original_positions[bid])
                    seam_log(string.format('[SEAM_DBG] align fallback %s -> %s (no doors)', tostring(aid), tostring(bid)))
                end
                visited[bid] = true
                queue[#queue+1] = bid
            end
        end
    end

    return new_positions
end
function M.init(layout_data)
    room_log("[ROOM_MANAGER] Initializing room manager system...")
    reset_runtime_state()
    if not resources then resources = FactoryResources.new(StreamS and StreamS.room) end

    if layout_data then
        M.load_layout(layout_data)
    end
    
    -- Set up player reference
    if C and C.URL and C.URL.PLAYER then
        player_url = C.URL.PLAYER
    end
    
    room_log("[ROOM_MANAGER] Room manager system initialized")
end

function M.load_layout(layout_data)
    room_log("[ROOM_MANAGER] Loading room layout data...")
    reset_runtime_state()
    if not resources then resources = FactoryResources.new(StreamS and StreamS.room) end

    if not layout_data or not layout_data.rooms then
        room_log("[ROOM_MANAGER] No room data provided")
        return false
    end
    WorldProperties.set_layout(layout_data)
    
    -- Parse room data
    for _, room_data in ipairs(layout_data.rooms) do
        local room_id = normalize_room_id(room_data.id)

        if room_id and room_id ~= "" then
            -- Store room position and size
            room_positions[room_id] = {
                x = tonumber(room_data.x) or 0,
                y = tonumber(room_data.y) or 0,
                w = tonumber(room_data.w) or 0,
                h = tonumber(room_data.h) or 0,
                ox = tonumber(room_data.ox) or 0, -- Offset X
                oy = tonumber(room_data.oy) or 0, -- Offset Y
                collection_offset_x = tonumber(room_data.collection_offset_x),
                collection_offset_y = tonumber(room_data.collection_offset_y),
                tags = room_data.tags  -- Preserve layout marker/custom tag data
            }
            
            local geom = Geometry.load(room_id, room_data)
            if geom then
                room_geometry[room_id] = geom
                if room_positions[room_id] then
                    room_positions[room_id].w = geom.width_px
                    room_positions[room_id].h = geom.height_px
                end
                if geom.door_list and #geom.door_list > 0 then
                    room_doors[room_id] = {}
                    for _, entry in ipairs(geom.door_list) do
                        room_doors[room_id][#room_doors[room_id]+1] = clone_door_meta(entry)
                    end
                    -- Verbose: dump per-room door geometry
                    local function dump_side(tag, list)
                        local n = #(list or {})
                        if n == 0 then return end
                        for i, d in ipairs(list) do
                            seam_log(string.format('[SEAM_DBG] doors %s #%d: cx=%.1f cy=%.1f seam=%.1f len=%.1f', tag, i, d.cx or 0, d.cy or 0, d.seam or -1, d.len or d.len_px or -1))
                        end
                    end
                    local doors = geom.doors or {}
                    dump_side(string.format('%s.left', room_id), doors.left)
                    dump_side(string.format('%s.right', room_id), doors.right)
                    dump_side(string.format('%s.top', room_id), doors.top)
                    dump_side(string.format('%s.bottom', room_id), doors.bottom)
                end
            else
                seam_log(string.format('[SEAM_DBG] geometry load failed for %s: %s', room_id, tostring(room_data.path or '?')))
            end
            if not room_doors[room_id] or #room_doors[room_id] == 0 then
                local fallback = {}
                for _, door in ipairs(room_data.doors or {}) do
                    local cloned = clone_door_meta(door)
                    if cloned then fallback[#fallback+1] = cloned end
                end
                if #fallback > 0 then
                    room_doors[room_id] = fallback
                    seam_log(string.format('[SEAM_DBG] fallback layout doors for %s (%d)', room_id, #fallback))
                end
            end


            -- Build neighbor graph (preserve editor door hints when present)
            room_graph[room_id] = {}
            for _, neighbor in ipairs(room_data.neighbors or {}) do
                local neighbor_id = normalize_room_id(neighbor.id)
                if neighbor_id and neighbor.side then
                    local edge = {
                        id   = neighbor_id,
                        side = tostring(neighbor.side),
                    }
                    -- Preserve any door hint metadata from the editor export to disambiguate multiple doors on one side.
                    if type(neighbor.door) == 'table' then edge.door = clone_door_meta(neighbor.door) end
                    if type(neighbor.mate) == 'table' then edge.mate = clone_door_meta(neighbor.mate) end
                    if not edge.mate and type(neighbor.target) == 'table' then edge.mate = clone_door_meta(neighbor.target) end
                    if not edge.mate and type(neighbor.peer) == 'table' then edge.mate = clone_door_meta(neighbor.peer) end
                    table.insert(room_graph[room_id], edge)
                    -- Verbose: print neighbor edge + hint metadata
                    local function hint_str(h)
                        if type(h) ~= 'table' then return 'nil' end
                        return string.format('{side=%s cx=%.1f cy=%.1f len=%.1f}', tostring(h.side), tonumber(h.cx) or 0, tonumber(h.cy) or 0, tonumber(h.len or h.len_px) or 0)
                    end
                    seam_log(string.format('[SEAM_DBG] edge %s -> %s side=%s door=%s mate=%s',
                        tostring(room_id), tostring(edge.id), tostring(edge.side), hint_str(edge.door), hint_str(edge.mate)))
                end
            end
            room_log(string.format("[ROOM_MANAGER] Loaded room '%s' at (%.1f, %.1f) with %d neighbors", 
                room_id, room_positions[room_id].x, room_positions[room_id].y, #room_graph[room_id]))
            log_spawn_offset('layout', room_id, room_positions[room_id])
        end
    end

    local originals = {}
    for id, pos in pairs(room_positions) do
        originals[id] = deepcopy_position(pos)
    end

    pcall(dbg_dump_positions, 'pre', layout_data.rooms, room_positions)
    -- Imported worlds already specify exact collection origins. Runtime seam
    -- repair must not pull authored rooms together or shift a partially aligned
    -- opening; manual layouts without the fixed-origin flag keep legacy repair.
    local rebuilt = not layout_data.preserve_origin and rebuild_positions_with_geometry(layout_data.rooms, room_graph, originals)
    if rebuilt then
        room_positions = rebuilt
    end
    for id, pos in pairs(room_positions) do
        log_geometry_shift(id, originals[id], pos)
        log_spawn_offset('layout-final', id, pos)
        pos.bounds = RoomGeom.make_room_bounds(pos)
    end
    pcall(dbg_dump_positions, 'post', layout_data.rooms, room_positions)
    
    return true
end

function M.get_room_data(room_id)
    room_id = normalize_room_id(room_id)
    return room_positions[room_id]
end

--- World-space rectangle { min_x, min_y, max_x, max_y } of a placed room,
-- or nil when the room is not in the loaded layout.
function M.get_room_bounds(room_id)
    room_id = normalize_room_id(room_id)
    return make_room_bounds(room_id and room_positions[room_id])
end

function M.get_room_neighbors(room_id)
    room_id = normalize_room_id(room_id)
    return room_graph[room_id] or {}
end

-- A startup gate, not a gameplay room. No discovery/room-enter events or
-- collection creation occur while warming resources for unvisited rooms.
function M.is_startup_ready()
    if not (StreamS.room and StreamS.room.prewarm_resources_on_start) then return true end
    return startup_resources ~= nil and startup_resources.ready()
end

-- Room-local doorway centres and spans, from the same geometry used for
-- transitions. Callers must not mutate these shared records.
function M.get_room_doors(room_id)
    return room_doors[normalize_room_id(room_id)] or {}
end

local function player_has_committed_to_room(room_id)
    room_id = normalize_room_id(room_id)
    if not room_id or not player_url or not go.exists(player_url) then
        return false
    end
    local player_pos = get_world_position(player_url)
    local room_data = room_positions[room_id]
    local bounds = make_room_bounds(room_data)
    if not player_pos or not bounds then
        return false
    end
    if not point_in_bounds(player_pos, bounds) then
        return false
    end
    return not point_near_room_edge(player_pos, bounds, TRANSITION_THRESHOLD)
end

local function should_keep_lingering_room(room_id, entry)
    if not entry or entry.state == ROOM_STATE_UNLOADING then
        return false
    end
    if not entry.linger_until then
        return false
    end
    if room_clock < entry.linger_until then
        return true
    end
    if player_url and go.exists(player_url) and current_room_id and not player_has_committed_to_room(current_room_id) then
        return true
    end
    entry.linger_until = nil
    return false
end

local function add_stream_radius(rooms, center_room_id)
    center_room_id = normalize_room_id(center_room_id)
    if not center_room_id then
        return
    end
    local candidates = M.get_rooms_to_stream(center_room_id, get_preload_distance())
    for room_id in pairs(candidates) do
        rooms[room_id] = true
    end
end

local function add_direct_neighbors(rooms, center_room_id)
    center_room_id = normalize_room_id(center_room_id)
    if not center_room_id then
        return
    end
    for _, neighbor in ipairs(room_graph[center_room_id] or {}) do
        local neighbor_id = normalize_room_id(neighbor.id)
        if neighbor_id then
            rooms[neighbor_id] = true
        end
    end
end

local function collect_rooms_to_keep_loaded()
    local rooms = {}
    add_stream_radius(rooms, current_room_id)
    add_stream_radius(rooms, pending_current_room_id)
    add_direct_neighbors(rooms, current_room_id)
    add_direct_neighbors(rooms, pending_current_room_id)

    -- Prepare the set that will be needed after the approaching seam, rather
    -- than discovering a cold frontier on the crossing frame. These extra
    -- rooms use the normal load budget and remain hidden until adjacent.
    if lookahead_room_id then
        add_stream_radius(rooms, lookahead_room_id)
        add_direct_neighbors(rooms, lookahead_room_id)
    end

    if current_room_id then
        rooms[current_room_id] = true
    end
    if pending_current_room_id then
        rooms[pending_current_room_id] = true
    end

    for room_id, entry in pairs(room_runtime) do
        if should_keep_lingering_room(room_id, entry) then
            rooms[room_id] = true
        end
    end

    for room_id in pairs(room_pins) do
        if room_has_load_pin(room_id) then
            rooms[room_id] = true
        end
    end

    -- Retain a bounded number of recently visible collections, disabled when
    -- outside the visible set. Recreating a whole collection is indivisible
    -- engine work even when its resources are already resident.
    local cache_limit = math.max(0, math.floor(tonumber(StreamS and StreamS.room
        and StreamS.room.inactive_room_cache) or 0))
    if cache_limit > 0 then
        local candidates = {}
        for room_id, entry in pairs(room_runtime) do
            if not rooms[room_id] and room_is_ready(entry) then
                candidates[#candidates + 1] = { id = room_id, used = entry.last_visible_clock or 0 }
            end
        end
        table.sort(candidates, function(a, b)
            if a.used == b.used then return a.id < b.id end
            return a.used > b.used
        end)
        for i = 1, math.min(cache_limit, #candidates) do rooms[candidates[i].id] = true end
    end

    return rooms
end

--- Set visibility of all game objects in a loaded room.
-- Used to manage current-room visibility and ready adjacent rooms.
-- @param room_id Room identifier
-- @param visible boolean - true to show, false to hide
function M.set_room_visible(room_id, visible, force)
    room_id = normalize_room_id(room_id)
    local room_data = room_runtime[room_id]
    if not room_data or not room_data.created then
        return
    end
    visible = visible and true or false
    local concealed = room_is_concealed(room_id)
    if concealed then visible = false end
    if not visible and not force and not concealed and room_has_visibility_pin(room_id) then
        return
    end
    if room_data.visible == visible and not force then
        return
    end
    if visible and not room_is_ready(room_data) then
        return
    end
    if visible then room_data.last_visible_clock = room_clock end
    local message = visible and hash("enable") or hash("disable")
    if visible and not room_data.visible then room_data.enabled_frame = room_frame + 1 end
    for _, go_url in pairs(room_data.created) do
        Util.safe_post(go_url, message, nil, { check_exists = true })
    end
    if visible then
        -- A game-object "enable" turns every component back on, including ones
        -- a script deliberately disabled (an open door's collision, a hidden
        -- sprite). Re-post those recorded "disable"s; same sender and socket as
        -- the enable above, so they are delivered after it.
        for _, go_url in pairs(room_data.created) do
            Util.reapply_disabled_components(go_url)
        end
    end
    room_data.visible = visible
    room_log(string.format("[ROOM_MANAGER] Room '%s' visibility set to %s", tostring(room_id), tostring(visible)))
end

local function add_ready_neighbors(rooms, center_room_id)
    center_room_id = normalize_room_id(center_room_id)
    if not center_room_id then
        return
    end
    for _, neighbor in ipairs(room_graph[center_room_id] or {}) do
        local neighbor_id = normalize_room_id(neighbor.id)
        if neighbor_id and room_is_ready(room_runtime[neighbor_id]) then
            rooms[neighbor_id] = true
        end
    end
end

local function collect_rooms_to_keep_visible(player_pos)
    local rooms = {}

    if current_room_id and room_is_ready(room_runtime[current_room_id]) then
        rooms[current_room_id] = true
    end

    if pending_current_room_id and room_is_ready(room_runtime[pending_current_room_id]) then
        rooms[pending_current_room_id] = true
    end

    -- Direct neighbors are already retained by collect_rooms_to_keep_loaded.
    -- Keep them visible from anywhere in the current room so the room behind
    -- the player does not disappear as soon as they move away from the seam.
    -- This only enables room objects; authored tile-layer visibility and map
    -- discovery remain owned by their existing systems.
    add_ready_neighbors(rooms, current_room_id)

    for room_id, entry in pairs(room_runtime) do
        if entry.preview_until and entry.preview_until > room_clock and room_is_ready(entry) then
            rooms[room_id] = true
        end
        if room_id ~= current_room_id and entry.linger_until and room_is_ready(entry) then
            rooms[room_id] = true
        end
    end

    if player_pos then
        local containing_room = find_room_containing_point(player_pos, current_room_id)
        if containing_room and room_is_ready(room_runtime[containing_room]) then
            rooms[containing_room] = true
        end
    end

    for room_id in pairs(room_pins) do
        if room_has_visibility_pin(room_id) and room_is_ready(room_runtime[room_id]) then
            rooms[room_id] = true
        end
    end

    return rooms
end

refresh_room_visibility = function(player_pos)
    local rooms_to_show = collect_rooms_to_keep_visible(player_pos)
    for room_id, entry in pairs(room_runtime) do
        if room_is_loaded(entry) then
            local should_show = rooms_to_show[room_id] == true and room_is_ready(entry)
            M.set_room_visible(room_id, should_show)
        end
    end
end

function M.load_room(room_id, position)
    room_id = normalize_room_id(room_id)
    if not room_id or not room_positions[room_id] then
        return false
    end

    local existing = room_runtime[room_id]
    if existing then
        -- Deletion is irreversible once scheduled. Wait for its completion
        -- before acquiring another generation of this room.
        if existing.state == ROOM_STATE_UNLOADING then return false end
        return true
    end

    room_log(string.format("[ROOM_MANAGER] Loading room: %s", room_id))
    
    -- Create room collection
    local factory_url = M.get_factory_url(room_id)
    if not factory_url then
        room_log(string.format("[ROOM_MANAGER] No factory found for room: %s", room_id))
        return false
    end
    
    local pos = position
    local meta = room_positions[room_id] or {}
    local expected_x, expected_y = compute_spawn_xy(meta)
    pos = pos or vmath.vector3(expected_x, expected_y, 0)
    log_spawn_offset('load_exec', room_id, meta)
    if math.abs(pos.x - expected_x) > 0.01 or math.abs(pos.y - expected_y) > 0.01 then
        align_log(string.format("[ROOM_ALIGN] spawn_input_mismatch %s expected=(%.1f, %.1f) got=(%.1f, %.1f)",
            room_id, expected_x, expected_y, pos.x, pos.y))
    end

    -- DEBUG: Log room loading position
    room_log(string.format("[ROOM_LOAD_DEBUG] Loading %s spawn=(%.1f, %.1f) authored=(%.1f, %.1f) offset=(%.1f, %.1f)",
        room_id,
        pos.x, pos.y,
        tonumber(meta.x) or 0, tonumber(meta.y) or 0,
        tonumber(meta.ox) or 0, tonumber(meta.oy) or 0))

    local generation = next_generation()
    local entry = {
        state = ROOM_STATE_PREPARING, generation = generation,
        position = pos, factory_url = factory_url, visible = false,
    }
    entry.resources = resources.acquire(entry, factory_url)
    room_runtime[room_id] = entry
    mark_streaming_dirty()
    return true
end

local function create_prepared_room(room_id, entry)
    if entry.resources.state ~= "ready" or room_is_concealed(room_id) then return false end
    FrameWatch.record_load()
    local started = os.clock()
    local success, created = pcall(collectionfactory.create, entry.factory_url, entry.position, nil, {}, 1)
    max_create_seconds = math.max(max_create_seconds, os.clock() - started)

    if success and created and next(created) then
        if startup_resources then startup_resources.claim(room_id) end
        entry.created = created
        entry.load_time = os.time()
        entry.ready_frame = room_frame + ROOM_READY_DELAY_FRAMES
        entry.state = ROOM_STATE_LOADING

        M.trigger_event("on_room_spawned", room_id)

        mark_streaming_dirty()
        room_log(string.format("[ROOM_MANAGER] Created room: %s", room_id))
        return true
    else
        entry.error = "room creation failed: " .. tostring(created)
        create_failures = create_failures + 1
        print(string.format("[ROOM_MANAGER] %s: %s", room_id, entry.error))
        return false
    end
end

function M.get_loaded_room_created(room_id)
    room_id = normalize_room_id(room_id)
    local r = room_runtime[room_id]
    if room_is_loaded(r) then
        return r.created
    end
    return nil
end

--- Get the tilemap URL for a loaded room
-- Searches the room's created objects for the main level tilemap (not platform tilemaps)
-- @param room_id The room identifier (string or hash)
-- @return tilemap_url, tilemap_position or nil,nil if not found
local function find_tilemap_url(room_id)
    local r = room_runtime[room_id]
    if not r or not r.created then
        room_log(string.format("[GET_TILEMAP_URL] No room data for %s", tostring(room_id)))
        return nil, nil
    end

    if r.tilemap_url ~= nil then
        if r.tilemap_url and go.exists(r.tilemap_go) then
            return r.tilemap_url, go.get_world_position(r.tilemap_go)
        end
        return nil, nil
    end

    -- Count objects (created is a hash table, not array)
    local obj_count = 0
    for _ in pairs(r.created) do obj_count = obj_count + 1 end
    room_log(string.format("[GET_TILEMAP_URL] Searching for tilemap in room %s, %d created objects",
        tostring(room_id), obj_count))

    -- Helper function to check if a game object has a valid tilemap
    local function try_get_tilemap(go_url)
        if not go_url or not go.exists(go_url) then
            return nil, nil
        end
        local u = msg.url(go_url)
        -- Try common tilemap component names
        for _, comp in ipairs({ "tilemap", "tm", "map", "level" }) do
            local tm = msg.url(u.socket, u.path, hash(comp))
            local ok = pcall(tilemap.get_bounds, tm)
            if ok then
                r.tilemap_url, r.tilemap_go = tm, go_url
                local pos = go.get_world_position(go_url)
                room_log(string.format("[GET_TILEMAP_URL] Found tilemap: %s at (%.1f, %.1f)", tostring(tm), pos.x, pos.y))
                return tm, pos
            end
        end
        return nil, nil
    end

    -- Helper to check if path contains platform-related keywords (but NOT in room name prefix)
    local function is_platform_object(go_url)
        local path_str = tostring(go_url)
        -- Only filter if "_platform" or "_crumble" appears (indicating object type, not room name)
        return path_str:find("_platform_") or path_str:find("_crumble_") or path_str:find("_crumble%d")
    end

    -- First pass: Look for a "level" game object specifically (the main room tilemap)
    for _, go_url in pairs(r.created) do
        local path_str = tostring(go_url)
        if path_str:find("/level") then
            room_log(string.format("[GET_TILEMAP_URL] First pass: found /level in %s", path_str))
            local tm, pos = try_get_tilemap(go_url)
            if tm then
                return tm, pos
            end
        end
    end

    -- Second pass: Look for any tilemap that is NOT a platform
    for _, go_url in pairs(r.created) do
        if not is_platform_object(go_url) then
            local tm, pos = try_get_tilemap(go_url)
            if tm then
                return tm, pos
            end
        end
    end

    -- Fallback: Return any tilemap found (shouldn't normally reach here)
    room_log("[GET_TILEMAP_URL] Fallback: returning any tilemap")
    for _, go_url in pairs(r.created) do
        local tm, pos = try_get_tilemap(go_url)
        if tm then
            return tm, pos
        end
    end

    r.tilemap_url = false
    room_log("[GET_TILEMAP_URL] No tilemap found!")
    return nil, nil
end

--- Find a loaded room's tilemap component URL and world position.
-- Registers the URL with mvtk.rooms.tilemap_layers so layer-existence checks
-- can use the baked manifest instead of probing (which logs engine errors).
function M.get_tilemap_url(room_id)
    room_id = normalize_room_id(room_id)
    local tm, pos = find_tilemap_url(room_id)
    if tm then
        local ok, TilemapLayers = pcall(require, "mvtk.rooms.tilemap_layers")
        if ok and TilemapLayers and TilemapLayers.register then
            TilemapLayers.register(tm, room_id)
        end
    end
    return tm, pos
end

function M.unload_room(room_id, opts)
    room_id = normalize_room_id(room_id)
    opts = opts or {}
    if keep_all_loaded and not opts.force then
        return false
    end
    if not opts.force and room_has_load_pin(room_id) then
        room_log(string.format("[ROOM_MANAGER] Refusing to unload pinned room: %s", tostring(room_id)))
        return false
    end
    local room_data = room_runtime[room_id]
    if room_data and room_data.state == ROOM_STATE_UNLOADING and opts.force then
        for _, info in pairs(pending_unloads) do
            if info.generation == room_data.generation then
                for i = info.delete_index or 1, #(info.delete_queue or {}) do
                    local url = info.delete_queue[i]
                    if go.exists(url) then
                        info.urls[#info.urls + 1] = url
                        go.delete(url, true)
                    end
                end
                info.delete_index = #(info.delete_queue or {}) + 1
            end
        end
    end
    if not room_data or room_data.state == ROOM_STATE_UNLOADING then
        return false
    end

    room_log(string.format("[ROOM_MANAGER] Unloading room: %s", room_id))
    FrameWatch.record_unload()

    local generation = room_data.generation
    room_data.state = ROOM_STATE_UNLOADING
    room_data.visible = false
    room_data.linger_until = nil
    if current_room_id == room_id then
        current_room_id = nil
    end
    if pending_current_room_id == room_id then
        pending_current_room_id = nil
    end

    -- Capture roots now, then schedule large room deletion in bounded chunks.
    local delete_queue = {}
    for _, go_url in pairs(room_data.created or {}) do
        if go_url then
            Util.forget_component_states(go_url)
        end
        if go_url and go.exists(go_url) then
            delete_queue[#delete_queue + 1] = go_url
        end
    end

    local function finish_unload()
        resources.release(room_data)
        local latest = room_runtime[room_id]
        if not latest or latest.generation ~= generation or latest.state ~= ROOM_STATE_UNLOADING then
            room_log(string.format("[ROOM_MANAGER] Ignoring stale unload completion for %s (generation=%s)",
                tostring(room_id), tostring(generation)))
            return
        end
        room_runtime[room_id] = nil
        mark_streaming_dirty()
        M.trigger_event("on_room_unloaded", room_id)
        if opts.on_complete then
            local ok, err = pcall(opts.on_complete, room_id)
            if not ok then
                room_log(string.format("[ROOM_MANAGER] room unload callback failed for %s: %s", tostring(room_id), tostring(err)))
            end
        end
    end

    if #delete_queue == 0 then
        finish_unload()
    elseif opts.force then
        local pending_urls = {}
        for _, go_url in ipairs(delete_queue) do
            if go.exists(go_url) then
                pending_urls[#pending_urls + 1] = go_url
                go.delete(go_url, true)
            end
        end
        if #pending_urls == 0 then
            finish_unload()
        else
            next_unload_token = next_unload_token + 1
            pending_unloads[next_unload_token] = {
                room_id = room_id,
                generation = generation,
                urls = pending_urls,
                delete_queue = {},
                delete_index = 1,
                callback = finish_unload,
            }
        end
    else
        next_unload_token = next_unload_token + 1
        pending_unloads[next_unload_token] = {
            room_id = room_id,
            generation = generation,
            urls = {},
            delete_queue = delete_queue,
            delete_index = 1,
            callback = finish_unload,
        }
    end
    return true
end

local function apply_room_music(room_id)
    local room_data = room_positions[room_id]
    room_log(string.format("[MUSIC_DEBUG] Checking music for room %s, has_data=%s",
        tostring(room_id), tostring(room_data ~= nil)))
    local environment = resolve_room_environment(room_id, room_data)
    local ambient = environment and environment.ambient_sound
    if ambient == "" or ambient == "none" or ambient == "inherit" then ambient = nil end
    if ambient ~= current_ambient_sound then
        local Audio = require("mvtk.audio.audio")
        if current_ambient_sound then Audio.stop_ambience(current_ambient_sound) end
        if ambient then Audio.ambience(ambient) end
        current_ambient_sound = ambient
    end
    if not environment then
        return
    end

    -- Registry resolves room music over the published world default. Biomes
    -- never choose music. Explicit none/hush silences a world using defaults;
    -- older worlds retain their existing no-override behavior.
    local ambience_id = environment.ambience
    room_log(string.format("[ROOM_MANAGER] Room music selection: %s (biome %s is visual-only)",
        tostring(ambience_id), tostring(environment.biome)))
    room_log(string.format("[MUSIC_DEBUG] current_music_track before: %s",
        tostring(current_music_track)))

    local choice = ambience_id and tostring(ambience_id):lower() or ""
    if environment.world_music_enabled and (choice == "none" or choice == "hush") then
        require("mvtk.audio.audio").music("none", { silence = true })
        current_music_track = nil
        return
    end
    if choice == "" or choice == "none" or choice == "hush" then
        room_log("[ROOM_MANAGER] No music override for this room; leaving current track playing")
        return
    end

    -- Canonical track key: an ambience alias (developer/config/
    -- ambience_tracks.lua) resolves to its cue's .sound basename, a raw
    -- synced track id stays as-is. Comparing canonical keys means two rooms
    -- sharing a soundtrack never restart it, no matter which spelling each
    -- room's `music` property used.
    local ambience_data = AmbienceConfig and AmbienceConfig[ambience_id]
    local track_key = ambience_id
    if ambience_data and ambience_data.cue then
        track_key = ambience_data.cue:match("/([^/]+)%.sound$") or ambience_id
    end
    if not is_registered_music_track(track_key) then
        warn_missing_music_track(room_id, environment.music_raw or ambience_id, track_key)
        room_log(string.format("[ROOM_MANAGER] Missing registered music track: room=%s raw=%s normalized=%s",
            tostring(room_id), tostring(environment.music_raw or ambience_id), tostring(track_key)))
        return
    end
    room_log(string.format("[MUSIC_DEBUG] Resolved track_key: %s, current_track: %s",
        tostring(track_key), tostring(current_music_track)))
    local Audio = require("mvtk.audio.audio")
    if track_key ~= current_music_track or
        (Audio.current_music_request and Audio.current_music_request() ~= track_key) then
        room_log(string.format("[ROOM_MANAGER] Playing music: %s (from music: %s)", track_key, ambience_id))
        Audio.music(track_key)
        current_music_track = track_key
    else
        room_log(string.format("[ROOM_MANAGER] Music already playing: %s", track_key))
    end
end

local function activate_current_room(room_id)
    room_id = normalize_room_id(room_id)
    local room_data = room_runtime[room_id]
    if not room_id or not room_is_ready(room_data) then
        return false
    end

    if room_id == current_room_id and room_data.state == ROOM_STATE_CURRENT then
        pending_current_room_id = nil
        return true
    end

    local old_room = current_room_id
    local old_entry = old_room and room_runtime[old_room] or nil
    local now = os.time()
    local time_since_last_transition = now - last_room_transition_time
    local rapid_transition = time_since_last_transition < 1 and old_room ~= nil

    current_room_id = room_id
    pending_current_room_id = nil
    last_room_transition_time = now
    last_transition_clock = room_clock
    last_transition_frame = room_frame
    room_data.state = ROOM_STATE_CURRENT
    room_data.linger_until = nil
    room_data.linger_expiry_notified = nil
    -- Visible neighbors are already enabled. Room-enter subscribers below
    -- carry the lifecycle event; avoid re-enabling every physics/render
    -- component merely because the player crossed the seam.
    M.set_room_visible(room_id, true)

    if old_entry and room_is_loaded(old_entry) then
        old_entry.state = ROOM_STATE_READY
        old_entry.linger_until = room_clock + ROOM_LINGER_TIME
        old_entry.linger_expiry_notified = false
    end

    if not old_room then
        transition_grace_t = SPAWN_GRACE_TIME
    end

    room_log(string.format("[ROOM_MANAGER] Room transition: %s -> %s",
        old_room or "none", room_id))
    mark_streaming_dirty()
    apply_room_clear_color(room_id)

    if old_room then
        M.trigger_event("on_room_exit", old_room)
    end

    M.trigger_event("on_room_enter", room_id)
    if old_room and old_room~=room_id and Config.progression and Config.progression.saves
        and Config.progression.saves.autosave_on_room_change then
        local saved,err=pcall(function() return require("mvtk.game.save_system.save_manager").on_room_changed(old_room,room_id) end)
        if not saved then print("[ROOM_MANAGER] Transition save failed: "..tostring(err)) end
    end
    if rapid_transition then
        -- Rapid transitions still are real lifecycle boundaries. Only defer
        -- the music change; skipping exit/enter here used to leave minimap,
        -- cleanup, and controlled traversal subscribers in the previous room.
        room_log(string.format("[MUSIC_DEBUG] Room transition too rapid (%.1fs ago), deferring only music", time_since_last_transition))
        pending_music_room_id = room_id
    else
        pending_music_room_id = nil
        apply_room_music(room_id)
    end
    return true
end

promote_room_ready = function(room_id, room_data)
    if not room_data or room_data.state ~= ROOM_STATE_LOADING then
        return false
    end

    room_data.state = ROOM_STATE_READY
    room_data.ready_frame = nil
    mark_streaming_dirty()
    M.trigger_event("on_room_ready", room_id)
    M.trigger_event("on_room_loaded", room_id)

    if pending_current_room_id == room_id then
        return activate_current_room(room_id)
    end
    return true
end

function M.set_current_room(room_id)
    room_id = normalize_room_id(room_id)
    room_log(string.format("[MUSIC_DEBUG] set_current_room called: %s (current=%s)",
        tostring(room_id), tostring(current_room_id)))

    if not room_id or not room_positions[room_id] then
        return false
    end

    local room_data = room_runtime[room_id]
    if room_id == current_room_id and room_data and room_data.state == ROOM_STATE_CURRENT then
        room_log("[MUSIC_DEBUG] Room already current, skipping")
        pending_current_room_id = nil
        return true
    end

    if not room_is_ready(room_data) then
        pending_current_room_id = room_id
        if not room_is_loaded(room_data) then
            local room_meta = room_positions[room_id]
            if room_meta then
                local spawn_x, spawn_y = compute_spawn_xy(room_meta)
                M.load_room(room_id, vmath.vector3(spawn_x, spawn_y, 0))
                room_data = room_runtime[room_id]
            end
        end
        if room_is_ready(room_data) then
            return activate_current_room(room_id)
        end
        room_log(string.format("[ROOM_MANAGER] Deferring current-room switch until %s is ready", tostring(room_id)))
        mark_streaming_dirty()
        return false
    end

    return activate_current_room(room_id)
end

function M.get_current_room()
    return current_room_id
end

function M.get_room_for_position(position)
    if not position then return nil end
    local current = current_room_id and room_positions[current_room_id]
    if current and point_in_bounds(position, make_room_bounds(current)) then return current_room_id end
    return find_room_containing_point(position)
end

function M.get_room_error(room_id)
    room_id = normalize_room_id(room_id)
    if not room_id or not room_positions[room_id] then return "unknown_room" end
    local entry = room_runtime[room_id]
    return entry and (entry.error or (resources and resources.error(entry))) or nil
end

-- A ready collection may still have an enable message in flight. Arrivals
-- and controlled handoffs also wait for that message's physics frame.
function M.is_room_enterable(room_id)
    room_id = normalize_room_id(room_id)
    local entry = room_runtime[room_id]
    return not room_is_concealed(room_id) and M.is_startup_ready()
        and room_is_ready(entry) and entry.visible == true
        and room_frame >= (entry.enabled_frame or math.huge)
end

function M.begin_arrival(owner, room_id, position)
    room_id = normalize_room_id(room_id) or M.get_room_for_position(position)
    if not room_id or not room_positions[room_id] then return nil, "unknown_destination_room" end
    if not M.get_factory_url(room_id) then return nil, "missing_destination_factory" end
    if position and not point_in_bounds(position, make_room_bounds(room_positions[room_id])) then
        return nil, "destination_outside_room"
    end
    if active_handoff_token then M.finish_handoff(active_handoff_token) end
    next_arrival_pin = next_arrival_pin + 1
    local token = "arrival:" .. next_arrival_pin
    arrival_pins[token] = { room_id = room_id, owner = owner, started = room_clock }
    add_room_pin(token, room_id, true)
    M.load_room(room_id)
    local entry = room_runtime[room_id]
    if entry and entry.state == ROOM_STATE_PREPARING then
        resources.retry(entry)
        entry.error, entry.error_reported = nil, nil
    end
    mark_streaming_dirty()
    return token
end

function M.arrival_status(token)
    local arrival = arrival_pins[token]
    if not arrival then return false, "stale_arrival" end
    local err = M.get_room_error(arrival.room_id)
    if err then return false, err end
    -- Whole-world startup work is not a stalled destination-room request.
    -- Start the ordinary arrival deadline once that loading gate has opened.
    if not M.is_startup_ready() then arrival.started = room_clock; return false end
    local settings = StreamS and StreamS.room or {}
    local deadline = (tonumber(settings.resource_load_timeout) or 15)
        * (tonumber(settings.resource_load_attempts) or 3)
        + (tonumber(settings.resource_retry_delay) or 1) * 3 + 5
    if room_clock - arrival.started > deadline then return false, "arrival_timed_out" end
    return M.is_room_enterable(arrival.room_id)
end

function M.finish_arrival(token, commit)
    local arrival = arrival_pins[token]
    if not arrival then return false end
    if commit then
        local ready, err = M.arrival_status(token)
        if not ready then return false, err end
        M.set_current_room(arrival.room_id)
    end
    remove_room_pin(token, arrival.room_id)
    arrival_pins[token] = nil
    mark_streaming_dirty()
    return true
end

function M.is_handoff_ready(token, room_id)
    local handoff = handoffs[token]
    if not handoff then return false, true, "stale_handoff" end
    local found = false
    room_id = normalize_room_id(room_id)
    for _, id in ipairs(handoff.route) do if id == room_id then found = true end end
    if not found then return false, true, "room_not_in_route" end
    local err = M.get_room_error(room_id)
    return M.is_room_enterable(room_id), err ~= nil, err
end

-- Check the swept player box before movement reaches an unprepared neighbor.
-- This also covers a dash crossing a whole small room in a single frame.
function M.can_move_between(from, to, half_w, half_h)
    if active_handoff_token then return true end -- Elevator owns its pinned route.
    if not current_room_id then return false end
    local dx, dy = to.x - from.x, to.y - from.y
    for _, edge in ipairs(room_graph[current_room_id] or {}) do
        local id = normalize_room_id(edge.id)
        local bounds = room_positions[id] and make_room_bounds(room_positions[id])
        if bounds and not M.is_room_enterable(id) then
            local min_x, max_x = bounds.min_x - (half_w or 0), bounds.max_x + (half_w or 0)
            local min_y, max_y = bounds.min_y - (half_h or 0), bounds.max_y + (half_h or 0)
            local enter, leave = 0, 1
            local function axis(p, d, lo, hi)
                if d == 0 then return p >= lo and p <= hi end
                local a, b = (lo - p) / d, (hi - p) / d
                enter, leave = math.max(enter, math.min(a, b)), math.min(leave, math.max(a, b))
                return enter <= leave
            end
            local toward = dx * ((bounds.min_x + bounds.max_x) * 0.5 - from.x)
                + dy * ((bounds.min_y + bounds.max_y) * 0.5 - from.y)
            if toward > 0 and axis(from.x, dx, min_x, max_x) and axis(from.y, dy, min_y, max_y) then
                M.load_room(id)
                local entry = room_runtime[id]
                if entry then entry.preview_until = room_clock + 0.5 end
                mark_streaming_dirty()
                return false, id, M.get_room_error(id)
            end
        end
    end
    local destination = M.get_room_for_position(to)
    if destination and not M.is_room_enterable(destination) then return false, destination end
    return true
end

local function is_direct_neighbor(center_room_id, candidate_room_id)
    if not center_room_id or not candidate_room_id then
        return false
    end
    for _, neighbor in ipairs(room_graph[center_room_id] or {}) do
        if normalize_room_id(neighbor.id) == candidate_room_id then
            return true
        end
    end
    return false
end

local function normalize_handoff_route(opts)
    opts = opts or {}
    local source = opts.route or opts.rooms or opts.room_ids
    local route = {}

    if type(source) == "table" then
        for _, value in ipairs(source) do
            local room_id = normalize_room_id(value)
            if room_id and route[#route] ~= room_id then
                route[#route + 1] = room_id
            end
        end
    end

    if #route == 0 then
        local from_room = normalize_room_id(opts.source_room_id or opts.source_room or current_room_id)
        local to_room = normalize_room_id(opts.target_room_id or opts.destination_room_id or opts.target_room)
        if from_room then route[#route + 1] = from_room end
        if to_room and to_room ~= from_room then route[#route + 1] = to_room end
    end

    return route
end

local function update_handoff_visibility(handoff)
    if not handoff then return end
    -- Keep the room immediately behind the cabin visible after a commit so a
    -- cabin straddling the seam cannot expose a one-frame disabled-room gap.
    local first_visible = math.max(1, handoff.index - 1)
    local last_visible = math.min(#handoff.route,
        handoff.index + math.max(0, handoff.visible_ahead or 1))
    for index, room_id in ipairs(handoff.route) do
        set_room_pin_visible(handoff.token, room_id,
            index >= first_visible and index <= last_visible)
    end
end

local function handoff_owner_alive(handoff)
    if not handoff or not handoff.owner_url then
        return true
    end
    local ok, exists = pcall(go.exists, handoff.owner_url)
    return ok and exists == true
end

--- Begin an owner-scoped, controlled cross-room handoff.
-- The full route is load-pinned; the current room, `visible_ahead` rooms, and
-- the immediately previous room after a commit are visibility-pinned.
-- Automatic player-position transitions remain suppressed until
-- finish_handoff is called.
-- @param owner GO/component URL used for dead-owner cleanup
-- background=true pins a moving object's route without taking player control.
-- @param opts { route={room ids}, visible_ahead=1, owner_url=url, background=false }
-- @return opaque generation token, or nil + error string
function M.begin_handoff(owner, opts)
    opts = opts or {}
    if not opts.background and active_handoff_token and handoffs[active_handoff_token] then
        return nil, "handoff_active"
    end
    if owner == nil then
        return nil, "missing_owner"
    end

    local route = normalize_handoff_route(opts)
    if #route < 2 then
        return nil, "route_requires_two_rooms"
    end
    for index, room_id in ipairs(route) do
        if not room_positions[room_id] then
            return nil, "unknown_room:" .. tostring(room_id)
        end
        if index > 1 then
            local previous = route[index - 1]
            if not is_direct_neighbor(previous, room_id)
                and not is_direct_neighbor(room_id, previous) then
                return nil, "rooms_not_adjacent:" .. tostring(previous) .. ":" .. tostring(room_id)
            end
        end
    end

    local current_index = nil
    for index, room_id in ipairs(route) do
        if room_id == current_room_id then
            current_index = index
            break
        end
    end
    if not current_index and not opts.background then
        return nil, "current_room_not_in_route"
    end

    next_handoff_generation = next_handoff_generation + 1
    local token = string.format("mvtk_handoff:%d:%d", handoff_epoch, next_handoff_generation)
    local inferred_owner_url = opts.owner_url
    if inferred_owner_url == nil and type(owner) ~= "string"
        and type(owner) ~= "number" and type(owner) ~= "boolean" then
        inferred_owner_url = owner
    end
    local handoff = {
        token = token,
        generation = next_handoff_generation,
        owner = owner,
        owner_key = tostring(owner),
        owner_url = inferred_owner_url,
        route = route,
        index = opts.background and 1 or current_index,
        background = opts.background == true,
        visible_ahead = math.max(0, math.floor(tonumber(opts.visible_ahead) or 1)),
    }

    handoffs[token] = handoff
    if not handoff.background then active_handoff_token = token end
    for _, room_id in ipairs(route) do
        add_room_pin(token, room_id, false)
    end
    update_handoff_visibility(handoff)
    mark_streaming_dirty()
    room_log(string.format("[ROOM_MANAGER] Began handoff %s owner=%s route=%s",
        token, tostring(owner), table.concat(route, " -> ")))
    return token
end

--- Commit the next room in a controlled handoff.
-- The destination must be the next route entry and already be ready. Room
-- activation still goes through set_current_room so all normal lifecycle
-- events, clear color, minimap, and music behavior remain authoritative.
function M.advance_handoff(token, room_id)
    local handoff = token and handoffs[token] or nil
    if not handoff or (not handoff.background and active_handoff_token ~= token) then
        return false, "stale_handoff"
    end
    if not handoff_owner_alive(handoff) then
        M.finish_handoff(token)
        return false, "owner_missing"
    end

    local destination = normalize_room_id(room_id)
    local next_index = handoff.index + 1
    if handoff.route[next_index] ~= destination then
        return false, "room_not_next"
    end
    if not M.is_room_enterable(destination) then
        return false, "room_not_ready"
    end
    if not handoff.background and not M.set_current_room(destination) then
        return false, "activation_failed"
    end

    handoff.index = next_index
    if not handoff.background then
        transition_grace_t = math.max(transition_grace_t, SPAWN_GRACE_TIME)
    end
    update_handoff_visibility(handoff)
    mark_streaming_dirty()
    room_log(string.format("[ROOM_MANAGER] Advanced handoff %s -> %s", token, destination))
    return true
end

--- Finish a controlled handoff and release only that generation's pins.
function M.finish_handoff(token)
    local handoff = token and handoffs[token] or nil
    if not handoff then
        return false, "stale_handoff"
    end

    for _, room_id in ipairs(handoff.route) do
        remove_room_pin(token, room_id)
    end
    handoffs[token] = nil
    if active_handoff_token == token then
        active_handoff_token = nil
    end
    if not handoff.background then
        transition_grace_t = math.max(transition_grace_t, SPAWN_GRACE_TIME)
    end
    mark_streaming_dirty()
    room_log(string.format("[ROOM_MANAGER] Finished handoff %s", tostring(token)))
    return true
end

local function cleanup_dead_handoff_owner()
    local dead = {}
    for token, handoff in pairs(handoffs) do
        if not handoff_owner_alive(handoff) then dead[#dead + 1] = token end
    end
    for _, token in ipairs(dead) do
        room_log(string.format("[ROOM_MANAGER] Releasing handoff %s because its owner no longer exists", tostring(token)))
        M.finish_handoff(token)
    end
end

local function load_priority(room_id)
    if room_id == pending_current_room_id then return 0 end
    if room_has_load_pin(room_id) then return 1 end
    if room_id == current_room_id then return 2 end
    if is_direct_neighbor(current_room_id, room_id)
        or is_direct_neighbor(pending_current_room_id, room_id) then
        return 3
    end
    return 4
end

local function rebuild_streaming_queues()
    load_queue = {}
    load_queued = {}
    unload_queue = {}
    unload_queued = {}

    local missing = {}
    for room_id in pairs(desired_rooms) do
        local entry = room_runtime[room_id]
        if room_positions[room_id]
            and (not entry or entry.state == ROOM_STATE_PREPARING) then
            missing[#missing + 1] = room_id
        end
    end
    table.sort(missing, function(a, b)
        local pa, pb = load_priority(a), load_priority(b)
        if pa == pb then return tostring(a) < tostring(b) end
        return pa < pb
    end)
    for _, room_id in ipairs(missing) do
        load_queue[#load_queue + 1] = room_id
        load_queued[room_id] = true
    end

    local excess = {}
    for room_id, room_data in pairs(room_runtime) do
        if room_data.state ~= ROOM_STATE_UNLOADING
            and room_id ~= current_room_id
            and room_id ~= pending_current_room_id
            and not desired_rooms[room_id]
            and not room_has_load_pin(room_id) then
            excess[#excess + 1] = room_id
        end
    end
    table.sort(excess)
    for _, room_id in ipairs(excess) do
        unload_queue[#unload_queue + 1] = room_id
        unload_queued[room_id] = true
    end
end

function M.update_streaming()
    streaming_reconcile_count = streaming_reconcile_count + 1
    desired_rooms = {}
    if not current_room_id and not pending_current_room_id and next(room_pins) == nil then
        rebuild_streaming_queues()
        return
    end

    if keep_all_loaded then
        for room_id in pairs(room_positions) do
            desired_rooms[room_id] = true
        end
    else
        desired_rooms = collect_rooms_to_keep_loaded()
    end

    -- Requests only reserve a generation. All resource preparation and object
    -- creation, including the current room, run through the update budget.
    if pending_current_room_id
        and desired_rooms[pending_current_room_id]
        and not room_is_loaded(room_runtime[pending_current_room_id]) then
        local meta = room_positions[pending_current_room_id]
        if meta then
            local spawn_x, spawn_y = compute_spawn_xy(meta)
            M.load_room(pending_current_room_id, vmath.vector3(spawn_x, spawn_y, 0))
        end
    end

    rebuild_streaming_queues()
end

local function process_load_queue()
    -- A seam already performs lifecycle callbacks and a configured autosave.
    -- Cached neighbor resources can create immediately, so keep that work
    -- off the same frame. The destination itself is ready before entry.
    if last_transition_frame == room_frame then return end
    local loaded = 0
    local waiting = {}
    while #load_queue > 0 do
        local room_id = table.remove(load_queue, 1)
        load_queued[room_id] = nil
        if desired_rooms[room_id]
            and room_positions[room_id]
            and not room_is_loaded(room_runtime[room_id]) then
            local spawn_x, spawn_y = compute_spawn_xy(room_positions[room_id])
            M.load_room(room_id, vmath.vector3(spawn_x, spawn_y, 0))
            local entry = room_runtime[room_id]
            if entry and entry.state == ROOM_STATE_PREPARING and not entry.error then
                resources.start(entry)
                -- Preload resources behind an intact secret wall, but do not
                -- instantiate its baked collection. Spawned objects start
                -- enabled and their init messages can re-enable components;
                -- deferring creation prevents even an initial scenery flash.
                if loaded < LOAD_BUDGET_PER_FRAME and entry.resources.state == "ready"
                    and not room_is_concealed(room_id) then
                    create_prepared_room(room_id, entry)
                    loaded = loaded + 1
                end
                local err = entry.error or resources.error(entry)
                if err and not entry.error_reported then
                    entry.error_reported = true
                    print(string.format("[ROOM_MANAGER] Cannot prepare %s: %s", room_id, err))
                end
                if entry.state == ROOM_STATE_PREPARING then waiting[#waiting + 1] = room_id end
            end
        end
    end
    load_queue = waiting
    for _, room_id in ipairs(waiting) do load_queued[room_id] = true end
end

local function process_unload_queue()
    local unloaded = 0
    while unloaded < UNLOAD_BUDGET_PER_FRAME and #unload_queue > 0 do
        local room_id = table.remove(unload_queue, 1)
        unload_queued[room_id] = nil
        local entry = room_runtime[room_id]
        if entry
            and entry.state ~= ROOM_STATE_UNLOADING
            and room_id ~= current_room_id
            and room_id ~= pending_current_room_id
            and not desired_rooms[room_id]
            and not room_has_load_pin(room_id) then
            M.unload_room(room_id)
            unloaded = unloaded + 1
        end
    end
end

local function process_unload_delete_chunks()
    local remaining = UNLOAD_DELETE_CHUNK_SIZE
    for _, info in pairs(pending_unloads) do
        local queue = info.delete_queue
        local index = info.delete_index or 1
        while remaining > 0 and queue and index <= #queue do
            local go_url = queue[index]
            index = index + 1
            if go_url and go.exists(go_url) then
                info.urls[#info.urls + 1] = go_url
                go.delete(go_url, true)
            end
            remaining = remaining - 1
        end
        info.delete_index = index
        if remaining <= 0 then
            break
        end
    end
end

local function reconcile_streaming_if_needed(player_pos, force)
    if force or streaming_dirty or streaming_safety_elapsed >= STREAMING_SAFETY_INTERVAL then
        streaming_dirty = false
        streaming_safety_elapsed = 0
        M.update_streaming()
        refresh_room_visibility(player_pos)
        return true
    end
    return false
end

function M.get_preload_distance()
    return get_preload_distance()
end

function M.get_streaming_debug_state()
    return {
        reconcile_count = streaming_reconcile_count,
        load_queue_count = #load_queue,
        unload_queue_count = #unload_queue,
        streaming_dirty = streaming_dirty,
        resources = resources and resources.snapshot() or {},
        create_failures = create_failures,
        max_create_seconds = max_create_seconds,
    }
end

function M.get_rooms_to_stream(center_room, max_distance)
    local rooms_to_stream = { [center_room] = true }
    local visited = { [center_room] = true }
    local distances = { [center_room] = 0 }
    local queue = { { id = center_room, distance = 0 } }
    local head = 1
    
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        
        if current.distance < max_distance then
            local neighbors = room_graph[current.id] or {}
            
            for _, neighbor in ipairs(neighbors) do
                local neighbor_id = normalize_room_id(neighbor.id)
                if neighbor_id and not visited[neighbor_id] then
                    visited[neighbor_id] = true
                    rooms_to_stream[neighbor_id] = true
                    distances[neighbor_id] = current.distance + 1
                    table.insert(queue, { 
                        id = neighbor_id, 
                        distance = current.distance + 1 
                    })
                end
            end
        end
    end
    
    return rooms_to_stream, distances
end

function M.get_factory_url(room_id)
    room_id = normalize_room_id(room_id)
    -- This should reference your room configuration
    local RoomsCF = Util.require_config("developer.config.rooms_config")

    -- Helper: resolve a factory URL string to the active collection socket
    -- Some configs encode URLs with the literal "main:/..." socket which only
    -- works when booting the game collection directly. When loaded via a
    -- collectionproxy, the socket differs. Rebuild the URL with the active
    -- socket (published by stream_manager.script) to be robust.
    local function resolve_in_active_socket(url_string)
        if type(url_string) ~= "string" then return nil end
        local u = msg.url(url_string)
        -- Determine the active socket of the running game collection
        local active_socket = nil
        if C and C.URL and C.URL.ROOM_MANAGER then
            local rm = msg.url(C.URL.ROOM_MANAGER)
            active_socket = rm and rm.socket or nil
        end
        if active_socket and tostring(u.socket) ~= tostring(active_socket) then
            return msg.url(active_socket, u.path, u.fragment)
        end
        return u
    end

    local normalized = "developer/rooms/" .. Util.normalize_room_id(room_id)
    local factory = RoomsCF and RoomsCF.factories and RoomsCF.factories[normalized]

    if factory then
        return resolve_in_active_socket(factory)
    end

    return nil
end

function M.is_room_loaded(room_id)
    room_id = normalize_room_id(room_id)
    return room_is_loaded(room_runtime[room_id])
end

function M.get_loaded_room(room_id)
    room_id = normalize_room_id(room_id)
    local room_data = room_runtime[room_id]
    if room_is_loaded(room_data) then
        return room_data
    end
    return nil
end

function M.is_room_ready(room_id)
    room_id = normalize_room_id(room_id)
    return room_is_ready(room_runtime[room_id])
end

function M.get_room_state(room_id)
    room_id = normalize_room_id(room_id)
    local room_data = room_runtime[room_id]
    return room_data and room_data.state or nil
end

function M.register_event(event_name, callback)
    if room_events[event_name] then
        table.insert(room_events[event_name], callback)
    end
end

-- Public lifecycle hooks
-- ---------------------------------------------------------------------------
-- Lua modules can subscribe to room lifecycle events without a Defold script.
-- Recognised event names: on_room_spawned, on_room_ready, on_room_enter,
-- on_room_exit, on_room_loaded, on_room_unloaded.
--
-- Use `on_room_unloaded` to clear per-room caches such as NPC tables,
-- ambient refcounts, hit-reaction state, and FX timers. Persistence (save
-- data, checkpoints) does NOT belong here -- it lives in mvtk/core/checkpoint.
--
--   local RoomMgr = require("mvtk.map.streaming.room_manager")
--   RoomMgr.register_event("on_room_unloaded", function(room_id)
--       my_module.clear(room_id)
--   end)
function M.on_room_unload(callback)
    M.register_event("on_room_unloaded", callback)
end

function M.trigger_event(event_name, room_id)
    local callbacks = room_events[event_name]
    if callbacks then
        for _, callback in ipairs(callbacks) do
            if type(callback) == "function" then
                pcall(callback, room_id)
            end
        end
    end
end

function M.update(dt)
    room_frame = room_frame + 1
    refresh_secret_visibility()
    local frame_dt = math.max(0, dt or 0)
    if resources then resources.update(frame_dt) end
    room_clock = room_clock + frame_dt
    streaming_safety_elapsed = streaming_safety_elapsed + frame_dt
    local player_pos = nil
    FrameWatch.set_room(current_room_id or pending_current_room_id)
    cleanup_dead_handoff_owner()
    for token, arrival in pairs(arrival_pins) do
        if arrival.owner and not go.exists(arrival.owner) then M.finish_arrival(token, false) end
    end

    if transition_grace_t > 0 then
        transition_grace_t = math.max(0, transition_grace_t - frame_dt)
    end

    for _, entry in pairs(room_runtime) do
        if entry.preview_until and room_clock >= entry.preview_until then
            entry.preview_until = nil
            mark_streaming_dirty()
        end
        if entry.linger_until
            and room_clock >= entry.linger_until
            and not entry.linger_expiry_notified then
            entry.linger_expiry_notified = true
            mark_streaming_dirty()
        end
    end

    for i = #rooms_to_promote, 1, -1 do
        rooms_to_promote[i] = nil
    end
    for room_id, room_data in pairs(room_runtime) do
        if room_data.state == ROOM_STATE_LOADING and room_frame >= (room_data.ready_frame or math.huge) then
            rooms_to_promote[#rooms_to_promote + 1] = room_id
        end
    end
    for _, room_id in ipairs(rooms_to_promote) do
        local room_data = room_runtime[room_id]
        if room_data and room_data.state == ROOM_STATE_LOADING then
            promote_room_ready(room_id, room_data)
        end
    end

    -- Check for room transitions based on player position
    if player_url and go.exists(player_url) then
        player_pos = get_world_position(player_url)
        if current_room_id and transition_grace_t <= 0 then
            M.check_room_transitions(player_pos)
        end
    end

    local lookahead = nil
    if not keep_all_loaded and not active_handoff_token and not pending_current_room_id
        and player_pos and current_room_id then
        local previous = previous_player_room == current_room_id and previous_player_position or nil
        -- Preserve an established preparation while standing still. Reversing
        -- recomputes it. Room changes start a fresh motion sample.
        if previous and player_pos.x == previous.x and player_pos.y == previous.y then
            lookahead = lookahead_room_id
        else
            lookahead = RoomLookahead.select(player_pos, previous,
                make_room_bounds(room_positions[current_room_id]), room_graph[current_room_id],
                Tile.width, Tile.height, tonumber(StreamS.room and StreamS.room.lookahead_tiles) or 0,
                M.get_room_bounds)
        end
    end
    if lookahead ~= lookahead_room_id then
        lookahead_room_id = lookahead
        mark_streaming_dirty()
    end
    if player_pos then
        previous_player_position = previous_player_position or {}
        previous_player_position.x, previous_player_position.y = player_pos.x, player_pos.y
    else
        previous_player_position = nil
    end
    previous_player_room = current_room_id

    reconcile_streaming_if_needed(player_pos, false)
    process_load_queue()
    if StreamS.room and StreamS.room.prewarm_resources_on_start then
        if not startup_resources then
            startup_resources = StartupResources.new(resources, room_positions, M.get_factory_url)
            for id, entry in pairs(room_runtime) do
                if entry.created then startup_resources.claim(id) end
            end
        end
        startup_resources.update()
    end
    process_unload_queue()
    process_unload_delete_chunks()

    -- Loads/promotions/unload starts can dirty the desired/visibility state.
    -- Reconcile once more in the same frame, but never consume a second room
    -- from either budget.
    reconcile_streaming_if_needed(player_pos, false)

    if next(pending_unloads) then
        for token, info in pairs(pending_unloads) do
            local queue = info.delete_queue
            local all_deletes_scheduled = not queue or (info.delete_index or 1) > #queue
            if all_deletes_scheduled then
                local all_gone = true
                for _, url in ipairs(info.urls) do
                    if go.exists(url) then
                        all_gone = false
                        break
                    end
                end
                if all_gone then
                    pending_unloads[token] = nil
                    if info.callback then
                        local ok, err = pcall(info.callback)
                        if not ok then
                            room_log(string.format("[ROOM_MANAGER] room unload callback failed for %s: %s",
                                tostring(info.room_id), tostring(err)))
                        end
                    end
                end
            end
        end
    end

    if pending_music_room_id and (room_clock - last_transition_clock) >= MUSIC_SETTLE_TIME then
        local rid = current_room_id or pending_music_room_id
        pending_music_room_id = nil
        apply_room_music(rid)
    end
end

function M.check_room_transitions(player_pos)
    if active_handoff_token and handoffs[active_handoff_token] then
        -- A controlled traversal owns the seam. It will call
        -- advance_handoff at its exact visual/physics transfer point.
        return
    end
    if not current_room_id then
        return
    end
    if not player_pos then
        transition_log("[ROOM_MANAGER] player_pos unavailable; skipping transition check")
        return
    end
    
    local current_room_data = room_positions[current_room_id]
    if not current_room_data then
        transition_log(string.format("[ROOM_MANAGER] No data for current room '%s'", tostring(current_room_id)))
        return
    end

    -- Start probing neighbors once the player approaches a seam, and
    -- transition immediately after they are actually inside the next room.
    local room_bounds = make_room_bounds(current_room_data)
    if not room_bounds then
        transition_log(string.format("[ROOM_MANAGER] Invalid bounds for current room '%s'", tostring(current_room_id)))
        return
    end
    local inside_current_room = point_in_bounds(player_pos, room_bounds)
    local should_probe_neighbors = (not inside_current_room)
        or point_near_room_edge(player_pos, room_bounds, TRANSITION_THRESHOLD)

    if should_probe_neighbors then
        if not inside_current_room then
            transition_log(string.format("[ROOM_MANAGER] Player outside bounds of %s (pos=(%.1f,%.1f) bounds=[%.1f..%.1f, %.1f..%.1f])",
                tostring(current_room_id), player_pos.x, player_pos.y,
                room_bounds.min_x, room_bounds.max_x, room_bounds.min_y, room_bounds.max_y))
        end
        
        -- Check which neighbor room the player might be in
        local neighbors = room_graph[current_room_id] or {}
        local containing_neighbor_id = nil

        for _, neighbor in ipairs(neighbors) do
            local neighbor_id = normalize_room_id(neighbor.id)
            local neighbor_data = room_positions[neighbor_id]

            if neighbor_data then
                local neighbor_bounds = make_room_bounds(neighbor_data)

                -- Check if player is in this neighbor room
                if point_in_bounds(player_pos, neighbor_bounds) then
                    containing_neighbor_id = neighbor_id

                    -- Once outside the current bounds, containment in a connected
                    -- neighbor is authoritative. Controlled traversal can suppress
                    -- checks until the player has walked well past the doorway
                    -- (for example while the elevator's doors finish opening).
                    -- Keep the proximity check for overlapping room bounds only.
                    local allow = not inside_current_room
                    -- Check a door on the current room's matching side
                    local from_side = normalize_side(neighbor.side) or normalize_side(neighbor.mate and neighbor.mate.side)
                    local cur_door_x, cur_door_y = door_pos_for_side(current_room_id, from_side)
                    local tgt_door_x, tgt_door_y = door_world_pos(neighbor.mate or neighbor.door, neighbor_data)
                    local has_door_reference = (cur_door_x and cur_door_y) or (tgt_door_x and tgt_door_y)
                    local function near(ax, ay)
                        if not (ax and ay) then return false end
                        local dx = player_pos.x - ax
                        local dy = player_pos.y - ay
                        local dist2 = dx * dx + dy * dy
                        return dist2 <= (DOOR_PROX_THRESHOLD * DOOR_PROX_THRESHOLD)
                    end
                    if allow or near(cur_door_x, cur_door_y) or near(tgt_door_x, tgt_door_y) then
                        allow = true
                    elseif not has_door_reference then
                        -- Some layouts do not provide door markers on every seam.
                        -- If the player is already inside the neighboring room,
                        -- prefer a correct room switch over leaving the room hidden.
                        allow = true
                    end

                    if allow then
                        transition_log(string.format("[ROOM_MANAGER] Transitioning to neighbor %s", tostring(neighbor_id)))
                        M.set_current_room(neighbor_id)
                        return
                    else
                        transition_log(string.format("[ROOM_MANAGER] Suppressed transition to %s (too far from door or missing door data)", tostring(neighbor_id)))
                    end
                end
            end
        end

        if not inside_current_room and not containing_neighbor_id then
            local fallback_room = find_room_containing_point(player_pos, current_room_id)
            if fallback_room then
                transition_log(string.format("[ROOM_MANAGER] Fallback transition to containing room %s", tostring(fallback_room)))
                M.set_current_room(fallback_room)
            end
        end
    end
end

function M.handle_room_load_message(room_id)
    room_id = normalize_room_id(room_id)
    room_log(string.format("[MUSIC_DEBUG] ========================================"))
    room_log(string.format("[MUSIC_DEBUG] handle_room_load_message called: %s", tostring(room_id)))
    room_log(string.format("[MUSIC_DEBUG] ========================================"))

    local room_data = room_positions[room_id]
    if not room_data then
        room_log(string.format("[ROOM_MANAGER] Unknown room ID: %s", room_id))
        return false
    end

    -- Explicit loads are used by respawn, fast travel, and boot. They supersede
    -- any in-flight controlled traversal; elevator commits use set_current_room
    -- directly through advance_handoff and therefore do not enter this path.
    if active_handoff_token and handoffs[active_handoff_token] then
        M.finish_handoff(active_handoff_token)
    end

    log_spawn_offset('load_request', room_id, room_data)
    local spawn_x, spawn_y = compute_spawn_xy(room_data)
    local pos = vmath.vector3(spawn_x, spawn_y, 0)

    if not room_is_loaded(room_runtime[room_id]) then M.load_room(room_id, pos) end

    pending_current_room_id = room_id
    M.set_current_room(room_id)
    mark_streaming_dirty()
    return true
end

function M.final()
    room_log("[ROOM_MANAGER] Cleaning up room manager...")
    if startup_resources then startup_resources.release_all(); startup_resources = nil end
    
    -- Unload all rooms
    for room_id in pairs(room_runtime) do
        M.unload_room(room_id, { force = true })
    end
    if resources then resources.release_all() end
    resources = nil -- The owning collection destroys its factories and callbacks.
    pending_unloads = {}
    arrival_pins = {}
    
    -- Clear state
    current_room_id = nil
    pending_current_room_id = nil
    room_runtime = {}
    room_pins = {}
    handoffs = {}
    active_handoff_token = nil
    room_positions = {}
    room_graph = {}
    room_events = {
        on_room_spawned = {},
        on_room_ready = {},
        on_room_enter = {},
        on_room_exit = {},
        on_room_loaded = {},
        on_room_unloaded = {}
    }
end

return M
