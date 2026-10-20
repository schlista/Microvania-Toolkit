-- animation/names.lua
-- Canonical animation names and simple metadata

local M = {}

-- List of canonical string names
M.list = {
  "idle", "run", "walk", "jump", "double_jump", "fall", "land",
  "slide", "crouch", "dash", "air_dash", "air_dash_right",
  "wall_slide", "wall_cling", "wall_land", "roll",
  "attack", "attack_alt", "punch", "weapon_attack", "shoot", "aim",
  "grapple",
  "hurt", "die", "death", "spawn", "taunt", "celebrate",
  "climb", "climb_up", "climb_down", "climb_idle", "hang",
  "swim", "swim_idle", "swim_move",
  "fly", "fly_idle", "fly_move",
  "hover", "dive",
  "patrol", "alert", "chase", "search", "return",
  "ranged_attack", "charge", "charge_windup", "slam", "block",
  "stun",
  "air_spin",
  "climb_facing_back_of_player", "climb_facing_side_of_player",
  "crouch_idle", "crouch_walk",
  "hurt_damaged",
  "ledge_grab_climb",
  "pull", "pull_idle", "push", "pushpull_idle_state",
  "punch_cross", "punch_jab",
  "running_aiming", "running_shooting",
  "shooting_two_handed",
  "sword_attack", "sword_idle", "sword_run", "sword_stab",
  "parry", "parry_success",
}

-- Aliases map to canonical names (universal only — NOT renderer-specific)
-- Player-only Spine remaps live in developer/config/player_spine_map.lua.
M.alias = {
  attack_light = "attack",
  attack_heavy = "attack_alt",
  die = "death",
  ["air spin"] = "air_spin",
  ["climb (facing back of player)"] = "climb_facing_back_of_player",
  ["climb (facing side of player)"] = "climb_facing_side_of_player",
  ["crouch-idle"] = "crouch_idle",
  ["crouch-walk"] = "crouch_walk",
  ["hurt-damaged"] = "hurt_damaged",
  ["ledge grab-climb"] = "ledge_grab_climb",
  ["pushpull (idle state)"] = "pushpull_idle_state",
  ["punch cross"] = "punch_cross",
  ["punch jab"] = "punch_jab",
  ["shooting (running and aiming)"] = "running_aiming",
  ["shooting (two-handed)"] = "shooting_two_handed",
  ["sword attack"] = "sword_attack",
  ["sword idle"] = "sword_idle",
  ["sword run"] = "sword_run",
  ["sword stab"] = "sword_stab",
  ["wall land"] = "wall_land",
  ["wall slide"] = "wall_slide",
}

local CANONICAL = {}
for _, n in ipairs(M.list) do
  CANONICAL[n] = true
end

-- Convert a provided string/hash name into canonical hash
local function canon_name(s)
  if type(s) == "string" then
    local lower = string.lower(s):gsub("^%s+", ""):gsub("%s+$", "")
    local normalized = lower
      :gsub("[^%w]+", "_")
      :gsub("^_+", "")
      :gsub("_+$", "")
      :gsub("_+", "_")
    local mapped = M.alias[lower]
      or M.alias[normalized]
      or (CANONICAL[lower] and lower)
      or (CANONICAL[normalized] and normalized)
      or lower
    return hash(mapped)
  end
  return s -- assume already a hash
end
M.canon = canon_name

-- Metadata: which states should loop by default
local LOOP = {
  idle = true, run = true, walk = true, crouch = true,
  wall_slide = true, wall_cling = true,
  fall = true, climb = true, climb_up = true, climb_down = true,
  climb_idle = true, hang = true, grapple = true,
  swim = true, swim_idle = true, swim_move = true,
  fly = true, fly_idle = true, fly_move = true,
  hover = true,
  patrol = true, alert = true, chase = true, search = true, ["return"] = true,
  charge_windup = true, block = true, stun = true,
  aim = true,
  climb_facing_back_of_player = true,
  climb_facing_side_of_player = true,
  crouch_idle = true,
  crouch_walk = true,
  pull = true,
  pull_idle = true,
  push = true,
  pushpull_idle_state = true,
  running_aiming = true,
  sword_idle = true,
  sword_run = true,
}

-- Metadata: which states are short one-shots by default
local ONCE = {
  jump = true, land = true,
  dash = true, slide = true, roll = true, wall_land = true,
  double_jump = true, air_dash = true, air_dash_right = true,
  attack = true, attack_alt = true, punch = true, weapon_attack = true, shoot = true,
  dive = true, ranged_attack = true, charge = true, slam = true,
  hurt = true, die = true, death = true, spawn = true,
  taunt = true, celebrate = true,
  air_spin = true,
  hurt_damaged = true,
  ledge_grab_climb = true,
  punch_cross = true,
  punch_jab = true,
  running_shooting = true,
  shooting_two_handed = true,
  sword_attack = true,
  sword_stab = true,
  parry = true,
  parry_success = true,
}

-- Public helpers
function M.is_loop(state)
  local s = canon_name(state)
  -- compare hash against hashed keys
  for k, v in pairs(LOOP) do
    if v and s == hash(k) then return true end
  end
  return false
end

function M.is_once(state)
  local s = canon_name(state)
  for k, v in pairs(ONCE) do
    if v and s == hash(k) then return true end
  end
  return false
end

-- Export hashed constants for convenience
for _, n in ipairs(M.list) do
  local up = string.upper(n)
  M[up] = hash(n)
end
for alias, target in pairs(M.alias) do
  local up = string.upper(alias)
  M[up] = hash(target)
end

return M
