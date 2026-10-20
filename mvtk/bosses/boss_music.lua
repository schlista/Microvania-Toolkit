--- Boss Music Controller
-- Encapsulates boss fight music management. Supports two modes:
--   "controller" — uses Audio.set_boss_theme() for the audio controller
--   "direct"     — plays a sound URL directly (loop)
--
-- boss_manager calls push(boss_id, audio_config) on spawn and pop(boss_id) on
-- defeat / cleanup. The module handles dedup, stop-before-start, and
-- block_music_requests so room music doesn't stomp over the boss theme.
--
-- @module boss_music

local Util = require "mvtk.core.util"
local Audio = Util.require_module("mvtk.audio.audio")
local C = require "mvtk.core.constants"
local SafeSound = require "mvtk.audio.safe_sound"

local M = {}

-- Debug-gate
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.bosses and _Dbg.bosses.manager then
        _orig_print(...)
    end
end

-- Internal state
local state = {
    mode = nil,       -- "controller" | "direct" | nil
    boss_id = nil,
    theme_id = nil,
    url = nil,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function extract_theme_name(value)
    if type(value) ~= "string" or value == "" then return nil end
    local fragment = value:match("#([%w_%-%]+)$")
    if fragment and fragment ~= "" then return fragment end
    local name = value:match("/([^/#]+)%.sound$")
    if name and name ~= "" then return name end
    name = value:match("/([^/#]+)%.ogg$")
    if name and name ~= "" then return name end
    return value
end

local function resolve_theme_id(value, visited)
    if not value then return nil end
    if type(value) == "string" then return extract_theme_name(value) end
    if type(value) == "table" then
        visited = visited or {}
        if visited[value] then return nil end
        visited[value] = true
        for _, key in ipairs({ "theme", "track", "id", "name", "cue", "label", "key" }) do
            local r = resolve_theme_id(value[key], visited)
            if r then return r end
        end
        for _, key in ipairs({ "url", "path", "resource", "src" }) do
            local r = extract_theme_name(value[key])
            if r then return r end
        end
    end
    return nil
end

local function resolve_url(value)
    if not value then return nil end
    if type(value) == "string" then return value end
    if type(value) == "table" then return value.url or value.cue or value.path end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Start boss music for a given boss.
-- @param boss_id   Unique boss id.
-- @param audio_cfg The boss config's `audio` table. May contain `music_theme`,
--                  `theme`, `music` fields (string or table).
function M.push(boss_id, audio_cfg)
    if not audio_cfg then return end

    local theme_id = resolve_theme_id(audio_cfg.music_theme or audio_cfg.theme or audio_cfg.music)
    local music_url = resolve_url(audio_cfg.music)

    print(string.format("[BOSS_MUSIC] push boss=%s theme=%s url=%s",
        tostring(boss_id), tostring(theme_id), tostring(music_url)))

    if theme_id then
        -- Already playing this exact theme for this boss?
        if state.mode == "controller" and state.theme_id == theme_id and state.boss_id == boss_id then
            return
        end
        -- Stop whatever was playing before
        M.pop()
        Audio.block_music_requests(false)
        Audio.set_boss_theme(theme_id, true)
        state.mode = "controller"
        state.boss_id = boss_id
        state.theme_id = theme_id

    elseif music_url then
        if state.mode == "direct" and state.url == music_url and state.boss_id == boss_id then
            return
        end
        M.pop()
        Audio.block_music_requests(true, "boss_direct")
        local audio_url = C and C.URL and C.URL.AUDIO
        if audio_url then
            pcall(msg.post, audio_url, hash("stop_all_music"), {})
        end
        local ok, err = SafeSound.play(music_url, { loop = true })
        if not ok then
            print(string.format("[BOSS_MUSIC] play failed: %s", tostring(err)))
            return
        end
        state.mode = "direct"
        state.boss_id = boss_id
        state.url = music_url
    end
end

--- Stop boss music.
-- @param boss_id  Optional: only stop if this boss owns the music.
function M.pop(boss_id)
    if not state.mode then return end
    if boss_id and state.boss_id and boss_id ~= state.boss_id then return end

    print(string.format("[BOSS_MUSIC] pop boss=%s mode=%s", tostring(boss_id or state.boss_id), tostring(state.mode)))

    if state.mode == "controller" and state.theme_id then
        Audio.set_boss_theme(state.theme_id, false)
        Audio.block_music_requests(false)
    elseif state.mode == "direct" and state.url then
        SafeSound.stop(state.url)
        Audio.block_music_requests(false)
    end

    state.mode = nil
    state.boss_id = nil
    state.theme_id = nil
    state.url = nil
end

--- True if boss music is currently playing.
function M.is_playing()
    return state.mode ~= nil
end

--- Get the current boss_id owning the music (or nil).
function M.get_active_boss()
    return state.boss_id
end

--- Get the resolved theme_id (or nil when in direct mode / idle).
function M.get_theme_id()
    return state.theme_id
end

return M
