-- Identical baked atlas/tilesource definitions share a texture across rooms. The content
-- determines the resource path, so rebuilding one room cannot change another
-- room's artwork. Keep image/animation order and flip flags exactly as authored.
local Adler = require "mvtk.core.adler32"
local R = require "mvtk.editor.resource_text"
local P = require "mvtk.editor.proto_utils"
local M = {}

local flips = {{"",0,0},{"_h",1,0},{"_v",0,1},{"_hv",1,1}}

local function has_comment(text)
    local i = 1
    while i <= #text do
        local char = text:sub(i,i)
        if char == '"' then
            i = i + 1
            while i <= #text and text:sub(i,i) ~= '"' do
                if text:sub(i,i) == "\\" then i = i + 1 end
                i = i + 1
            end
        elseif char == "#" or text:sub(i,i+1) == "//" then return true end
        i = i + 1
    end
    return false
end

-- Defold saves tilesources with reordered animations, expanded blocks and
-- omitted zero defaults. Recover only our complete, four-flip sheet format;
-- comments, extra fields and changed animation behavior remain creator-owned.
local function sheet_text(text)
    if has_comment(text) then return nil end
    local ok, result = pcall(function()
        local root = R.parse(text).root
        -- resource_text exposes decoded values. Check their literal spelling
        -- too: quoted enums and octal integers must not inherit Lua meanings.
        local function scalar(field, kind)
            local raw = text:sub(field.first,field.last)
            if kind == "string" then
                assert(type(field.value) == "string"
                    and raw == '"' .. P.proto_escape(field.value) .. '"', "Invalid sheet string")
            elseif kind == "integer" then
                assert(type(field.value) == "number" and field.value >= 0
                    and field.value <= 4294967295 and raw:match("^%d+$")
                    and raw == P.fmt_num(field.value), "Invalid sheet integer")
            else assert(raw == "PLAYBACK_LOOP_FORWARD", "Invalid sheet playback") end
        end
        local fields, animations = {}, {}
        local allowed = {image=true,tile_width=true,tile_height=true,
            tile_margin=true,tile_spacing=true,extrude_borders=true}
        for _, field in ipairs(root.entries) do
            if field.name == "animations" then
                assert(field.node, "Expected sheet animation block")
                animations[#animations+1] = field.node
            else
                assert(allowed[field.name] and not field.node and fields[field.name] == nil,
                    "Unrecognized or duplicate sheet field")
                scalar(field, field.name == "image" and "string" or "integer")
                fields[field.name] = field.value
            end
        end
        local function integer(value, minimum)
            return type(value) == "number" and value >= minimum
                and value < math.huge and value == math.floor(value)
        end
        local margin, spacing = fields.tile_margin or 0, fields.tile_spacing or 0
        assert(type(fields.image) == "string" and fields.image:match("^/developer/.+"), "Invalid sheet image")
        assert(integer(fields.tile_width,1) and integer(fields.tile_height,1)
            and integer(margin,0) and integer(spacing,0) and fields.extrude_borders == 2,
            "Invalid sheet dimensions")
        assert(#animations > 0 and #animations % 4 == 0, "Incomplete sheet animations")
        local count, seen = #animations / 4, {}
        local animation_fields = {id=true,start_tile=true,end_tile=true,
            playback=true,fps=true,flip_horizontal=true,flip_vertical=true}
        for _, node in ipairs(animations) do
            local values = {}
            for _, field in ipairs(node.entries) do
                assert(animation_fields[field.name] and not field.node and values[field.name] == nil,
                    "Unrecognized or duplicate animation field")
                scalar(field, field.name == "id" and "string"
                    or field.name == "playback" and "enum" or "integer")
                values[field.name] = field.value
            end
            assert(type(values.id) == "string", "Missing sheet animation id")
            local digits, suffix = values.id:match("^tile_(%d+)(.*)$")
            local tile_id = tonumber(digits)
            assert(tile_id and tile_id < count and values.id == "tile_" .. tile_id .. suffix
                and not seen[values.id], "Invalid or duplicate sheet animation")
            local expected
            for _, flip in ipairs(flips) do if suffix == flip[1] then expected = flip end end
            assert(expected and values.start_tile == tile_id+1 and values.end_tile == tile_id+1
                and values.playback == "PLAYBACK_LOOP_FORWARD" and values.fps == 1
                and (values.flip_horizontal or 0) == expected[2]
                and (values.flip_vertical or 0) == expected[3], "Changed sheet animation")
            seen[values.id] = true
        end
        local rows = {'image: "' .. P.proto_escape(fields.image) .. '"',
            "tile_width: " .. P.fmt_num(fields.tile_width),
            "tile_height: " .. P.fmt_num(fields.tile_height),
            "tile_margin: " .. P.fmt_num(margin), "tile_spacing: " .. P.fmt_num(spacing),
            "extrude_borders: 2"}
        for tile_id = 0,count-1 do
            for _, flip in ipairs(flips) do
                rows[#rows+1] = 'animations { id: "tile_' .. tile_id .. flip[1] ..
                    '" start_tile: ' .. (tile_id+1) .. " end_tile: " .. (tile_id+1) ..
                    " playback: PLAYBACK_LOOP_FORWARD fps: 1 flip_horizontal: " .. flip[2] ..
                    " flip_vertical: " .. flip[3] .. " }"
            end
        end
        return table.concat(rows,"\n") .. "\n"
    end)
    return ok and result or nil
end

-- Similar names and locally edited definitions remain creator-owned.
function M.is_generated(name, text)
    if type(text) ~= "string" then return false end
    local stem = name:match("^(object_art_.+)%.atlas$") or name:match("^(object_art_.+)%.tilesource$")
    if not stem then return false end
    local signature = stem:match("^object_art_(%d+_%d+_%d+)$")
    if not signature then
        local suffix
        signature, suffix = stem:match("^object_art_(%d+_%d+_%d+)_(%d+)$")
        if not suffix or tonumber(suffix) < 1 then return false end
    end
    text = text:gsub("\r\n", "\n")
    if signature == Adler.fingerprint(text):gsub(":", "_") then return true end
    local original = name:match("%.tilesource$") and sheet_text(text)
    return original ~= nil and signature == Adler.fingerprint(original):gsub(":", "_")
end

function M.collect_generated(root, list_dir, read)
    local directory = root:gsub("\\", "/"):gsub("/+$", "") .. "/developer/assets/atlas"
    local _, files = list_dir(directory, {force_process = true})
    local paths = {}
    for _, name in ipairs(files or {}) do
        if name:match("^object_art_.*%.atlas$") or name:match("^object_art_.*%.tilesource$") then
            local path = directory .. "/" .. name
            if M.is_generated(name, read(path)) then paths[#paths + 1] = path end
        end
    end
    table.sort(paths)
    return paths
end

local function store(c, text, extension)
    text = text:gsub("\r\n", "\n")
    local canonical_sheet, canonical_checked
    local stem = "/developer/assets/atlas/object_art_" .. Adler.fingerprint(text):gsub(":", "_")
    local suffix = 0
    while true do
        local path = stem .. (suffix == 0 and "" or "_" .. suffix) .. extension
        local absolute = c.join(c.ROOT, path:sub(2))
        -- The context reads pending writes too. Compare full content: a short
        -- checksum is a filename hint, never proof that two atlases are equal.
        local existing = c.read_text(absolute)
        if not existing then
            c.write_if_changed(absolute, text)
            return path
        end
        if existing:gsub("\r\n", "\n") == text then return path end
        -- Compare complete reconstructed definitions, never just fingerprints,
        -- so editor formatting can reuse a sheet without weakening collisions.
        if extension == ".tilesource" then
            if not canonical_checked then canonical_sheet, canonical_checked = sheet_text(text), true end
            if canonical_sheet and sheet_text(existing) == canonical_sheet then return path end
        end
        suffix = suffix + 1
    end
end

function M.store(c, text) return store(c, text, ".atlas") end
function M.store_tilesource(c, text) return store(c, text, ".tilesource") end

return M
