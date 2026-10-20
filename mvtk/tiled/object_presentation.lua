-- Shared state for baked Tiled artwork. Keys include the collection socket and
-- instance path, so streamed copies never share presentation or trigger state.
local M = {}
local entries = {}
local function key(owner)
    local url = msg.url(owner or ".")
    return tostring(url.socket) .. ":" .. tostring(url.path)
end
local function entry(owner)
    local id = key(owner)
    entries[id] = entries[id] or { state = "default", removed = false }
    return entries[id]
end
function M.attach(owner, callback, bounds, animation)
    local e = entry(owner)
    e.callback, e.bounds = callback, bounds
    e.animation = animation
    callback(e)
end
-- A behavior can own the clock so damage and the displayed frame agree,
-- including after disabling, pausing, or streaming a room back in.
function M.animation(owner) return entry(owner).animation end
function M.animate(time, owner) entry(owner).animation_time = time end
function M.detach(owner)
    entries[key(owner)] = nil
end
function M.release_unbound(owner)
    local id = key(owner)
    if entries[id] and not entries[id].callback then entries[id] = nil end
end
-- Restoring state never produces feedback. Missing alternate art retains the
-- default artwork; availability and removal remain decisions of the behavior.
function M.restore(state, removed, owner)
    local e = entry(owner)
    if state then e.state = state end
    if removed ~= nil then e.removed = removed end
    if e.callback then e.callback(e) end
end
function M.emit(event, state, removed, owner)
    local e = entry(owner)
    if e.removed then return false end
    if state then e.state = state end
    if removed then e.removed = true end
    if e.callback then e.callback(e, event)
    else e.pending_event = event end
    return true
end
function M.visible(visible, owner)
    local e = entry(owner)
    e.visible = visible
    if e.callback then e.callback(e) end
end
-- Optional transforms for the default image when a behavior state has no
-- dedicated artwork. Explicit art_state images always take precedence.
function M.set_state_fallbacks(fallbacks, owner)
    local e = entry(owner)
    e.fallbacks = fallbacks
    if e.callback then e.callback(e) end
end
function M.take_pending(owner)
    local e = entry(owner)
    local event = e.pending_event
    e.pending_event = nil
    return event
end
function M.contains(owner, position)
    local e = entries[key(owner)]
    if not e or not e.bounds then return nil end
    if e.removed then return false end
    return e.bounds(position)
end
function M.is_removed(owner)
    local e = entries[key(owner)]
    return e and e.removed == true or false
end
function M.is_authored(owner)
    local e = entries[key(owner)]
    return e and e.bounds ~= nil or false
end
return M
