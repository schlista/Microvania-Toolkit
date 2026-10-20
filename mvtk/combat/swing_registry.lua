-- mvtk/combat/swing_registry.lua
-- Swing-level hit dedup registry.
--
-- A "swing" is one player attack window — possibly spawning multiple
-- overlapping hitboxes (e.g. a body box + a tip box). Each spawned
-- melee_hitbox.script tracks its own _hit_targets, which prevents the same
-- hitbox from hitting the same target twice but does NOT stop two sibling
-- hitboxes from each scoring a hit on the same enemy. This module gives all
-- hitboxes in the same swing a shared registry, so a target hit once during a
-- swing cannot be hit again until the next swing.
--
-- Enemy / boss hitboxes do not pass a swing_id; they continue to use the
-- per-instance _hit_targets table only. That keeps existing behavior for
-- non-player paths.

local M = {}

local TTL = 5.0  -- seconds; safety net to evict swings whose owners died
                 -- mid-attack and never called clear_swing.

-- swings[swing_id] = { last_seen = <time>, targets = { [target_key] = <time> } }
local swings = {}

local function now()
    return socket and socket.gettime and socket.gettime() or os.time()
end

local function ensure(swing_id)
    local entry = swings[swing_id]
    if not entry then
        entry = { last_seen = now(), targets = {} }
        swings[swing_id] = entry
    else
        entry.last_seen = now()
    end
    return entry
end

function M.has_hit(swing_id, target_key)
    if not swing_id or swing_id == "" then return false end
    local entry = swings[swing_id]
    if not entry then return false end
    return entry.targets[target_key] ~= nil
end

function M.mark_hit(swing_id, target_key)
    if not swing_id or swing_id == "" then return end
    if not target_key then return end
    local entry = ensure(swing_id)
    entry.targets[target_key] = now()
end

function M.clear_swing(swing_id)
    if not swing_id or swing_id == "" then return end
    swings[swing_id] = nil
end

-- Best-effort eviction of stale swings. Call sparingly (e.g. once per second
-- from a debug script) to bound memory if clear_swing is missed.
function M.gc(current_time)
    local t = current_time or now()
    for id, entry in pairs(swings) do
        if (t - (entry.last_seen or 0)) > TTL then
            swings[id] = nil
        end
    end
end

-- Test hook: wipe everything (used by unit tests to isolate cases).
function M._reset()
    swings = {}
end

return M
