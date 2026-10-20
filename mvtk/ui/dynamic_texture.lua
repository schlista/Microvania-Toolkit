-- Shared helpers for GUI textures created or refreshed at runtime.
--
-- Minimap/world-map tools regenerate PNG data during editor workflows and then
-- push the decoded pixel buffer into GUI textures. Keep that path centralized so
-- release-build texture replacement behavior is tested in one place.

local M = {}

local function log_error(options, fmt, ...)
    local fn = options and options.log
    if type(fn) == "function" then
        fn(string.format(fmt, ...))
    end
end

local function has_gui_fn(name)
    return gui and type(gui[name]) == "function"
end

local function get_texture_info(name)
    if not has_gui_fn("get_texture_info") then
        return nil
    end
    local ok, info = pcall(gui.get_texture_info, name)
    if ok and type(info) == "table" then
        return info
    end
    return nil
end

local function create_texture(name, width, height, texture_format, buffer, flip)
    if not has_gui_fn("new_texture") then
        return false, "gui.new_texture unavailable"
    end
    local ok, result, code = pcall(gui.new_texture, name, width, height, texture_format, buffer, flip)
    if not ok then
        return false, result
    end
    if result == false then
        return false, code or "gui.new_texture returned false"
    end
    return true
end

local function update_texture_data(name, width, height, texture_format, buffer, flip)
    if not has_gui_fn("set_texture_data") then
        return false, "gui.set_texture_data unavailable"
    end
    local ok, result = pcall(gui.set_texture_data, name, width, height, texture_format, buffer, flip)
    if not ok or result == false then
        return false, result
    end
    return true
end

local function delete_texture(name)
    if has_gui_fn("delete_texture") then
        pcall(gui.delete_texture, name)
    end
end

--- Create or refresh a GUI texture from raw image data.
-- @param name string GUI texture name.
-- @param width number Texture width in pixels.
-- @param height number Texture height in pixels.
-- @param buffer userdata|string Raw RGBA buffer accepted by gui.new_texture().
-- @param options table? { format = "rgba", flip = false, log = function(message) end }
-- @return boolean true when the texture exists and contains the supplied buffer.
function M.update(name, width, height, buffer, options)
    options = options or {}
    if not (name and width and height and buffer) then
        log_error(options, "Dynamic texture update missing name/size/buffer")
        return false
    end

    local texture_format = options.format or "rgba"
    local flip = options.flip == true
    local info = get_texture_info(name)
    if info then
        local size_changed = (info.width ~= width) or (info.height ~= height)
        if size_changed then
            delete_texture(name)
            local ok, err = create_texture(name, width, height, texture_format, buffer, flip)
            if not ok then
                log_error(options, "Failed to recreate texture %s: %s", tostring(name), tostring(err))
                return false
            end
            return true
        end

        local ok, err = update_texture_data(name, width, height, texture_format, buffer, flip)
        if not ok then
            log_error(options, "Failed to update texture data for %s: %s", tostring(name), tostring(err))
            return false
        end
        return true
    end

    local ok, err = create_texture(name, width, height, texture_format, buffer, flip)
    -- Defold 1.13 has no gui.get_texture_info. Duplicate creation returns a
    -- documented result code; updating it requires the complete API signature.
    if not ok and gui.RESULT_TEXTURE_ALREADY_EXISTS and err == gui.RESULT_TEXTURE_ALREADY_EXISTS then
        return update_texture_data(name, width, height, texture_format, buffer, flip)
    end
    if not ok then
        log_error(options, "Failed to create texture %s: %s", tostring(name), tostring(err))
        return false
    end
    return true
end

return M
