-- Shared creator presets for Project > Game Settings...; the accepted values stay unchanged.
-- Current means the session's saved values; it is never stored in this table.
-- Consumers copy player before adding their own mutable Current entry.
return {
  order = { "current", "balanced", "fast", "heavy" },
  player = {
  balanced = {
    name = "Balanced", description = "Standard platformer controls",
    player_scale = 1.0, walk_speed = 2100, run_speed = 3500, jump_height = 448,
    gravity = -4200, max_health = 5, max_energy = 3, max_stamina = 100,
    -- Advanced settings
    air_accel_mult = 0.8, coyote_time = 0.12, attack_buffer = 0.15, air_jumps = 1,
    slide_speed = 3850, air_dash_speed = 3150, air_dash_count = 1,
    wall_climb_speed = 1050, wall_cling_fall_speed = 0,
    slide_enabled = true, air_dash_enabled = true, wall_climb_enabled = false,
    double_jump_enabled = true, extended_jump_enabled = false, grapple_enabled = false,
    glide_enabled = true,
    charge_attack_enabled = true, down_strike_enabled = true, ranged_attack_enabled = true,
    slide_iframes_enabled = false, air_dash_iframes_enabled = false,
    -- Combat settings
    melee_light_damage = 1, melee_light_cooldown = 0.18, melee_heavy_damage = 2,
    ranged_damage = 1, ranged_projectile_speed = 2100, parry_window = 0.18,
    combo_chaining = true, mixed_finishers = true, attack_cancels = true,
    parry = true, perfect_parry = true, parry_counter = true,
    aerial_attacks = true, aerial_juggle = true,
    -- Game settings
    camera_shake = true, damage_numbers = false, icon_theme = "xbox",
  },
  fast = {
    name = "Fast & Agile", description = "Quick movement, lower jump",
    player_scale = 1.0, walk_speed = 2625, run_speed = 4375, jump_height = 350,
    gravity = -5600, max_health = 4, max_energy = 4, max_stamina = 100,
    -- Advanced settings
    air_accel_mult = 1.0, coyote_time = 0.08, attack_buffer = 0.12, air_jumps = 2,
    slide_speed = 4550, air_dash_speed = 3850, air_dash_count = 2,
    wall_climb_speed = 1225, wall_cling_fall_speed = 0,
    slide_enabled = true, air_dash_enabled = true, wall_climb_enabled = false,
    double_jump_enabled = true, extended_jump_enabled = false, grapple_enabled = false,
    glide_enabled = true,
    charge_attack_enabled = true, down_strike_enabled = true, ranged_attack_enabled = true,
    slide_iframes_enabled = false, air_dash_iframes_enabled = false,
    -- Combat settings (faster attacks)
    melee_light_damage = 1, melee_light_cooldown = 0.12, melee_heavy_damage = 2,
    ranged_damage = 1, ranged_projectile_speed = 2800, parry_window = 0.15,
    combo_chaining = true, mixed_finishers = true, attack_cancels = true,
    parry = true, perfect_parry = true, parry_counter = true,
    aerial_attacks = true, aerial_juggle = true,
    -- Game settings
    camera_shake = true, damage_numbers = false, icon_theme = "xbox",
  },
  heavy = {
    name = "Heavy & Slow", description = "Slower movement, higher jump arc",
    player_scale = 1.0, walk_speed = 1575, run_speed = 2800, jump_height = 560,
    gravity = -3150, max_health = 8, max_energy = 2, max_stamina = 80,
    -- Advanced settings
    air_accel_mult = 0.5, coyote_time = 0.15, attack_buffer = 0.18, air_jumps = 0,
    slide_speed = 3150, air_dash_speed = 2625, air_dash_count = 1,
    wall_climb_speed = 875, wall_cling_fall_speed = 0,
    slide_enabled = true, air_dash_enabled = false, wall_climb_enabled = true,
    double_jump_enabled = false, extended_jump_enabled = false, grapple_enabled = false,
    glide_enabled = true,
    charge_attack_enabled = true, down_strike_enabled = true, ranged_attack_enabled = true,
    slide_iframes_enabled = false, air_dash_iframes_enabled = false,
    -- Combat settings (heavier hits)
    melee_light_damage = 2, melee_light_cooldown = 0.25, melee_heavy_damage = 4,
    ranged_damage = 2, ranged_projectile_speed = 1575, parry_window = 0.22,
    combo_chaining = true, mixed_finishers = true, attack_cancels = true,
    parry = true, perfect_parry = true, parry_counter = true,
    aerial_attacks = true, aerial_juggle = true,
    -- Game settings
    camera_shake = true, damage_numbers = false, icon_theme = "xbox",
  },
},
}
