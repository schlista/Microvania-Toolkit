-- mvtk/editor/layout_editor/tag_export.lua
-- Writes derived world POI configuration from layout marker tags.

local Util = require "mvtk.core.util"
local LayoutSettings

local M = {}

local ROOT_CACHE

local function normalize(path)
    if not path then return nil end
    return path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
end

local function file_exists(path)
    local fh = io.open(path, "r")
    if fh then fh:close() return true end
    return false
end

local function project_root()
    LayoutSettings = LayoutSettings or Util.require_config("developer.config.layout_editor_settings")
    if ROOT_CACHE then return ROOT_CACHE end

    local candidates = {}

    if debug and debug.getinfo then
        local src = debug.getinfo(1, "S").source
        if src then
            src = src:gsub("^@", "")
            src = normalize(src)
            local base = src:match("^(.*)/mvtk/editor/layout_editor/tag_export.lua$")
            if base then
                candidates[#candidates + 1] = base
            end
        end
    end

    local env = os.getenv("MVTK_PROJECT_ROOT")
    if env and env ~= "" then
        candidates[#candidates + 1] = env
    end

    if LayoutSettings and LayoutSettings.project_root then
        candidates[#candidates + 1] = LayoutSettings.project_root
    end

    candidates[#candidates + 1] = "."

    for _, base in ipairs(candidates) do
        base = normalize(base)
        if base and base ~= "" then
            if file_exists(base .. "/game.project") then
                ROOT_CACHE = base
                return ROOT_CACHE
            end
        end
    end

    return nil
end

local function join(base, relative)
    base = normalize(base or "")
    relative = normalize(relative or "")
    if relative:match("^/") then
        relative = relative:gsub("^/+", "")
    end
    if base == "" then
        return relative
    end
    return base .. "/" .. relative
end

local function key_literal(id)
    if id:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        return id
    end
    return string.format("[%q]", id)
end

local function write_if_changed(path, content)
    local existing = nil
    local fh = io.open(path, "r")
    if fh then
        existing = fh:read("*a")
        fh:close()
    end
    if existing == content then
        return false
    end
    fh = assert(io.open(path, "w"), string.format("Unable to open %s for writing", path))
    fh:write(content)
    fh:close()
    return true
end

local function float_str(value)
    return string.format("%.1f", value or 0)
end

local function collect_poi(rooms)
    local bosses, custom = {}, {}
    for _, rec in ipairs(rooms or {}) do
        local id = rec.id or rec.path
        if id then
            id = tostring(id):gsub("^developer/rooms/", "")
            local tags = rec.tags
            local marker = tags and tags.marker
            if marker and marker.enabled then
                local w = tonumber(rec.w) or 0
                local h = tonumber(rec.h) or 0
                local ox = tonumber(rec.ox) or 0
                local oy = tonumber(rec.oy) or 0
                local base_x = (tonumber(rec.x) or 0) + ox
                local base_y = (tonumber(rec.y) or 0) + oy
                local center_x = base_x + w * 0.5
                local center_y = base_y + h * 0.5
                local offset = marker.offset or {}
                local offset_x = tonumber(offset.x) or 0
                local offset_y = tonumber(offset.y) or 0
                local world_x = center_x + offset_x
                local world_y = center_y + offset_y
                local entry = {
                    x = world_x,
                    y = world_y,
                    label = marker.label,
                    color = marker.color,
                }

                local target
                if marker.type == "boss" then
                    target = bosses
                    entry.label = entry.label or "Boss"
                else
                    target = custom
                    entry.label = entry.label or id
                end
                target[#target + 1] = { key = id, data = entry }
            end
        end
    end

    local function sort_entries(list)
        table.sort(list, function(a, b)
            return tostring(a.key) < tostring(b.key)
        end)
    end

    sort_entries(bosses)
    sort_entries(custom)

    return bosses, custom
end

local function render_poi_table(entries)
    local lines = {}
    for _, entry in ipairs(entries) do
        local data = entry.data
        local parts = {
            string.format("    %s = { x = %s, y = %s", key_literal(entry.key), float_str(data.x), float_str(data.y)),
        }
        if data.label and data.label ~= "" then
            parts[#parts + 1] = string.format('      , label = %q', data.label)
        end
        if data.color then
            local c = data.color
            parts[#parts + 1] = string.format("      , color = vmath.vector4(%.2f, %.2f, %.2f, %.2f)", c.r or c.x or 0, c.g or c.y or 0, c.b or c.z or 0, c.a or c.w or 1)
        end
        parts[#parts + 1] = " },"
        lines[#lines + 1] = table.concat(parts, "")
    end
    if #lines == 0 then
        lines[#lines + 1] = "    -- none"
    end
    return table.concat(lines, "\n")
end

local function render_poi_file(bosses, custom)
    local lines = {
        "-- Auto-generated by MV Toolkit Layout Editor.",
        "-- Manual edits will be overwritten on next layout save.",
        "return {",
        "  bosses = {",
        render_poi_table(bosses),
        "  },",
        "  custom = {",
        render_poi_table(custom),
        "  },",
        "}",
        "",
    }
    return table.concat(lines, "\n")
end

function M.render(layout)
    return render_poi_file(collect_poi((layout and layout.rooms) or {}))
end

function M.write(layout)
    local root = project_root()
    if not root then
        print("[TAG_EXPORT] Unable to determine project root; skipping POI export.")
        return
    end

    local rooms = (layout and layout.rooms) or {}

    local bosses, custom = collect_poi(rooms)
    local poi_path = join(root, "developer/config/poi.lua")
    local poi_content = render_poi_file(bosses, custom)
    local poi_changed = write_if_changed(poi_path, poi_content)

    if poi_changed then
        print("[TAG_EXPORT] POI config updated")
    end
end

return M
