-- Pure helpers for Project > Sync Music.
--
-- This module intentionally has no Defold editor or filesystem dependencies so
-- the generator can be tested with exact-string fixtures.

local M = {}

M.SUPPORTED_MUSIC_EXTENSIONS = { ogg = true, wav = true }

local RECOGNIZED_MUSIC_EXTENSIONS = {
    ogg = true,
    wav = true,
    mp3 = true,
    flac = true,
    m4a = true,
    aac = true,
    opus = true,
}

local function detect_newline(text)
    if type(text) == "string" and text:find("\r\n", 1, true) then
        return "\r\n"
    end
    return "\n"
end

local function basename(path)
    path = tostring(path or "")
    return path:match("([^/\\]+)$") or path
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function basename_without_extension(path)
    local name = basename(path)
    return (name:gsub("%.[^%.]+$", ""))
end

local function sorted_keys(set)
    local out = {}
    for key in pairs(set or {}) do
        out[#out + 1] = key
    end
    table.sort(out)
    return out
end

local function escape_lua_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return value
end

local function escape_json_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return '"' .. value .. '"'
end

local function escape_lua_pattern(value)
    return (tostring(value or ""):gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1"))
end

local function escape_proto_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return value
end

function M.sanitize_track_id(filename)
    local id = basename_without_extension(filename):lower()
    id = id:gsub("[%s%-]+", "_")
    id = id:gsub("[^a-z0-9_]", "")
    id = id:gsub("_+", "_")
    id = id:gsub("^_+", "")
    id = id:gsub("_+$", "")
    return id
end

function M.classify_music_value(value)
    local s = trim(value)
    local lower = s:lower()
    if s == "" or lower == "none" or lower == "hush" or lower == "inherit" then
        return "empty", nil
    end

    local ext = s:match("%.([^%.\\/]+)$")
    ext = ext and ext:lower() or nil
    if ext and RECOGNIZED_MUSIC_EXTENSIONS[ext] then
        return "file", ext
    end

    return "legacy", nil
end

local function normalize_slashes(path)
    return tostring(path or ""):gsub("\\", "/")
end

local function is_absolute_path(path)
    return path:match("^%a:") ~= nil or path:sub(1, 1) == "/"
end

local function collapse_path(path)
    path = normalize_slashes(path)

    local prefix = ""
    local rest = path
    local drive = path:match("^(%a:)")
    if drive then
        prefix = drive
        rest = path:sub(#drive + 1)
        if rest:sub(1, 1) == "/" then
            prefix = prefix .. "/"
            rest = rest:sub(2)
        end
    elseif path:sub(1, 1) == "/" then
        prefix = "/"
        rest = path:sub(2)
    end

    local parts = {}
    for part in rest:gmatch("[^/]+") do
        if part == "." or part == "" then
            -- skip
        elseif part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = part
            end
        else
            parts[#parts + 1] = part
        end
    end

    local body = table.concat(parts, "/")
    if prefix == "" then
        return body
    elseif prefix == "/" then
        return body ~= "" and ("/" .. body) or "/"
    elseif prefix:sub(-1) == "/" then
        return body ~= "" and (prefix .. body) or prefix
    end
    return body ~= "" and (prefix .. "/" .. body) or prefix
end

function M.resolve_map_music_path(value, map_dir)
    local path = normalize_slashes(trim(value))
    if path == "" then
        return ""
    end
    if not is_absolute_path(path) then
        local base = normalize_slashes(trim(map_dir))
        if base ~= "" then
            path = base:gsub("/+$", "") .. "/" .. path
        end
    end
    return collapse_path(path)
end

local function track_sort_key(track)
    return tostring(track.track_id or ""):lower() .. "\0" .. tostring(track.filename or ""):lower()
end

function M.prepare_tracks(files)
    local entries = {}
    for _, file in ipairs(files or {}) do
        local filename = type(file) == "table" and (file.filename or file.file or file.path) or file
        filename = basename(filename)
        entries[#entries + 1] = {
            filename = filename,
            track_id = M.sanitize_track_id(filename),
            basename_key = basename_without_extension(filename):lower(),
        }
    end

    table.sort(entries, function(a, b)
        if a.basename_key ~= b.basename_key then
            return a.basename_key < b.basename_key
        end
        local af = a.filename:lower()
        local bf = b.filename:lower()
        if af ~= bf then
            return af < bf
        end
        return a.filename < b.filename
    end)

    local groups = {}
    local order = {}
    local invalid = {}
    for _, entry in ipairs(entries) do
        if entry.track_id == "" then
            invalid[#invalid + 1] = {
                filename = entry.filename,
                reason = "sanitized track id is empty",
            }
        else
            if not groups[entry.track_id] then
                groups[entry.track_id] = {}
                order[#order + 1] = entry.track_id
            end
            groups[entry.track_id][#groups[entry.track_id] + 1] = entry
        end
    end

    local tracks = {}
    local collisions = {}
    for _, track_id in ipairs(order) do
        local group = groups[track_id]
        if #group == 1 then
            tracks[#tracks + 1] = {
                track_id = track_id,
                filename = group[1].filename,
            }
        else
            local filenames = {}
            for _, entry in ipairs(group) do
                filenames[#filenames + 1] = entry.filename
            end
            collisions[#collisions + 1] = {
                track_id = track_id,
                filenames = filenames,
            }
        end
    end

    table.sort(tracks, function(a, b)
        return track_sort_key(a) < track_sort_key(b)
    end)

    return tracks, {
        collisions = collisions,
        invalid = invalid,
    }
end

local function track_ids_from_tracks(tracks)
    local ids = {}
    for _, track in ipairs(tracks or {}) do
        if type(track) == "table" then
            ids[#ids + 1] = tostring(track.track_id or "")
        else
            ids[#ids + 1] = tostring(track)
        end
    end
    table.sort(ids)
    return ids
end

function M.track_id_set(tracks)
    local set = {}
    for _, id in ipairs(track_ids_from_tracks(tracks)) do
        if id ~= "" then
            set[id] = true
        end
    end
    return set
end

function M.map_music_sources_conflict(claim, source)
    if not claim or not source then
        return false, nil
    end
    if tostring(claim.source or "") == tostring(source.source or "") then
        return false, nil
    end
    if claim.bytes ~= nil and source.bytes ~= nil then
        if claim.bytes == source.bytes then
            return false, nil
        end
        return true, "different"
    end
    return true, "unverified"
end

local function safe_call(fn, ...)
    if not fn then
        return false, nil, "missing function"
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return false, nil, value
    end
    return true, value, nil
end

function M.copy_map_music_source(opts)
    opts = opts or {}
    local source = tostring(opts.source or "")
    local dest = tostring(opts.dest or "")
    if source == "" or dest == "" then
        return false, { status = "invalid_path", source = source, dest = dest }
    end

    local bytes = opts.bytes
    if bytes == nil and opts.read_binary then
        local ok_read, read_value = safe_call(opts.read_binary, source)
        if ok_read then
            bytes = read_value
        end
    end

    if bytes ~= nil then
        local ok_write, changed, write_err = safe_call(opts.write_binary, dest, bytes)
        if not ok_write then
            return false, {
                status = "write_failed",
                source = source,
                dest = dest,
                error = write_err,
                bytes = bytes,
                verified = true,
            }
        end
        return true, {
            status = changed and "copied" or "unchanged",
            source = source,
            dest = dest,
            bytes = bytes,
            verified = true,
        }
    end

    local exists = opts.exists
    if exists == nil and opts.file_exists then
        local ok_exists, exists_value = safe_call(opts.file_exists, source)
        exists = ok_exists and exists_value == true
    end
    if not exists then
        return false, {
            status = "missing",
            source = source,
            dest = dest,
            verified = false,
        }
    end

    local ok_copy, copied, copy_err = safe_call(opts.copy_file, source, dest)
    if not ok_copy or copied ~= true then
        return false, {
            status = "copy_failed",
            source = source,
            dest = dest,
            error = copy_err,
            verified = false,
        }
    end

    return true, {
        status = "copied",
        source = source,
        dest = dest,
        verified = false,
    }
end

local function lua_key(track_id)
    if tostring(track_id):match("^[%a_][%w_]*$") then
        return track_id
    end
    return '["' .. escape_lua_string(track_id) .. '"]'
end

local function find_matching_char(text, open_pos, open_char, close_char)
    local depth = 1
    local i = open_pos + 1
    local quote = nil
    while i <= #text do
        local ch = text:sub(i, i)
        if quote then
            if ch == "\\" then
                i = i + 2
            elseif ch == quote then
                quote = nil
                i = i + 1
            else
                i = i + 1
            end
        else
            local pair = text:sub(i, i + 1)
            if pair == "--" then
                local nl = text:find("\n", i + 2, true)
                i = nl and (nl + 1) or (#text + 1)
            elseif ch == '"' or ch == "'" then
                quote = ch
                i = i + 1
            elseif ch == open_char then
                depth = depth + 1
                i = i + 1
            elseif ch == close_char then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
                i = i + 1
            else
                i = i + 1
            end
        end
    end
    return nil
end

local function find_self_table(text, field_name)
    local pattern = "self%." .. field_name .. "%s*=%s*{"
    local start_pos, open_pos = text:find(pattern)
    if not start_pos then
        return nil, string.format("Could not find self.%s table", field_name)
    end
    local close_pos = find_matching_char(text, open_pos, "{", "}")
    if not close_pos then
        return nil, string.format("Could not find closing brace for self.%s table", field_name)
    end
    return {
        start_pos = start_pos,
        open_pos = open_pos,
        close_pos = close_pos,
        body = text:sub(open_pos + 1, close_pos - 1),
    }
end

local function line_indent_before(text, pos)
    local before = text:sub(1, pos)
    local line_start = before:match(".*\n()") or 1
    return text:sub(line_start, pos - 1):match("^([ \t]*)") or ""
end

function M.rewrite_music_table(script_text, tracks)
    local found, err = find_self_table(script_text, "_music")
    if not found then
        return nil, err
    end

    local newline = detect_newline(script_text)
    local body_indent = found.body:match("\n([ \t]*)%S")
    if not body_indent then
        body_indent = line_indent_before(script_text, found.open_pos) .. "  "
    end
    local close_indent = line_indent_before(script_text, found.close_pos)

    local lines = {
        body_indent .. "-- AUTO-GENERATED by Project > Sync Music (from developer/assets/music/*). Do not edit by hand.",
    }
    for _, track in ipairs(tracks or {}) do
        local id = track.track_id or track
        lines[#lines + 1] = string.format('%s%s = msg.url(nil, go.get_id(), hash("%s")),',
            body_indent, lua_key(id), escape_lua_string(id))
    end

    local body = newline .. table.concat(lines, newline) .. newline .. close_indent
    return script_text:sub(1, found.open_pos) .. body .. script_text:sub(found.close_pos)
end

function M.rewrite_music_map(script_text, mappings)
    local found, err = find_self_table(script_text, "_music_map")
    if not found then return nil, err end

    local newline = detect_newline(script_text)
    local body_indent = found.body:match("\n([ \t]*)%S")
    if not body_indent then
        body_indent = line_indent_before(script_text, found.open_pos) .. "  "
    end
    local close_indent = line_indent_before(script_text, found.close_pos)
    local lines = {
        body_indent .. "-- Reset to empty; add theme aliases after syncing project music.",
    }
    local keys = sorted_keys(mappings or {})
    for _, key in ipairs(keys) do
        lines[#lines + 1] = string.format('%s%s = "%s",',
            body_indent, lua_key(key), escape_lua_string(mappings[key]))
    end
    local body = newline .. table.concat(lines, newline) .. newline .. close_indent
    return script_text:sub(1, found.open_pos) .. body .. script_text:sub(found.close_pos)
end

local function parse_table_assignment_keys(script_text, field_name)
    local found = find_self_table(script_text, field_name)
    if not found then
        return {}
    end

    local keys = {}
    local seen = {}
    for line in found.body:gmatch("[^\r\n]+") do
        local clean = line:gsub("%-%-.*$", "")
        local key = clean:match("^%s*([%a_][%w_]*)%s*=")
            or clean:match('^%s*%[%s*"([^"]+)"%s*%]%s*=')
        if key and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

function M.parse_music_table_ids(script_text)
    return parse_table_assignment_keys(script_text, "_music")
end

local function parse_top_level_blocks(text)
    local blocks = {}
    local pos = 1
    while true do
        local start_pos, open_pos, kind = text:find("([%a_][%w_]*)%s*{", pos)
        if not start_pos then
            break
        end
        if kind == "components" or kind == "embedded_components" then
            local close_pos = find_matching_char(text, open_pos, "{", "}")
            if not close_pos then
                return nil, string.format("Could not find closing brace for %s block", kind)
            end
            blocks[#blocks + 1] = {
                kind = kind,
                start_pos = start_pos,
                open_pos = open_pos,
                close_pos = close_pos,
                text = text:sub(start_pos, close_pos),
            }
            pos = close_pos + 1
        else
            pos = open_pos + 1
        end
    end
    return blocks
end

local function is_music_embedded_component(block_text)
    return block_text:find('group:%s*\\"music\\"') ~= nil
        or block_text:find('group:%s*"music"') ~= nil
end

local function component_id(block_text)
    return block_text:match('id:%s*"([^"]+)"')
end

local function trim_one_trailing_newline(text, pos)
    if text:sub(pos, pos + 1) == "\r\n" then
        return pos + 2
    end
    if text:sub(pos, pos) == "\n" then
        return pos + 1
    end
    return pos
end

local function generate_music_component_blocks(tracks, newline)
    local blocks = {}
    for _, track in ipairs(tracks or {}) do
        local id = tostring(track.track_id or track)
        local filename = tostring(track.filename or (id .. ".ogg"))
        blocks[#blocks + 1] = table.concat({
            "embedded_components {",
            string.format('  id: "%s"', escape_proto_string(id)),
            '  type: "sound"',
            string.format('  data: "sound: \\"/developer/assets/music/%s\\"\\n"', escape_proto_string(filename)),
            '  "looping: 1\\n"',
            '  "group: \\"music\\"\\n"',
            '  ""',
            "}",
        }, newline)
    end
    if #blocks == 0 then
        return ""
    end
    return table.concat(blocks, newline) .. newline
end

local function remove_music_blocks(go_text, blocks)
    local out = {}
    local pos = 1
    local removed_ids = {}
    for _, block in ipairs(blocks or {}) do
        if block.kind == "embedded_components" and is_music_embedded_component(block.text) then
            out[#out + 1] = go_text:sub(pos, block.start_pos - 1)
            local id = component_id(block.text)
            if id then
                removed_ids[#removed_ids + 1] = id
            end
            pos = trim_one_trailing_newline(go_text, block.close_pos + 1)
        end
    end
    out[#out + 1] = go_text:sub(pos)
    table.sort(removed_ids)
    return table.concat(out), removed_ids
end

local function insertion_anchor_after_components(text)
    local blocks = parse_top_level_blocks(text)
    if not blocks then
        return nil
    end

    local anchor = nil
    local first_embedded = nil
    for _, block in ipairs(blocks) do
        if block.kind == "components" then
            anchor = block.close_pos
        elseif block.kind == "embedded_components" and not first_embedded then
            first_embedded = block.start_pos
        end
    end

    if anchor then
        return trim_one_trailing_newline(text, anchor + 1) - 1
    end
    if first_embedded then
        return first_embedded - 1
    end
    return #text
end

function M.rewrite_audio_go(go_text, tracks)
    local blocks, err = parse_top_level_blocks(go_text)
    if not blocks then
        return nil, err
    end
    local filtered, removed_ids = remove_music_blocks(go_text, blocks)
    local anchor = insertion_anchor_after_components(filtered)
    if not anchor then
        return nil, "Could not find insertion point in audio_controller.go"
    end

    local generated = generate_music_component_blocks(tracks, detect_newline(go_text))
    local rewritten = filtered:sub(1, anchor) .. generated .. filtered:sub(anchor + 1)
    return rewritten, {
        removed_ids = removed_ids,
    }
end

function M.rewrite_music_tracks_enum(json_text, tracks, enum_name)
    enum_name = tostring(enum_name or "music_tracks")
    local name_pattern = '"name"%s*:%s*' .. escape_lua_pattern(escape_json_string(enum_name))
    local name_start, name_end = json_text:find(name_pattern)
    if not name_start then
        return nil, "Could not find " .. enum_name .. " enum"
    end

    local _, open_pos = json_text:find('"values"%s*:%s*%[', name_end + 1)
    if not open_pos then
        return nil, "Could not find " .. enum_name .. " values array"
    end
    local close_pos = find_matching_char(json_text, open_pos, "[", "]")
    if not close_pos then
        return nil, "Could not find closing bracket for " .. enum_name .. " values"
    end

    local newline = detect_newline(json_text)
    local body = json_text:sub(open_pos + 1, close_pos - 1)
    local value_indent = body:match("\n([ \t]*)\"")
    local close_indent = line_indent_before(json_text, close_pos)
    if not value_indent then
        value_indent = close_indent .. "    "
    end

    -- "none" is always offered first: it is the "no music override" choice --
    -- whatever track is already playing keeps playing. It is not a track file.
    -- ("hush" is the legacy spelling; drop it so it never appears twice.)
    local ids = { "none" }
    -- Room/world defaults can inherit without changing existing soundtracks.
    -- Boss cues retain their separate, existing none/track contract.
    if enum_name == "music_tracks" then ids[#ids + 1] = "inherit" end
    for _, id in ipairs(track_ids_from_tracks(tracks)) do
        if id ~= "none" and id ~= "hush" and id ~= "inherit" then
            ids[#ids + 1] = id
        end
    end
    local lines = {}
    for i, id in ipairs(ids) do
        local comma = (i < #ids) and "," or ""
        lines[#lines + 1] = value_indent .. escape_json_string(id) .. comma
    end

    local replacement
    if #lines > 0 then
        replacement = newline .. table.concat(lines, newline) .. newline .. close_indent
    else
        replacement = newline .. close_indent
    end

    return json_text:sub(1, open_pos) .. replacement .. json_text:sub(close_pos)
end

function M.generate_music_tracks_manifest(tracks)
    local sorted = {}
    for _, track in ipairs(tracks or {}) do
        sorted[#sorted + 1] = {
            track_id = tostring(track.track_id or track),
            filename = tostring(track.filename or ((track.track_id or track) .. ".ogg")),
        }
    end
    table.sort(sorted, function(a, b)
        return track_sort_key(a) < track_sort_key(b)
    end)

    local lines = {
        "-- AUTO-GENERATED by Project > Sync Music. Do not edit by hand.",
        "return {",
        "    tracks = {",
    }
    for _, track in ipairs(sorted) do
        lines[#lines + 1] = string.format('        ["%s"] = { filename = "%s" },',
            escape_lua_string(track.track_id), escape_lua_string(track.filename))
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "    ids = {"
    for _, track in ipairs(sorted) do
        lines[#lines + 1] = string.format('        "%s",', escape_lua_string(track.track_id))
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

function M.detect_dangling_music_map(script_text, tracks)
    local found = find_self_table(script_text, "_music_map")
    if not found then
        return {}
    end

    local valid = M.track_id_set(tracks)
    local warnings = {}
    for line in found.body:gmatch("[^\r\n]+") do
        local clean = line:gsub("%-%-.*$", "")
        local key, value = clean:match('^%s*([%a_][%w_]*)%s*=%s*"([^"]+)"')
        if not key then
            key, value = clean:match('^%s*%[%s*"([^"]+)"%s*%]%s*=%s*"([^"]+)"')
        end
        if key and value and not valid[value] then
            warnings[#warnings + 1] = {
                theme = key,
                track_id = value,
            }
        end
    end

    table.sort(warnings, function(a, b)
        if a.track_id ~= b.track_id then
            return a.track_id < b.track_id
        end
        return a.theme < b.theme
    end)
    return warnings
end

function M.sorted_track_ids(tracks)
    local set = M.track_id_set(tracks)
    return sorted_keys(set)
end

return M
