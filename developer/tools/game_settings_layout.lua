-- Display order for Project > Game Settings. Field titles, values, types,
-- choices, ranges and help belong to creator_settings_model, not this layout.
local Model = require "mvtk.core.creator_settings_model"
local M = {}

local function ability_sections()
    local sections, by_category = {}, {}
    local titles = { movement = "Movement", combat = "Combat", defensive = "Defensive", other = "Other" }
    for _, field in ipairs(Model.toggle_fields("ability")) do
        local category = field.category or "other"
        if not by_category[category] then
            local title = titles[category] or (category:gsub("_", " "):gsub("^%l", string.upper))
            by_category[category] = { title = title, fields = {} }
            sections[#sections + 1] = by_category[category]
        end
        local fields = by_category[category].fields
        fields[#fields + 1] = field.key
    end
    return sections
end

M.tabs = {
    { title = "Player", sections = {
        { title = "Size", fields = { "player_scale", "scale_movement" } },
        { title = "Movement", fields = { "walk_speed", "run_speed", "jump_height", "gravity" } },
        { title = "Health and resources", fields = { "max_health", "max_energy", "max_stamina" } },
    } },
    { title = "Player art", sections = {
        { title = "Source and frames", fields = { "art_source", "art_mode", "art_frame_width", "art_frame_height",
            "art_animations", "art_mappings", "art_fps", "art_once", "art_required", "art_fallback" } },
        { title = "Size and body", fields = { "art_width", "art_height", "art_origin_x", "art_origin_y",
            "art_body_width", "art_body_height" } },
    } },
    { title = "Abilities", sections = ability_sections() },
    { title = "Advanced", sections = {
        { title = "Movement and input", fields = { "air_accel_mult", "coyote_time", "attack_buffer" } },
        { title = "Double Jump and Slide", fields = { "air_jumps", "slide_speed" } },
        { title = "Air Dash", fields = { "air_dash_speed", "air_dash_count" } },
        { title = "Wall Climb", fields = { "wall_climb_speed", "wall_cling_fall_speed" } },
    } },
    { title = "Combat", sections = {
        { title = "Light attack", fields = { "melee_light_damage", "melee_light_cooldown",
            "light_hitbox_width", "light_hitbox_height" } },
        { title = "Heavy attack", fields = { "melee_heavy_damage", "heavy_hitbox_width", "heavy_hitbox_height" } },
        { title = "Ranged attack", fields = { "ranged_damage", "ranged_projectile_speed" } },
        { title = "Parry", fields = { "parry_window" } },
    } },
    { title = "Combat features", sections = {
        { title = "Combo attacks", fields = { "combo_chaining", "mixed_finishers", "attack_cancels" } },
        { title = "Parry", fields = { "parry", "perfect_parry", "parry_counter" } },
        { title = "Aerial attacks", fields = { "aerial_attacks", "aerial_juggle" } },
    } },
    { title = "Grapple", sections = {
        { title = "Hook", fields = { "grapple_style", "grapple_targets", "grapple_stay_hooked", "grapple_reel",
            "grapple_break_on_impact", "grapple_walls" } },
        { title = "Swing and rope", fields = { "grapple_range", "grapple_swing_strength", "grapple_swing_speed",
            "grapple_swing_fade", "grapple_reel_speed", "grapple_pull_speed" } },
        { title = "Letting go", fields = { "grapple_momentum", "grapple_release_carry", "grapple_release_float",
            "grapple_release_boost", "grapple_release_lift", "grapple_rehook_window" } },
    } },
    { title = "Game", sections = {
        { title = "Game", fields = { "project_name", "game_id" } },
        { title = "Options", fields = { "camera_shake", "damage_numbers", "icon_theme" } },
        { title = "Death drop", fields = { "death_drop_enabled", "death_currency_fraction", "death_minimum" } },
    } },
    { title = "Ending", sections = {
        { title = "Ending settings", fields = { "ending_enabled", "ending_id", "ending_condition", "ending_flag",
            "ending_boss_id", "ending_continue_policy", "ending_return_room", "ending_return_x", "ending_return_y",
            "ending_title", "ending_body", "ending_credits", "ending_music", "ending_artwork", "ending_reward_flag" } },
    } },
    { title = "Camera", sections = {
        { title = "View", fields = { "camera_zoom", "camera_pixel_snap" } },
        { title = "Following the player", fields = { "camera_follow_x", "camera_follow_y", "camera_deadzone_x",
            "camera_deadzone_y", "camera_lookahead", "camera_offset_x", "camera_offset_y", "camera_vertical_look" } },
        { title = "Respawning", fields = { "camera_respawn_snap", "camera_respawn_time" } },
    } },
    { title = "HUD and prompts", sections = {
        { title = "Layout", fields = { "hud_preset", "hud_scale", "hud_theme", "hud_health_anchor" } },
        { title = "Show on screen", fields = { "hud_health_bar", "hud_energy_bar", "hud_stamina_bar",
            "hud_currency", "hud_abilities", "hud_interact_hint" } },
        { title = "Health bar color", fields = { "hud_health_red", "hud_health_green", "hud_health_blue" } },
    } },
    { title = "Map", sections = {
        { title = "Discovery", fields = { "map_fog", "map_discovery_mode", "map_reveal_radius", "map_softness" } },
        { title = "Visibility", fields = { "map_visible", "minimap_visible" } },
        { title = "Player markers", fields = { "map_marker_limit", "map_marker_size" } },
    } },
    { title = "Saves and checkpoints", sections = {
        { title = "Save slots", fields = { "save_slots" } },
        { title = "Autosave", fields = { "save_autosave", "save_interval", "save_room_change", "save_pickup" } },
    } },
    { title = "Movement test", sections = {
        { title = "Course", fields = { "test_floor_tiles", "test_step_tiles", "test_gap_tiles" } },
    } },
}

M.deferred = {}

return M
