-- mvtk/audio/audio.lua
-- moved from modules/audio/audio.lua

local C = require "mvtk.core.constants"
local Time = require "mvtk.core.time"
local Util = require "mvtk.core.util"
local Debug = Util.require_config('developer.config.debug_config')
local GameplayConstants = Util.require_config("developer.config.gameplay_constants")
local SoundDebug = Util.require_module("mvtk.audio.sound_debug")

-- Only install sound debug wrappers when audio debugging is enabled
if SoundDebug and (Debug.global.enable or (Debug.audio and (Debug.audio.trace_sfx or Debug.audio.music or Debug.audio.controller))) then
    SoundDebug.install()
end

local M = {
  _vol = { music = 1.0, sfx = 1.0, ambient = 1.0 },
  _footsteps = {
    default = "footstep_default",
    factory = "footstep_metal",
    forest  = "footstep_grass",
    stone   = "footstep_stone",
  },
  _music_blocked = false,
  _pending_music = nil,
  _pending_area = nil,
  _sfx_last_play = {},
}

local audio_log = Util.make_debug_log("[AUDIO]", function()
  return Debug.global.enable or (Debug.audio and (Debug.audio.controller or Debug.audio.manager or Debug.audio.music))
end)



local function post_audio(id, msgtbl)
  local url = C and C.URL and C.URL.AUDIO
  audio_log("post_audio called:", id, "url:", url, "msg:", msgtbl)
  if url then
    local ok, err = pcall(msg.post, url, id, msgtbl or {})
    if not ok then
      audio_log("ERROR posting audio message:", err)
    end
  else
    audio_log("WARNING: No audio URL available (C.URL.AUDIO is nil)")
  end
end

function M.set_volume(kind, v)
  if M._vol[kind] ~= nil then
    M._vol[kind] = Util.clamp01(v)
    post_audio(hash("set_volume"), { kind = kind, value = M._vol[kind] })
  end
end

function M.music(id, opts)
  if M._music_blocked then
    audio_log("Music request skipped (blocked):", tostring(id))
    M._pending_music = { id = id, opts = opts }
    if M._pending_music then
      audio_log("  >> stored pending music request:", tostring(id))
    end
    return
  end
  audio_log("M.music called with id:", id, "opts:", opts)
  if not id then
    audio_log("WARNING: music() called with nil id")
    return
  end
  if Debug.global.enable or (Debug.audio and (Debug.audio.controller or Debug.audio.manager or Debug.audio.music)) then
    local info = debug.getinfo(2, "Sl")
    if info then
      audio_log("  -> request origin:", tostring(info.source), "line", tostring(info.currentline))
    end
  end
  M._last_music_request = id
  if opts and opts.silence then
    post_audio(hash("stop_all_music"))
  else
    post_audio(hash("play_music"), { id = id, t = opts and opts.t })
  end
end

function M.current_music_request()
  return M._last_music_request
end

function M.set_area_theme(area_id)
  if M._music_blocked then
    audio_log("Area theme request skipped (blocked):", tostring(area_id))
    M._pending_area = area_id
    if M._pending_area then
      audio_log("  >> stored pending area theme:", tostring(area_id))
    end
    return
  end
  audio_log("M.set_area_theme called with area_id:", area_id)
  if not area_id then
    audio_log("WARNING: set_area_theme() called with nil area_id")
    return
  end
  if Debug.global.enable or (Debug.audio and (Debug.audio.controller or Debug.audio.manager or Debug.audio.music)) then
    local info = debug.getinfo(2, "Sl")
    if info then
      audio_log("  -> area theme origin:", tostring(info.source), "line", tostring(info.currentline))
    end
  end
  post_audio(hash("set_area_theme"), { area = area_id })
  M._last_music_request = nil
end

function M.set_boss_theme(boss_id, active)
  if M._music_blocked and active then
    audio_log("Boss theme activation skipped (blocked):", tostring(boss_id))
    return
  end
  audio_log("M.set_boss_theme called with boss_id:", boss_id, "active:", active)
  if not boss_id then
    audio_log("WARNING: set_boss_theme() called with nil boss_id")
    return
  end
  post_audio(hash("set_boss_theme"), { boss = boss_id, active = active and true or false })
end

local DEFAULT_SFX_COOLDOWN = 0.08
if GameplayConstants and GameplayConstants.audio then
  DEFAULT_SFX_COOLDOWN = tonumber(GameplayConstants.audio.default_sfx_cooldown) or DEFAULT_SFX_COOLDOWN
end

function M.sfx(id, opts)
  if not id then return end
  local now = Time.gettime()
  local cooldown = (opts and opts.cooldown) or DEFAULT_SFX_COOLDOWN
  local last_play = M._sfx_last_play[id]
  if last_play and cooldown and cooldown > 0 then
    local elapsed = now - last_play
    if elapsed < cooldown then
      if Debug.global.enable or (Debug.audio and Debug.audio.sfx) then
        audio_log(string.format("Skipping sfx '%s' (cooldown %.3fs, elapsed %.3fs)", tostring(id), cooldown, elapsed))
      end
      return
    end
  end

  M._sfx_last_play[id] = now
  local payload = Util.acquire_table()
  payload.id = id
  payload.gain = opts and opts.gain
  payload.pan = opts and opts.pan
  post_audio(hash("sfx"), payload)
  Util.release_table(payload)
end

function M.ambience(id, opts)
  if not id then return end
  local payload = Util.acquire_table()
  payload.id = id
  payload.gain = opts and opts.gain
  post_audio(hash("play_ambient"), payload)
  Util.release_table(payload)
end

function M.stop_sfx(id)
  if not id then return end
  post_audio(hash("stop_sfx"), { id = id })
end

function M.stop_ambience(id)
  if not id then return end
  post_audio(hash("stop_ambient"), { id = id })
end

function M.set_music_duck(zone_id, percent)
  if not zone_id then return end
  post_audio(hash("set_music_duck"), {
    id = zone_id,
    percent = percent,
  })
end

function M.clear_music_duck(zone_id)
  if not zone_id then return end
  post_audio(hash("clear_music_duck"), {
    id = zone_id,
  })
end

function M.footstep(surface, biome)
  local key = surface or biome or "default"
  local id = M._footsteps[key] or M._footsteps.default
  M.sfx(id)
end

function M.block_music_requests(block, reason)
  local should_block = block and true or false
  if M._music_blocked == should_block then
    return
  end
  M._music_blocked = should_block
  if should_block then
    audio_log("Music requests blocked", reason and ("(" .. tostring(reason) .. ")") or "")
    if M._pending_area or (M._pending_music and M._pending_music.id) then
      audio_log("  >> clearing pre-existing pending requests before block")
    end
    M._pending_area = nil
    M._pending_music = nil
  else
    audio_log("Music requests unblocked")
    local pending_area = M._pending_area
    local pending_music = M._pending_music
    M._pending_area = nil
    M._pending_music = nil
    if pending_area then
      audio_log("  >> replaying pending area theme:", pending_area)
      M.set_area_theme(pending_area)
    end
    if pending_music and pending_music.id then
      audio_log("  >> replaying pending music:", pending_music.id)
      M.music(pending_music.id, pending_music.opts)
    end
  end
end

return M
