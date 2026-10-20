--- Dynamic Parallax Layer Manager
-- Manages unlimited parallax layers with data from Tiled maps
-- Integrates with camera system for smooth parallax scrolling
--
-- Features:
-- - Dynamic layer creation from Tiled layer properties
-- - Per-layer parallax factors (from Tiled custom properties)
-- - Automatic sprite/texture assignment
-- - Camera-driven position updates
-- - Layer visibility and opacity control
--
-- @module parallax_layer_manager

local Util = require "mvtk.core.util"
local CameraState = require "mvtk.camera.camera_state"

local M = {}

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.tiled and _Dbg.tiled.spawner then
        _orig_print(...)
    end
end

-- Active parallax layer data
local layers = {}
local camera_url = nil
local anchor = vmath.vector3(0, 0, 0)
local enabled = true
local clip_rect = nil
local apply_clip_rect
local apply_view

local PUBLISH_HOOK_KEY = "parallax_layer_manager"

local function component_exists(url)
    if not url then return false end
    local ok, exists = pcall(go.exists, url)
    return ok and exists
end

local function is_zero_vector(v)
    if not v then
        return true
    end
    return math.abs(v.x or 0) < 0.0001
        and math.abs(v.y or 0) < 0.0001
        and math.abs(v.z or 0) < 0.0001
end

local function as_vector3(value)
    if value == nil then
        return vmath.vector3(0, 0, 0)
    end
    return vmath.vector3(value)
end

local function add_vector3(a, b)
    a = as_vector3(a)
    b = as_vector3(b)
    return vmath.vector3(
        (a.x or 0) + (b.x or 0),
        (a.y or 0) + (b.y or 0),
        (a.z or 0) + (b.z or 0)
    )
end

local function sub_vector3(a, b)
    a = as_vector3(a)
    b = as_vector3(b)
    return vmath.vector3(
        (a.x or 0) - (b.x or 0),
        (a.y or 0) - (b.y or 0),
        (a.z or 0) - (b.z or 0)
    )
end

local function refresh_offset_from_base(layer)
    if layer and layer.base_position then
        layer.base_position = as_vector3(layer.base_position)
        layer.offset = sub_vector3(layer.base_position, anchor)
    end
end

local function each_sprite(layer, fn)
    if not layer or type(fn) ~= "function" then
        return
    end

    local urls = layer.sprite_urls
    local offsets = layer.sprite_offsets
    if type(urls) == "table" and #urls > 0 then
        for i, sprite_url in ipairs(urls) do
            fn(sprite_url, offsets and offsets[i], i)
        end
        return
    end

    if layer.sprite_url then
        fn(layer.sprite_url, vmath.vector3(0, 0, 0), 1)
    end
end

local function register_sprite_instance(layer, sprite_url)
    if not layer or not component_exists(sprite_url) then
        return false
    end

    layer.sprite_urls = layer.sprite_urls or {}
    layer.sprite_offsets = layer.sprite_offsets or {}

    for _, existing in ipairs(layer.sprite_urls) do
        if existing == sprite_url then
            return true
        end
    end

    local ok, sprite_pos = pcall(go.get_position, sprite_url)
    if ok and sprite_pos then
        if not layer.base_position then
            layer.base_position = vmath.vector3(sprite_pos)
            refresh_offset_from_base(layer)
        end

        local offset = vmath.vector3(0, 0, 0)
        if layer.base_position then
            offset = sub_vector3(sprite_pos, layer.base_position)
        end

        layer.sprite_offsets[#layer.sprite_offsets + 1] = offset
        if is_zero_vector(offset) then
            layer.sprite_url = sprite_url
        end
    else
        layer.sprite_offsets[#layer.sprite_offsets + 1] = vmath.vector3(0, 0, 0)
    end

    layer.sprite_urls[#layer.sprite_urls + 1] = sprite_url
    layer.sprite_url = layer.sprite_url or sprite_url

    -- The parallax_clip material is baked into background sprites at build
    -- time, so we only need to push the clip_rect constant.  When clipping
    -- is disabled the constant keeps its safe defaults (huge bounds).
    if clip_rect then
        apply_clip_rect(layer, sprite_url)
    end

    local tint = vmath.vector4(layer.tint.x, layer.tint.y, layer.tint.z, layer.opacity)
    pcall(go.set, sprite_url, hash("tint"), tint)
    return true
end

local function get_clip_vec4()
    if clip_rect then
        return vmath.vector4(
            clip_rect.min_x or -1000000,
            clip_rect.min_y or -1000000,
            clip_rect.max_x or 1000000,
            clip_rect.max_y or 1000000
        )
    end
    -- Safe default: effectively disable clipping
    return vmath.vector4(-1000000, -1000000, 1000000, 1000000)
end

apply_clip_rect = function(layer, sprite_url)
    local target = sprite_url or (layer and layer.sprite_url)
    if layer and target and component_exists(target) then
        local rect = get_clip_vec4()
        pcall(go.set, target, hash("clip_rect"), rect)
    end
end

--- Initialize the parallax system
-- @param cam_url URL of the camera game object
function M.init(cam_url)
    camera_url = cam_url
    layers = {}
    -- Reposition from the camera's own publish (inside its late_update) so
    -- every layer uses exactly the view the render projection uses this
    -- frame. Keyed registration makes repeated init calls idempotent.
    CameraState.on_publish(PUBLISH_HOOK_KEY, apply_view)
    print("[PARALLAX] Initialized with camera:", camera_url)
end

--- Set global clip rectangle (world space)
-- @param rect Table with min_x, min_y, max_x, max_y
function M.set_clip_rect(rect)
    clip_rect = rect
    for _, layer in ipairs(layers) do
        each_sprite(layer, function(sprite_url)
            apply_clip_rect(layer, sprite_url)
        end)
    end
end

--- Create a parallax layer from Tiled data
-- @param layer_data Table with: name, parallax_factor, z_index, layer_type, image, etc.
-- @param parent_collection Optional: parent collection for spawning layer game objects
-- @return Layer ID for future reference
function M.create_layer(layer_data, parent_collection)
    if not layer_data then
        print("[PARALLAX] No layer data provided")
        return nil
    end

    local layer_id = layer_data.name or ("layer_" .. #layers)
    local parallax_factor = layer_data.parallax_factor or 0.5
    local z_index = layer_data.z_index or 0
    local base_position = nil

    if layer_data.base_position then
        base_position = vmath.vector3(layer_data.base_position)
    end

    -- Create layer entry
    local layer = {
        id = layer_id,
        name = layer_data.name,
        parallax_factor = parallax_factor,
        z_index = z_index,
        visible = layer_data.visible ~= false,
        opacity = layer_data.opacity or 1.0,
        offset = vmath.vector3(layer_data.offsetx or 0, layer_data.offsety or 0, 0),
        base_position = base_position,

        -- Layer type (tilelayer or imagelayer)
        layer_type = layer_data.layer_type or "tilelayer",

        -- Rendering data
        texture_path = layer_data.texture_path,
        image = layer_data.image,  -- Image path from Tiled (for image layers)
        sprite_url = layer_data.sprite_url,
        sprite_urls = {},
        sprite_offsets = {},
        game_object_id = nil,  -- Will be set if we spawn a GO

        -- Tiled tile data (for tile-based parallax)
        tile_data = layer_data.data,
        width = layer_data.width,
        height = layer_data.height,

        -- Image layer properties
        repeatx = layer_data.repeatx or false,
        repeaty = layer_data.repeaty or false,

        -- Custom tint
        tint = layer_data.tint or vmath.vector4(1, 1, 1, 1),
    }

    refresh_offset_from_base(layer)

    table.insert(layers, layer)

    -- Sort layers by z_index (back to front)
    table.sort(layers, function(a, b)
        return a.z_index < b.z_index
    end)

    print(string.format("[PARALLAX] Created %s layer '%s' (factor: %.2f, z: %.2f)",
        layer.layer_type, layer_id, parallax_factor, z_index))

    if layer.image and layer.image ~= "" then
        print(string.format("[PARALLAX]   Image: %s (repeat: %s/%s)",
            layer.image, tostring(layer.repeatx), tostring(layer.repeaty)))
    end
    if layer.base_position then
        print(string.format("[PARALLAX]   Base position: (%.1f, %.1f, %.2f)",
            tonumber(layer.base_position.x) or 0,
            tonumber(layer.base_position.y) or 0,
            tonumber(layer.base_position.z) or 0))
    end

    return layer_id
end

--- Remove a parallax layer
-- @param layer_id ID of the layer to remove
function M.remove_layer(layer_id)
    for i = #layers, 1, -1 do
        if layers[i].id == layer_id then
            local layer = table.remove(layers, i)

            -- Clean up game object if it exists
            if layer.game_object_id and go.exists(layer.game_object_id) then
                go.delete(layer.game_object_id)
            end

            print("[PARALLAX] Removed layer:", layer_id)
            return true
        end
    end

    return false
end

--- Clear all parallax layers
function M.clear_all()
    for i = #layers, 1, -1 do
        local layer = layers[i]
        if layer.game_object_id and go.exists(layer.game_object_id) then
            go.delete(layer.game_object_id)
        end
    end

    layers = {}
    print("[PARALLAX] Cleared all layers")
end

--- Reposition every registered layer for the given camera view.
-- Runs as the CameraState publish hook (registered by M.init), i.e. inside the
-- camera's late_update, with the exact view the render projection uses.
apply_view = function(cam_x, cam_y)
    if not enabled or #layers == 0 then return end

    -- Update each layer position
    for _, layer in ipairs(layers) do
        if layer.visible then
            local parallax_pos = vmath.vector3()
            parallax_pos.x = anchor.x + (cam_x - anchor.x) * layer.parallax_factor
            parallax_pos.y = anchor.y + (cam_y - anchor.y) * layer.parallax_factor
            parallax_pos.z = layer.z_index or 0
            parallax_pos = add_vector3(parallax_pos, layer.offset)

            local active_urls = {}
            local active_offsets = {}

            each_sprite(layer, function(sprite_url, instance_offset)
                if component_exists(sprite_url) then
                    local final_pos = add_vector3(parallax_pos, instance_offset)
                    pcall(go.set_position, final_pos, sprite_url)
                    active_urls[#active_urls + 1] = sprite_url
                    active_offsets[#active_offsets + 1] = as_vector3(instance_offset)
                end
            end)

            layer.sprite_urls = active_urls
            layer.sprite_offsets = active_offsets
            layer.sprite_url = active_urls[1]
        end
    end
end

function M.apply_view(cam_x, cam_y)
    apply_view(cam_x, cam_y)
end

--- Reposition layers from the last published camera view.
-- Kept for callers that drive the manager manually (tests, tools). During
-- play the publish hook already applied this frame's view; calling this as
-- well only repeats the same positions.
-- @param dt Delta time (unused)
function M.update(dt)
    if not enabled or #layers == 0 then return end

    local has_camera_state, cam_x, cam_y = CameraState.get()
    if not has_camera_state then
        if not camera_url or not go.exists(camera_url) then
            return
        end
        local cam_pos = go.get_position(camera_url)
        cam_x, cam_y = cam_pos.x, cam_pos.y
    end
    apply_view(cam_x, cam_y)
end

--- Set the anchor point for parallax calculations
-- Usually set to the center of the current room/area
-- @param position vmath.vector3 for anchor point
function M.set_anchor(position)
    anchor = vmath.vector3(position.x, position.y, 0)
    for _, layer in ipairs(layers) do
        refresh_offset_from_base(layer)
    end
    print("[PARALLAX] Set anchor:", anchor)
end

--- Set anchor from room bounds
-- @param bounds Table with min_x, max_x, min_y, max_y
function M.set_anchor_from_bounds(bounds)
    if not bounds then return end

    local center_x = (bounds.min_x + bounds.max_x) * 0.5
    local center_y = (bounds.min_y + bounds.max_y) * 0.5

    M.set_anchor(vmath.vector3(center_x, center_y, 0))
end

--- Set layer visibility
-- @param layer_id ID of the layer
-- @param visible Boolean visibility state
function M.set_layer_visible(layer_id, visible)
    for _, layer in ipairs(layers) do
        if layer.id == layer_id then
            layer.visible = visible

            each_sprite(layer, function(sprite_url)
                if component_exists(sprite_url) then
                    if visible then
                        Util.set_component_enabled(sprite_url, true)
                    else
                        Util.set_component_enabled(sprite_url, false)
                    end
                end
            end)

            return
        end
    end
end

--- Set layer opacity
-- @param layer_id ID of the layer
-- @param opacity Opacity value (0.0 to 1.0)
function M.set_layer_opacity(layer_id, opacity)
    for _, layer in ipairs(layers) do
        if layer.id == layer_id then
            layer.opacity = math.max(0, math.min(1, opacity))

            each_sprite(layer, function(sprite_url)
                if component_exists(sprite_url) then
                    local tint = vmath.vector4(layer.tint.x, layer.tint.y, layer.tint.z, layer.opacity)
                    pcall(go.set, sprite_url, hash("tint"), tint)
                end
            end)

            return
        end
    end
end

--- Set layer tint color
-- @param layer_id ID of the layer
-- @param color vmath.vector4 (r, g, b, a)
function M.set_layer_tint(layer_id, color)
    for _, layer in ipairs(layers) do
        if layer.id == layer_id then
            layer.tint = color

            each_sprite(layer, function(sprite_url)
                if component_exists(sprite_url) then
                    pcall(go.set, sprite_url, hash("tint"), color)
                end
            end)

            return
        end
    end
end

--- Apply biome tint to all layers
-- @param color vmath.vector4 (r, g, b, a)
function M.set_biome_tint(color)
    for _, layer in ipairs(layers) do
        M.set_layer_tint(layer.id, color)
    end
end

--- Enable/disable the parallax system
-- @param is_enabled Boolean
function M.set_enabled(is_enabled)
    enabled = is_enabled

    -- Show/hide all layers
    for _, layer in ipairs(layers) do
        each_sprite(layer, function(sprite_url)
            if component_exists(sprite_url) then
                if enabled and layer.visible then
                    Util.set_component_enabled(sprite_url, true)
                else
                    Util.set_component_enabled(sprite_url, false)
                end
            end
        end)
    end

    print("[PARALLAX] Enabled:", enabled)
end

--- Get layer by ID
-- @param layer_id ID of the layer
-- @return Layer data table or nil
function M.get_layer(layer_id)
    for _, layer in ipairs(layers) do
        if layer.id == layer_id then
            return layer
        end
    end
    return nil
end

--- Get all layers
-- @return Array of layer data
function M.get_all_layers()
    return layers
end

--- Get layer count
-- @return Number of active layers
function M.get_layer_count()
    return #layers
end

--- Register sprite URL for a layer
-- Use this after manually creating sprite components
-- @param layer_id ID of the layer
-- @param sprite_url URL to the sprite component (e.g., msg.url("#layer1"))
function M.register_sprite(layer_id, sprite_url)
    for _, layer in ipairs(layers) do
        if layer.id == layer_id then
            if register_sprite_instance(layer, sprite_url) then
                local sprite_count = (type(layer.sprite_urls) == "table") and #layer.sprite_urls or 0
                local base_pos = layer.base_position or vmath.vector3(0, 0, 0)
                local offset = layer.sprite_offsets and layer.sprite_offsets[sprite_count] or vmath.vector3(0, 0, 0)
                print(string.format("[PARALLAX] Registered sprite for layer '%s' -> %s (count=%d, base=(%.1f, %.1f), offset=(%.1f, %.1f))",
                    tostring(layer_id),
                    tostring(sprite_url),
                    sprite_count,
                    tonumber(base_pos.x) or 0,
                    tonumber(base_pos.y) or 0,
                    tonumber(offset.x) or 0,
                    tonumber(offset.y) or 0))
            end
            return
        end
    end
end

function M.register_sprites(layer_id, sprite_urls)
    if type(sprite_urls) ~= "table" then
        return
    end

    for _, sprite_url in ipairs(sprite_urls) do
        M.register_sprite(layer_id, sprite_url)
    end
end

--- Debug: Print all layer information
function M.debug_print()
    print("[PARALLAX] Layer count:", #layers)
    print("[PARALLAX] Anchor:", anchor)
    print("[PARALLAX] Camera:", camera_url)
    print("[PARALLAX] Enabled:", enabled)

    for i, layer in ipairs(layers) do
        print(string.format("  [%d] %s (factor: %.2f, z: %.2f, visible: %s)",
            i, layer.id, layer.parallax_factor, layer.z_index, tostring(layer.visible)))
    end
end

return M
