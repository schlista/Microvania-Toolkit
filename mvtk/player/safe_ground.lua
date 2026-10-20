-- Last walkable, room-local placement for a currency recovery drop.
-- Trigger hazards cannot be raycast, so their authored rectangles are tracked
-- separately. No safe sample means the fee is waived rather than trapping it.
local Util = require "mvtk.core.util"
local Config = Util.require_config("developer.config.resolved_config")
local Surface = require "mvtk.core.surface_classifier"
local Geometry = require "mvtk.map.streaming.room_geometry"
local M = {}
local blockers = {}
local RoomManager

local function enabled()
    return Config.progression and Config.progression.death
        and Config.progression.death.drop_enabled == true
end
local function rooms()
    RoomManager = RoomManager or require "mvtk.map.streaming.room_manager"
    return RoomManager
end

-- Called by static hazard/water scripts after their world transform is ready.
-- Keep the live owner so activation/retraction changes need no frame messages.
function M.register_blocker(id, owner, position, width, height, water)
    if not enabled() then return end
    blockers[id] = { owner = owner, x = position.x, y = position.y,
        width = tonumber(width) or 0, height = tonumber(height) or 0,
        water = water == true }
end
function M.unregister_blocker(id) blockers[id] = nil end
function M.clear() blockers = {} end

function M.is_safe(room_id, x, y, half_width, half_height)
    local rm = rooms()
    for _, zone in pairs(blockers) do
        local owner = zone.owner
        if zone.water or (owner.is_enabled ~= false and not owner.is_retracted) then
            if zone.width <= 0 or zone.height <= 0 then
                -- An unconfigured legacy zone has no trustworthy footprint.
                -- Conservatively refuse this room instead of guessing a size.
                if rm.get_room_for_position(zone) == room_id then return false end
            elseif math.abs(x - zone.x) <= zone.width * 0.5 + (half_width or 0)
                and math.abs(y - zone.y) <= zone.height * 0.5 + (half_height or 0) then
                return false
            end
        end
    end
    return true
end

function M.observe(self)
    if not enabled() or not self.grounded or self._is_dead or self._room_arrival
        or self._in_water or self._in_climb or self._ledge_kinematic
        or self._grapple_active or self._block_grab or self._ground_is_platform then return false end
    local pos = self.pos
    if not pos then return false end
    local group = self._bone_physics and self._bone_physics.last_ground_group
    if group ~= Surface.GROUPS.SOLID and group ~= Surface.GROUPS.WORLD
        and group ~= Surface.GROUPS.GROUND then return false end
    local rm = rooms()
    if not rm.is_startup_ready() then return false end
    local room_id = rm.get_room_for_position(pos)
    if not room_id or not rm.is_room_enterable(room_id) then return false end
    local room = rm.get_room_data(room_id)
    if not room then return false end
    local hw, hh = self.collider_half_width or 0, self.collider_half_height or 0
    if not M.is_safe(room_id, pos.x, pos.y, hw, hh) then return false end
    local x, y = Geometry.compute_spawn_xy(room)
    local sample = self._death_safe_ground or {}
    sample.room_id, sample.x, sample.y = room_id, pos.x - x, pos.y - y
    sample.half_width, sample.half_height = hw, hh
    sample.foot_adjust = self.foot_floor_adjust or 0
    self._death_safe_ground = sample
    return true
end

function M.capture(self)
    local sample = self._death_safe_ground
    self._death_safe_ground = nil
    if not sample then return nil end
    local rm = rooms()
    local room_id = rm.get_room_for_position(self.pos) or rm.get_current_room()
    if room_id ~= sample.room_id then return nil end
    local room = rm.get_room_data(room_id)
    if not room then return nil end
    local x, y = Geometry.compute_spawn_xy(room)
    if not M.is_safe(room_id, x + sample.x, y + sample.y, sample.half_width, sample.half_height) then return nil end
    -- A destructible/crumbling floor may have disappeared since the sample.
    -- Query only stable terrain; moving/one-way platforms are excluded.
    local from = vmath.vector3(x + sample.x, y + sample.y, 0)
    local reach = math.max(1, sample.half_height * 2 + math.abs(sample.foot_adjust))
    local hit = physics.raycast(from, from - vmath.vector3(0, reach, 0),
        { Surface.GROUPS.SOLID, Surface.GROUPS.WORLD })
    if not hit or Surface.classify_normal(hit.normal) ~= Surface.KINDS.GROUND then return nil end
    return { room_id = room_id, x = sample.x, y = sample.y }
end
return M
