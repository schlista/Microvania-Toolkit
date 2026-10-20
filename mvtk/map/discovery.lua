-- Persistent room-local discovery from visits and the rendered camera view.
-- Streaming residency never grants discovery.
-- Rows are packed into byte strings (eight cells per byte) to keep saves small.
local Config = require("developer.config.runtime_settings").section("map_discovery",require "developer.config.map_discovery_settings")
local SecretVisibility = require "mvtk.map.secret_visibility"
local secret_rooms = SecretVisibility.compile(require "developer.config.secret_rooms")
local M = { explored = {}, markers = {} }
local state, bounds = {}, {}
local revision = 0
local restore_revision = 0
local rect_cache
local room_rect_cache = {}
local secret_hidden, secret_flags_revision = {}, nil
local secret_bounds = {}

local function normalize(id)
    if type(id) ~= "string" then return nil end
    return id:gsub("^developer/rooms/", ""):gsub("%.lua$", "")
end

local function changed(room_id)
    revision = revision + 1
    rect_cache = nil
    if room_id then room_rect_cache[room_id] = nil else room_rect_cache = {} end
end

local function sync_secrets()
    if not next(secret_rooms) then return end
    -- Lazy lookup avoids Flags -> Checkpoint -> Discovery module-load cycles.
    local flags = require "mvtk.core.flags"
    local current = flags.revision()
    if secret_flags_revision == current then return end
    secret_flags_revision = current
    for id, entries in pairs(secret_rooms) do
        local hidden, reveal = SecretVisibility.status(entries, flags)
        local dirty = secret_hidden[id] ~= hidden
        secret_hidden[id] = hidden
        local room = state.rooms[id]
        if reveal and (not room or not room.revealed) then
            room = room or { visited = false, revealed = false, rows = {} }
            state.rooms[id], room.revealed = room, true
            dirty = true
        end
        M.explored[id] = not hidden and room and room.visited or nil
        if dirty then changed(id) end
    end
end

function M.revision() sync_secrets(); return revision end
function M.restore_revision() return restore_revision end
function M.enabled() return Config.enabled ~= false end

function M.restore(data, legacy)
    state = { cell_size = math.max(1, tonumber(data and data.cell_size) or tonumber(Config.cell_size) or 256), rooms = {}, markers = M.markers }
    for id in pairs(M.explored) do M.explored[id] = nil end
    for id in pairs(M.markers) do M.markers[id] = nil end
    for id, marker in pairs(data and data.markers or {}) do
        if type(id) == "string" and type(marker) == "table" then
            -- Marker metadata contains only scalar values, never live GO URLs.
            local copy = {}
            for key, value in pairs(marker) do
                if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
                    copy[key] = value
                end
            end
            if type(copy.x) == "number" and type(copy.y) == "number" then M.markers[id] = copy end
        end
    end
    for id, room in pairs(data and data.rooms or {}) do
        local key = normalize(id)
        if key and type(room) == "table" then
            local entry = { visited = room.visited == true, revealed = room.revealed == true, rows = {} }
            for row, bytes in pairs(room.rows or {}) do
                if tonumber(row) and type(bytes) == "string" then entry.rows[tostring(row)] = bytes end
            end
            state.rooms[key] = entry
            if entry.visited then M.explored[key] = true end
        end
    end
    if not data then
        -- Older saves only knew whole rooms. Preserve their already-known map.
        for id, visited in pairs(legacy or {}) do
            local key = normalize(id)
            if key and visited then
                state.rooms[key] = { visited = true, revealed = true, rows = {} }
                M.explored[key] = true
            end
        end
    end
    restore_revision = restore_revision + 1
    secret_hidden, secret_flags_revision = {}, nil
    changed()
end

M.restore()

function M.capture() sync_secrets(); return state end

function M.set_rooms(rooms)
    bounds = {}
    for id, room in pairs(rooms or {}) do
        local key = normalize(id)
        if key then bounds[key] = room end
    end
    secret_bounds = {}
    for id, entries in pairs(secret_rooms) do
        if bounds[id] then secret_bounds[id] = SecretVisibility.bounds(bounds[id], entries) end
    end
    changed()
    sync_secrets()
end

local function room_state(id)
    local room = state.rooms[id]
    if not room then
        room = { visited = false, revealed = false, rows = {} }
        state.rooms[id] = room
    end
    return room
end

local function bit_is_set(bytes, x)
    local byte = bytes and bytes:byte(math.floor(x / 8) + 1) or 0
    return math.floor((byte or 0) / 2 ^ (x % 8)) % 2 == 1
end

local function reveal_cell(room, x, y)
    local key = tostring(y)
    local bytes = room.rows[key] or ""
    if bit_is_set(bytes, x) then return false end
    local index = math.floor(x / 8) + 1
    if #bytes < index then bytes = bytes .. string.rep("\0", index - #bytes) end
    room.rows[key] = bytes:sub(1, index - 1) .. string.char(bytes:byte(index) + 2 ^ (x % 8)) .. bytes:sub(index + 1)
    return true
end

function M.visit(id, position)
    sync_secrets()
    id = normalize(id)
    local b = id and bounds[id]
    if not b or secret_hidden[id] then return false end
    local room = room_state(id)
    local dirty = not room.visited
    room.visited, M.explored[id] = true, true
    if Config.mode == "room" then
        dirty = dirty or not room.revealed
        room.revealed = true
    elseif position and not room.revealed then
        local size = state.cell_size
        local radius = math.max(0, tonumber(Config.reveal_radius) or size * 2)
        local px, py = position.x - b.min_x, position.y - b.min_y
        local width, height = b.max_x - b.min_x, b.max_y - b.min_y
        -- Do not paint along the origin-to-spawn path or into a preloaded neighbor.
        if px >= 0 and py >= 0 and px <= width and py <= height then
            local x0 = math.max(0, math.floor((px - radius) / size))
            local x1 = math.min(math.ceil(width / size) - 1, math.floor((px + radius) / size))
            local y0 = math.max(0, math.floor((py - radius) / size))
            local y1 = math.min(math.ceil(height / size) - 1, math.floor((py + radius) / size))
            for y = y0, y1 do
                for x = x0, x1 do
                    local dx = math.max(x * size - px, 0, px - (x + 1) * size)
                    local dy = math.max(y * size - py, 0, py - (y + 1) * size)
                    if dx * dx + dy * dy <= radius * radius then
                        if reveal_cell(room, x, y) then dirty = true end
                    end
                end
            end
        end
    end
    if dirty then changed(id) end
    return dirty
end

-- Reveal cells intersecting the actual screen, clipped to each visible room.
-- The streaming caller supplies the visibility predicate so a loaded collection
-- waiting to be enabled cannot grant discovery. Seeing a neighbor does not
-- count as entering it; visit() remains the only source of the visited flag.
function M.reveal_view(view, room_visible)
    if type(view) ~= "table" then return false end
    for _, key in ipairs({ "min_x", "max_x", "min_y", "max_y" }) do
        local value = view[key]
        if type(value) ~= "number" or value ~= value or value <= -math.huge or value >= math.huge then
            return false
        end
    end
    if view.max_x <= view.min_x or view.max_y <= view.min_y then return false end
    sync_secrets()
    local dirty = false
    local size = state.cell_size
    for id, b in pairs(bounds) do
        if not secret_hidden[id] and (not room_visible or room_visible(id)) then
            local left, right = math.max(view.min_x, b.min_x), math.min(view.max_x, b.max_x)
            local bottom, top = math.max(view.min_y, b.min_y), math.min(view.max_y, b.max_y)
            -- Merely touching a room edge reveals no off-screen cells.
            if right > left and top > bottom then
                local room = room_state(id)
                if not room.revealed then
                    local room_dirty = false
                    local x0 = math.floor((left - b.min_x) / size)
                    local x1 = math.ceil((right - b.min_x) / size) - 1
                    local y0 = math.floor((bottom - b.min_y) / size)
                    local y1 = math.ceil((top - b.min_y) / size) - 1
                    for y = y0, y1 do
                        for x = x0, x1 do
                            if reveal_cell(room, x, y) then room_dirty = true end
                        end
                    end
                    if room_dirty then changed(id); dirty = true end
                end
            end
        end
    end
    return dirty
end

function M.reveal_room(id)
    sync_secrets()
    id = normalize(id)
    if not id or not bounds[id] or secret_hidden[id] then return false end
    local room = room_state(id)
    if room.revealed then return false end
    room.revealed = true
    changed(id)
    return true
end

function M.is_visited(id)
    sync_secrets()
    return M.explored[normalize(id)] == true
end

function M.is_secret_hidden(x, y, id)
    sync_secrets()
    if id and secret_hidden[normalize(id)] then return true end
    if x and y then
        for key, hidden in pairs(secret_hidden) do
            local b = hidden and secret_bounds[key]
            if b and x >= b.min_x and x < b.max_x and y >= b.min_y and y < b.max_y then
                return true
            end
        end
    end
    return false
end

function M.hidden_rectangles()
    sync_secrets()
    local rects = {}
    for id, hidden in pairs(secret_hidden) do
        if hidden and secret_bounds[id] then rects[#rects + 1] = secret_bounds[id] end
    end
    return rects
end

function M.mask_enabled()
    return M.enabled() or #M.hidden_rectangles() > 0
end

function M.marker_visible(marker)
    return not M.is_secret_hidden(marker.x, marker.y, marker.room_id)
        and (marker.visible_from_start or M.is_visible(marker.x, marker.y, marker.room_id))
end

function M.is_visible(x, y, id)
    if M.is_secret_hidden(x, y, id) then return false end
    if not M.enabled() then return true end
    local function visible(key, b)
        local room = state.rooms[key]
        if not room or x < b.min_x or x > b.max_x or y < b.min_y or y > b.max_y then return false end
        if room.revealed then return true end
        local size = state.cell_size
        -- Door markers can lie exactly on the outer room edge. Attribute that
        -- boundary to the last in-room cell instead of a nonexistent next one.
        local cx = math.min(math.ceil((b.max_x - b.min_x) / size) - 1, math.floor((x - b.min_x) / size))
        local cy = math.min(math.ceil((b.max_y - b.min_y) / size) - 1, math.floor((y - b.min_y) / size))
        return bit_is_set(room.rows[tostring(cy)], cx)
    end
    if id then
        local key = normalize(id)
        return key and bounds[key] and visible(key, bounds[key]) or false
    end
    for key, b in pairs(bounds) do if visible(key, b) then return true end end
    return false
end

-- Cache horizontal runs; texture generation does not scan the world per pixel.
function M.rectangles()
    sync_secrets()
    if rect_cache then return rect_cache end
    local rects = {}
    local size = state.cell_size
    for id, room in pairs(state.rooms) do
        local b = bounds[id]
        if b and not secret_hidden[id] then
            local room_rects = room_rect_cache[id]
            if not room_rects then
                room_rects = {}
                if room.revealed then
                    room_rects[#room_rects + 1] = b
                else
                    local columns = math.ceil((b.max_x - b.min_x) / size)
                    for row, bytes in pairs(room.rows) do
                        local y = tonumber(row)
                        local start
                        for x = 0, columns do
                            local shown = x < columns and bit_is_set(bytes, x)
                            if shown and not start then start = x end
                            if not shown and start then
                                room_rects[#room_rects + 1] = {
                                    min_x = b.min_x + start * size, max_x = math.min(b.max_x, b.min_x + x * size),
                                    min_y = b.min_y + y * size, max_y = math.min(b.max_y, b.min_y + (y + 1) * size),
                                }
                                start = nil
                            end
                        end
                    end
                end
                room_rect_cache[id] = room_rects
                end
            for _, rect in ipairs(room_rects) do rects[#rects + 1] = rect end
        end
    end
    rect_cache = rects
    return rects
end

return M
