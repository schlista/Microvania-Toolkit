-- Published camera view state, including immediate camera-message changes.
--
-- Subscribers registered with on_publish run synchronously inside publish,
-- so every camera-driven compositor (Tiled parallax, starter parallax,
-- lighting) positions itself from exactly the view the render projection
-- uses this frame. Registration order does not matter: hooks run in sorted
-- key order, and a failing hook is reported once and never blocks the camera.
-- Durable observers use on_commit instead: camera.script commits only its
-- final late_update view, so superseded message projections grant no discovery.

local M = {
    has_value = false,
    x = 0,
    y = 0,
    zoom = 1,
}

local publish_hooks = { callbacks = {}, order = {}, reported_errors = {} }
local commit_hooks = { callbacks = {}, order = {}, reported_errors = {} }
local published_bounds = {}
local publication = 0
local committed_publication = 0

local function rebuild_order(registry)
    local order = {}
    for key in pairs(registry.callbacks) do
        order[#order + 1] = key
    end
    table.sort(order)
    registry.order = order
end

local function register_hook(registry, key, fn)
    if key == nil or type(fn) ~= "function" then
        return false
    end
    key = tostring(key)
    local is_new = registry.callbacks[key] == nil
    registry.callbacks[key] = fn
    registry.reported_errors[key] = nil
    if is_new then
        rebuild_order(registry)
    end
    return true
end

local function remove_hook(registry, key)
    if key == nil then
        return false
    end
    key = tostring(key)
    if registry.callbacks[key] == nil then
        return false
    end
    registry.callbacks[key] = nil
    registry.reported_errors[key] = nil
    rebuild_order(registry)
    return true
end

local function dispatch(registry, kind, x, y, zoom, view_bounds)
    -- Iterate a snapshot so a hook that unregisters itself cannot disturb
    -- the pass.
    local order = registry.order
    for i = 1, #order do
        local key = order[i]
        local fn = registry.callbacks[key]
        if fn then
            local ok, err = pcall(fn, x, y, zoom, view_bounds)
            if not ok and not registry.reported_errors[key] then
                registry.reported_errors[key] = true
                print(string.format("[CAMERA_STATE] %s hook '%s' failed: %s",
                    kind, tostring(key), tostring(err)))
            end
        end
    end
end

--- Register (or replace) a publish hook.
-- @param key Unique string identifying the subscriber
-- @param fn function(x, y, zoom, view_bounds) called inside every publish.
-- view_bounds is the reused world rectangle for this frame, or nil when the
-- publisher has no projection extents. Copy it if retaining an earlier view.
function M.on_publish(key, fn)
    return register_hook(publish_hooks, key, fn)
end

function M.off_publish(key)
    return remove_hook(publish_hooks, key)
end

--- Subscribe to final camera frames rather than immediate message changes.
-- Receives the same arguments as on_publish, but only from commit().
function M.on_commit(key, fn)
    return register_hook(commit_hooks, key, fn)
end

function M.off_commit(key)
    return remove_hook(commit_hooks, key)
end

function M.hook_count()
    return #publish_hooks.order + #commit_hooks.order
end

--- Drop every hook. Intended for tests; runtime subscribers unhook in final().
function M.clear_hooks()
    publish_hooks = { callbacks = {}, order = {}, reported_errors = {} }
    commit_hooks = { callbacks = {}, order = {}, reported_errors = {} }
end

function M.publish(x, y, zoom, half_width, half_height)
    M.x = x
    M.y = y
    M.zoom = zoom
    M.has_value = true
    publication = publication + 1
    half_width, half_height = tonumber(half_width), tonumber(half_height)
    if half_width and half_height and half_width > 0 and half_height > 0
        and half_width < math.huge and half_height < math.huge then
        published_bounds.min_x, published_bounds.max_x = x - half_width, x + half_width
        published_bounds.min_y, published_bounds.max_y = y - half_height, y + half_height
        M.view_bounds = published_bounds
    else
        -- Legacy publishers must not accidentally reuse a previous rectangle.
        M.view_bounds = nil
    end

    dispatch(publish_hooks, "publish", x, y, zoom, M.view_bounds)
end

--- Commit the latest publication once. The camera calls this only after a
-- late_update integration actually renders a view; stale/no-op frames cannot
-- commit a preceding message or previous-frame projection.
function M.commit()
    if not M.has_value or publication == committed_publication then return false end
    committed_publication = publication
    dispatch(commit_hooks, "commit", M.x, M.y, M.zoom, M.view_bounds)
    return true
end

function M.get()
    return M.has_value, M.x, M.y, M.zoom
end

--- Clear the published values. Hooks are owned by their subscribers and stay
-- registered; use clear_hooks() to drop them.
function M.reset()
    M.has_value = false
    M.x = 0
    M.y = 0
    M.zoom = 1
    M.view_bounds = nil
    committed_publication = publication
end

return M
