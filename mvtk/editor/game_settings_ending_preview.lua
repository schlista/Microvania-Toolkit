-- Read ending artwork only after the settings dialog returns. The resulting
-- resource path and pure pages are safe to render without further file access.
local Pages = require "mvtk.ui.completion_pages"
local ResourceText = require "mvtk.editor.resource_text"
local M = {}

local function resource_path(value)
    if type(value) ~= "string" or value:sub(1, 1) ~= "/"
        or value:sub(2, 2) == "/" or value:find("[\\:%c]") then return nil end
    for part in value:gmatch("[^/]+") do
        if part == "." or part == ".." then return nil end
    end
    return value ~= "/" and value or nil
end

local function read_resource(deps, path)
    path = resource_path(path)
    if not path then return nil end
    return deps.read(path:sub(2))
end

local function parse_resource(deps, path)
    local text = read_resource(deps, path)
    if not text then return nil end
    return ResourceText.parse(text).root
end

local function first_image(node)
    local images = ResourceText.all(node, "images")
    return images[1] and images[1].node and ResourceText.value(images[1].node, "image")
end

local function image_id(path, patterns)
    local name = path:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    -- Atlas rename patterns are literal search/replacements of image basenames.
    -- They do not change explicitly named animation groups.
    for entry in (patterns or ""):gmatch("[^,]+") do
        local search, replacement = entry:match("^(.-)=(.*)$")
        if not search or search == "" then return nil end
        local parts, cursor = {}, 1
        while true do
            local first, last = name:find(search, cursor, true)
            if not first then parts[#parts + 1] = name:sub(cursor); break end
            parts[#parts + 1] = name:sub(cursor, first - 1)
            parts[#parts + 1] = replacement
            cursor = last + 1
        end
        name = table.concat(parts)
    end
    return name
end

local function find_image(deps, animation)
    local gui_path = deps.gui_path or "/developer/ui/game/completion.gui"
    if gui_path:sub(1, 1) ~= "/" then gui_path = "/" .. gui_path end
    local gui = parse_resource(deps, gui_path)
    if not gui then return nil end
    local atlas_path
    for _, entry in ipairs(ResourceText.all(gui, "textures")) do
        if entry.node and ResourceText.value(entry.node, "name") == "artwork" then
            atlas_path = ResourceText.value(entry.node, "texture"); break
        end
    end
    if not resource_path(atlas_path) or not atlas_path:match("%.atlas$") then return nil end
    local atlas = parse_resource(deps, atlas_path)
    if not atlas then return nil end
    for _, entry in ipairs(ResourceText.all(atlas, "animations")) do
        if entry.node and ResourceText.value(entry.node, "id") == animation then
            return first_image(entry.node)
        end
    end
    local patterns = ResourceText.value(atlas, "rename_patterns")
    for _, entry in ipairs(ResourceText.all(atlas, "images")) do
        local path = entry.node and ResourceText.value(entry.node, "image")
        if resource_path(path) and image_id(path, patterns) == animation then return path end
    end
end

function M.artwork(deps, animation)
    local result = {animation = animation or ""}
    if result.animation == "" then return result end
    -- Missing/malformed resources are a readable preview fallback, not a failed
    -- settings operation. No resource text is compiled or executed.
    local ok, path = pcall(find_image, deps, result.animation)
    path = ok and resource_path(path) or nil
    if path then
        local exists_ok, exists
        if deps.exists then exists_ok, exists = pcall(deps.exists, path:sub(2))
        else exists_ok, exists = pcall(read_resource, deps, path) end
        if exists_ok and exists then result.image = path end
    end
    if not result.image then result.message = "Artwork not found" end
    return result
end

function M.prepare(deps, cfg)
    return {pages = Pages.build(cfg, {playtime_s = 0, stats = {items = {}}}),
        artwork = M.artwork(deps, cfg.artwork)}
end

return M
