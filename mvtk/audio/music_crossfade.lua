-- mvtk/audio/music_crossfade.lua
-- Music resolution and crossfade helpers extracted from audio_controller.script.

local SafeSound = require "mvtk.audio.safe_sound"

local M = {}

local current = { theme = nil, area = nil, boss = nil, track = nil }
local get_time = function() return os.time() end
local safe_sound_stop = function() end
local safe_sound_set_gain = function() end
local debug_print = function() end
local dump_music_state = function() end
local snapshot_music_flags = function() end
local audit_music_components = function() end

function M.configure(opts)
  opts = opts or {}
  current = opts.current or current
  get_time = opts.get_time or get_time
  safe_sound_stop = opts.safe_sound_stop or safe_sound_stop
  safe_sound_set_gain = opts.safe_sound_set_gain or safe_sound_set_gain
  debug_print = opts.debug_print or debug_print
  dump_music_state = opts.dump_music_state or dump_music_state
  snapshot_music_flags = opts.snapshot_music_flags or snapshot_music_flags
  audit_music_components = opts.audit_music_components or audit_music_components
end

function M.stop_all_music(self)
  if not (self and self._music) then return end

  -- Stop all music tracks
  for name, url in pairs(self._music) do
    safe_sound_stop(self, url, name)
    if self._music_playing then
      self._music_playing[name] = false
    end
  end

  -- Clear current track state (allows new music to play)
  current.track = nil
  current.theme = nil

  snapshot_music_flags(self, "stop_all_music_complete")
  audit_music_components(self, "stop_all_music_complete")
end

function M.resolve_track(self, id)
  if not id then
    return nil, nil
  end

  -- Map theme name to track ID (or use ID directly)
  local key = nil
  if self._music_map_hash and self._music_map_hash[id] then
    key = self._music_map_hash[id]
  elseif self._music_hash and self._music_hash[id] then
    key = self._music_hash[id]
  else
    key = self._music_map[id] or id
  end
  local url = self._music and self._music[key]

  -- No registered track for this id. Historically this fell back to
  -- self._music_map.default (graveyard_1), which silently played the WRONG
  -- song for any unknown/misspelled/stale selection and made room music feel
  -- permanently stuck on one track. Prefer honest "no change" (nil url) so the
  -- caller leaves the current track playing, plus a one-time warning so a bad
  -- selection is visible instead of masked.
  if not url then
    self._music_unresolved_warned = self._music_unresolved_warned or {}
    local warn_key = tostring(id)
    if not self._music_unresolved_warned[warn_key] then
      self._music_unresolved_warned[warn_key] = true
      print(string.format(
        "[MUSIC] No registered track for '%s' -- leaving current music unchanged. "
        .. "Pick a track that exists in developer/assets/music/ (add the file there, "
        .. "then run Project > Prepare & Check to register it).", warn_key))
    end
    return key, nil
  end

  return key, url
end

function M.cleanup_previous_fade(self)
  if self._fade_dir ~= 0 then
    debug_print("  Cleaning up previous crossfade state")
    if self._to_url then
      safe_sound_set_gain(self._to_url, 1.0, self._to)
      if self._to then
        self._music_playing[self._to] = true
      end
    end
    if self._from_url then
      debug_print("  >> Stopping lingering track:", tostring(self._from))
      safe_sound_stop(self, self._from_url, self._from)
    end
    self._from = nil
    self._from_url = nil
    self._to = nil
    self._to_url = nil
    self._fade_dir = 0
    self._fade_total = 0
    self._fader = 0
    dump_music_state(self, "cleanup_previous_fade")
    snapshot_music_flags(self, "cleanup_previous_fade")
    audit_music_components(self, "cleanup_previous_fade")
  end
end

function M.start_crossfade(self, from_key, to_key, duration)
  -- Validate before touching an active fade. resolve_track warns once for an
  -- unavailable selection; rejecting it must leave the current music intact.
  local resolved_to, to_url = M.resolve_track(self, to_key)
  if not to_url then return false end

  debug_print("=============================================")
  debug_print("start_crossfade() called")
  debug_print("  from_key:", tostring(from_key))
  debug_print("  to_key:", tostring(to_key))
  debug_print("  duration:", tostring(duration))

  M.cleanup_previous_fade(self)
  snapshot_music_flags(self, "after_cleanup_previous_fade")
  audit_music_components(self, "after_cleanup_previous_fade")

  local resolved_from, from_url = M.resolve_track(self, from_key)

  debug_print("  current.track:", tostring(current.track))
  debug_print("  resolved_from:", tostring(resolved_from))
  debug_print("  from_url:", tostring(from_url))
  debug_print("  resolved_to:", tostring(resolved_to))
  debug_print("  to_url:", tostring(to_url))

  -- Check if we're already playing this track
  if resolved_to == current.track then
    debug_print("*** ALREADY PLAYING THIS TRACK, SKIPPING ***")
    debug_print("=============================================")
    return
  end

  -- CRITICAL FIX: GLOBAL debounce to prevent ANY music changes too rapidly
  local now = get_time()
  local time_since_last_change = now - (self._last_any_music_change or 0)
  if time_since_last_change < 0.3 then
    debug_print(string.format("*** GLOBAL DEBOUNCE: Last music change was %.3fs ago, skipping (track: %s) ***", time_since_last_change, tostring(resolved_to)))
    debug_print("=============================================")
    return
  end

  -- CRITICAL FIX: Prevent rapid re-playing of the same track (per-track debounce)
  local last_play = self._last_play_time[resolved_to] or 0
  local time_since_last_play = now - last_play
  if time_since_last_play < 0.5 then
    debug_print(string.format("*** DEBOUNCE: Track %s was played %.3fs ago, skipping ***", tostring(resolved_to), time_since_last_play))
    debug_print("=============================================")
    return
  end

  self._from = resolved_from
  self._from_url = from_url
  self._to = resolved_to
  self._to_url = to_url

  local fade = math.max(0, tonumber(duration) or self.crossfade_time or 0.8)
  debug_print("  fade time:", fade)

  if fade < 0.001 then
    -- Instant transition (no crossfade)
    debug_print("INSTANT TRANSITION (no fade)")

    debug_print("  >> Clearing any currently playing music before start")
    M.stop_all_music(self)

    -- CRITICAL: Clear ALL playing flags and timestamps
    self._music_playing = {}
    self._last_play_time = {}
    snapshot_music_flags(self, "post_stop_all_music_instant")
    audit_music_components(self, "post_stop_all_music_instant")

    debug_print("  >> PLAYING new track:", tostring(resolved_to), "at gain 1.0")
    local ok, err = SafeSound.play(to_url, { gain = 1.0 })
    if not ok then
      debug_print("  >> *** PLAY FAILED ***:", err)
    else
      debug_print("  >> *** PLAY SUCCEEDED ***")
      safe_sound_set_gain(to_url, 1.0, resolved_to)
      if resolved_to then
        self._music_playing[resolved_to] = true
        self._last_play_time[resolved_to] = get_time()
      end
      self._last_any_music_change = get_time()
      dump_music_state(self, "instant_play_success")
      snapshot_music_flags(self, "instant_play_success")
      audit_music_components(self, "instant_play_success")
    end

    self._fade_total = 0
    self._fader = 0
    self._fade_dir = 0
    self._from = nil
    self._from_url = nil
    current.track = resolved_to
    debug_print("  current.track now set to:", current.track)
    debug_print("=============================================")
    return
  end

  -- Crossfade transition
  debug_print("CROSSFADE TRANSITION")
  self._fade_total = fade
  self._fader = fade
  self._fade_dir = 1

  -- CRITICAL FIX: Stop all tracks EXCEPT the ones involved in the crossfade
  debug_print("  >> Stopping unwanted tracks before crossfade")
  for name, url in pairs(self._music) do
    -- Don't stop the from or to tracks - we need them for the crossfade
    if name ~= resolved_from and name ~= resolved_to then
      debug_print("  >> Stopping extra track:", name)
      safe_sound_set_gain(url, 0.0, name)
      safe_sound_stop(self, url, name)
    end
  end
  snapshot_music_flags(self, "post_extra_stop")
  audit_music_components(self, "post_extra_stop")

  -- Stop the target track if it's already playing (but not the source)
  if resolved_to ~= resolved_from then
    debug_print("  >> Stopping target track to prevent layering:", tostring(resolved_to))
    if self._music_playing[resolved_to] then
      debug_print("  >> NOTE: Track flagged playing before crossfade restart:", tostring(resolved_to))
    end
    safe_sound_stop(self, to_url, resolved_to)
  end

  -- Start the new track at zero volume
  debug_print("  >> PLAYING new track:", tostring(resolved_to), "at gain 0.0 (will fade in)")
  local ok, err = SafeSound.play(to_url, { gain = 0.0 })
  if not ok then
    debug_print("  >> *** PLAY FAILED ***:", err)
    self._fade_dir = 0
    self._from = nil
    self._from_url = nil
    self._to = nil
    self._to_url = nil
    debug_print("=============================================")
    return
  else
    debug_print("  >> *** PLAY SUCCEEDED ***")
    if resolved_to then
      self._music_playing[resolved_to] = true
      self._last_play_time[resolved_to] = get_time()
    end
    self._last_any_music_change = get_time()
    dump_music_state(self, "crossfade_new_play")
    snapshot_music_flags(self, "crossfade_new_play")
    audit_music_components(self, "crossfade_new_play")
  end

  -- Set initial gains
  if from_url then
    debug_print("  >> Setting old track gain to 1.0 (will fade out)")
    safe_sound_set_gain(from_url, 1.0, resolved_from)
  end
  safe_sound_set_gain(to_url, 0.0, resolved_to)

  current.track = resolved_to
  debug_print("  current.track now set to:", current.track)
  debug_print("  Crossfade in progress:", tostring(resolved_from), "->", tostring(resolved_to))
  debug_print("=============================================")
end

function M.apply_theme(self, theme_id, fade_time)
  debug_print("apply_theme() called: theme_id =", tostring(theme_id), "current.theme =", tostring(current.theme))
  if current.theme == theme_id then
    debug_print("  Theme already active, skipping")
    return
  end

  local from = current.track
  current.theme = theme_id
  M.start_crossfade(self, from, theme_id, fade_time or 0)
end

return M
