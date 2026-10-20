-- mvtk/map/minimap/gate_markers.lua
-- Minimap integration for showing gate status
-- Shows gates with different colors based on locked/accessible/unlocked state

local GateManager = require "mvtk.world.gates.gate_manager"
local Time = require "mvtk.core.time"
local Discovery = require "mvtk.map.discovery"
local Flags = require "mvtk.core.flags"

local M = {}

local MINIMAP_URL = "main:/minimap_gui#minimap"

-- Color scheme for gate markers
M.COLORS = {
    LOCKED = vmath.vector4(0.8, 0.2, 0.2, 0.9),      -- Red - can't open yet
    ACCESSIBLE = vmath.vector4(1.0, 0.8, 0.2, 0.9),  -- Yellow - you can open this now!
    UNLOCKED = vmath.vector4(0.2, 0.8, 0.2, 0.5),    -- Green/transparent - already open
    HIDDEN = vmath.vector4(0.5, 0.5, 0.5, 0.3),      -- Gray - undiscovered
}

-- Gate marker visual settings
M.MARKER_SIZE = 8   -- Pixels
M.MARKER_SHAPE = "square"  -- "square", "circle", "diamond"
M.SHOW_UNLOCKED = false  -- Hide markers for unlocked gates
M.PULSE_ACCESSIBLE = true  -- Pulse animation for gates you can now open

-- Forward declarations for local helper functions
local should_draw_gate
local draw_gate_marker
local is_room_explored
local get_gate_color
local world_to_minimap
local draw_square
local draw_circle
local draw_diamond
local draw_gate_icon
local draw_worldmap_gate
local world_to_worldmap
local get_gate_label

-----------------------------------------------------------
-- Minimap Integration
-----------------------------------------------------------

function M.draw_gate_markers(minimap_context)
    -- Called by minimap during rendering
    local gates = GateManager.get_all_gates()

    for gate_id, gate in pairs(gates) do
        if should_draw_gate(gate) then
            draw_gate_marker(minimap_context, gate)
        end
    end
end

should_draw_gate = function(gate)
    -- Don't show unlocked gates if setting is off
    if gate.unlocked and not M.SHOW_UNLOCKED then
        return false
    end

    -- Only show gates in explored rooms
    local room_id = gate.config.room_id
    if not is_room_explored(room_id) then
        return false
    end

    return true
end

is_room_explored = function(room_id)
    return Discovery.is_visited(room_id)
end

-----------------------------------------------------------
-- Drawing Functions
-----------------------------------------------------------

draw_gate_marker = function(ctx, gate)
    local pos = gate.config.position
    if not pos then return end

    -- Convert world position to minimap coordinates
    local minimap_x, minimap_y = world_to_minimap(ctx, pos.x, pos.y)

    -- Determine color based on gate state
    local color = get_gate_color(gate)

    -- Draw marker shape
    if M.MARKER_SHAPE == "square" then
        draw_square(ctx, minimap_x, minimap_y, M.MARKER_SIZE, color)
    elseif M.MARKER_SHAPE == "circle" then
        draw_circle(ctx, minimap_x, minimap_y, M.MARKER_SIZE / 2, color)
    elseif M.MARKER_SHAPE == "diamond" then
        draw_diamond(ctx, minimap_x, minimap_y, M.MARKER_SIZE, color)
    end

    -- Optional: Draw icon for gate type
    if ctx.show_gate_icons then
        draw_gate_icon(ctx, minimap_x, minimap_y, gate)
    end
end

get_gate_color = function(gate)
    if gate.unlocked then
        return M.COLORS.UNLOCKED
    end

    -- Check if player can open this gate now
    if GateManager.check_gate_requirements(gate.id) then
        local color = M.COLORS.ACCESSIBLE
        -- Pulse animation
        if M.PULSE_ACCESSIBLE then
            local pulse = math.abs(math.sin(Time.gettime() * 3))
            color = vmath.vector4(color.x, color.y, color.z, 0.6 + pulse * 0.4)
        end
        return color
    end

    return M.COLORS.LOCKED
end

world_to_minimap = function(ctx, world_x, world_y)
    -- Convert world coordinates to minimap pixel coordinates
    -- This depends on your minimap implementation
    local scale = ctx.scale or 0.1
    local offset_x = ctx.offset_x or 0
    local offset_y = ctx.offset_y or 0

    local minimap_x = (world_x * scale) + offset_x
    local minimap_y = (world_y * scale) + offset_y

    return minimap_x, minimap_y
end

-----------------------------------------------------------
-- Shape Drawing Helpers
-----------------------------------------------------------

draw_square = function(ctx, x, y, size, color)
    -- Draw filled square at minimap position
    -- Implementation depends on your minimap rendering system
    if ctx.draw_rect then
        ctx.draw_rect(x - size/2, y - size/2, size, size, color)
    end
end

draw_circle = function(ctx, x, y, radius, color)
    if ctx.draw_circle then
        ctx.draw_circle(x, y, radius, color)
    end
end

draw_diamond = function(ctx, x, y, size, color)
    if ctx.draw_polygon then
        local half = size / 2
        local points = {
            {x = x, y = y + half},        -- Top
            {x = x + half, y = y},        -- Right
            {x = x, y = y - half},        -- Bottom
            {x = x - half, y = y}         -- Left
        }
        ctx.draw_polygon(points, color)
    end
end

draw_gate_icon = function(ctx, x, y, gate)
    -- Draw small icon representing gate type
    local gate_type = gate.config.gate_type

    local icon_map = {
        dash_barrier = "icon_dash",
        double_jump_ledge = "icon_jump",
        breakable_wall = "icon_break",
        key_door_red = "icon_key_red",
        key_door_blue = "icon_key_blue",
        key_door_gold = "icon_key_gold",
    }

    local icon = icon_map[gate_type]
    if icon and ctx.draw_icon then
        ctx.draw_icon(x, y, icon, 0.5)  -- 50% scale
    end
end

-----------------------------------------------------------
-- World Map Integration
-----------------------------------------------------------

function M.draw_world_map_gates(worldmap_context)
    -- Draw gates on full world map view
    -- Similar to minimap but different scale/detail
    local gates = GateManager.get_all_gates()

    for gate_id, gate in pairs(gates) do
        if gate.config.position then
            draw_worldmap_gate(worldmap_context, gate)
        end
    end
end

draw_worldmap_gate = function(ctx, gate)
    local pos = gate.config.position
    local map_x, map_y = world_to_worldmap(ctx, pos.x, pos.y)

    local color = get_gate_color(gate)

    -- Draw with label on world map
    if ctx.draw_marker then
        local label = get_gate_label(gate)
        ctx.draw_marker(map_x, map_y, label, color)
    end
end

world_to_worldmap = function(ctx, world_x, world_y)
    local scale = ctx.world_scale or 0.05
    local offset_x = ctx.world_offset_x or 0
    local offset_y = ctx.world_offset_y or 0

    return (world_x * scale) + offset_x, (world_y * scale) + offset_y
end

get_gate_label = function(gate)
    local config = gate.config

    if gate.unlocked then
        return "OK"  -- Checkmark
    end

    -- Show what's required
    if config.type == "ability_requirement" then
        return "L"  -- Lock
    elseif config.type == "item_requirement" then
        return "K"  -- Key
    elseif config.type == "destructible" then
        return "X"  -- Break
    end

    return "?"
end

-----------------------------------------------------------
-- Legend/HUD Integration
-----------------------------------------------------------

function M.get_legend_entries()
    -- Return legend entries for minimap legend
    return {
        {
            color = M.COLORS.LOCKED,
            label = "Gate - Locked",
            icon = "gate_locked"
        },
        {
            color = M.COLORS.ACCESSIBLE,
            label = "Gate - Can Open",
            icon = "gate_accessible"
        },
        {
            color = M.COLORS.UNLOCKED,
            label = "Gate - Open",
            icon = "gate_open"
        }
    }
end

function M.get_nearby_gates(player_pos, radius)
    -- Get gates within radius of player (for HUD hints)
    local gates = GateManager.get_all_gates()
    local nearby = {}

    for gate_id, gate in pairs(gates) do
        if not gate.unlocked then
            local gate_pos = gate.config.position
            if gate_pos then
                local dist = vmath.length(vmath.vector3(
                    gate_pos.x - player_pos.x,
                    gate_pos.y - player_pos.y,
                    0
                ))

                if dist <= radius then
                    table.insert(nearby, {
                        gate = gate,
                        distance = dist
                    })
                end
            end
        end
    end

    -- Sort by distance
    table.sort(nearby, function(a, b) return a.distance < b.distance end)

    return nearby
end

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

function M.set_colors(color_scheme)
    -- Allow developers to customize gate colors
    for key, color in pairs(color_scheme) do
        if M.COLORS[key] then
            M.COLORS[key] = color
        end
    end
end

function M.set_marker_style(size, shape, show_unlocked, pulse_accessible)
    M.MARKER_SIZE = size or M.MARKER_SIZE
    M.MARKER_SHAPE = shape or M.MARKER_SHAPE
    M.SHOW_UNLOCKED = show_unlocked ~= nil and show_unlocked or M.SHOW_UNLOCKED
    M.PULSE_ACCESSIBLE = pulse_accessible ~= nil and pulse_accessible or M.PULSE_ACCESSIBLE
end

-----------------------------------------------------------
-- Event Handlers
-----------------------------------------------------------

function M.on_gate_unlocked(gate_id)
    -- Called when a gate is unlocked
    -- Can trigger minimap update/animation
    print(string.format("[MINIMAP_GATES] Gate unlocked: %s", gate_id))

    -- Post message to minimap to refresh
    pcall(msg.post, MINIMAP_URL, hash("refresh_gates"))
end

function M.on_ability_unlocked(ability_id)
    -- Called when player unlocks an ability
    -- Check if any gates are now accessible
    local gates = GateManager.get_all_gates()
    local newly_accessible = {}

    for gate_id, gate in pairs(gates) do
        if not gate.unlocked then
            if GateManager.check_gate_requirements(gate_id) then
                table.insert(newly_accessible, gate)
            end
        end
    end

    if #newly_accessible > 0 then
        print(string.format("[MINIMAP_GATES] %d gates now accessible!", #newly_accessible))
        -- Trigger minimap highlight/notification
        pcall(msg.post, MINIMAP_URL, hash("gates_accessible"), {
            count = #newly_accessible
        })
    end
end

local cached_markers = {}
local cached_gate_revision, cached_discovery_revision, cached_flags_revision, cached_tick
local marker_version = 0
function M.collect_gate_markers()
    -- Resource/timed requirements may change without a gate event. Refresh
    -- those at 4 Hz; discovery and flag changes invalidate immediately.
    local gates_revision, discovery_revision = GateManager.get_gate_revision(), Discovery.revision()
    local flags_revision, tick = Flags.revision(), math.floor(Time.gettime() * 4)
    if gates_revision == cached_gate_revision and discovery_revision == cached_discovery_revision
        and flags_revision == cached_flags_revision and tick == cached_tick then return cached_markers end
    cached_gate_revision, cached_discovery_revision = gates_revision, discovery_revision
    cached_flags_revision, cached_tick = flags_revision, tick
    local markers = {}
    local gates = GateManager.get_map_gates()
    for gate_id, gate in pairs(gates) do
        local config = gate.config or {}
        local pos = config.position
        if pos and config.room_id and Discovery.is_visible(pos.x, pos.y, config.room_id) then
            local state
            if gate.unlocked then
                state = "unlocked"
            elseif GateManager.check_gate_requirements(gate_id) then
                state = "accessible"
            else
                state = "locked"
            end
            markers[#markers + 1] = {
                gate_id = gate_id,
                gate_type = config.gate_type,
                room_id = config.room_id,
                x = pos.x,
                y = pos.y,
                state = state,
                temporary = gate.temporary and true or false,
            }
        end
    end

    table.sort(markers, function(a, b) return tostring(a.gate_id) < tostring(b.gate_id) end)
    cached_markers = markers
    marker_version = marker_version + 1
    return markers
end

function M.get_marker_version()
    return marker_version
end

return M
