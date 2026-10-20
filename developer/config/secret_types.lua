-- developer/config/secret_types.lua
-- ============================================================================
-- MV Toolkit . Secret Type Definitions (data-only)
-- All secret/hidden elements: illusory walls, hidden platforms, secret doors.
-- Auto-registers with secret_detector for minimap reveal and persistence.
-- ============================================================================

return {
    -- =========================================================================
    -- ILLUSORY / PASSTHROUGH WALLS
    -- =========================================================================
    
    illusory_wall = {
        name = "Illusory Wall",
        description = "A wall that can be walked through",
        
        -- Detection
        detection_method = "touch",  -- "touch", "attack", "ability", "item"
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Behavior
        solid_until_revealed = false,  -- false = always passthrough
        fade_on_enter = true,
        fade_alpha = 0.3,
        fade_duration = 0.3,
        
        -- Visual
        sprite_hidden = "wall_normal",
        sprite_revealed = "wall_illusory",
        particle_reveal = "shimmer",
        
        -- Audio
        sound_reveal = "secret_reveal",
        
        -- Tiled detection
        tile_ids = { 600, 601, 602 },
        layer_name = "secrets",
        object_type = "illusory_wall",
    },
    
    -- =========================================================================
    -- HIDDEN PLATFORMS
    -- =========================================================================
    
    hidden_platform = {
        name = "Hidden Platform",
        description = "An invisible platform that appears when touched",
        
        detection_method = "touch",
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Behavior
        solid_until_revealed = true,  -- can stand on it invisibly
        visible_after_reveal = true,
        
        -- Visual
        sprite_hidden = nil,  -- invisible
        sprite_revealed = "platform_secret",
        particle_reveal = "platform_appear",
        
        -- Audio
        sound_reveal = "secret_reveal",
        
        tile_ids = { 610, 611 },
        layer_name = "secrets",
        object_type = "hidden_platform",
    },
    
    -- =========================================================================
    -- BREAKABLE SECRETS
    -- =========================================================================
    
    cracked_wall = {
        name = "Cracked Wall",
        description = "A wall that can be broken with attacks",
        
        detection_method = "attack",
        required_ability = nil,  -- any attack works
        health = 3,  -- hits to break
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Visual
        sprite_hidden = "wall_cracked",
        sprite_damaged = "wall_cracked_damaged",
        sprite_revealed = nil,  -- disappears
        particle_hit = "dust_puff",
        particle_break = "wall_debris",
        
        -- Drops
        drop_collectible = nil,  -- set per-instance in Tiled
        
        -- Audio
        sound_hit = "wall_crack",
        sound_break = "wall_break",
        sound_reveal = "secret_reveal",
        
        tile_ids = { 620, 621 },
        layer_name = "breakables",
        object_type = "cracked_wall",
    },
    
    bomb_wall = {
        name = "Bomb Wall",
        description = "A wall that requires bombs to destroy",
        
        detection_method = "ability",
        required_ability = "bomb",
        health = 1,
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Visual hint
        show_hint_particle = true,
        hint_particle = "subtle_glow",
        
        sprite_hidden = "wall_bomb",
        particle_break = "explosion_debris",
        
        sound_break = "explosion",
        sound_reveal = "secret_reveal",
        
        tile_ids = { 625, 626 },
        layer_name = "breakables",
        object_type = "bomb_wall",
    },
    
    charge_wall = {
        name = "Charge Wall",
        description = "A wall that requires charge attack to break",
        
        detection_method = "ability",
        required_ability = "charge_attack",
        health = 1,
        reveal_on_map = true,
        persist_revealed = true,
        
        sprite_hidden = "wall_reinforced",
        particle_break = "wall_debris",
        
        sound_break = "wall_break",
        sound_reveal = "secret_reveal",
        
        tile_ids = { 627, 628 },
        layer_name = "breakables",
        object_type = "charge_wall",
    },
    
    -- =========================================================================
    -- SECRET DOORS
    -- =========================================================================
    
    secret_door = {
        name = "Secret Door",
        description = "A door hidden as part of the wall",
        
        detection_method = "interact",  -- requires interaction button
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Requires puzzle/trigger to open
        requires_trigger = false,  -- or set trigger_id in Tiled
        
        -- Visual
        sprite_hidden = "wall_door_hidden",
        sprite_revealed = "door_secret_open",
        particle_open = "dust_cloud",
        
        -- Animation
        open_animation = "door_secret_open",
        open_duration = 0.5,
        
        sound_open = "door_open",
        sound_reveal = "secret_reveal",
        
        tile_ids = { 630, 631 },
        layer_name = "secrets",
        object_type = "secret_door",
    },
    
    -- =========================================================================
    -- ONE-WAY SECRETS
    -- =========================================================================
    
    one_way_secret = {
        name = "One-Way Secret",
        description = "Can only be entered from one direction",
        
        detection_method = "touch",
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Direction player must approach from (set in Tiled)
        entry_direction = "left",  -- "left", "right", "up", "down"
        
        -- Behavior
        blocks_from_other_side = true,
        
        sprite_hidden = "wall_normal",
        particle_enter = "phase_through",
        
        sound_enter = "phase_whoosh",
        
        tile_ids = { 640, 641, 642, 643 },  -- one per direction
        layer_name = "secrets",
        object_type = "one_way_secret",
    },
    
    -- =========================================================================
    -- HIDDEN ITEMS
    -- =========================================================================
    
    buried_treasure = {
        name = "Buried Treasure",
        description = "Treasure hidden in the ground, found by down-strike",
        
        detection_method = "ability",
        required_ability = "down_strike",
        reveal_on_map = true,
        persist_revealed = true,
        
        -- Spawns collectible when found
        spawns_collectible = true,
        default_collectible = "gem_large",
        
        sprite_hidden = nil,  -- no visual hint
        sprite_revealed = nil,  -- collectible appears
        particle_reveal = "dig_burst",
        
        sound_reveal = "dig_treasure",
        
        tile_ids = { 650 },
        layer_name = "secrets",
        object_type = "buried_treasure",
    },
    
    -- =========================================================================
    -- SECRET AREAS
    -- =========================================================================
    
    secret_area_trigger = {
        name = "Secret Area",
        description = "Marks an entire area as secret for map completion",
        
        detection_method = "touch",
        reveal_on_map = true,
        persist_revealed = true,
        
        -- For map completion tracking
        counts_for_completion = true,
        completion_category = "secrets",
        
        -- Can trigger notification
        show_notification = true,
        notification_text = "Secret Area Found!",
        
        sprite_hidden = nil,
        particle_reveal = "secret_sparkle",
        
        sound_reveal = "secret_reveal",
        
        object_type = "secret_area",
    },
    
    -- =========================================================================
    -- GLOBAL SECRET SETTINGS
    -- =========================================================================
    settings = {
        -- Minimap markers
        show_unrevealed_hints = false,  -- show ? on map before found
        show_revealed_markers = true,
        marker_icon_unrevealed = "marker_question",
        marker_icon_revealed = "marker_secret",
        
        -- Persistence
        save_revealed_to_flags = true,
        flag_prefix = "secret_",
        
        -- Completion tracking
        track_secret_completion = true,
        completion_notification = "Secrets: %d/%d",
        
        -- Audio
        default_reveal_sound = "secret_reveal",
        
        -- Particles
        default_reveal_particle = "secret_sparkle",
    },
}
