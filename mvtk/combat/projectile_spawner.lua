-- mvtk/combat/projectile_spawner.lua
-- Safe projectile factory wrapper used by boss and enemy attacks.
--
-- Centralizes the pcall + set_velocity pattern so geometry-only callers
-- don't need to know how projectiles are actually instantiated, and we
-- don't crash when a factory URL is missing on a prefab.
--
-- Typical usage from an attack:
--   local Geometry = require "mvtk.combat.attack_geometry"
--   local Spawn    = require "mvtk.combat.projectile_spawner"
--   local angles   = Geometry.compute_spread_angles(count, arc, base_angle)
--   for _, a in ipairs(angles) do
--       Spawn.fire("#boss_projectile_factory", origin, a, {
--           speed = 300, damage = 1, lifetime = 3,
--           facing = boss.facing,
--       })
--   end

local M = {}

local function resolve_factory_url(url_or_path)
    if type(url_or_path) == "string" then
        local ok, url = pcall(msg.url, url_or_path)
        if ok then return url end
        return nil
    end
    return url_or_path
end

local function factory_exists(url)
    if not url then return false end
    local ok, exists = pcall(go.exists, url)
    return ok and exists
end

-- Fire a single projectile.
-- factory_ref: "#component_id" string OR resolved msg.url
-- origin: spawn position (vector3)
-- angle: radians; the projectile's dir_x / dir_y are set to cos/sin(angle)
-- props: table merged into factory props. Recognized fields:
--   speed (default 300), lifetime (default 3.0), damage, facing,
--   extra_props (table of additional factory props to pass through).
-- Returns the created instance id (or nil on failure).
function M.fire(factory_ref, origin, angle, props)
    props = props or {}
    local url = resolve_factory_url(factory_ref)
    if not factory_exists(url) then
        return nil
    end

    local speed = tonumber(props.speed) or 300
    local lifetime = tonumber(props.lifetime) or 3.0
    local dir_x = math.cos(angle)
    local dir_y = math.sin(angle)

    local factory_props = {
        speed = speed,
        lifetime = lifetime,
        damage = props.damage,
        dir = props.facing or (dir_x >= 0 and 1 or -1),
        dir_x = dir_x,
        dir_y = dir_y,
    }
    if props.extra_props then
        for k, v in pairs(props.extra_props) do
            factory_props[k] = v
        end
    end

    local ok, proj_id = pcall(factory.create, url, origin, nil, factory_props)
    if not ok or not proj_id then
        return nil
    end

    -- Some projectile scripts read velocity from a message; best-effort push.
    pcall(msg.post, proj_id, hash("set_velocity"), {
        velocity = vmath.vector3(dir_x * speed, dir_y * speed, 0),
    })

    return proj_id
end

return M
