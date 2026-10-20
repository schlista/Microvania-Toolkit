-- Frozen pre-T9 pixel units from 80b56ae6b08ce4bcd0d7349a93a2c85c23b6133e.
-- Never read the upgraded project baseline to reconstruct its old effective values.
-- Values retain their original player_settings.lua units (px, px/s or px/s^2).
return {
    player_scale = 1.75,
    scale_movement = true,
    collider_half_height = 31, collider_half_width = 24,
    foot_floor_adjust = -8, head_margin = 14,
    -- roll.small_half_width/height were absent; an explicit override still migrates.
    walk_speed = 1200, run_speed = 2000, stop_epsilon = 3,
    gravity = -2400, jump_height = 256, extended_jump_height = 64,
    landing_snap_distance = 0,
    slide = { speed = 2200 }, air_dash = { speed = 1800 },
    wall_climb = {
        speed = 600, climb_speed = 600, stick_speed = 0,
        wall_jump = { slide_fall_speed = 200 },
        ledge_climb = { climb_x = 32, climb_y = 64 },
    },
    block_grab = { pull_speed = 700 }, glide = { max_fall_speed = 900 },
    ground_pound = { slam_speed = 1400, impact_bounce = 340 },
    grapple = {
        range_px = 800, pull_speed = 2200, swing_acceleration = 2000,
        swing_max_speed = 1200, swing_speed_limit = 0, rope_length_px = 0,
        min_rope_length_px = 96, reel_speed = 320, surface_clearance_px = 4,
        release_boost_px = 150, release_up_boost_px = 0, impact_release_speed = 150,
        occlusion_tolerance_px = 8, ground_clearance_px = 16,
        launch_reel_speed = 1400, arrival_distance_px = 8,
    },
    -- combat_overrides.lua ranged.projectile_speed (the game-used base px/s).
    ranged_projectile_speed = 1200,
}
