-- mvtk/audio/volume_groups.lua
-- Volume group and music-ducking helpers extracted from audio_controller.script.

local M = {}

local vol = { music = 1.0, sfx = 1.0, ambient = 1.0 }
local get_music_duck_overrides = function() return {} end
local get_music_duck_multiplier = function() return 1.0 end
local set_music_duck_multiplier = function() end
local stable_hash_key = function(value) return value and tostring(value) or nil end
local ambient_trace = function() end

function M.configure(opts)
  opts = opts or {}
  vol = opts.vol or vol
  get_music_duck_overrides = opts.get_music_duck_overrides or get_music_duck_overrides
  get_music_duck_multiplier = opts.get_music_duck_multiplier or get_music_duck_multiplier
  set_music_duck_multiplier = opts.set_music_duck_multiplier or set_music_duck_multiplier
  stable_hash_key = opts.stable_hash_key or stable_hash_key
  ambient_trace = opts.ambient_trace or ambient_trace
end

function M.clamp01(x)
  return math.max(0, math.min(1, tonumber(x) or 0))
end

function M.clamp_pan(x)
  if x == nil then return nil end
  return math.max(-1, math.min(1, tonumber(x) or 0))
end

function M.clamp_music_duck(value)
  return math.max(0, math.min(1, tonumber(value) or 1))
end

function M.sync_group_volumes_from_settings()
  local ok, Settings = pcall(require, "mvtk.core.settings")
  if not ok or not Settings then
    return false
  end
  if Settings.load then
    pcall(Settings.load)
  end
  local muted = Settings.is_muted and Settings.is_muted() or Settings.get and Settings.get("audio.muted") or false
  local master = muted and 0 or M.clamp01(Settings.get_master_volume and Settings.get_master_volume() or Settings.get and Settings.get("audio.master_volume") or 0.8)
  local music = muted and 0 or (master * M.clamp01(Settings.get_music_volume and Settings.get_music_volume() or Settings.get and Settings.get("audio.music_volume") or 0.7))
  local sfx = muted and 0 or (master * M.clamp01(Settings.get_sfx_volume and Settings.get_sfx_volume() or Settings.get and Settings.get("audio.sfx_volume") or 0.8))
  vol.music = music
  vol.sfx = sfx
  vol.ambient = master
  return true
end

function M.recompute_music_duck()
  local duck = 1.0
  for _, value in pairs(get_music_duck_overrides() or {}) do
    duck = math.min(duck, M.clamp_music_duck(value))
  end
  set_music_duck_multiplier(duck)
  return duck
end

function M.music_duck_key(zone_id)
  local key = stable_hash_key(zone_id)
  if key == nil or key == "" or key == "hash: [0000000000000000]" then
    return nil
  end
  return key
end

function M.set_group_volumes()
  local active_groups = {}
  local ok_groups, groups = pcall(sound.get_groups)
  if ok_groups and type(groups) == "table" then
    for _, g in ipairs(groups) do
      active_groups[g] = true
    end
  end
  local h_music = hash("music")
  local h_sfx = hash("sfx")
  local h_ambient = hash("ambient")
  local effective_music = M.clamp01((vol.music or 1.0) * (get_music_duck_multiplier() or 1.0))
  if active_groups[h_music] then
    pcall(sound.set_group_gain, h_music, effective_music)
  end
  if active_groups[h_sfx] then
    pcall(sound.set_group_gain, h_sfx, vol.sfx)
  end
  if active_groups[h_ambient] then
    pcall(sound.set_group_gain, h_ambient, vol.ambient)
  end
  ambient_trace(string.format(
    "group_gain music=%.2f effective_music=%.2f duck=%.2f sfx=%.2f ambient=%.2f",
    vol.music or -1,
    effective_music,
    get_music_duck_multiplier() or -1,
    vol.sfx or -1,
    vol.ambient or -1
  ))
end

return M
