-- developer/config/debug_config.lua
-- Centralised toggles for debug logging across systems.

local Debug = {
    global = {
        enable = false,  -- Master switch - enable only for a focused diagnostic session
    },
    perf = {
        -- Logs frames slower than 33 ms together with room load/unload counts,
        -- plus one per-second summary line of the frame-time distribution
        -- (mean/median/min/max, frames off the median, Lua memory delta).
        -- Enable only while profiling a debug build.
        frame_watch = false,
        -- Shows Defold's on-screen profiler (frame time, Script/Physics/GC
        -- scopes, vsync wait) from boot. Debug builds only.
        profiler_ui = false,
    },
    gameplay = {
        main = false,
        game_manager = false,
        spawner = false,
        camera = false,
        save_manager = false,
        ability_manager = false,
        progression = false,
        input = false,  -- Changed to false (was spamming)
        player = false,  -- Player movement/animation debug
        player_state = false,  -- Player state machine debug
        glide = false,  -- Glide mechanic debug (gravity, speed caps)
        swim = false,  -- Water entry/exit, swim velocity, ability gate
        checkpoint = false,
        inventory = false,
        flags = false,
        gates = false,  -- Gate collision/unlock trace
        fast_travel = false,  -- Fast travel unlocking and teleportation
        teleporters = false,  -- Room-to-room teleporter diagnostics
        interaction = false,  -- NPC/object interactions (proximity checks)
        npcs = false,  -- NPC spawning and dialogue
    },
    animation = {
        controller = false,  -- Enable to see animation changes (noisy per-frame)
        spine_play = false,  -- Enable to see Spine calls (noisy per-frame)
        flip = false,  -- Enable to log PLAYER_FACING input and ladder/wall state on each turn.
        state_machine = false,  -- Animation state transitions
    },
    combat = {
        damage = false,  -- Damage calculations
        melee = false,  -- Melee attack spawning
        ranged = false,  -- Ranged attack spawning
        parry = false,  -- Parry system
        hitstop = false,  -- Hit pause effects
    },
    enemies = {
        ai = false,  -- Enemy AI decisions
        spawner = false,  -- Enemy spawning
        behavior = false,  -- Behavior patterns
        detection = false,  -- Player detection
        pathfinding = false,  -- Movement paths
    },
    -- Temporary native-crash bisection switches. These are consulted only while
    -- global.enable is true and all default to false, so normal/release behavior
    -- is unchanged. See docs/archive/ENEMY_SPRITE_VERTEX_CRASH_PLAN.md before changing
    -- more than one switch at a time.
    enemy_crash = {
        defer_first_flipbook = false,  -- Run the initial sprite flipbook on the next timer tick
        disable_state_swaps = false,  -- Keep the initial flipbook; suppress later sprite swaps
        disable_tint_set = false,  -- Suppress direct enemy-sprite tint writes
        disable_tint_animate = false,  -- Suppress anim.flash tint animation
        disable_hflip = false,  -- Suppress enemy sprite horizontal flips
        disable_projectiles = false,  -- Let attacks animate, but do not create enemy projectiles
        disable_combat_fx = false,  -- Suppress animation/enemy hit visual-FX hooks
    },
    bosses = {
        manager = false,  -- Boss state machine
        phases = false,  -- Boss stage transitions
        attacks = false,  -- Attack pattern execution
        health = false,  -- Health/damage tracking
    },
    rooms = {
        stream_manager = false,
        room_manager = false,
        transitions = false,  -- Room transition detection/boundary checks
        layout_io = false,
        align = false,
        seam = false,
        room = false,
        door_debug = false,  -- Door detection debugging
        loading = false,  -- Room loading/unloading
    },
    minimap = {
        info = false,
        view = false,
        load = false,
        room_pick = false,
        debug = false,
        markers = false,  -- Marker placement
    },
    ui = {
        simple_menu = false,
        world_map = false,
        hud = false,  -- HUD updates
        health_bar = false,  -- Health display
        inventory_ui = false,  -- Inventory screen
    },
    boot = {
        simple_manager = false,
        initialization = false,  -- System init order
        skip_menu = false,  -- Skip menu and start game directly (for testing)
    },
    audio = {
        controller = false,  -- Changed to false (was spamming)
        music = false,  -- Changed to false (was spamming)
        sfx = false,
        trace_sfx = false,  -- Logs sound.play/stop calls for SFX-like URLs (disabled for release)
        manager = false,  -- Changed to false (was spamming)
        transitions = false,  -- Music transitions
    },
    physics = {
        collision = false,  -- Collision detection
        bones = false,  -- Bone collision system
        raycast = false,  -- Raycast operations
        triggers = false,  -- Trigger zones
    },
    fx = {
        screen_shake = false,  -- Camera shake
        particles = false,  -- Particle systems
        vfx_spawn = false,  -- Effect spawning
    },
    collectibles = {
        pickup = false,  -- Item collection
        spawner = false,  -- Collectible spawning
        secret = false,  -- Secret detector debug
    },
    tiled = {
        spawner = false,  -- Object spawner from Tiled exports
        parser = false,  -- Tiled data parsing
        adapter = false,  -- Room adapter from Tiled rooms
        animator = false,  -- Tilemap tile animation diagnostics
    },
    editor = {
        outline = false,
        doors = false,
        tools = false,  -- Editor tool operations
    }
}

return Debug
