-- mvtk/game/triggers/boss_arena.lua

local M = {}
local Ctx = nil

function M.configure(ctx)
    Ctx = ctx or Ctx
end

local function ctx()
    assert(Ctx, "mvtk.game.triggers.boss_arena is not configured")
    return Ctx
end

function M.on_trigger(self, trigger_data)
    local C = ctx()
    local lock = trigger_data and trigger_data.lock or trigger_data
    if not lock then
        return false
    end

    local player_room = trigger_data and trigger_data.player_room
    local player_pos = trigger_data and trigger_data.player_pos

    if C.room_matches(player_room, lock.room_id) and not lock.triggered_this_frame then
        local inside = C.player_overlaps_zone(player_pos, lock)
        if inside then
            lock.player_inside = true
            -- Baked marker registrations are delivered asynchronously. Retry
            -- while the player remains inside so an early arena registration
            -- cannot consume the only entry edge before its boss is known.
            if lock.lock_on_enter and not lock.triggered then
                local boss_id = C.resolve_boss_spawn_for_arena(self, lock)
                if boss_id then
                    C.trigger_boss_fight(self, boss_id)
                    lock.triggered = true
                    return true
                end
            end
        elseif not inside then
            lock.player_inside = false
        end
    else
        lock.player_inside = false
    end
    return false
end

function M.on_message(self, msg_id, msg, sender)
    local C = ctx()
    if msg_id == hash("trigger_boss_fight") then
        C.trigger_boss_fight(self, msg and msg.boss_id)
        return true
    end
    return false
end

return M
