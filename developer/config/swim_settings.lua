-- developer/config/swim_settings.lua
-- Default swimming movement and oxygen tuning.

return {
    swim_speed = 200,
    swim_acceleration = 800,
    swim_friction = 0.85,
    swim_dash_speed = 400,
    swim_dash_duration = 0.3,

    bubble_interval = 0.5,
    oxygen_max = 10.0,
    oxygen_drain_rate = 1.0,
    oxygen_refill_rate = 2.0,
    surface_splash_threshold = 50,
}
