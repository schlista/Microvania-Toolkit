--- Boss UI Registry
-- Decouples boss_manager from the concrete boss health bar URL.
-- The boss HUD gui_script calls register() from init() with its own URL;
-- boss_manager uses send() which dispatches to every registered listener.
-- If no HUD is registered, messages are silently dropped.
--
-- @module boss_ui

local M = {}

local listeners = {}

-- Register a HUD listener URL (or string path). Safe to call multiple times.
function M.register(url)
    if not url then return end
    local key = tostring(url)
    listeners[key] = url
end

-- Unregister a previously registered URL.
function M.unregister(url)
    if not url then return end
    listeners[tostring(url)] = nil
end

-- Dispatch a message to every registered HUD. Failures are swallowed so a
-- missing/renamed GUI doesn't break boss logic.
function M.send(message_id, message)
    local hashed = type(message_id) == "string" and hash(message_id) or message_id
    for _, url in pairs(listeners) do
        pcall(msg.post, url, hashed, message or {})
    end
end

-- Number of active listeners (for debug).
function M.count()
    local n = 0
    for _ in pairs(listeners) do n = n + 1 end
    return n
end

return M
