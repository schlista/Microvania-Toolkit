-- mvtk/tiled/tiled_properties_reference.lua
-- ============================================================================
-- Tiled Properties Reference
-- ============================================================================
-- This file documents all supported Tiled object properties for MVTK systems.
-- Use this as a reference when setting up objects in your Tiled maps.
--
-- To use: Add an object layer in Tiled and set the "type" property to one of
-- the supported types below. Then configure additional properties as needed.

local M = {}

-- ============================================================================
-- PROPERTY CATEGORY GUIDE
-- ============================================================================
-- Identity fields name the object for saves, flags, and cross-object links.
-- Runtime fields tune behavior such as health, damage, movement, and timers.
-- Presentation fields select sprites, effects, sounds, prompts, and UI text.
-- Non-character world artwork now comes from collection-image objects. Legacy
-- use_defold_sprite / sprite_atlas fields below are ignored by room generation;
-- see docs/TILED_OBJECT_ART.md for the current authoring workflow.
-- Gating fields connect objects to abilities, items, or game flags.
-- Placement fields use Tiled coordinates, rectangle size, and optional paths.

-- ============================================================================
-- OBJECT TYPES
-- ============================================================================

M.OBJECT_TYPES = {
    -- Player & Spawning
    "player_spawn",     -- Player spawn/start location
    "player_start",     -- Alias for player_spawn
    "respawn_point",    -- Alias for player_spawn
    "checkpoint",       -- Auto-save checkpoint
    "save_point",       -- Manual save and recovery point

    -- Enemies
    "enemy",            -- Single enemy spawn
    "enemy_group",      -- Coordinated group of enemies
    "spawn_point",      -- Respawning enemy point

    -- Bosses
    "boss",             -- Boss with all systems
    "boss_arena",       -- Boss arena mechanics
    "end_game",         -- Baked ending region; completion_id selects game_completion.id.
    "boss_phase",       -- Boss phase definition
    "boss_phase_trigger", -- Boss phase trigger zone
    "boss_weak_point",  -- Targetable weak point
    "arena_boundary",   -- Arena boundary wall
    "boss_add_spawner", -- Boss add spawner

    -- Hazards
    "hazard",           -- Environmental hazard (generic)
    "spike_hazard",     -- Spike damage zone
    "spikes",           -- Alias for spike_hazard
    "lava_hazard",      -- Lava/fire damage zone
    "lava",             -- Alias for lava_hazard
    "void_hazard",      -- Instant death pit
    "pit",              -- Alias for void_hazard
    "void",             -- Alias for void_hazard
    "breakable_wall",   -- Destructible collision wall

    -- Platforms & Movement
    "moving_platform",  -- Platform that moves along a path
    "platform",         -- Alias for moving_platform
    "elevator",         -- Persistent vertical cabin crossing streamed rooms
    "elevator_node",    -- Landing or pass-through route marker
    "crumble_platform",
    "bounce_pad",
    "conveyor",
    "teleporter",
    "grapple_point",
    "grapple_surface",   -- Baked rectangle tagging an entire grapple surface
    "grapple_box",       -- Grapple Box: exact static rectangle tagging a hook target
    "grapple_slope",     -- Grapple Slope: exact static polygon tagging a hook target
    "wall_jump_surface", -- Wall that allows wall jump/slide
    "one_way_platform",
    "camera_zone",

    -- Static Collision (physics templates; decoupled from the art tilesheet)
    "collision_box",     -- Solid Box: static box collider sized to the rect
    "collision_slope",   -- Solid Slope: static triangle collider
    "solid",             -- Alias for collision_box
    "ground",            -- Alias for collision_box
    "collision",         -- Alias for collision_box
    "slope",             -- Alias for collision_slope

    -- Stations & Recovery
    "health_station",   -- Healing station
    "healing_fountain", -- Alias for health_station
    "energy_station",   -- Mana/energy refill
    "mana_fountain",    -- Alias for energy_station
    "map_station",      -- Map reveal station
    "cartographer",     -- Alias for map_station

    -- Collectibles & Lore
    "lore_item",        -- Journal entry/note
    "collectible",
    "ability",
    "chest",
    "journal_entry",    -- Alias for lore_item
    "note",             -- Alias for lore_item

    -- Interactive Objects
    "light_source",
    "torch_holder",
    "map_marker",      -- Minimap/world map marker (POI)
    "pushable_block",
    "pressure_plate",
    "timed_door",
    "sign",
    "lever",
    "hint_stone",
    "gate",
    "locked_door",
    "secret",
    "dialogue_trigger",
    "cutscene",

    -- Audio/Visual
    "music_trigger",
    "ambience_zone",
    "particle_emitter",
    "screen_effect_zone",
}

-- ============================================================================
-- ENEMY PROPERTIES
-- ============================================================================
-- Identity: type, enemy_type, template, group_id
-- Runtime: behaviors, movement ranges, chase/attack tuning
-- Placement: facing, patrol_distance, patrol_height

M.ENEMY = {
    -- Required
    type = "enemy",              -- Object type

    -- Enemy Configuration
    enemy_type = "slime",        -- Synced art/preset id; choose this first, then optionally override behavior below
    art = "",                   -- Optional external skin frame path (file); blank or an existing <state>_<NN>.png outside the project. Links art while preserving a deliberate preset.
    template = "elite_slime",    -- Template ID (from enemy_templates.lua)

    -- Behavior Configuration
    movement = "type_default",   -- Movement slot; type_default/inherit/legacy none keeps the enemy-type preset
    attack_pattern = "type_default",  -- Primary attack slot; inherits independently from movement
    attack_pattern2 = "type_default", -- Optional second attack; disabled removes the inherited attack in that slot
    behaviors = "ground_patrol,melee_attack",  -- Comma-separated behavior IDs
    behavior_preset = "basic_walker",           -- OR use a preset

    -- Available Behavior IDs:
    --   ground_patrol, fly_patrol, chase_player, melee_attack,
    --   ranged_attack, spread_attack, charge_attack, retreat_when_low,
    --   jump_attack, summon_minions, heal_allies, group_flank

    -- Available Presets:
    --   basic_walker, ranged_shooter, aggressive_charger,
    --   flying_chaser, pack_hunter, hit_and_run

    -- Movement/Combat
    facing = 1,                  -- Initial facing (1=right, -1=left)
    patrol_distance = 200,       -- Distance to patrol from spawn
    patrol_height = 48,          -- Vertical patrol height for hover/patrol_v
    patrol_speed = 50,           -- Patrol movement speed
    chase_range = 300,           -- Range to detect and chase player
    detection_range = -1,        -- Aggro radius; -1 grouped default (or legacy flat 0) inherits the selected type
    chase_speed = -1,            -- Base chase speed in pixels/second; -1 grouped default (or legacy flat 0) inherits
    chase_speed_mult = -1,       -- Positive multiplier applied to resolved chase speed; -1 grouped default inherits
    attack_range = -1,           -- Swipe/attack reach in pixels; -1 inherits the selected type

    -- Per-instance overrides
    difficulty = "none",        -- difficulty enum; none bakes as unset (uses the global/default profile)
    drops = "currency:5",       -- Inline CSV drops, used only when loot_table is empty
    loot_table = "",            -- Config loot table; takes precedence over drops when both are supplied

    -- Group Coordination
    group_id = "room_1_guards",  -- Join this coordination group
}

-- ============================================================================
-- ENEMY GROUP PROPERTIES
-- ============================================================================

M.ENEMY_GROUP = {
    -- Required
    type = "enemy_group",        -- Object type

    -- Group Configuration
    group_id = "patrol_squad",   -- Unique group identifier
    enemy_type = "guard",        -- Enemy type for all members
    count = 4,                   -- Number of enemies to spawn

    -- Formation
    formation = "line",          -- "line", "wedge", "circle", "box"
    spacing = 60,                -- Space between enemies (pixels)

    -- Coordination Behavior
    attack_mode = "coordinated", -- "individual", "coordinated", "wave", "limited"
    flank_style = "surround",    -- "surround", "pincer", "line", "arc"

    -- Shared Behaviors
    behaviors = "chase_player,melee_attack,group_flank",
}

-- ============================================================================
-- BOSS PROPERTIES
-- ============================================================================
-- Identity/linking: boss_id, boss_type, arena_id
-- Runtime: health, defense, damage scaling, attacks, transitions
-- Presentation/rewards: visual component, music, drops, unlock flags

M.BOSS = {
    -- Required
    type = "boss",               -- Object type

    -- Boss Configuration
    boss_id = "forest_boss", -- Unique boss identifier
    boss_type = "forest_boss",   -- Boss preset id
    arena_id = "forest_arena",   -- Link to boss_arena / arena objects
    boss_visual_type = "sprite", -- Explicit render path: "sprite" or "spine"
    visual_component = "sprite", -- Defold component id to render (sprite/spine based on boss_visual_type)
    max_health = 120,            -- Optional stat override
    defense = 2,                 -- Optional stat override
    damage_resistance = 0.9,     -- Multiplier applied to all incoming boss damage
    attack_pattern_ids = "root_spike,poison_cloud", -- Fallback CSV if phases omit attacks or none are authored
    show_health_bar = true,      -- Show the boss HUD when this fight starts
    health_bar_position = "top", -- Boss HUD edge: "top" or "bottom"

    -- Boss template > Combat. -1 inherits; 0 disables that recoil axis/recovery.
    contact_knockback_x = -1,    -- Horizontal player recoil speed on body contact, away from the boss.
    contact_knockback_y = -1,    -- Vertical player recoil speed on body contact.
    contact_stun_t = -1,         -- Player recovery seconds on body contact; player feedback override wins.

    -- Boss hit feedback: enable the override to use this group's values.
    override_boss_feedback = false, -- False keeps combat_config/boss_defaults and preset audio.
    boss_hurt_sfx = "enemy_hurt", -- Sound-bank key; blank or none silences confirmed boss hits.
    boss_hitstop = 0.05,         -- Gameplay impact pause in seconds; 0 disables it.
    boss_flash_color = "#ffff4040", -- Tiled color picker; exports #AARRGGBB.
    boss_flash_duration = 0.2,   -- Flash fade duration in seconds; 0 disables it.
    boss_shake = 6,              -- Screen shake magnitude in pixels; 0 disables it.
    boss_rumble = 0.2,           -- Controller rumble strength, 0 to 1; 0 disables it.

    -- Player hit feedback applies only to damage from this boss, including
    -- contact, melee and projectiles. It does not change other enemies.
    override_player_feedback = false, -- False inherits the global player response and attack stun.
    player_hurt_sfx = "player_hurt", -- Sound-bank key; blank or none silences the hurt sound.
    player_hitstop = 0.06,       -- Gameplay impact pause in seconds; 0 disables it.
    player_flash_color = "#ffff4040", -- Tiled color picker; exports #AARRGGBB.
    player_flash_duration = 0.2, -- Flash fade duration in seconds; 0 disables it.
    player_shake = 5,           -- Screen shake magnitude in pixels; 0 disables it.
    player_rumble = 0.18,       -- Controller rumble strength, 0 to 1.
    player_stun_t = 0.2,        -- Recovery seconds; overrides attack/contact stun, 0 disables it.
    player_hurt_animation = "hurt", -- Logical player animation; blank or none skips the reaction clip.
    player_interrupt_attack = true, -- Cancel the current swing and its hitboxes on direct damage.
    player_hurt_decel = 5,      -- Recoil damping per second; lower retains more recoil, 0 keeps its speed.

    -- Audio / rewards
    music_track = "none",       -- boss_music_tracks enum; boss_arena battle_music is the fallback
    victory_music = "none",     -- boss_music_tracks enum; boss_arena victory_music is the fallback
    reward_currency_min = 150,
    reward_currency_max = 250,
    reward_drops = "health_large:1:1.0,gem_large:2:0.5",
    reward_loot_table = "rare",
    reward_unlock_flag = "forest_boss_defeated",
}

-- ============================================================================
-- BOSS ARENA PROPERTIES
-- ============================================================================

M.BOSS_ARENA = {
    -- Required
    type = "boss_arena",         -- Object type

    -- Arena Configuration
    arena_id = "forest_arena",   -- Unique arena identifier
    phases = 3,                  -- Number of phases
    camera_lock = false,         -- true locks to the arena center and auto-fits; false follows the player
    camera_priority = 10,        -- Priority over overlapping camera zones (higher wins)
    lock_on_enter = true,        -- Lock the room when the player enters
    unlock_on_clear = true,      -- Unlock after the boss encounter completes
    battle_music = "none",      -- Shared fallback if the boss object leaves music_track unset
    victory_music = "none",     -- Shared fallback if the boss object leaves victory_music unset

    -- Author hazards, boundaries, weak points, and add spawners as their own
    -- Tiled objects. boss_arena only defines the shared arena metadata.
}

-- ============================================================================
-- BOSS PHASE PROPERTIES
-- ============================================================================

M.BOSS_PHASE = {
    type = "boss_phase",         -- Object type

    phase_id = "forest_phase_2",
    boss_id = "forest_boss", -- Optional specific boss id
    boss_type = "forest_boss",   -- Optional preset fallback
    arena_id = "forest_arena",   -- Optional arena link

    phase = 2,
    health_min = 0.25,          -- Use -1 / -1 to auto-distribute
    health_max = 0.60,
    attacks = "root_spike,poison_cloud",
    attack_interval_min = 1.5,
    attack_interval_max = 3.0,
    behavior = "aggressive",     -- boss_behaviors enum: aggressive/cautious/defensive/etc.
    speed_multiplier = 1.2,
    damage_multiplier = 1.3,

    transition_type = "rage",   -- boss_transition_types enum; aliases like power_up/final_form are accepted
    transition_duration = 1.5,
    transition_iframes = 1.2,
    transition_animation = "enrage",
    transition_camera_intensity = 12,
    transition_camera_duration = 0.8,
    transition_flash = true,
    transition_arena_darkness = false,
    transition_spawn_hazards = "spikes",
    transition_new_music = "none",
}

-- ============================================================================
-- BOSS PHASE TRIGGER PROPERTIES
-- ============================================================================

M.BOSS_PHASE_TRIGGER = {
    type = "boss_phase_trigger", -- Object type

    trigger_id = "phase_trigger_01",
    boss_id = "",               -- Preferred boss tag/id target
    boss_type = "",             -- Boss type fallback when boss_id is empty
    arena_id = "",              -- Optional arena id (defaults to active arena)

    phase = 2,                  -- Phase to force
    transition_time = 0,        -- Arena-only transition time; boss still uses its normal phase transition

    trigger_once = true,        -- Trigger once
    requires_flag = "",         -- Require flag to trigger
    set_flag = "",              -- Flag to set after trigger
    delay = 0,                  -- Delay before applying
}

-- ============================================================================
-- BOSS WEAK POINT PROPERTIES
-- ============================================================================

M.BOSS_WEAK_POINT = {
    type = "boss_weak_point",   -- Object type
    use_defold_sprite = true,

    point_id = "core",
    boss_id = "",
    boss_type = "",
    damage_mult = 2.0,
    health = 0,
    exposed_in_phase = 1,
    hidden_in_phase = 0,
    active_phases = "",
    vulnerable = true,
    destroy_flag = "",
    requires_flag = "",
    poll_interval = 0.2,
}

-- ============================================================================
-- ARENA BOUNDARY PROPERTIES
-- ============================================================================

M.ARENA_BOUNDARY = {
    type = "arena_boundary",    -- Object type

    boundary_id = "arena_wall_01",
    arena_id = "",
    active_phases = "",
    enabled_when_locked = true,
    start_enabled = true,
    poll_interval = 0.25,
}

-- ============================================================================
-- BOSS ADD SPAWNER PROPERTIES
-- ============================================================================

M.BOSS_ADD_SPAWNER = {
    type = "boss_add_spawner",  -- Object type

    spawner_id = "boss_adds_01",
    boss_id = "",
    boss_type = "",
    arena_id = "",

    enemy_type = "slime",
    spawn_interval = 4.0,
    spawn_count = 1,
    spawn_radius = 120.0,
    max_alive = 3,
    max_total = 0,
    active_phases = "2,3",
    start_delay = 0,
    start_active = true,

    health_mult = 1.0,
    damage_mult = 1.0,
    speed_mult = 1.0,
}

-- ============================================================================
-- HAZARD PROPERTIES
-- ============================================================================
-- Identity/linking: hazard_type, arena_id, active_phases
-- Runtime: damage, damage_interval, pattern, and ability immunity requirements
-- Presentation: impact sound and phase-driven arena effects

M.HAZARD = {
    -- Required
    type = "hazard",             -- Object type

    -- Hazard Configuration
    hazard_type = "spikes",      -- Hazard type from developer/config/hazard_types.lua
    damage = 1,                    -- Damage per hit
    damage_interval = 0.5,         -- Seconds between damage ticks (alias: damage_cooldown)
    stun_t = -1,                  -- Player recovery seconds: -1 inherits hazard_types[type].stun_t, then combat_config.feedback.hurt.stun_t; 0 disables.
    knockback_force = 300,         -- Knockback strength on contact
    required_resistance = "none", -- Optional ability ID that grants immunity; none means no authored requirement
    instant_kill = false,          -- Bypass normal damage and kill on contact
    enabled = true,                -- Can be controlled by arena/trigger state
    sound_on_hit = "",            -- Optional SFX id played when hazard damages player
    retractable = false,           -- Retract/extend collision and sprite over time
    retract_time = 2.0,
    extend_time = 2.0,
    start_retracted = false,

    -- Link to Arena (optional)
    arena_id = "forest_arena",    -- Managed by this arena
    active_phases = "2,3",        -- Only active in these phases

    -- Pattern (for some hazard types)
    pattern = "none",             -- hazard_patterns: none/static stay enabled; wave/random animate activation
    pattern_speed = 1.0,          -- Pattern animation speed
}

-- ============================================================================
-- WATER VOLUME PROPERTIES
-- ============================================================================

M.WATER_VOLUME = {
    type = "water_volume",
    use_defold_sprite = false,
    water_id = "water_01",          -- Stable identifier
    water_type = "water",           -- water_types enum
    swim_enabled = true,
    swim_speed_mult = 0.7,
    damage = 0,
    damage_interval = 1.0,
    current_direction = "none",     -- water_directions enum
    current_strength = 0,
    buoyancy = 0.5,
    water_drag = 0.85,
    oxygen_drain = true,
    oxygen_drain_rate = 1.0,
    surface_y_offset = 0,
    splash_effect = true,
    tint_color = "",
}

-- ============================================================================
-- SPAWN POINT PROPERTIES
-- ============================================================================
-- Identity: spawn_id, enemy_type
-- Runtime: max_count, respawn_delay, activation and despawn behavior
-- Placement: object position plus optional path/polyline references

M.SPAWN_POINT = {
    -- Required
    type = "spawn_point",        -- Object type

    -- Spawn Configuration
    spawn_id = "cave_bats",      -- Unique spawn point ID
    enemy_type = "bat",          -- Enemy type to spawn
    max_count = 3,               -- Max enemies from this point
    respawn_delay = 10.0,        -- Seconds before respawn

    -- Enemy Configuration (inherited by spawned enemies)
    behaviors = "fly_patrol,chase_player",
    template = "",               -- Template to apply
    patrol_distance = 150,
}

M.TELEPORTER = {
    type = "teleporter",
    use_defold_sprite = true,

    teleporter_id = "teleporter_a",            -- Unique teleporter id
    pair_id = "pair_1",                        -- Shared pair/group id
    target_id = "",                            -- Explicit destination teleporter id (optional)
    requires_flag = "",                        -- Flag required before this teleporter can activate
    hide_when_locked = false,                  -- Hide sprite while locked
    active_effect_id = "collectible_sparkle",  -- Looping effect while teleporter is active; blank disables
    unlock_effect_id = "",                     -- One-shot effect when the teleporter becomes available
    require_interact = false,                  -- Auto-teleport on enter when false
    cooldown = 0.5,                            -- Seconds before the same actor can teleport again
    transition_time = 0.0,                     -- Camera transition time
    preserve_velocity = false,                 -- Keep actor velocity after teleport
    facing = 0,                                -- Optional facing override after teleport
    label = "Teleport",                        -- Interaction prompt label
    fade_out = 0.5,                             -- Fade-to-black duration for cross-room travel
    fade_in = 0.5,                              -- Fade-from-black duration after arrival
    one_way = false,                            -- Receive-only teleporter when true
}

M.CAMERA_ZONE = {
    type = "camera_zone",
    zone_id = "camera_zone_01",
    camera_mode = "follow",
    zoom_level = 1.0,
    transition_speed = 1.0,
    bounds_padding = 0,
    lock_x = false,
    lock_y = false,
    focus_x = 0,
    focus_y = 0,
    parallax_override = "",
    smooth_follow = true,
    deadzone_width = 0,
    deadzone_height = 0,
    auto_fit = false,
}

M.COLLECTIBLE = {
    type = "collectible",
    use_defold_sprite = true,
    collectible_type = "currency", -- Required collectible_types id; never use none
    amount = 1,
    set_flag_on_collect = "",
    respawns = false,
}

M.ABILITY = {
    type = "ability",
    use_defold_sprite = true,
    ability_id = "double_jump",    -- optional_abilities enum; none is an authoring error
    show_popup = true,
    popup_title = "",
    popup_description = "",
}

M.CHEST = {
    type = "chest",
    use_defold_sprite = true,
    chest_id = "chest_01",
    chest_type = "wooden",
    contents = "currency:25",
    locked = false,
    requires_key = "none",         -- Optional keys id
    single_use = true,
    -- Deliberate non-default escape hatch: true skips collection baking and
    -- creates the chest at runtime, so it is not editable in Defold's scene UI.
}

M.GATE = {
    type = "gate",
    use_defold_sprite = false,
    gate_id = "gate_01",
    gate_type = "key_gate",         -- gates enum / developer/config/gate_types.lua key
    required_key = "normal",
    required_item = "none",
    required_ability = "none",      -- optional_abilities enum
    required_action = "none",
    starts_open = false,
    stays_open = true,
    persist_unlock = true,
    open_message = "",
}

M.LOCKED_DOOR = {
    type = "locked_door",
    door_id = "locked_door_01",
    require_ability = "none",       -- optional_abilities enum
    require_key = "none",            -- Optional keys id
    require_item = "none",           -- Optional collectibles id
    consume_key = true,
    unlock_message = "unlock",
    sound_locked = "none",
    sound_unlock = "none",
    starts_locked = true,
}

M.BREAKABLE_WALL = {
    type = "breakable_wall",
    use_defold_sprite = false,
    wall_id = "wall_01",
    wall_type = "cracked",
    health = 3,
    required_ability = "none",      -- optional_abilities enum
    drop_collectible = "none",      -- Optional collectibles id
    reveals_secret = "",             -- Free-form secret_id, not a sample-map enum
    particle_effect_name = "hit_impact",
    swap_tiles_on_break = true,
    wall_layer = "wall",
    broken_wall_layer = "broken_wall",
    swap_width = 0,
    swap_height = 0,
    sound_break = "wall_break",
}

-- ============================================================================
-- INTERACTION PROPERTIES
-- ============================================================================

M.SIGN = {
    type = "sign",
    use_defold_sprite = true,
    sign_id = "sign_01",
    label = "Read",
    range = 96,
    text = "Welcome to the ruins",
    title = "",
    display_mode = "toast", -- "toast", "dialogue", "tutorial"
    dialogue_id = "",
    duration = 2.5,
    trigger_once = false,
    set_flag = "",
    requires_flag = "",
    sound_id = "",
}

M.NPC = {
    type = "npc",
    use_defold_sprite = true,
    npc_id = "npc_01",
    npc_type = "villager_male",       -- NPC preset from developer/config/npc_types.lua
    npc_name = "NPC",
    npc_sprite = "",
    dialogue_id = "",
    dialogue_text = "",
    facing = 1,
    interaction_range = 48,
    despawn_flag = "",
}

M.LEVER = {
    type = "lever",
    use_defold_sprite = true,
    lever_id = "lever_01",
    target_id = "door_01",
    starts_on = false,
    toggle = true,
    message_on = "activate",
    message_off = "deactivate",
    label_on = "Switch On",
    label_off = "Switch Off",
    range = 96,
    cooldown = 0.2,
    set_flag_on = "",
    set_flag_off = "",
    requires_flag = "",
    sound_on = "lever_on",
    sound_off = "lever_off",
    on_animation = "",
    off_animation = "",
    reset_delay = 0,
}

M.PRESSURE_PLATE = {
    type = "pressure_plate",
    use_defold_sprite = false,
    plate_id = "plate_01",
    target_id = "door_01",
    required_count = 1,
    allow_player = true,
    allow_world = true,
    allow_enemy = false,
    stays_pressed = false,
    message_on = "activate",
    message_off = "deactivate",
    set_flag = "",
    sound_on = "none",           -- Optional sound_effects id
    sound_off = "none",          -- Optional sound_effects id
    anim_tilemap = "",           -- Optional tilemap URL for a visual tile swap
    anim_layer = "",
    anim_offset_x = 0,
    anim_offset_y = 0,
    tile_on = 0,
    tile_off = 0,
}

M.HINT_STONE = {
    type = "hint_stone",
    use_defold_sprite = true,
    hint_id = "hint_01",
    label = "Inspect",
    range = 96,
    title = "Hint",
    body = "",
    position = "top",
    duration = 4.0,
    trigger_once = false,
    set_flag = "",
    requires_flag = "",
    sound_id = "",
}

-- ============================================================================
-- AUDIO/VISUAL PROPERTIES
-- ============================================================================

M.MUSIC_TRIGGER = {
    type = "music_trigger",
    trigger_id = "music_01",
    music_id = "none",
    -- Legacy aliases preserved for old maps only; current templates omit them.
    area_theme = "",
    fade_time = 0.5,
    stop_on_exit = true,
    exit_music = "none",
    exit_area = "",
    trigger_once = false,
}

M.AMBIENCE_ZONE = {
    type = "ambience_zone",
    zone_id = "ambience_01",
    ambience_id = "cave",
    gain = 1.0,
    music_volume_percent = 100.0, -- Music volume while the player is in the zone
    stop_on_exit = true,
    trigger_once = false,
}

M.PARTICLE_EMITTER = {
    type = "particle_emitter",
    emitter_id = "emitter_01",
    effect_id = "ambient_sparkle",
    auto_play = true,
    loop = true,
    loop_interval = 0.5,
    start_delay = 0,
    run_duration = 0,
    debug_marker = false,
    debug_follow_player = false,
}

M.SCREEN_EFFECT_ZONE = {
    type = "screen_effect_zone",
    zone_id = "screenfx_01",
    effect_type = "tint", -- "underwater", "darkness", "tint", "shake"
    intensity = 0.5,
    tint_color = "#00000080",
    duration = 0.3,
    trigger_once = false,
    exit_darkness = 0,
    exit_tint = "",
    underwater_overlay = true,
}

-- ============================================================================
-- TRIGGER NOTE
-- ============================================================================
-- Generic authored trigger zones (type = "trigger") are deprecated.
-- Use specialized authored trigger types instead:
--   - cutscene
--   - dialogue_trigger

-- ============================================================================
-- PLAYER SPAWN PROPERTIES
-- ============================================================================

M.PLAYER_SPAWN = {
    type = "player_spawn",          -- Legacy runtime alias. Authoring template player_start.tx emits spawn_point with spawn_type = "player".

    spawn_id = "spawn_a",           -- Unique spawn identifier
    facing = 1,                     -- Initial facing (1=right, -1=left)
    is_default = false,             -- Is this the default spawn for the room?
    requires_flag = "",             -- Only spawn here if flag is set
}

-- ============================================================================
-- CHECKPOINT PROPERTIES
-- ============================================================================

M.CHECKPOINT = {
    type = "checkpoint",            -- Object type
    use_defold_sprite = true,

    checkpoint_id = "checkpoint_01", -- Unique checkpoint identifier
    respawn_facing = 1,             -- Direction player faces when respawning (1/-1)
    trigger_once = false,           -- If true, only activates once per session
    room_id = "",                   -- Room ID for respawn tracking
    sound_id = "save_point",        -- Sound to play when activated
    particle_id = "ambient_sparkle", -- Particle effect when activated
    requires_flag = "",             -- Optional flag required before activation
    set_flag = "",                  -- Optional flag set on activation
}

M.SAVE_POINT = {
    type = "save_point",
    use_defold_sprite = true,
    save_id = "save_01",            -- Stable save identifier
    display_name = "Save Point",
    heal_on_save = true,
    restore_energy = true,
    is_fast_travel = false,
    show_on_map = true,
    requires_interact = true,
    sound_id = "none",              -- Optional sound_effects id
    particle_id = "none",           -- Optional particle_effects id
}

M.ONE_WAY_PLATFORM = {
    type = "one_way_platform",
    use_defold_sprite = false,
    direction = "down",
}

M.TIMED_DOOR = {
    type = "timed_door",
    use_defold_sprite = false,
}

-- ============================================================================
-- MOVING PLATFORM PROPERTIES
-- ============================================================================

M.MOVING_PLATFORM = {
    type = "moving_platform",       -- Object type

    platform_id = "platform_01",    -- Unique platform identifier

    -- Path Configuration
    platform_type = "path",         -- "horizontal", "vertical", "path", or "circular"
    path_name = "platform_path",    -- Name of a polyline object in the room
    distance = 0,                    -- Linear travel distance for horizontal/vertical platforms
    speed = 100,                    -- Movement speed (pixels/second)

    -- Movement Modes
    -- "loop"     - Return to start after reaching end
    -- "pingpong" - Reverse direction at each end
    -- "once"     - Stop at final waypoint
    loop_mode = "pingpong",         -- Canonical name (legacy alias: mode)

    -- Timing
    wait = 1.0,                     -- Pause at each waypoint (seconds; legacy alias: wait_time)
    start_delay = 0,                -- Delay before first movement

    -- Player Interaction
    player_parent = true,           -- Player moves with platform

    -- Activation
    trigger_id = "",                -- Start moving when triggered
    co_y_offset = 0,                -- Collision object vertical offset
    sensor_y_offset = 0,            -- Trigger sensor vertical offset
    collision_height = 0,           -- Optional collision-height override; 0 uses authored rectangle height
}

-- Cross-room elevators use one rectangle controller around painted cabin art
-- plus one point node in each participating room. Create Rooms extracts the
-- rectangle's environment tiles into a persistent cabin resource.
M.ELEVATOR = {
    type = "elevator",
    elevator_id = "shaft_a",       -- Shared globally unique id
    start_node_id = "shaft_a_bottom", -- Landing where the authored cabin starts

    speed = 96,
    acceleration = 384,
    deceleration = 384,
    endpoint_wait = 0.35,
    start_delay = 0,
    close_time = 0.25,
    open_time = 0.25,
    ready_timeout = 5,

    enabled = true,
    activation_mode = "on_board",
    trigger_id = "",
    require_interact = false,

    floor_offset = 32,              -- Origin-to-floor distance; normally match rectangle height
    co_y_offset = 0,
    sensor_y_offset = 0,
    carry_player = true,
    carry_enemies = false,
    carry_pushables = true,
    require_rider = true,
    shaft_clearance = 0,
    shaft_tolerance = 0.5,

    camera_follow = true,
    camera_lock_x = true,
    camera_look_ahead = 96,
    camera_blend_time = 0.2,
    camera_priority = 50,

    persist_landing = true,
    restore_to_last_landing = true,
    source_layer = "environment",  -- Tile layer containing the painted cabin art
    visual_z = 0.5,
}

M.ELEVATOR_NODE = {
    type = "elevator_node",
    elevator_id = "shaft_a",
    node_id = "shaft_a_bottom",    -- Unique within this elevator route
    node_kind = "landing",         -- "landing" or "pass_through"
    stop = "bottom",               -- landing: "bottom"/"top"; pass-through: "none"
}

M.CRUMBLE_PLATFORM = {
    type = "crumble_platform",
    platform_id = "crumble_01",
    crumble_delay = 0.5,
    respawn_delay = 3.0,
    shake_before_crumble = true,
    one_way = true,
    clear_visual_layer_tiles = true,
    visual_layer = "environment",
    co_y_offset = 0,
    sensor_y_offset = 0,
    sound_crumble = "none",         -- Optional sound_effects id
    sound_respawn = "none",         -- Optional sound_effects id
}

-- ============================================================================
-- BOUNCE PAD PROPERTIES
-- ============================================================================

M.BOUNCE_PAD = {
    type = "bounce_pad",            -- Object type
    use_defold_sprite = false,

    bounce_speed = 900,             -- Launch speed
    cooldown = 0.2,                 -- Cooldown between activations
    require_interact = false,       -- Require interact input instead of auto-bounce
    label = "Bounce",               -- Interaction label when require_interact is true
    sound_id = "",                  -- Optional bounce sound id
    range = 80,                     -- Interaction range in pixels
}

-- ============================================================================
-- CONVEYOR PROPERTIES
-- ============================================================================

M.CONVEYOR = {
    type = "conveyor",              -- Object type
    use_defold_sprite = false,

    conveyor_id = "conveyor_01",    -- Stable identifier
    direction = "right",            -- "left", "right", "up", or "down"
    speed = 100,                    -- Push speed in pixels/second
    affects_enemies = true,         -- Push enemy bodies too
    affects_items = false,          -- Push item / collectible bodies too
    enabled = true,                 -- Start enabled
    animation_speed = 1.0,          -- Visual animation multiplier
}

-- ============================================================================
-- LADDER PROPERTIES
-- ============================================================================

M.LADDER = {
    type = "ladder",                -- Object type

    ladder_id = "ladder_01",        -- Stable identifier
    ladder_type = "ladder",         -- "ladder", "rope", "vine", etc.
    climb_speed = 80,               -- Climb speed override
    can_jump_off = true,            -- Allow jump input while climbing
    snap_to_center = true,          -- Snap the player to ladder center while climbing
    climb_offset_x = 0,             -- Horizontal nudge for the climbing player: -left, +right, 0 = ladder center
    pass_through_top = true,        -- Allow entering through the top lip
    grab_extend_down = 128,         -- Additional grab range below the ladder
    grab_extend_up = 128,           -- Additional grab range above the ladder
}

-- ============================================================================
-- SECRET PROPERTIES
-- ============================================================================

M.SECRET = {
    type = "secret",                -- Object type
    use_defold_sprite = true,

    secret_id = "secret_01",        -- Stable identifier used for persistence
    secret_type = "illusory_wall",  -- Secret type from developer/config/secret_types.lua
    reveals_on = "touch",           -- "touch", "attack", "ability", or "interact"
    required_ability = "none",     -- optional_abilities enum; none means no required reveal ability
    hide_tiles = true,              -- Clear overlapping tiles when revealed
    notification = true,            -- Show the discovery toast
    notification_text = "Secret Found!",
    reward_type = "",               -- Optional collectible reward type from developer/config/collectible_types.lua
    reward_amount = 0,              -- Optional reward amount
    map_reveal = true,              -- Reveal the secret on the map/minimap
}

M.DIALOGUE_TRIGGER = {
    type = "dialogue_trigger",
    trigger_id = "dialogue_01",
    dialogue_id = "",
    trigger_once = true,
    persist_once = true,
    once_flag = "",
    consume_on_fire = true,
    auto_play = true,
    delay = 0,
    npc_id = "",
    requires_flag = "",
    skip_if_flag = "",
    set_flag = "",
}

M.CUTSCENE = {
    type = "cutscene",
    cutscene_id = "",
    trigger_id = "",
    trigger_once = true,
    requires_flag = "",
    set_flag = "",
}


-- ============================================================================
-- HEALTH STATION PROPERTIES
-- ============================================================================

M.HEALTH_STATION = {
    type = "health_station",        -- Object type (or healing_fountain)
    use_defold_sprite = true,

    station_id = "health_01",       -- Unique station identifier
    label = "Heal",                 -- Interaction label
    range = 96,                     -- Interaction range in pixels

    -- Healing Configuration
    heal_amount = 0,                -- HP to restore (0 = full heal)
    heal_percent = 0.0,             -- Percent of max HP (0.0-1.0)
    uses = 0,                       -- Number of uses (0 = unlimited)
    recharge_time = 0,              -- Cooldown between uses (seconds)
    cost_currency = 0,              -- Currency cost to use (0 = free)
    require_interact = true,        -- Requires button press (false = auto trigger)
    requires_flag = "",             -- Flag required to use

    -- Feedback
    sound_id = "collect_health",    -- Sound when used
    particle_id = "collectible_sparkle", -- Particle effect when used
}

-- ============================================================================
-- ENERGY STATION PROPERTIES
-- ============================================================================

M.ENERGY_STATION = {
    type = "energy_station",        -- Object type (or mana_fountain)
    use_defold_sprite = true,

    station_id = "energy_01",       -- Unique station identifier
    prompt_text = "Restore Energy", -- Interaction label
    range = 96,                     -- Interaction range in pixels

    -- Restore Configuration
    restore_amount = 0,             -- Energy/mana to restore (0 = full)
    restore_percent = 0.0,          -- Percent of max energy (0.0-1.0)
    resource_type = "energy",       -- "energy" or "stamina"
    uses = 0,                       -- Number of uses (0 = unlimited)
    cooldown = 0,                   -- Cooldown between uses (seconds)
    cost = 0,                       -- Currency cost to use (0 = free)

    -- Interaction
    require_interact = true,        -- Requires button press

    -- Feedback
    sound_id = "none",              -- Optional sound_effects id
    particle_id = "none",           -- Optional particle_effects id
}

-- ============================================================================
-- MAP STATION PROPERTIES
-- ============================================================================

M.MAP_STATION = {
    type = "map_station",           -- Object type (or cartographer)
    use_defold_sprite = true,

    station_id = "map_01",          -- Unique station identifier
    prompt_text = "Reveal Map",     -- Interaction label
    range = 96,                     -- Interaction range in pixels

    -- Map Reveal Configuration
    reveal_area = "current",        -- Area to reveal ("current" = current room biome)
    reveal_full_biome = true,       -- Reveal all rooms in target biome
    reveal_radius = 320,            -- Fallback world radius if reveal_full_biome is false
    cost = 0,                       -- Currency cost to use (0 = free)
    trigger_once = true,            -- Only works once per save file

    -- Feedback
    sound_id = "collect_map",       -- Sound when used
    particle_id = "marker_placed",  -- Particle effect when used
}

-- ============================================================================
-- LORE ITEM PROPERTIES
-- ============================================================================

M.LORE_ITEM = {
    type = "lore_item",             -- Object type (or journal_entry, note)
    use_defold_sprite = true,

    lore_id = "lore_01",            -- Unique lore identifier (for save tracking)
    prompt_text = "Read",           -- Interaction label

    -- Content
    title = "Ancient Note",         -- Title shown in UI (can be localization key)
    text = "The text content...",   -- Main text (can be localization key)
    category = "notes",             -- Category: notes, journals, lore

    -- Behavior
    auto_pickup = false,            -- Collect on contact (vs require interact)
    destroyable = false,            -- Disappears after reading
    trigger_once = false,           -- Only show once per save
    requires_flag = "",             -- Flag required to read
    unlock_flag = "",               -- Flag to set when read

    -- Feedback
    sound_id = "none",              -- Optional sound_effects id
    particle_id = "none",           -- Optional particle_effects id
}

-- ============================================================================
-- WALL JUMP SURFACE PROPERTIES
-- ============================================================================

M.WALL_JUMP_SURFACE = {
    type = "wall_jump_surface",     -- Object type
    use_defold_sprite = false,

    -- Identity
    surface_id = "wall_surface_01", -- Stable identifier (optional; autogenerated if blank)

    -- Allowed Mechanics
    allow_slide = true,             -- Player can wall slide
    allow_jump = true,              -- Player can wall jump
    allow_climb = false,            -- Player can climb (requires wall_climb ability)

    -- Physics
    slide_speed = 0.3,              -- Fall speed multiplier when sliding
    jump_force_x = 400,             -- Horizontal force when wall jumping
    jump_force_y = 500,             -- Vertical force when wall jumping

    -- Configuration
    facing = 1,                     -- Which direction wall faces (1=right, -1=left)
    require_ability = "none",      -- optional_abilities enum; none means always usable
    surface_type = "stone",         -- Visual/audio type: stone, ice, vine, metal
}

-- ============================================================================
-- SPIKE HAZARD PROPERTIES
-- ============================================================================

M.SPIKE_HAZARD = {
    type = "spike_hazard",          -- Object type (or spikes)

    hazard_id = "spikes_01",        -- Unique hazard identifier

    -- Damage Configuration
    damage = 1,                     -- Damage per hit
    damage_interval = 0.5,          -- Minimum time between damage ticks
    stun_t = -1,                   -- Player recovery seconds: -1 inherits hazard_types.spikes.stun_t, then combat_config.feedback.hurt.stun_t; 0 disables.
    knockback_force = 300,          -- Knockback force applied to player

    -- Status Effect (optional)
    sound_on_hit = "spike_hit",     -- SFX id on damage

    -- Behavior
    retractable = false,            -- Can retract/extend
    retract_time = 2.0,             -- Time spent retracted
    extend_time = 2.0,              -- Time spent extended
    start_retracted = false,        -- Start in retracted state
}

-- ============================================================================
-- LAVA HAZARD PROPERTIES
-- ============================================================================

M.LAVA_HAZARD = {
    type = "lava_hazard",           -- Object type (or lava)

    hazard_id = "lava_01",          -- Unique hazard identifier

    -- Damage Configuration
    damage = 2,                     -- Damage per tick
    damage_interval = 0.3,          -- Time between damage ticks
    knockback_force = 200,          -- Knockback force

    -- Sound feedback
    sound_on_hit = "burn_sizzle",   -- SFX id on damage

    -- Immunity
    required_resistance = "none",   -- Optional ability ID that grants immunity
}

-- ============================================================================
-- VOID HAZARD PROPERTIES
-- ============================================================================

M.VOID_HAZARD = {
    type = "void_hazard",           -- Object type (or pit, void)

    hazard_id = "pit_01",           -- Unique hazard identifier

    -- Behavior
    instant_kill = true,            -- Instantly kills player
    respawn_at_checkpoint = true,   -- Respawn at last checkpoint
    respawn_at_ledge = false,       -- Respawn at last safe ledge instead

    -- If not instant kill:
    damage = 999,                   -- Damage if not instant kill
    knockback_force = 0,            -- No knockback for pits
}

-- ============================================================================
-- PRINT REFERENCE
-- ============================================================================

function M.print_reference()
    print("=== MVTK Tiled Properties Reference ===")
    print("")
    print("Object Types:")
    for _, obj_type in ipairs(M.OBJECT_TYPES) do
        print("  - " .. obj_type)
    end
    print("")
    print("See mvtk/tiled/tiled_properties_reference.lua for full documentation")
    print("==========================================")
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

--- Validate object properties
-- @param obj Tiled object
-- @return is_valid, errors
function M.validate(obj)
    local errors = {}
    local obj_type = obj.type or (obj.properties and obj.properties.type)

    if not obj_type then
        table.insert(errors, "Missing 'type' property")
        return false, errors
    end

    local valid_types = {}
    for _, t in ipairs(M.OBJECT_TYPES) do
        valid_types[t] = true
    end

    if not valid_types[obj_type] then
        table.insert(errors, "Unknown type: " .. obj_type)
        return false, errors
    end

    -- Type-specific validation
    local props = obj.properties or {}

    if obj_type == "enemy" then
        if not props.enemy_type and not obj.name then
            table.insert(errors, "Enemy needs 'enemy_type' or object name")
        end
    elseif obj_type == "enemy_group" then
        if not props.enemy_type then
            table.insert(errors, "Enemy group needs 'enemy_type'")
        end
    elseif obj_type == "boss" then
        if not props.boss_type then
            table.insert(errors, "Boss needs 'boss_type'")
        end
    end

    return #errors == 0, errors
end

return M
