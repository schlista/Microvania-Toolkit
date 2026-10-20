-- mvtk/fx/hitstop.lua
-- ============================================================================
-- Hitstop (Freeze Frames) System
-- ============================================================================
-- Creates brief pauses in gameplay when hits connect for impactful combat feel.
-- Uses Defold's time scaling to slow down the entire game briefly (except audio).
--
-- Intensities:
--   Light: 25ms - Normal hits
--   Medium: 50ms - Heavy attacks (DEFAULT)
--   Heavy: 100ms - Charged attacks, special moves
--   Critical: 150ms - Killing blows, boss hits
--
-- Usage:
--   Hitstop.start_hitstop(nil, "heavy")  -- Start heavy hitstop
--   Hitstop.on_hit_light()  -- Convenience method
--   Hitstop.update(dt)  -- Call each frame
--
-- The boot host owns the real-time recovery clock, including when gameplay is frozen.

local M = {}
local Pause = require "mvtk.core.pause"

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- Hitstop durations in seconds (frames calculated at 60fps)
local DEFAULT_HITSTOP_DURATION = 0.05  -- 50ms (3 frames at 60fps) - Medium intensity
local HEAVY_HITSTOP_DURATION = 0.1     -- 100ms (6 frames at 60fps) - Heavy intensity
local CRITICAL_HITSTOP_DURATION = 0.15 -- 150ms (9 frames at 60fps) - Critical intensity

-- ============================================================================
-- STATE
-- ============================================================================

-- Whether hitstop is currently active
local hitstop_active = false

-- Remaining duration of current hitstop (seconds)
local hitstop_timer = 0


-- Callbacks to call when current hitstop ends
local hitstop_callbacks = {}

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

-- Initialize the hitstop system
-- Resets all state to defaults.
-- Call this at game start or when resetting game state.
function M.init()
    hitstop_active = false
    hitstop_timer = 0
    hitstop_callbacks = {}
end

-- ============================================================================
-- UPDATE LOOP
-- ============================================================================

-- Update hitstop timer each frame
-- dt: Delta time in seconds
--
-- Call this from your main update loop. Decrements the hitstop timer
-- and ends hitstop when timer reaches zero.
function M.update(dt)
    if not hitstop_active then return end

    hitstop_timer = Pause.hitstop_remaining()

    -- Timer expired - end hitstop
    if hitstop_timer <= 0 then
        M.end_hitstop()
    end
end

-- ============================================================================
-- HITSTOP CONTROL
-- ============================================================================

-- Start a hitstop effect
-- duration: Duration in seconds (optional, calculated from intensity if nil)
-- intensity: Intensity level string - "light", "medium", "heavy", "critical" (optional)
-- on_complete: Callback function() to call when hitstop ends (optional)
--
-- Example:
--   Hitstop.start_hitstop(0.1, "heavy", function() print("Hitstop ended!") end)
--   Hitstop.start_hitstop(nil, "critical")  -- Use intensity-based duration
function M.start_hitstop(duration, intensity, on_complete)
    -- Calculate duration from intensity if not explicitly provided
    if not duration then
        if intensity == "light" then
            duration = DEFAULT_HITSTOP_DURATION * 0.5  -- 25ms
        elseif intensity == "medium" then
            duration = DEFAULT_HITSTOP_DURATION  -- 50ms
        elseif intensity == "heavy" then
            duration = HEAVY_HITSTOP_DURATION  -- 100ms
        elseif intensity == "critical" then
            duration = CRITICAL_HITSTOP_DURATION  -- 150ms
        else
            duration = DEFAULT_HITSTOP_DURATION  -- Default to medium
        end
    end

    -- Activate hitstop
    hitstop_active = true
    hitstop_timer = duration

    -- Freeze gameplay through the shared effect clock.
    Pause.hitstop(duration)

    -- Register completion callback
    if on_complete then
        table.insert(hitstop_callbacks, on_complete)
    end

    print(string.format("[HITSTOP] Started - Duration: %.3fs, Intensity: %s", duration, intensity or "default"))
end

-- End the current hitstop effect immediately
-- Restores normal time scale and triggers all registered callbacks.
function M.end_hitstop()
    if not hitstop_active then return end

    hitstop_active = false
    hitstop_timer = 0

    -- Restore normal time scale
    Pause.clear_hitstop()

    print("[HITSTOP] Ended - Normal time resumed")

    -- Call all registered completion callbacks (protected)
    for _, callback in ipairs(hitstop_callbacks) do
        pcall(callback)
    end
    hitstop_callbacks = {}
end

-- ============================================================================
-- QUERY FUNCTIONS
-- ============================================================================

-- Check if hitstop is currently active
-- Returns: true if hitstop active, false otherwise
function M.is_active()
    return hitstop_active
end

-- Get remaining hitstop duration
-- Returns: Remaining duration in seconds (0 if not active)
function M.get_remaining()
    return hitstop_timer
end

-- ============================================================================
-- CONVENIENCE FUNCTIONS
-- ============================================================================

-- Trigger light hitstop (25ms) - for normal hits
function M.on_hit_light()
    M.start_hitstop(nil, "light")
end

-- Trigger medium hitstop (50ms) - for heavy attacks
function M.on_hit_medium()
    M.start_hitstop(nil, "medium")
end

-- Trigger heavy hitstop (100ms) - for charged attacks, special moves
function M.on_hit_heavy()
    M.start_hitstop(nil, "heavy")
end

-- Trigger critical hitstop (150ms) - for killing blows, boss hits
function M.on_hit_critical()
    M.start_hitstop(nil, "critical")
end

return M
