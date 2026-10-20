-- Currency recovery state is global; its visual exists only in a ready room.
-- Death fees are committed against the restored checkpoint snapshot, never
-- against unsaved gains in the dying player's runtime inventory.
local Util = require "mvtk.core.util"
local Config = Util.require_config("developer.config.resolved_config")
local Checkpoint = require "mvtk.core.checkpoint"
local Inventory = require "mvtk.core.inventory"
local SafeGround = require "mvtk.player.safe_ground"
local Geometry = require "mvtk.map.streaming.room_geometry"
local RoomManager = require "mvtk.map.streaming.room_manager"
local M = {}
local active, pending, instance
local generation, bound = 0, false
local playing = function() return false end
local spawn_failed = false
local FACTORY_URL = "main:/room_manager#death_drop_factory"
local SUSPENSION = "pending_death"

local function settings()
    return (Config.progression and Config.progression.death) or {}
end
local function delete_instance()
    -- Provider apply can run in a GUI (Continue/Quit). Removal belongs to the
    -- marker script, which has a game-object context.
    if instance then pcall(msg.post, instance, hash("death_drop_remove")); instance = nil end
end
local function replace_record(record)
    delete_instance()
    active = record
    spawn_failed = false
end
local function valid_record(data)
    local drop = type(data) == "table" and data.drop
    if type(drop) ~= "table" or type(drop.room_id) ~= "string" or drop.room_id == ""
        or type(drop.x) ~= "number" or type(drop.y) ~= "number"
        or drop.x ~= drop.x or drop.y ~= drop.y or math.abs(drop.x) == math.huge or math.abs(drop.y) == math.huge
        or (tonumber(drop.amount) or 0) <= 0 then return nil end
    if drop.remaining ~= nil and (tonumber(drop.remaining) or 0) <= 0 then return nil end
    return Util.deep_copy(drop)
end

Checkpoint.register_provider("death_drop", {
    capture = function() return { drop = active and Util.deep_copy(active) or nil } end,
    apply = function(data) replace_record(valid_record(data)) end,
    defaults = function()
        replace_record(nil)
        -- Explicit Reset/Delete releases suspension before provider defaults.
        -- A missing-slot load during a pending death still needs its waiver path.
        if not Checkpoint.is_save_suspended() then pending = nil end
    end,
    version = 1, order = 45, description = "Recoverable currency drop",
})

function M.loss(currency, cfg)
    currency = math.max(0, math.floor(tonumber(currency) or 0))
    cfg = cfg or settings()
    local fraction = math.max(0, math.min(1, tonumber(cfg.currency_loss_fraction) or 0))
    local loss = math.max(math.max(0, math.floor(tonumber(cfg.min_loss) or 0)), math.floor(currency * fraction))
    local maximum = math.max(0, math.floor(tonumber(cfg.max_loss) or 0))
    if maximum > 0 then loss = math.min(loss, maximum) end
    return math.min(currency, loss)
end

function M.has_pending() return pending ~= nil end
function M.record() return active and Util.deep_copy(active) or nil end
function M.instance_id() return instance end

function M.capture_death(self)
    if pending or settings().drop_enabled ~= true then return false end
    pending = { safe = SafeGround.capture(self), slot = Checkpoint.slot,
        config = Util.deep_copy(settings()) }
    Checkpoint.suspend_saves(SUSPENSION, M.flush_pending)
    return true
end

-- Invoked immediately after Checkpoint.load and before restoring player state.
function M.after_checkpoint_load(load_ok)
    if not pending then return true end
    if Checkpoint.slot ~= pending.slot then return false, "death_snapshot_slot_mismatch" end
    if not load_ok or not pending.safe then
        print("[DEATH_DROP] No safe saved-room placement; death fee waived and previous drop preserved")
        pending = nil
        Checkpoint.resume_saves(SUSPENSION)
        return true
    end
    local currency = Inventory.get_currency()
    local loss = M.loss(currency, pending.config)
    local previous = active
    local next_drop
    if loss > 0 then
        next_drop = Util.deep_copy(pending.safe)
        next_drop.amount = loss
        local lifetime = tonumber(pending.config.drop_lifetime) or 0
        if lifetime > 0 then next_drop.remaining = lifetime end
    end
    local inventory = Util.deep_copy((Checkpoint.data.modules.inventory or {}).data
        or Checkpoint.data.inventory or {})
    inventory.currency = math.max(0, currency - loss)
    local saved, err = Checkpoint.save_provider_updates({ inventory = inventory, death_drop = { drop = next_drop } },
        { slot = pending.slot })
    if not saved then
        -- The loaded baseline is still authoritative. Retry starts by loading it
        -- again, so failed backup/primary writes cannot compound the fee.
        Inventory.set_currency(currency)
        replace_record(previous)
        print("[DEATH_DROP] Cannot persist death fee; Restart will retry: " .. tostring(err))
        return false, err
    end
    Inventory.set_currency(inventory.currency)
    replace_record(next_drop)
    pending = nil
    Checkpoint.resume_saves(SUSPENSION)
    return true
end

-- Quit-before-Restart follows exactly the same restored-snapshot transaction.
function M.flush_pending()
    if not pending then return true end
    local loaded, err = Checkpoint.load(pending.slot)
    if not loaded and err then return false, err end
    return M.after_checkpoint_load(loaded)
end

local function spawn_if_ready()
    if settings().drop_enabled ~= true or not active or pending or instance or spawn_failed or not playing()
        or not RoomManager.is_room_enterable(active.room_id) then return end
    local room = RoomManager.get_room_data(active.room_id)
    if not room then return end
    local x, y = Geometry.compute_spawn_xy(room)
    local cfg = settings()
    local radius = tonumber(cfg.drop_pickup_radius) or 16
    if radius <= 0 then radius = 16 end
    local sound = cfg.drop_sound or "collect_gem"
    local ok, id = pcall(factory.create, FACTORY_URL, vmath.vector3(x + active.x, y + active.y, 0), nil,
        { pickup_radius = radius, sound_id = sound }, 1)
    if ok and id then instance = id else
        spawn_failed = true
        print("[DEATH_DROP] Cannot create recovery marker: " .. tostring(id))
    end
end

function M.init(is_playing)
    playing = is_playing or playing
    if bound then return end
    bound = true
    generation = generation + 1
    local token = generation
    local function ready()
        if token ~= generation then return end
        spawn_failed = false
        spawn_if_ready()
    end
    RoomManager.register_event("on_room_ready", ready)
    RoomManager.register_event("on_room_enter", ready)
    RoomManager.on_room_unload(function(room_id)
        if token == generation and active and active.room_id == room_id then delete_instance() end
    end)
end

function M.update(dt)
    if settings().drop_enabled ~= true or pending or not playing() then return end
    if active and active.remaining then
        active.remaining = active.remaining - math.max(0, dt or 0)
        if active.remaining <= 0 then replace_record(nil) end
    end
    if instance and active and not RoomManager.is_room_enterable(active.room_id) then delete_instance() end
    spawn_if_ready()
end

function M.collect(id)
    if settings().drop_enabled ~= true or pending or not active or instance ~= id or not playing()
        or not RoomManager.is_room_enterable(active.room_id) then return false end
    local amount = active.amount
    instance = nil -- The prefab owns its short collection-particle tail.
    active = nil
    Inventory.add_currency(amount)
    return amount
end

function M.instance_failed(id, err)
    if instance == id then delete_instance() end
    spawn_failed = true
    print("[DEATH_DROP] Pickup trigger could not be resized: " .. tostring(err))
end

function M.final()
    delete_instance()
    generation = generation + 1
    bound = false
    playing = function() return false end
    SafeGround.clear()
end
return M
