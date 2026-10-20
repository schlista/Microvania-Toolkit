-- hooks/core/atlas_manifest.lua
--
-- Generates the runtime atlas-animation index from every project atlas.  The
-- index deliberately records source resource paths rather than build output
-- paths: those are the paths baked into sprite properties and available to
-- runtime scripts.

local M = {}

M.VERSION = 1
M.ATLAS_DIR = "developer/assets/atlas"
M.MANIFEST_PATH = "developer/config/atlas_animations_generated.lua"

local function trim_trailing_slashes(path)
    return tostring(path or "."):gsub("[/\\]+$", "")
end

local function join_path(root, rel_path)
    root = trim_trailing_slashes(root)
    rel_path = tostring(rel_path or ""):gsub("\\", "/"):gsub("^/+", "")
    if root == "" or root == "." then
        return rel_path
    end
    if rel_path == "" then
        return root
    end
    return root .. "/" .. rel_path
end

local function normalize_rel_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", "")
    path = path:gsub("/+", "/")
    return path
end

local function normalize_resource_path(path)
    path = normalize_rel_path(path)
    if path == "" then
        return nil
    end
    return "/" .. path
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function sorted_copy(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[#out + 1] = value
    end
    table.sort(out, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return out
end

-- Find the end of a protobuf-ish { ... } block. Atlas files are simple text
-- protos, but this also honours quoted strings so a path/comment-like string
-- containing a brace cannot desynchronise the scan.
local function find_matching_brace(text, open_pos)
    local depth = 0
    local quote = false
    local escaped = false

    for index = open_pos, #text do
        local ch = text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == '"' then
                quote = false
            end
        elseif ch == '"' then
            quote = true
        elseif ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then
                return index
            end
        end
    end

    return nil
end

local function is_identifier_character(ch)
    return ch ~= "" and ch:match("[%w_]") ~= nil
end

--- Parse all `animations { ... }` blocks in an atlas.
---
--- Returns a sorted array of animation ids plus an array of human-readable
--- parse errors. The parser deliberately accepts one-line and multi-line
--- Defold atlas forms and only requires an id field in each block.
function M.parse_animation_ids(atlas_text, atlas_path)
    atlas_text = tostring(atlas_text or "")
    local ids = {}
    local seen = {}
    local errors = {}
    local cursor = 1

    while cursor <= #atlas_text do
        local start_pos, open_pos = atlas_text:find("animations%s*{", cursor)
        if not start_pos then
            break
        end

        -- Avoid treating a longer field name such as `foo_animations` as an
        -- animation block. Defold's emitted field name is exactly
        -- `animations`.
        local before = start_pos > 1 and atlas_text:sub(start_pos - 1, start_pos - 1) or ""
        if is_identifier_character(before) then
            cursor = open_pos + 1
        else
            local close_pos = find_matching_brace(atlas_text, open_pos)
            if not close_pos then
                errors[#errors + 1] = string.format(
                    "Unclosed animations block near byte %d in %s.",
                    start_pos,
                    tostring(atlas_path or "<atlas>")
                )
                break
            end

            local block = atlas_text:sub(start_pos, close_pos)
            local id = block:match('id%s*:%s*"([^"\r\n]*)"')
            if not id or id == "" then
                errors[#errors + 1] = string.format(
                    "Animation block near byte %d in %s is missing a non-empty id.",
                    start_pos,
                    tostring(atlas_path or "<atlas>")
                )
            elseif seen[id] then
                errors[#errors + 1] = string.format(
                    "Animation id '%s' is duplicated in %s.",
                    id,
                    tostring(atlas_path or "<atlas>")
                )
            else
                seen[id] = true
                ids[#ids + 1] = id
            end
            cursor = close_pos + 1
        end
    end

    table.sort(ids)
    return ids, errors
end

local function append_file_if_atlas(files, rel_path)
    rel_path = normalize_rel_path(rel_path)
    if rel_path:lower():match("%.atlas$") then
        files[#files + 1] = rel_path
    end
end

local function collect_paths_from_explicit_files(files)
    local out = {}
    if type(files) ~= "table" then
        return out
    end
    for key, value in pairs(files) do
        local path = type(key) == "number" and value or key
        if type(path) == "string" then
            append_file_if_atlas(out, path)
        end
    end
    return sorted_copy(out)
end

--- Find every atlas under developer/assets/atlas. The editor supplies a
--- filesystem bridge, while the lfs fallback keeps the helper useful in the
--- command-line generator and in isolated tests.
function M.collect_atlas_paths(deps)
    deps = deps or {}
    if deps.atlas_files ~= nil then
        return collect_paths_from_explicit_files(deps.atlas_files), {}
    end

    local files = {}
    local errors = {}
    local seen_dirs = {}
    local root = deps.root or "."
    local list_dir = deps.list_dir_filesystem
    if type(list_dir) ~= "function" then
        local ok_fs, filesystem = pcall(require, "hooks.core.filesystem")
        if ok_fs and filesystem then
            list_dir = filesystem.list_dir_filesystem
        end
    end

    local function walk(rel_dir)
        rel_dir = normalize_rel_path(rel_dir)
        if seen_dirs[rel_dir] then
            return
        end
        seen_dirs[rel_dir] = true

        local dirs, dir_files
        if type(list_dir) == "function" then
            local ok, listed_dirs, listed_files = pcall(list_dir, join_path(root, rel_dir))
            if not ok then
                errors[#errors + 1] = string.format(
                    "Could not list atlas directory %s: %s.",
                    rel_dir,
                    tostring(listed_dirs)
                )
                return
            end
            dirs = type(listed_dirs) == "table" and listed_dirs or {}
            dir_files = type(listed_files) == "table" and listed_files or {}
        else
            local ok_lfs, lfs = pcall(require, "lfs")
            dirs, dir_files = {}, {}
            local abs_dir = join_path(root, rel_dir)
            if ok_lfs and lfs and lfs.dir and lfs.attributes then
                local mode = lfs.attributes(abs_dir, "mode")
                if mode == "directory" then
                    for name in lfs.dir(abs_dir) do
                        if name ~= "." and name ~= ".." then
                            local mode_for_entry = lfs.attributes(abs_dir .. "/" .. name, "mode")
                            if mode_for_entry == "directory" then
                                dirs[#dirs + 1] = name
                            elseif mode_for_entry == "file" then
                                dir_files[#dir_files + 1] = name
                            end
                        end
                    end
                end
            else
                errors[#errors + 1] = "Atlas directory listing is unavailable (no filesystem bridge or lfs)."
                return
            end
        end

        for _, name in ipairs(sorted_copy(dirs)) do
            if type(name) == "string" and name ~= "." and name ~= ".." then
                walk(rel_dir .. "/" .. name)
            end
        end
        for _, name in ipairs(sorted_copy(dir_files)) do
            if type(name) == "string" then
                append_file_if_atlas(files, rel_dir .. "/" .. name)
            end
        end
    end

    walk(M.ATLAS_DIR)
    table.sort(files)
    return files, errors
end

local function read_project_text(deps, rel_path)
    if type(deps.read_project_text) == "function" then
        return deps.read_project_text(rel_path)
    end
    if type(deps.read_text) == "function" then
        return deps.read_text(join_path(deps.root or ".", rel_path))
    end

    local path = join_path(deps.root or ".", rel_path)
    if type(deps.to_os_path) == "function" then
        path = deps.to_os_path(path)
    end
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local text = fh:read("*a")
    fh:close()
    return text
end

--- Collect the manifest data without writing it. Exposed for validators and
--- tests that need the same parser as the bake command.
function M.collect_manifest(deps)
    deps = deps or {}
    local atlas_paths, errors = M.collect_atlas_paths(deps)
    local atlases = {}
    local animation_count = 0

    for _, rel_path in ipairs(atlas_paths) do
        local atlas_text = read_project_text(deps, rel_path)
        if atlas_text == nil then
            errors[#errors + 1] = "Could not read atlas " .. rel_path .. "."
        else
            local resource_path = normalize_resource_path(rel_path)
            local ids, parse_errors = M.parse_animation_ids(atlas_text, resource_path)
            local set = {}
            for _, id in ipairs(ids) do
                set[id] = true
                animation_count = animation_count + 1
            end
            atlases[resource_path] = set
            for _, parse_error in ipairs(parse_errors) do
                errors[#errors + 1] = parse_error
            end
        end
    end

    return atlases, errors, {
        atlas_count = #atlas_paths,
        animation_count = animation_count,
        atlas_paths = atlas_paths,
    }
end

local function sorted_animation_ids(animations)
    local ids = {}
    for key, value in pairs(animations or {}) do
        if type(key) == "number" then
            if type(value) == "string" and value ~= "" then
                ids[#ids + 1] = value
            end
        elseif value == true and tostring(key) ~= "" then
            ids[#ids + 1] = tostring(key)
        end
    end
    table.sort(ids)
    return ids
end

--- Serialize a deterministic, safe-to-require Lua manifest. Bracket notation
--- is intentional: user-authored animation ids are not limited to Lua
--- identifiers.
function M.generate_manifest(atlases)
    local lines = {
        "-- GENERATED by Create Rooms / Validate All. Do not hand-edit.",
        "return {",
        "    version = " .. tostring(M.VERSION) .. ",",
        "    atlases = {",
    }

    for _, atlas_path in ipairs(sorted_keys(atlases)) do
        local normalized_path = normalize_resource_path(atlas_path)
        if normalized_path then
            lines[#lines + 1] = string.format("        [%q] = {", normalized_path)
            for _, id in ipairs(sorted_animation_ids(atlases[atlas_path])) do
                lines[#lines + 1] = string.format("            [%q] = true,", id)
            end
            lines[#lines + 1] = "        },"
        end
    end

    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

--- Generate developer/config/atlas_animations_generated.lua. Returns the
--- same `(ok, result_or_error)` shape as the other editor sync helpers.
function M.sync_core(deps)
    deps = deps or {}
    local atlases, errors, stats = M.collect_manifest(deps)
    if #errors > 0 then
        return false, table.concat(errors, "\n")
    end

    local text = M.generate_manifest(atlases)
    local changed = false
    if type(deps.write_project_text) == "function" then
        local ok, value = pcall(deps.write_project_text, M.MANIFEST_PATH, text)
        if not ok then
            return false, "Could not write " .. M.MANIFEST_PATH .. ": " .. tostring(value)
        end
        changed = value and true or false
    elseif type(deps.write_if_changed) == "function" then
        local target_path = join_path(deps.root or ".", M.MANIFEST_PATH)
        local ok, value = pcall(deps.write_if_changed, target_path, text)
        if not ok then
            return false, "Could not write " .. M.MANIFEST_PATH .. ": " .. tostring(value)
        end
        changed = value and true or false
    else
        return false, "Atlas manifest writer unavailable."
    end

    stats.changed_files = changed and { M.MANIFEST_PATH } or {}
    stats.manifest_path = M.MANIFEST_PATH
    return true, stats
end

M.sync = M.sync_core

return M
