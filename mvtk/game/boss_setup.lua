-- mvtk/game/boss_setup.lua
-- Boss authoring and spawn helpers extracted from main.script.

local AuthoredObjectProps = require "mvtk.tiled.authored_object_props"
local BossFeedbackSettings = require "mvtk.bosses.feedback_settings"
local RenderOrder = require "mvtk.core.render_order"

local M = {}

local trim_string = function(value)
    if value == nil then
        return nil
    end
    local s = tostring(value):match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end
local split_csv = function() return {} end
local coerce_bool = function(value, default) return value == nil and default or value end
local Util = { to_bool = function(value, default) return value == nil and default or value end }
local post_play_cutscene = function() end
local main_log = function() end
local parse_drop_table = function() return nil end
local merge_drop_tables = function(base) return base end
local build_loot_table_drops = function() return nil end

local function optional_id(value)
    local id = trim_string(value)
    if id and string.lower(id) == "none" then
        return nil
    end
    return id
end

-- Defold messages have a small fixed buffer. Baked boss proxies therefore
-- post only their identity (room/object id, boss id, and position), and this
-- module restores the full flattened Tiled property set on the receiving side.
-- Runtime spawners that still provide fields directly are supported as well.
local BOSS_REGISTRATION_PROPERTY_FIELDS = {
    "boss_tag",
    "boss_name",
    "boss_preset",
    "boss_type",
    "boss_visual_type",
    "visual_component",
    "phase_config",
    "attack_pattern_ids",
    "arena_id",
    "intro_cutscene",
    "defeat_flag",
    "show_health_bar",
    "health_bar_position",
    "music_track",
    "victory_music",
    "reward_currency_min",
    "reward_currency_max",
    "reward_drops",
    "reward_loot_table",
    "reward_unlock_flag",
    "reward_unlock_fast_travel",
    "max_health",
    "boss_health",
    "defense",
    "damage_resistance",
    "chase_speed",
    "charge_speed",
    "charge_distance",
    "charge_telegraph_time",
    "charge_duration",
    "charge_cooldown",
    "charge_recovery",
    "intro_animation",
    "contact_damage",
    "contact_knockback_x",
    "contact_knockback_y",
    "contact_stun_t",
}
for field in pairs(BossFeedbackSettings.defaults) do
    BOSS_REGISTRATION_PROPERTY_FIELDS[#BOSS_REGISTRATION_PROPERTY_FIELDS + 1] = field
end

local function copy_fields(target, source, overwrite)
    if type(source) ~= "table" then
        return target
    end
    for key, value in pairs(source) do
        if overwrite or target[key] == nil then
            target[key] = value
        end
    end
    return target
end

local function non_generic_boss_name(object)
    local name = trim_string(object and object.name)
    local normalized = name and string.lower(name) or nil
    if normalized == "boss" or normalized == "boss spawn" then
        return nil
    end
    return name
end

--- Rehydrate a compact register_boss_spawn message into runtime boss data.
-- The numeric Tiled object id is the stable bridge to free-form strings and
-- grouped class properties that cannot safely travel as Defold hash values.
function M.build_boss_spawn_data(message)
    message = message or {}

    local room_id = trim_string(message.room_id)
    local object_id = math.floor(tonumber(message.object_id) or 0)
    local boss_props = {}
    local authored_object = nil

    if room_id and object_id > 0 then
        local ok, authored_props, object = pcall(AuthoredObjectProps.get_properties, room_id, object_id)
        if ok and type(authored_props) == "table" then
            copy_fields(boss_props, authored_props, true)
            authored_object = object
        end
    end

    -- Explicit runtime properties win over authored data. Direct fields are a
    -- compatibility fallback for non-baked/dynamic spawners.
    copy_fields(boss_props, message.properties, true)
    for _, field in ipairs(BOSS_REGISTRATION_PROPERTY_FIELDS) do
        if boss_props[field] == nil and message[field] ~= nil then
            boss_props[field] = message[field]
        end
    end
    if boss_props.max_health == nil and message.boss_health ~= nil then
        boss_props.max_health = message.boss_health
    end

    local boss_id = trim_string(message.id)
        or trim_string(boss_props.boss_id)
        or trim_string(boss_props.boss_tag)
    if not boss_id then
        return nil, nil
    end

    local boss_preset = optional_id(message.boss_preset)
        or optional_id(message.boss_type)
        or optional_id(boss_props.boss_preset)
        or optional_id(boss_props.boss_type)
    local boss_name = trim_string(message.boss_name)
        or trim_string(boss_props.boss_name)
        or non_generic_boss_name(authored_object)
        or boss_id
    local boss_tag = trim_string(message.boss_tag)
        or trim_string(boss_props.boss_tag)
        or trim_string(boss_props.boss_id)
        or boss_id

    boss_props.boss_id = trim_string(boss_props.boss_id) or boss_id
    boss_props.boss_tag = boss_tag
    boss_props.boss_name = boss_name
    boss_props.boss_preset = boss_preset or ""
    boss_props.boss_type = boss_preset or optional_id(boss_props.boss_type) or ""
    boss_props.room_id = room_id
    boss_props.object_id = object_id

    local data = {
        boss_type = boss_preset,
        boss_preset = boss_preset,
        boss_name = boss_name,
        position = message.position,
        room_id = room_id,
        arena_id = boss_props.arena_id,
        boss_id = boss_id,
        boss_tag = boss_tag,
        intro_cutscene = boss_props.intro_cutscene,
        arena_lock = coerce_bool(boss_props.arena_lock, true),
        show_health_bar = coerce_bool(boss_props.show_health_bar, true),
        health_bar_position = boss_props.health_bar_position,
        phase_config = boss_props.phase_config,
        chase_speed = tonumber(boss_props.chase_speed),
        charge_speed = tonumber(boss_props.charge_speed),
        charge_distance = tonumber(boss_props.charge_distance),
        charge_telegraph_time = tonumber(boss_props.charge_telegraph_time),
        charge_duration = tonumber(boss_props.charge_duration),
        charge_cooldown = tonumber(boss_props.charge_cooldown),
        charge_recovery = tonumber(boss_props.charge_recovery),
        properties = boss_props,
        source_object_id = object_id,
        spawned = false,
    }

    return boss_id, data
end

-- Tiled boss tuning fields use -1 as "inherit". Zero remains an authored
-- value for settings where it is meaningful (for example, removing a charge
-- cooldown); speed and distance are filtered separately below.
local function nonnegative_number(value)
    local number = tonumber(value)
    if number == nil or number < 0 then
        return nil
    end
    return number
end

local BOSS_ATTACK_TUNING_FIELDS = {
    "charge_speed",
    "charge_distance",
    "charge_telegraph_time",
    "charge_duration",
    "charge_cooldown",
    "charge_recovery",
}

local POSITIVE_BOSS_ATTACK_TUNING_FIELDS = {
    charge_speed = true,
    charge_distance = true,
}

local function boss_attack_tuning_number(field, value)
    local number = nonnegative_number(value)
    if number == nil or (POSITIVE_BOSS_ATTACK_TUNING_FIELDS[field] and number == 0) then
        return nil
    end
    return number
end

function M.configure(opts)
    opts = opts or {}
    trim_string = opts.trim_string or trim_string
    split_csv = opts.split_csv or split_csv
    coerce_bool = opts.coerce_bool or coerce_bool
    Util = opts.Util or Util
    post_play_cutscene = opts.post_play_cutscene or post_play_cutscene
    main_log = opts.main_log or main_log
    parse_drop_table = opts.parse_drop_table or parse_drop_table
    merge_drop_tables = opts.merge_drop_tables or merge_drop_tables
    build_loot_table_drops = opts.build_loot_table_drops or build_loot_table_drops
end

function M.build_boss_rewards_from_props(props)
    if type(props) ~= "table" then
        return nil
    end

    local rewards = {}
    local currency_min = tonumber(props.reward_currency_min)
    local currency_max = tonumber(props.reward_currency_max)
    if (currency_min and currency_min > 0) or (currency_max and currency_max > 0) then
        currency_min = currency_min or currency_max or 0
        currency_max = currency_max or currency_min
        if currency_max < currency_min then
            currency_max = currency_min
        end
        rewards.currency = {
            min = currency_min,
            max = currency_max,
        }
    end

    local drops = nil
    drops = merge_drop_tables(drops, parse_drop_table(props.reward_drops))
    drops = merge_drop_tables(drops, build_loot_table_drops(props.reward_loot_table))
    if drops and next(drops) then
        rewards.drops = drops
    end

    local unlock_flag = trim_string(props.reward_unlock_flag) or trim_string(props.defeat_flag)
    if unlock_flag then
        rewards.unlock_flag = unlock_flag
    end

    local unlock_fast_travel = trim_string(props.reward_unlock_fast_travel)
    if unlock_fast_travel then
        rewards.unlock_fast_travel = unlock_fast_travel
    end

    return next(rewards) and rewards or nil
end

function M.build_boss_audio_from_props(props)
    if type(props) ~= "table" then
        return nil
    end

    local audio = {}
    local music_track = optional_id(props.music_track)
        or optional_id(props.battle_music)
        or optional_id(props.combat_music)
    if music_track then
        audio.music = music_track
    end

    local victory_music = optional_id(props.victory_music)
    if victory_music then
        audio.victory = victory_music
    end

    return next(audio) and audio or nil
end

function M.resolve_boss_arena_props(self, boss_data)
    if not self or not self.arena_locks or not boss_data then
        return nil
    end

    local boss_props = boss_data.properties or {}
    local arena_id = trim_string(boss_props.arena_id) or trim_string(boss_data.arena_id)
    if not arena_id then
        return nil
    end

    local room_id = trim_string(boss_data.room_id)
    for _, lock in pairs(self.arena_locks) do
        if type(lock) == "table" then
            local lock_props = type(lock.properties) == "table" and lock.properties or nil
            local lock_arena_id = trim_string(lock.arena_id) or trim_string(lock_props and lock_props.arena_id)
            local lock_room_id = trim_string(lock.room_id) or trim_string(lock_props and lock_props.room_id)
            if lock_arena_id == arena_id and (not room_id or not lock_room_id or lock_room_id == room_id) then
                return lock_props or lock
            end
        end
    end

    return nil
end

function M.resolve_boss_arena_audio_props(self, boss_data)
    local arena_props = M.resolve_boss_arena_props(self, boss_data)
    if not arena_props then
        return nil
    end

    local battle_music = optional_id(arena_props.battle_music or arena_props.combat_music)
    local victory_music = optional_id(arena_props.victory_music)
    return (battle_music or victory_music) and arena_props or nil
end

function M.build_effective_boss_props(self, boss_data)
    local props = {}
    local base_props = boss_data and boss_data.properties
    if type(base_props) == "table" then
        for k, v in pairs(base_props) do
            props[k] = v
        end
    end

    local arena_props = M.resolve_boss_arena_props(self, boss_data)
    if not arena_props then
        return props
    end

    if not optional_id(props.music_track) then
        local arena_music = optional_id(arena_props.battle_music) or optional_id(arena_props.combat_music)
        if arena_music then
            props.music_track = arena_music
        end
    end

    if not optional_id(props.victory_music) then
        local arena_victory = optional_id(arena_props.victory_music)
        if arena_victory then
            props.victory_music = arena_victory
        end
    end

    -- Arena geometry owns the charge stopping margin. A value authored on
    -- the boss itself still wins, which preserves the normal instance-over-
    -- arena precedence while allowing one arena setting to serve its boss.
    if nonnegative_number(props.charge_edge_padding) == nil then
        local arena_padding = nonnegative_number(arena_props.charge_edge_padding)
        if arena_padding ~= nil then
            props.charge_edge_padding = arena_padding
        end
    end

    return props
end

function M.resolve_boss_preset_id(props, boss_data)
    return trim_string(props and (props.boss_preset or props.boss_type))
        or trim_string(boss_data and (boss_data.boss_preset or boss_data.boss_type))
end

function M.resolve_boss_display_name(props, boss_data)
    return trim_string(props and props.boss_name)
        or trim_string(boss_data and boss_data.boss_name)
        or trim_string(boss_data and boss_data.boss_id)
        or trim_string(boss_data and boss_data.boss_tag)
        or M.resolve_boss_preset_id(props, boss_data)
        or "Boss"
end

function M.normalize_boss_health_bar_position(value)
    local raw = trim_string(value)
    if not raw then
        return nil
    end

    local position = string.lower(raw)
    if position == "top" or position == "bottom" then
        return position
    end

    return nil
end

function M.build_boss_phase_transition(def)
    if type(def) ~= "table" then
        return nil
    end

    local transition = {}
    local transition_type = trim_string(def.transition_type) or trim_string(def.transition_kind)
    if transition_type then
        transition.type = transition_type
    end

    local duration = tonumber(def.transition_duration)
    if duration and duration > 0 then
        transition.duration = duration
    end

    local iframes = tonumber(def.transition_iframes)
    if iframes and iframes > 0 then
        transition.iframes = iframes
    end

    local animation = trim_string(def.transition_animation)
    if animation then
        transition.animation = animation
    end

    local camera_intensity = tonumber(def.transition_camera_intensity)
    local camera_duration = tonumber(def.transition_camera_duration)
    if (camera_intensity and camera_intensity > 0) or (camera_duration and camera_duration > 0) then
        transition.camera_shake = {
            intensity = (camera_intensity and camera_intensity > 0) and camera_intensity or 8,
            duration = (camera_duration and camera_duration > 0) and camera_duration or duration or 0.5,
        }
    end

    if coerce_bool(def.transition_flash, false) then
        transition.flash = true
    end
    if coerce_bool(def.transition_arena_darkness, false) then
        transition.arena_darkness = true
    end

    local hazard_list = split_csv(def.transition_spawn_hazards)
    if #hazard_list > 0 then
        transition.spawn_hazards = hazard_list
    end

    local teleport_to = trim_string(def.transition_teleport_to)
    if teleport_to then
        transition.teleport_to = teleport_to
    end

    local transition_music = optional_id(def.transition_new_music)
    if transition_music then
        transition.new_music = transition_music
    end

    if next(transition) == nil then
        return nil
    end
    if not transition.type then
        transition.type = "cutscene"
    end
    return transition
end

function M.build_boss_phase_definition(def, phase_count, fallback_attacks)
    if type(def) ~= "table" then
        return nil
    end

    local attacks = split_csv(def.attacks)
    if #attacks == 0 then
        attacks = fallback_attacks or {}
    end

    local min_health = tonumber(def.health_min)
    local max_health = tonumber(def.health_max)
    if min_health and min_health < 0 then
        min_health = nil
    end
    if max_health and max_health < 0 then
        max_health = nil
    end
    if min_health == nil and max_health == nil and phase_count and phase_count > 0 then
        max_health = (phase_count - def.phase_index + 1) / phase_count
        min_health = (phase_count - def.phase_index) / phase_count
    end
    if max_health == nil then
        max_health = 1.0
    end
    if min_health == nil then
        min_health = 0.0
    end

    local phase = {
        health_range = {
            min = min_health,
            max = max_health,
        },
        attacks = attacks,
        attack_interval = {
            min = tonumber(def.attack_interval_min) or 2.0,
            max = tonumber(def.attack_interval_max) or tonumber(def.attack_interval_min) or 4.0,
        },
    }

    local behavior = trim_string(def.behavior)
    if behavior then
        phase.behavior = behavior
    end

    local speed_multiplier = tonumber(def.speed_multiplier)
    if speed_multiplier then
        phase.speed_multiplier = speed_multiplier
    end

    local damage_multiplier = tonumber(def.damage_multiplier)
    if damage_multiplier then
        phase.damage_multiplier = damage_multiplier
    end

    -- Movement profile: routes to mvtk.bosses.movement_strategies.
    -- Unknown / missing profiles fall back to ground_chase at dispatch time.
    local movement_profile = trim_string(def.movement_profile)
    if movement_profile then
        phase.movement_profile = movement_profile
    end

    if def.facing_lock == true or def.facing_lock == "true" then
        phase.facing_lock = true
    end

    local hover_height = tonumber(def.hover_height)
    if hover_height and hover_height > 0 then
        phase.hover_height = hover_height
    end

    local jump_height = tonumber(def.jump_height)
    if jump_height and jump_height > 0 then
        phase.jump_height = jump_height
    end

    local jump_speed = tonumber(def.jump_speed)
    if jump_speed and jump_speed > 0 then
        phase.jump_speed = jump_speed
    end

    local leash_radius = tonumber(def.leash_radius)
    if leash_radius and leash_radius > 0 then
        phase.leash_radius = leash_radius
    end

    local attack_range_override = tonumber(def.attack_range)
    if attack_range_override and attack_range_override > 0 then
        phase.attack_range = attack_range_override
    end

    local chase_speed = nonnegative_number(def.chase_speed)
    if chase_speed ~= nil then
        phase.chase_speed = chase_speed
    end

    -- Keep phase attack tuning alongside the phase definition. The runtime
    -- resolves these values over the boss preset/instance without changing
    -- the shared framework attack pattern.
    for _, field in ipairs(BOSS_ATTACK_TUNING_FIELDS) do
        local value = boss_attack_tuning_number(field, def[field])
        if value ~= nil then
            phase[field] = value
        end
    end

    local transition = M.build_boss_phase_transition(def)
    if transition then
        phase.transition = transition
    end

    return phase
end

function M.collect_tiled_boss_phases(self, boss_data)
    if not self or type(self.boss_phase_defs) ~= "table" then
        return nil
    end
    if type(boss_data) ~= "table" then
        return nil
    end

    local props = boss_data.properties or {}
    local boss_id = trim_string(boss_data.boss_id) or trim_string(boss_data.boss_tag)
    local boss_type = trim_string(boss_data.boss_preset) or trim_string(boss_data.boss_type)
    local arena_id = trim_string(props.arena_id) or trim_string(boss_data.arena_id)
    local room_id = trim_string(boss_data.room_id)
    local matching = {}

    for _, phase_def in ipairs(self.boss_phase_defs) do
        local matches = true

        if phase_def.boss_id and phase_def.boss_id ~= boss_id then
            matches = false
        end
        local phase_type = trim_string(phase_def.boss_preset) or trim_string(phase_def.boss_type)
        if matches and phase_type and phase_type ~= boss_type then
            matches = false
        end
        if matches and phase_def.arena_id and phase_def.arena_id ~= arena_id then
            matches = false
        end
        if matches and phase_def.room_id and phase_def.room_id ~= room_id then
            matches = false
        end

        if matches then
            matching[#matching + 1] = phase_def
        end
    end

    if #matching == 0 then
        return nil
    end

    table.sort(matching, function(a, b)
        return (a.phase_index or 1) < (b.phase_index or 1)
    end)

    local fallback_attacks = split_csv(props.attack_pattern_ids)
    local phases = {}
    for _, def in ipairs(matching) do
        phases[#phases + 1] = M.build_boss_phase_definition(def, #matching, fallback_attacks)
    end

    return #phases > 0 and phases or nil
end

function M.resolve_boss_spawn_for_arena(self, lock)
    if not self.boss_spawns or not lock then
        return nil
    end

    local props = lock.properties or {}
    local room_id = lock.room_id

    -- Direct boss id/tag match
    local direct_id = props.boss_id or props.boss_tag or lock.boss_id or lock.boss_tag
    if direct_id and self.boss_spawns[direct_id] and not self.boss_spawns[direct_id].spawned then
        return direct_id
    end

    local want_type = props.boss_preset or props.boss_type or lock.boss_preset or lock.boss_type
    local want_arena = props.arena_id or lock.arena_id
    local fallback = nil

    for id, data in pairs(self.boss_spawns) do
        if not data.spawned then
            local room_ok = (not room_id) or (data.room_id == room_id)
            if room_ok then
                if want_type and (data.boss_preset == want_type or data.boss_type == want_type) then
                    return id
                end
                if want_arena and data.properties and data.properties.arena_id == want_arena then
                    return id
                end
                if not want_type and not want_arena and not fallback then
                    fallback = id
                end
            end
        end
    end

    return fallback
end

--- true when this spawn's boss identity already has a saved defeat.
-- BossManager keys the flag by the authored boss_id (spawn_id).
function M.is_spawn_defeated(boss_data)
    local ok, BossManager = pcall(require, "mvtk.bosses.boss_manager")
    if not (ok and BossManager and BossManager.is_boss_defeated and boss_data) then
        return false
    end
    for _, id in pairs({ boss_data.boss_id, boss_data.boss_tag }) do
        if trim_string(id) and BossManager.is_boss_defeated(id) then
            return true
        end
    end
    return false
end

local function normalize_room_key(value)
    local s = trim_string(value)
    if not s then return nil end
    return (s:gsub("^/", ""):gsub("%.collection$", ""):gsub("^developer/rooms/", ""))
end

-- Room ownership changes when the player's centre crosses a seam. Closing
-- the tile-sized door blockers then can eject the overlapping player into the
-- previous room. Wait until the entire collider clears the doorway tiles.
-- Dimensions come from the published room and current player/tile settings.
function M.room_entry_clear(player_pos, bounds, half_w, half_h, tile_w, tile_h, doors)
    if not player_pos or not bounds then return false end
    local hw, hh = math.max(0, half_w or 0), math.max(0, half_h or 0)
    local x, y = player_pos.x, player_pos.y
    if x - hw < bounds.min_x or x + hw > bounds.max_x
        or y - hh < bounds.min_y or y + hh > bounds.max_y then return false end
    for _, door in ipairs(doors or {}) do
        local side = door.side
        local vertical = side == "left" or side == "right"
        local span = tonumber(door.len or door.len_px or door.span)
        local center = tonumber(vertical and door.cy or door.cx)
        local across = vertical and (y - bounds.min_y) or (x - bounds.min_x)
        local half = vertical and hh or hw
        -- Unknown spans conservatively cover the side. Other door runs and
        -- ordinary floor/ceiling tiles must not prevent an encounter starting.
        local overlaps = not span or not center or math.abs(across - center) <= span * 0.5 + half
        if overlaps then
            if side == "left" and x - hw <= bounds.min_x + tile_w then return false end
            if side == "right" and x + hw >= bounds.max_x - tile_w then return false end
            if (side == "bottom" or side == "down") and y - hh <= bounds.min_y + tile_h then return false end
            if (side == "top" or side == "up") and y + hh >= bounds.max_y - tile_h then return false end
        end
    end
    return true
end

--- Bosses with no boss_arena in their room start when the player enters that
-- room (otherwise nothing ever triggered them). Returns sorted spawn ids.
function M.room_entry_boss_ids(self, player_room)
    local out = {}
    local player_key = normalize_room_key(player_room)
    if not (self and self.boss_spawns and player_key) then
        return out
    end
    local rooms_with_arenas = {}
    for _, lock in pairs(self.arena_locks or {}) do
        local key = normalize_room_key(lock and lock.room_id)
        if key then rooms_with_arenas[key] = true end
    end
    for id, data in pairs(self.boss_spawns) do
        local room_key = normalize_room_key(data and data.room_id)
        if data and not data.spawned and room_key == player_key and not rooms_with_arenas[room_key] then
            out[#out + 1] = id
        end
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function M.trigger_boss_fight(self, boss_id)
    if not boss_id or not self.boss_spawns then
        return
    end

    local boss_data = self.boss_spawns[boss_id]
    if not boss_data or boss_data.spawned then
        return
    end

    boss_data.spawned = true
    -- A saved defeat must not restart the fight when the room reloads.
    if M.is_spawn_defeated(boss_data) then
        main_log(string.format("[MAIN] Boss '%s' already defeated; not starting", tostring(boss_id)))
        return
    end

    -- Play intro cutscene if specified
    if boss_data.intro_cutscene then
        post_play_cutscene(boss_data.intro_cutscene)
    end

    -- Use BossManager for proper boss spawning
    local ok_boss, BossManager = pcall(require, "mvtk.bosses.boss_manager")
    local props = M.build_effective_boss_props(self, boss_data)
    local boss_preset = M.resolve_boss_preset_id(props, boss_data)
    if ok_boss and BossManager and BossManager.spawn_boss then
        -- Build custom config from Tiled properties
        local arena_id = props.arena_id or boss_data.arena_id
        local boss_name = M.resolve_boss_display_name(props, boss_data)
        local custom_config = {
            room_id = boss_data.room_id,
            arena_id = arena_id,
            arena = boss_data.arena_lock and (arena_id or string.format("arena_%s", boss_data.room_id)) or nil,
            name = boss_name,
            boss_name = boss_name,
        }
        if boss_preset then
            custom_config.boss_preset = boss_preset
        end
        if props.boss_visual_type and props.boss_visual_type ~= "" then
            custom_config.boss_visual_type = props.boss_visual_type
        end
        if props.visual_component and props.visual_component ~= "" then
            custom_config.visual_component = props.visual_component
        end

        local chase_speed = nonnegative_number(props.chase_speed)
        if chase_speed ~= nil then
            custom_config.chase_speed = chase_speed
        end
        for _, field in ipairs(BOSS_ATTACK_TUNING_FIELDS) do
            local value = boss_attack_tuning_number(field, props[field])
            if value ~= nil then
                custom_config[field] = value
            end
        end
        local edge_padding = nonnegative_number(props.charge_edge_padding)
        if edge_padding ~= nil then
            custom_config.charge_edge_padding = edge_padding
        end
        local boss_health_override = tonumber(props.boss_health or props.max_health or props.health)
        if boss_health_override and boss_health_override > 0 then
            custom_config.max_health = boss_health_override
        end
        local defense_override = tonumber(props.defense)
        if defense_override and defense_override > 0 then
            custom_config.defense = defense_override
        end
        local damage_resistance_override = tonumber(props.damage_resistance)
        if damage_resistance_override and damage_resistance_override > 0 then
            custom_config.damage_resistance = damage_resistance_override
        end
        if props.intro_animation and props.intro_animation ~= "" then
            custom_config.intro_animation = props.intro_animation
        end
        if props.show_health_bar ~= nil then
            custom_config.show_health_bar = Util.to_bool(props.show_health_bar, true)
        elseif boss_data.show_health_bar ~= nil then
            custom_config.show_health_bar = Util.to_bool(boss_data.show_health_bar, true)
        end
        local health_bar_position = M.normalize_boss_health_bar_position(
            props.health_bar_position or boss_data.health_bar_position)
        if health_bar_position then
            custom_config.health_bar_position = health_bar_position
        end
        -- Contact damage (player collides with boss body)
        local contact_damage = tonumber(props.contact_damage)
        if contact_damage and contact_damage > 0 then
            custom_config.contact_damage = contact_damage
        end
        BossFeedbackSettings.apply(props, custom_config)

        if boss_data.boss_id or boss_data.boss_tag then
            custom_config.boss_tag = boss_data.boss_id or boss_data.boss_tag
            custom_config.boss_id = boss_data.boss_id or boss_data.boss_tag
            custom_config.spawn_id = boss_data.boss_id or boss_data.boss_tag
        end
        if boss_data.phase_config then
            custom_config.phase_config = boss_data.phase_config
        end
        local tiled_phases = M.collect_tiled_boss_phases(self, boss_data)
        if tiled_phases then
            custom_config.phases = tiled_phases
        else
            -- No boss_phase objects found; check if attack_pattern_ids is set
            -- to build a synthetic single-phase so the attacks are still used
            local attack_ids = split_csv(props.attack_pattern_ids)
            if #attack_ids > 0 then
                custom_config.phases = {
                    {
                        health_range = { min = 0.0, max = 1.0 },
                        attacks = attack_ids,
                        attack_interval = {
                            min = tonumber(props.attack_interval_min) or 2.0,
                            max = tonumber(props.attack_interval_max) or tonumber(props.attack_interval_min) or 4.0,
                        },
                    }
                }
            end
        end
        local reward_overrides = M.build_boss_rewards_from_props(props)
        if reward_overrides then
            custom_config.on_defeat = reward_overrides
        end
        local audio_overrides = M.build_boss_audio_from_props(props)
        if audio_overrides then
            custom_config.audio = audio_overrides
        end

        -- Spawn via boss manager (handles health bar, music, arena locks)
        local spawn_position = vmath.vector3(
            boss_data.position.x, boss_data.position.y, RenderOrder.boss_z())
        local spawned_id = BossManager.spawn_boss(
            boss_preset,
            spawn_position,
            custom_config
        )

        if spawned_id then
            boss_data.active_boss_id = spawned_id
            main_log(string.format("[MAIN] Boss spawned via BossManager: %s (id: %s)",
                tostring(boss_name), tostring(spawned_id)))

            -- Spawn boss game object if factory is available (Tiled bosses rely on this)
            if not boss_data.active_boss_url or not go.exists(boss_data.active_boss_url) then
                local factory_url = msg.url("main:/main_go#boss_factory")
                if go.exists(factory_url) then
                    local spawn_props = {
                        boss_id = boss_data.boss_id or boss_data.boss_tag or boss_id or "",
                    }
                    if boss_preset and boss_preset ~= "" then
                        spawn_props.boss_type = boss_preset
                    end
                    if props.boss_visual_type and props.boss_visual_type ~= "" then
                        spawn_props.boss_visual_type = props.boss_visual_type
                    end
                    if props.visual_component and props.visual_component ~= "" then
                        spawn_props.visual_component = props.visual_component
                    end
                    if boss_health_override and boss_health_override > 0 then
                        spawn_props.boss_health = boss_health_override
                    end
                    if props.intro_animation and props.intro_animation ~= "" then
                        spawn_props.intro_animation = props.intro_animation
                    end
                    local ok_spawn, instance = pcall(factory.create, factory_url, spawn_position, nil, spawn_props, 1)
                    if ok_spawn then
                        boss_data.active_boss_url = instance
                        main_log(string.format("[MAIN] Spawned boss GO for '%s'", tostring(boss_name)))
                    else
                        main_log(string.format("[MAIN] Boss factory spawn failed: %s", tostring(instance)))
                    end
                else
                    main_log("[MAIN] Boss factory not found on main_go; skipping boss GO spawn")
                end
            end
        else
            main_log(string.format("[MAIN] BossManager.spawn_boss failed for boss '%s'",
                tostring(boss_name)))
        end
    else
        -- Fallback: spawn via enemy factory
        main_log("[MAIN] BossManager not available, using enemy factory fallback")
        pcall(msg.post, "main:/room_manager#enemy_factory", hash("spawn_boss"), {
            boss_type = boss_preset or boss_data.boss_type,
            position = boss_data.position
        })

        -- Manual arena lock
        if boss_data.arena_lock then
            local ok_arena, BossArena = pcall(require, "mvtk.bosses.boss_arena")
            if ok_arena and BossArena and BossArena.lock_arena then
                BossArena.lock_arena(string.format("arena_%s", boss_data.room_id))
            end
        end
    end

    main_log(string.format("[MAIN] Triggered boss fight: %s", tostring(M.resolve_boss_display_name(props, boss_data))))
end

return M
