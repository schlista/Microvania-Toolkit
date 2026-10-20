-- developer/config/difficulty_settings.lua
-- Difficulty scalars for player/enemy tuning.
--
-- Tuning ranges (each multiplier; 1.0 = baseline):
--   damage_taken_mult   0.5 (very forgiving) - 2.0 (one-shot territory)
--   damage_dealt_mult   0.5 (long fights)    - 1.5 (snappy)
--   enemy_health_mult   0.5                  - 2.5
--   loot_mult           0.5                  - 2.0
-- Choose the starting profile here; Tiled enemy overrides can select a profile.

return {
    current = "normal",
    profiles = {
        easy = {
            damage_taken_mult = 0.8,
            damage_dealt_mult = 1.1,
            enemy_health_mult = 0.9,
            loot_mult = 1.1,
        },
        normal = {
            damage_taken_mult = 1.0,
            damage_dealt_mult = 1.0,
            enemy_health_mult = 1.0,
            loot_mult = 1.0,
        },
        hard = {
            damage_taken_mult = 1.2,
            damage_dealt_mult = 0.95,
            enemy_health_mult = 1.25,
            loot_mult = 1.0,
        },
        nightmare = {
            damage_taken_mult = 1.4,
            damage_dealt_mult = 0.9,
            enemy_health_mult = 1.4,
            loot_mult = 1.2,
        },
    }
}
