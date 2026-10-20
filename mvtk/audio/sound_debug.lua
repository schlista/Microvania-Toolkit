-- mvtk/audio/sound_debug.lua
-- Runtime instrumentation that wraps sound.* calls so we can pinpoint
-- who is starting or stopping looping music (e.g. duplicate graveyard tracks).

---@diagnostic disable: duplicate-set-field

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")

local M = {}
local installed = false
local active_counts = {}
local play_ids = {}
local total_play_calls = 0
local successful_plays = 0

-- Store original functions for uninstall
local original_sound_play = nil
local original_sound_stop = nil
local original_sound_set_gain = nil
local original_msg_post = nil
local msg_hooked = false

local function to_string(value)
  if type(value) == "string" then
    return value
  end
  local ok, str = pcall(tostring, value)
  return ok and str or "<unprintable>"
end

local function is_music_label(label)
  if not label then
    return false
  end
  if label:match("graveyard") then
    return true
  end
  if label:match("/music") then
    return true
  end
  if label:match("#music") then
    return true
  end
  return false
end

local function is_sfx_label(label)
  if not label then
    return false
  end
  if label:match("#sfx_") then
    return true
  end
  if label:match("/sound#") then
    return true
  end
  if label:match("/sfx/") then
    return true
  end
  -- Heuristic: catch common movement sounds even if URL formatting differs.
  if label:match("air_dash") or label:match("dash") or label:match("slide") then
    return true
  end
  return false
end

local function opts_requests_loop(options)
  if type(options) ~= "table" then
    return false
  end
  -- Defold sound.play() doesn't officially support looping options, but
  -- some code may still try to pass flags; if we see them, log it.
  return (options.loop == true) or (options.looping == true)
end

local function should_log(label, options)
  if is_music_label(label) then
    return true
  end
  if opts_requests_loop(options) then
    return true
  end
  if Debug and Debug.audio and Debug.audio.trace_sfx and is_sfx_label(label) then
    return true
  end
  return false
end

local function caller_label(stack_level)
  local info = debug.getinfo(stack_level or 3, "Sl")
  if not info then
    return "?"
  end

  local source = info.source or "?"
  local line = info.currentline or 0
  return string.format("%s:%d", source, line)
end

local function format_options(opts)
  if not opts then
    return "nil"
  end
  if type(opts) ~= "table" then
    return to_string(opts)
  end
  local parts = {}
  for k, v in pairs(opts) do
    parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(v))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function should_emit_logs()
  if Debug and Debug.global and Debug.global.enable then
    return true
  end
  if Debug and Debug.audio then
    for _, flag in pairs(Debug.audio) do
      if flag then
        return true
      end
    end
  end
  -- Only emit logs when debug flags are enabled
  return false
end

local function emit(tag, label, caller, extra)
  if not should_emit_logs() then
    return
  end
  print(string.format("[AUDIO_HOOK][%s] %s | caller=%s%s", tag, label, caller or "?", extra or ""))
end

local function install_wrappers()
  if installed or not sound then
    return
  end

  installed = true
  
  -- Only print install banner when debug flags are enabled
  if should_emit_logs() then
    print("====================================================")
    print("[AUDIO_HOOK] Installing sound.play/stop wrappers... (sfx-trace v3-startup)")
    print("[AUDIO_HOOK] This will prevent duplicate music playback")
    print("[AUDIO_HOOK] STARTUP TRACING: All sound.play calls will be logged")
    print("====================================================")
  end

  -- CRITICAL: Stop ALL currently playing sounds BEFORE wrapping
  if sound and sound.stop then
    -- We can't enumerate playing sounds, so we can't stop them here
    -- The audio controller will handle this in its init()
  end

  -- Store originals for potential uninstall
  original_sound_play = sound.play
  original_sound_stop = sound.stop
  original_sound_set_gain = sound.set_gain
  
  local original_play = original_sound_play
  local original_stop = original_sound_stop
  local original_set_gain = original_sound_set_gain
  sound.play = function(url, options)
    local label = to_string(url)
    local caller = caller_label(3)
    local play_id
    local is_music = is_music_label(label)

    -- CRITICAL FIX: Check if this music track is already playing
    local current_active = active_counts[label] or 0

    if should_log(label, options) then
      print(string.format("[AUDIO_HOOK][PLAY] %s | caller=%s | opts=%s | current_active=%d",
        label, caller, format_options(options), current_active))
      if (not is_music) and current_active > 0 then
        print(string.format("[AUDIO_HOOK][WARN] Duplicate play without stop? %s | active=%d | caller=%s",
          label, current_active, caller))
      end
    elseif Debug and Debug.global and Debug.global.enable then
      -- Log ALL plays when global debug is on for startup debugging
      print(string.format("[AUDIO_HOOK][PLAY-ALL] %s | caller=%s | opts=%s | current_active=%d",
        label, caller, format_options(options), current_active))
    end

    -- CRITICAL FIX: For looping music, ALWAYS stop first to prevent layering
    -- This works around a Defold issue where looping sounds can create multiple instances
    -- Previously we forced a stop before playing to prevent layering, but that caused
    -- the new playback to get caught by the async stop message. Rely on the active_counts
    -- guard instead of issuing an immediate stop.

    -- PREVENT multiple instances of looping music (music group sounds)
    -- Check if this sound component is already playing (active_counts > 0)
    if current_active > 0 and is_music then
      print("====================================================")
      print(string.format("[AUDIO_HOOK][CRITICAL] *** BLOCKING DUPLICATE ***"))
      print(string.format("[AUDIO_HOOK][CRITICAL] Sound: %s", label))
      print(string.format("[AUDIO_HOOK][CRITICAL] Already active: %d instances", current_active))
      print(string.format("[AUDIO_HOOK][CRITICAL] Caller: %s", caller))
      print("====================================================")
      -- Return nil to prevent errors, but don't actually play
      return nil
    end

    -- Prevent stacking looping/ambient SFX on shared sound components.
    -- Example: collectible ambient hum uses a shared "/sound#item_hum" component.
    local is_loopish = opts_requests_loop(options) or (label and label:match("item_hum"))
    if (not is_music) and current_active > 0 and is_loopish then
      print("====================================================")
      print(string.format("[AUDIO_HOOK][CRITICAL] *** BLOCKING DUPLICATE LOOP SFX ***"))
      print(string.format("[AUDIO_HOOK][CRITICAL] Sound: %s", label))
      print(string.format("[AUDIO_HOOK][CRITICAL] Already active: %d instances", current_active))
      print(string.format("[AUDIO_HOOK][CRITICAL] Caller: %s", caller))
      print("====================================================")
      return nil
    end

    local ok, result = pcall(original_play, url, options)
    if not ok then
      if is_music then
        print(string.format("[AUDIO_HOOK][ERROR] play_failed for %s: %s", label, to_string(result)))
      end
      error(result)
    end
    play_id = result
    active_counts[label] = (active_counts[label] or 0) + 1

    if should_log(label, options) and is_music then
      successful_plays = successful_plays + 1
      print(string.format("[AUDIO_HOOK][STATE] %s | active=%d | play_id=%s | total_success=%d",
        label, active_counts[label], to_string(play_id), successful_plays))
    end

    if play_id then
      play_ids[play_id] = label
    end
    return result
  end

  sound.stop = function(url)
    local label = to_string(url)
    local caller = caller_label(3)
    local is_music = is_music_label(label)
    local was_active = active_counts[label] or 0

    if should_log(label, nil) then
      print(string.format("[AUDIO_HOOK][STOP] %s | caller=%s | was_active=%d",
        label, caller, was_active))
    end

    local result = original_stop(url)

    if active_counts[label] then
      active_counts[label] = 0
      if is_music then
        print(string.format("[AUDIO_HOOK][STATE] %s | active=0 (stopped)", label))
      end
    end
    return result
  end

  sound.set_gain = function(url, gain)
    local label = to_string(url)
    local caller = caller_label(3)
    if is_music_label(label) or (Debug and Debug.audio and Debug.audio.trace_sfx and is_sfx_label(label)) then
      emit("GAIN", label, caller, string.format(" gain=%.3f", tonumber(gain) or -1))
    end
    return original_set_gain(url, gain)
  end

  if should_emit_logs() then
    print("====================================================")
    print("[AUDIO_HOOK] Sound wrappers successfully installed!")
    print("[AUDIO_HOOK] Will now block duplicate music playback")
    print("====================================================")
  end
  
  -- Install msg.post hook to catch "play_sound"/"stop_sound" messages
  if not msg_hooked and msg and type(msg.post) == "function" then
    msg_hooked = true
    original_msg_post = msg.post
    local play_hash = hash("play_sound")
    local stop_hash = hash("stop_sound")

    msg.post = function(target, message_id, message)
      local id_matches = false
      if message_id == play_hash or message_id == stop_hash then
        id_matches = true
      elseif type(message_id) == "string" then
        if message_id == "play_sound" or message_id == "stop_sound" then
          id_matches = true
        end
      end

      if id_matches then
        local tag
        if message_id == play_hash or message_id == "play_sound" then
          tag = "MSG_PLAY"
        else
          tag = "MSG_STOP"
        end
        local label = to_string(target)
        emit(tag, label, caller_label(3), message and (" msg=" .. format_options(message)) or "")
      end

      if message ~= nil then
        return original_msg_post(target, message_id, message)
      else
        return original_msg_post(target, message_id)
      end
    end
  end
end

function M.install()
  install_wrappers()
end

--- Uninstall sound wrappers and restore original functions.
-- Call this to disable audio tracing at runtime without restarting.
function M.uninstall()
  if not installed or not sound then
    return
  end
  if original_sound_play then
    sound.play = original_sound_play
  end
  if original_sound_stop then
    sound.stop = original_sound_stop
  end
  if original_sound_set_gain then
    sound.set_gain = original_sound_set_gain
  end
  -- Restore original msg.post
  if msg_hooked and original_msg_post then
    msg.post = original_msg_post
    msg_hooked = false
  end
  installed = false
  active_counts = {}
  play_ids = {}
  if should_emit_logs() then
    print("[AUDIO_HOOK] Sound wrappers uninstalled, originals restored")
  end
end

--- Check if wrappers are currently installed
function M.is_installed()
  return installed
end

return M
