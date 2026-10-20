--- Boss projectile attack executor.
-- Fires `count` projectiles in a spread aimed at the player. Uses the boss's
-- `#boss_projectile_factory` when present; otherwise schedules a delayed hit
-- test at the player's predicted position so the attack still registers.
-- @module boss_attacks.projectile

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local projectiles_config = pattern.projectiles or {}
    local count = projectiles_config.count or 1
    local spread_deg = projectiles_config.spread or 0
    local speed = projectiles_config.speed or C.Defaults.default_projectile_speed
    local lifetime = projectiles_config.lifetime or C.Defaults.default_projectile_life

    C.print(string.format("[BOSS_ATTACKS] Firing %d projectiles", count))

    local pos = go.get_position()
    local damage = (pattern.damage or C.Defaults.default_projectile_damage) * C.damage_mult(boss)

    local player_pos = C.Detection.get_player_position()
    if not player_pos then return end

    local to_player = player_pos - pos
    local base_angle = math.atan2(to_player.y, to_player.x)
    local angles = C.Geometry.compute_spread_angles(count, spread_deg, base_angle)

    local have_factory = C.factory_exists("#boss_projectile_factory")

    for _, angle in ipairs(angles) do
        local dir = vmath.vector3(math.cos(angle), math.sin(angle), 0)
        local spawn_pos = pos + dir * 30

        if have_factory then
            C.ProjectileSpawner.fire("#boss_projectile_factory", spawn_pos, angle, {
                speed = speed,
                lifetime = lifetime,
                damage = damage,
                facing = boss.facing,
                extra_props = {
                    boss_id = boss.boss_id or "",
                    source_actor = boss.self_url,
                    parryable = pattern.parryable ~= false,
                    -- Shots spawn 30 px out from the boss. The first frame sweeps
                    -- from the boss itself, so a wall right beside it stops them
                    -- (a ray that starts inside a wall never reports it).
                    origin_x = pos.x,
                    origin_y = pos.y,
                    probe_origin = true,
                },
            })
        else
            local hit_delay = vmath.length(player_pos - spawn_pos) / math.max(1, speed)
            C.delay(hit_delay, function()
                local current_player_pos = C.Detection.get_player_position()
                if current_player_pos and vmath.length(current_player_pos - player_pos) < 50 then
                    local payload = C.build_payload(boss, pattern, damage, 0, 0)
                    C.post_damage(payload)
                end
            end)
        end
    end
end

return M
