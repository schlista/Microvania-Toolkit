-- Creator-document pixel paths for the pre-T9 units frozen next door in
-- player_units_baseline.lua. Keep conversion rules in this single table:
-- always converts explicit values; movement preserves the old effective value.
local PlayerScale = require "mvtk.player.player_scale"
local M = { always = {}, movement = {} }

for family, paths in pairs(PlayerScale.SCALED_KEYS) do
    for _, path in ipairs(paths) do M[family][#M[family] + 1] = "player." .. path end
end
for _, attack in ipairs({ "light", "heavy" }) do
    for _, axis in ipairs({ "width", "height" }) do
        M.always[#M.always + 1] = "combat.melee_" .. attack .. ".hitbox." .. axis
    end
end
for _, key in ipairs({ "width", "height", "offset_x", "offset_y" }) do
    M.always[#M.always + 1] = "player_art." .. key
end
M.movement[#M.movement + 1] = "combat.ranged.projectile_speed"

return M
