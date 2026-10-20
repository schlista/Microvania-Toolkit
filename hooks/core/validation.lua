-- hooks/core/validation.lua
--
-- Validation command helpers used by editor hooks.

local M = {}

local AtlasManifest = require("hooks.core.atlas_manifest")
local PropertyTypes = require("hooks.core.property_types")

local EXIT_SENTINEL = {}
local COLLECTIONS_DIR = "developer/rooms/collections"
local ENEMY_ATLAS_PATH = "developer/assets/atlas/enemy.atlas"
local ENEMY_ART_DIR = "developer/assets/enemies"
local GENERATED_ENEMY_SPRITE_DIR = ENEMY_ART_DIR .. "/generated"
local DEFAULT_COLLECTIBLE_ATLAS = "/developer/assets/atlas/gameplay_visuals.atlas"
local NPC_PREFAB_PATH = "developer/game/prefabs/npc.go"
local GENERATED_ROOM_DIR = "developer/rooms/generated"
local PLAYER_ADDRESS_LITERAL = "main:" .. "/player"
local unpack_values = table.unpack or unpack

local function pack_values(...)
    local values = { ... }
    values.n = select("#", ...)
    return values
end

local function trim_trailing_slashes(path)
    return tostring(path or "."):gsub("[/\\]+$", "")
end

local function project_path(deps, rel_path)
    local to_os_path = deps.to_os_path or function(path) return path end
    return to_os_path(trim_trailing_slashes(deps.root) .. "/" .. rel_path)
end

function M.with_mvtk_bridge(bridge, fn)
    assert(type(fn) == "function", "with_mvtk_bridge requires a function")

    local previous_bridge = rawget(_G, "_MVTK")
    rawset(_G, "_MVTK", bridge)
    local results = pack_values(pcall(fn))
    rawset(_G, "_MVTK", previous_bridge)

    if not results[1] then
        error(results[2], 0)
    end
    return unpack_values(results, 2, results.n)
end

function M.build_validate_all_failure_message(steps)
    local failed_labels = {}
    for _, step in ipairs(steps or {}) do
        if step.status == "failed" then
            failed_labels[#failed_labels + 1] = tostring(step.label)
        end
    end
    return "Failed: " .. table.concat(failed_labels, ", ")
        .. ". See debug_output.txt in the project root."
end

function M.build_validate_all_success_message(steps)
    local passed_labels = {}
    local skipped_labels = {}
    for _, step in ipairs(steps or {}) do
        if step.status == "skipped" then
            skipped_labels[#skipped_labels + 1] = tostring(step.label)
        else
            passed_labels[#passed_labels + 1] = tostring(step.label)
        end
    end
    local message = "Passed: " .. table.concat(passed_labels, ", ") .. "."
    if #skipped_labels > 0 then
        message = message .. " Skipped: " .. table.concat(skipped_labels, ", ") .. "."
    end
    return message
end

local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local text = fh:read("*a")
    fh:close()
    return text
end

local function file_exists(path)
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

local function append_collection_file(files, name)
    if type(name) == "string" and name:match("%.collection$") then
        files[#files + 1] = COLLECTIONS_DIR .. "/" .. name
    end
end

local function list_collection_files(deps)
    if type(deps.list_collection_files) == "function" then
        local files = deps.list_collection_files() or {}
        table.sort(files)
        return files
    end

    local files = {}
    local project_dir = trim_trailing_slashes(deps.root) .. "/" .. COLLECTIONS_DIR
    if type(deps.list_dir_filesystem) == "function" then
        local ok_list, _, listed_files = pcall(deps.list_dir_filesystem, project_dir)
        if ok_list and type(listed_files) == "table" then
            for _, name in ipairs(listed_files) do
                append_collection_file(files, name)
            end
        end
    end

    if #files == 0 then
        local fs_dir = project_path(deps, COLLECTIONS_DIR)
        local ok_lfs, lfs = pcall(require, "lfs")
        if ok_lfs and lfs and lfs.dir and lfs.attributes then
            local mode = lfs.attributes(fs_dir, "mode")
            if mode == "directory" then
                for name in lfs.dir(fs_dir) do
                    append_collection_file(files, name)
                end
            end
        end
    end

    if #files == 0 then
        local fs_dir = project_path(deps, COLLECTIONS_DIR)
        local ok_fs, filesystem = pcall(require, "hooks.core.filesystem")
        if ok_fs and filesystem and type(filesystem.list_dir_filesystem) == "function" then
            local ok, _, listed_files = pcall(filesystem.list_dir_filesystem, fs_dir)
            if ok then
                for _, name in ipairs(listed_files or {}) do
                    append_collection_file(files, name)
                end
            end
        end
    end

    table.sort(files)
    return files
end

local function normalize_resource_path(path)
    path = tostring(path or "")
    if path == "" then
        return nil
    end
    path = path:gsub("\\", "/")
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

local function is_prefab_resource(resource_path)
    return type(resource_path) == "string" and resource_path:find("/prefabs/", 1, true) ~= nil
end

local function scan_prototype_paths(line, on_path)
    for proto in tostring(line or ""):gmatch('prototype:%s*"([^"]+)"') do
        on_path(proto)
    end
    for proto in tostring(line or ""):gmatch('prototype:%s*\\%"([^"]+)\\%"') do
        on_path(proto)
    end
end

local function parse_quoted_field(text, field_name)
    return tostring(text or ""):match(field_name .. ':%s*"([^"]+)"')
end

local function atlas_animation_info(atlas_text, animation_id)
    atlas_text = tostring(atlas_text or "")
    animation_id = tostring(animation_id or "")
    local cursor = 1
    while true do
        local start_pos, open_pos = atlas_text:find("animations%s*{", cursor)
        if not start_pos then
            return nil
        end

        local depth = 0
        local block_end = nil
        for i = open_pos, #atlas_text do
            local ch = atlas_text:sub(i, i)
            if ch == "{" then
                depth = depth + 1
            elseif ch == "}" then
                depth = depth - 1
                if depth == 0 then
                    block_end = i
                    break
                end
            end
        end

        if not block_end then
            return nil
        end

        local block = atlas_text:sub(start_pos, block_end)
        if parse_quoted_field(block, "id") == animation_id then
            local images = {}
            for image_path in block:gmatch('image:%s*"([^"]+)"') do
                images[#images + 1] = normalize_resource_path(image_path)
            end
            return {
                playback = block:match("playback:%s*([%w_]+)"),
                images = images,
            }
        end
        cursor = block_end + 1
    end
end

local function atlas_animation_entries(atlas_text)
    atlas_text = tostring(atlas_text or "")
    local entries = {}
    local cursor = 1
    while true do
        local start_pos, open_pos = atlas_text:find("animations%s*{", cursor)
        if not start_pos then
            return entries, nil
        end

        local depth = 0
        local block_end = nil
        for i = open_pos, #atlas_text do
            local ch = atlas_text:sub(i, i)
            if ch == "{" then
                depth = depth + 1
            elseif ch == "}" then
                depth = depth - 1
                if depth == 0 then
                    block_end = i
                    break
                end
            end
        end

        if not block_end then
            return entries, string.format("Unclosed animations block near byte %d in %s.", start_pos, ENEMY_ATLAS_PATH)
        end

        local block = atlas_text:sub(start_pos, block_end)
        local images = {}
        for image_path in block:gmatch('image:%s*"([^"]+)"') do
            images[#images + 1] = normalize_resource_path(image_path)
        end
        entries[#entries + 1] = {
            id = parse_quoted_field(block, "id"),
            images = images,
        }
        cursor = block_end + 1
    end
end

local function list_project_directory(deps, rel_path)
    if type(deps.list_dir_filesystem) == "function" then
        local abs_dir = trim_trailing_slashes(deps.root) .. "/" .. rel_path
        local ok, dirs, files = pcall(deps.list_dir_filesystem, abs_dir)
        if ok and type(dirs) == "table" and type(files) == "table" then
            table.sort(dirs)
            table.sort(files)
            return dirs, files
        end
    end

    local dirs, files = {}, {}
    local fs_dir = project_path(deps, rel_path)
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs and lfs and lfs.dir and lfs.attributes
        and lfs.attributes(fs_dir, "mode") == "directory"
    then
        for name in lfs.dir(fs_dir) do
            if name ~= "." and name ~= ".." then
                local full_path = fs_dir .. "/" .. name
                if lfs.attributes(full_path, "mode") == "directory" then
                    dirs[#dirs + 1] = name
                else
                    files[#files + 1] = name
                end
            end
        end
    end

    -- CLI validation may run without lfs. Reuse the single portability bridge
    -- instead of maintaining another set of platform command strings here.
    if #dirs == 0 and #files == 0 then
        local ok_fs, filesystem = pcall(require, "hooks.core.filesystem")
        if ok_fs and filesystem and type(filesystem.list_dir_filesystem) == "function" then
            local ok, listed_dirs, listed_files = pcall(filesystem.list_dir_filesystem, fs_dir)
            if ok then
                dirs = type(listed_dirs) == "table" and listed_dirs or dirs
                files = type(listed_files) == "table" and listed_files or files
            end
        end
    end
    table.sort(dirs)
    table.sort(files)
    return dirs, files
end

local function sorted_values(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[#out + 1] = value
    end
    table.sort(out, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return out
end

local function sorted_map_keys(values)
    local out = {}
    for key in pairs(values or {}) do
        out[#out + 1] = key
    end
    table.sort(out, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return out
end

local function join_rel_path(parent, child)
    parent = tostring(parent or ""):gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
    child = tostring(child or ""):gsub("\\", "/"):gsub("^/+", "")
    if parent == "" then return child end
    if child == "" then return parent end
    return parent .. "/" .. child
end

-- Recursive file enumeration through the same bridge used by editor hooks.
-- Tests can provide `project_files` directly to avoid filesystem setup.
local function collect_project_files(deps, roots, matcher)
    deps = deps or {}
    local supplied = deps.project_files
    if type(supplied) == "table" then
        local files = {}
        for key, value in pairs(supplied) do
            local path = type(key) == "number" and value or key
            if type(path) == "string" and (not matcher or matcher(path)) then
                files[#files + 1] = path:gsub("\\", "/")
            end
        end
        return sorted_values(files)
    end

    local files = {}
    local visited = {}
    local function walk(rel_dir)
        rel_dir = tostring(rel_dir or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/$", "")
        if visited[rel_dir] then return end
        visited[rel_dir] = true
        local dirs, entries = list_project_directory(deps, rel_dir)
        for _, dir in ipairs(sorted_values(dirs)) do
            if type(dir) == "string" and dir ~= "." and dir ~= ".." then
                walk(join_rel_path(rel_dir, dir))
            end
        end
        for _, name in ipairs(sorted_values(entries)) do
            if type(name) == "string" then
                local path = join_rel_path(rel_dir, name)
                if not matcher or matcher(path) then
                    files[#files + 1] = path
                end
            end
        end
    end

    for _, root in ipairs(roots or {}) do
        walk(root)
    end
    return sorted_values(files)
end

local function read_text_from_deps(deps, rel_path)
    if type(deps.read_project_text) == "function" then
        return deps.read_project_text(rel_path)
    end
    if type(deps.project_texts) == "table" and deps.project_texts[rel_path] ~= nil then
        return deps.project_texts[rel_path]
    end
    return read_file(project_path(deps, rel_path))
end

-- Baked script property types must match the declarations even when Bob accepts
-- stale overrides. Otherwise an instance can silently lose every property.
function M.collect_property_type_errors(deps)
    deps = deps or {}
    local errors, stats = {}, { files = 0 }
    -- Use the same exported-room list and world selection as Create Rooms.
    -- Retired-world files and handwritten scaffolds cannot be repaired by it.
    local room_ids = deps.room_ids
    if not room_ids then
        local list_room_ids = assert(deps.list_room_ids, "property validation requires list_room_ids")
        room_ids = require("developer.tools.world_layout").generation_room_ids({
            root = deps.root,
            world_manifest = deps.world_manifest,
        }, list_room_ids())
    end
    local current_rooms = {}
    for _, room_id in ipairs(room_ids) do
        current_rooms[room_id] = true
    end
    -- Check the current world's room collections. Each check also reads the
    -- generated prototypes the collection instantiates, so every baked file the
    -- game loads is covered. Generated files that no room references are skipped:
    -- Create Rooms does not delete the leftovers of removed objects, the game never
    -- loads them, and Prepare & Check cannot repair them.
    local paths = collect_project_files(deps, { COLLECTIONS_DIR }, function(path)
        path = path:gsub("\\", "/"):gsub("^/+", "")
        local room_id = path:match("^" .. COLLECTIONS_DIR .. "/([^/]+)%.collection$")
        return room_id ~= nil and current_rooms[room_id] == true
    end)
    local function read_resource(path)
        return read_text_from_deps(deps, path:gsub("\\", "/"):gsub("^/+", ""))
    end
    for _, path in ipairs(paths) do
        local text = read_resource(path)
        if not text then
            errors[#errors + 1] = "Could not read script property types from " .. path .. "."
        else
            stats.files = stats.files + 1
            local check = path:match("%.collection$") and PropertyTypes.check_collection or PropertyTypes.check_go
            local ok, mismatches = pcall(check, text, read_resource)
            if not ok then
                errors[#errors + 1] = path .. ": could not check script property types: " .. tostring(mismatches)
            else
                for _, mismatch in ipairs(mismatches) do
                    local where = path
                    if mismatch.source then
                        where = (tostring(mismatch.source):gsub("^/+", "")) .. " (used by " .. path .. ")"
                    end
                    errors[#errors + 1] = string.format(
                        "%s: '%s' of %s is stored as %s but the script declares %s. Run Prepare & Check. If it remains, re-enter the value in the Defold Properties panel, or report a toolkit bug.",
                        where, tostring(mismatch.property), tostring(mismatch.script or "<missing script>"),
                        tostring(mismatch.stored), tostring(mismatch.declared or "<undeclared>"))
                end
            end
        end
    end
    return errors, stats
end

local function load_lua_table_from_deps(deps, rel_path)
    if type(deps.load_lua_table) == "function" then
        return deps.load_lua_table(rel_path)
    end
    local text = read_text_from_deps(deps, rel_path)
    if not text then
        return nil, "missing"
    end
    local loader = loadstring or load
    local chunk, compile_err = loader(text, "@" .. tostring(rel_path))
    if not chunk then
        return nil, compile_err
    end
    local ok, result = pcall(chunk)
    if not ok then
        return nil, result
    end
    if type(result) ~= "table" then
        return nil, "module did not return a table"
    end
    return result
end

local function normalized_animation_set(value)
    if type(value) ~= "table" then return nil end
    local set = {}
    for key, present in pairs(value) do
        if type(key) == "number" then
            if type(present) == "string" and present ~= "" then
                set[present] = true
            end
        elseif present == true then
            set[tostring(key)] = true
        end
    end
    return set
end

local function atlas_animation_set(deps, atlas_path, cache)
    atlas_path = normalize_resource_path(atlas_path)
    if not atlas_path then
        return nil, "atlas path is empty"
    end

    cache = cache or {}
    if cache[atlas_path] ~= nil then
        return cache[atlas_path]
    end

    local supplied = deps.atlas_animations
    if type(supplied) == "table" and supplied[atlas_path] ~= nil then
        local set = normalized_animation_set(supplied[atlas_path]) or {}
        cache[atlas_path] = set
        return set
    end

    local text = read_text_from_deps(deps, atlas_path:gsub("^/", ""))
    if not text then
        return nil, "could not read atlas " .. atlas_path
    end
    local ids, parse_errors = AtlasManifest.parse_animation_ids(text, atlas_path)
    if #parse_errors > 0 then
        return nil, table.concat(parse_errors, "; ")
    end
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    cache[atlas_path] = set
    return set
end

local function atlas_contains_animation(deps, atlas_path, animation, cache)
    local set, err = atlas_animation_set(deps, atlas_path, cache)
    if not set then return nil, err end
    return set[tostring(animation or "")] == true
end

local function find_matching_proto_brace(text, open_pos)
    local depth = 0
    local quoted = false
    local escaped = false
    for index = open_pos, #text do
        local ch = text:sub(index, index)
        if quoted then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == '"' then
                quoted = false
            end
        elseif ch == '"' then
            quoted = true
        elseif ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then return index end
        end
    end
    return nil
end

local function find_named_proto_blocks(text, name)
    text = tostring(text or "")
    local blocks = {}
    local cursor = 1
    while cursor <= #text do
        local start_pos, open_pos = text:find(name .. "%s*{", cursor)
        if not start_pos then break end
        local before = start_pos > 1 and text:sub(start_pos - 1, start_pos - 1) or ""
        if before:match("[%w_]") then
            cursor = open_pos + 1
        else
            local close_pos = find_matching_proto_brace(text, open_pos)
            if not close_pos then break end
            blocks[#blocks + 1] = {
                text = text:sub(start_pos, close_pos),
                start_pos = start_pos,
            }
            cursor = close_pos + 1
        end
    end
    return blocks
end

local function component_property_value(component_text, wanted_id)
    for _, block in ipairs(find_named_proto_blocks(component_text, "properties")) do
        local property_id = block.text:match('id:%s*"([^"]+)"')
        if property_id == wanted_id then
            return block.text:match('value:%s*"([^"]*)"')
        end
    end
    return nil
end

local function collect_go_component_records(go_text)
    local records = {}
    local function append(kind, block)
        local text = block.text
        local id = text:match(kind .. '%s*{%s*id:%s*"([^"]+)"')
            or text:match('\nid:%s*"([^"]+)"')
        records[#records + 1] = {
            id = id,
            kind = kind,
            text = text,
            component = text:match('component:%s*"([^"]+)"'),
            type = text:match('type:%s*"([^"]+)"'),
        }
    end
    for _, block in ipairs(find_named_proto_blocks(go_text, "components")) do
        append("components", block)
    end
    for _, block in ipairs(find_named_proto_blocks(go_text, "embedded_components")) do
        append("embedded_components", block)
    end
    return records
end

local function first_atlas_path(text)
    text = tostring(text or "")
    for path in text:gmatch('tile_set:%s*\\?"([^"\\]+)\\?"') do
        local normalized = normalize_resource_path(path)
        if normalized and normalized:lower():match("%.atlas$") then
            return normalized
        end
    end
    for path in text:gmatch('texture:%s*\\?"([^"\\]+)\\?"') do
        local normalized = normalize_resource_path(path)
        if normalized and normalized:lower():match("%.atlas$") then
            return normalized
        end
    end
    return nil
end

local function is_sprite_component(record)
    if not record then return false end
    return record.type == "sprite"
        or (type(record.component) == "string" and record.component:lower():match("%.sprite$") ~= nil)
end

local function sprite_component_atlas(deps, record)
    if not record then return nil end
    local atlas = first_atlas_path(record.text)
    if atlas then return atlas end
    if type(record.component) == "string" and record.component:lower():match("%.sprite$") then
        local sprite_text = read_text_from_deps(deps, record.component:gsub("^/", ""))
        return sprite_text and first_atlas_path(sprite_text) or nil
    end
    return nil
end

local function component_by_id(records, wanted_id)
    for _, record in ipairs(records or {}) do
        if record.id == wanted_id then return record end
    end
    return nil
end

local function resolve_anim_controller_atlas(deps, records, anim_record)
    local explicit = component_property_value(anim_record.text, "sprite_atlas")
    if explicit and explicit ~= "" then
        return normalize_resource_path(explicit)
    end

    local target_id = component_property_value(anim_record.text, "sprite_id")
    if target_id and target_id ~= "" then
        target_id = target_id:match("#([^#]+)$") or target_id
        local target = component_by_id(records, target_id)
        local atlas = sprite_component_atlas(deps, target)
        if atlas then return atlas end
    end

    local default_sprite = component_by_id(records, "sprite")
    local default_atlas = sprite_component_atlas(deps, default_sprite)
    if default_atlas then return default_atlas end

    for _, record in ipairs(records or {}) do
        if is_sprite_component(record) then
            local atlas = sprite_component_atlas(deps, record)
            if atlas then return atlas end
        end
    end
    return nil
end

local function is_animation_controller(record)
    return type(record and record.component) == "string"
        and record.component:find("/mvtk/animation/animation_controller.script", 1, true) ~= nil
end

local function is_tilemap_component(record)
    return type(record and record.component) == "string"
        and record.component:lower():match("%.tilemap$") ~= nil
end

local function is_collision_component(record)
    return record and (record.type == "collisionobject"
        or (type(record.component) == "string" and record.component:lower():match("%.collisionobject$") ~= nil))
end

local function collision_shape_path(component_text)
    for path in tostring(component_text or ""):gmatch('collision_shape:%s*\\?"([^"\\]*)\\?"') do
        if path ~= "" then
            return normalize_resource_path(path)
        end
    end
    return nil
end

local COMBAT_SPRITE_IMAGE_RULES = {
    ["developer/game/attacks/projectile.sprite"] = {
        animation = "projectile",
        forbidden_images = {
            ["/developer/assets/atlas/placeholder_base.png"] = "placeholder art",
        },
    },
}

function M.collect_stale_collection_prefab_errors(deps)
    deps = deps or {}
    local errors = {}
    local scanned = 0

    local function read_project_text(rel_path)
        if type(deps.read_project_text) == "function" then
            return deps.read_project_text(rel_path)
        end
        return read_file(project_path(deps, rel_path))
    end

    local function resource_exists(resource_path)
        if type(deps.resource_exists) == "function" then
            return deps.resource_exists(resource_path)
        end
        return file_exists(project_path(deps, resource_path:gsub("^/", "")))
    end

    for _, rel_path in ipairs(list_collection_files(deps)) do
        scanned = scanned + 1
        local room_id = rel_path:match("([^/\\]+)%.collection$") or rel_path
        local text = read_project_text(rel_path)
        if not text then
            errors[#errors + 1] = string.format("Room '%s' collection could not be read: %s", room_id, rel_path)
        else
            local line_no = 0
            for line in (text .. "\n"):gmatch("(.-)\n") do
                line_no = line_no + 1
                scan_prototype_paths(line, function(proto)
                    local resource_path = normalize_resource_path(proto)
                    if is_prefab_resource(resource_path) and not resource_exists(resource_path) then
                        errors[#errors + 1] = string.format(
                            "Room '%s' references missing prefab %s at %s:%d.",
                            room_id,
                            resource_path,
                            rel_path,
                            line_no
                        )
                    end
                end)
            end
        end
    end

    return errors, scanned
end

function M.collect_sprite_default_playback_errors(deps)
    deps = deps or {}
    local errors = {}
    local scanned = 0
    local sprite_files = deps.sprite_files or {
        "developer/game/attacks/projectile.sprite",
    }

    local function read_project_text(rel_path)
        if type(deps.read_project_text) == "function" then
            return deps.read_project_text(rel_path)
        end
        return read_file(project_path(deps, rel_path))
    end

    for _, rel_path in ipairs(sprite_files) do
        scanned = scanned + 1
        local sprite_text = read_project_text(rel_path)
        if not sprite_text then
            errors[#errors + 1] = string.format("Sprite '%s' could not be read.", rel_path)
        else
            local tile_set = normalize_resource_path(parse_quoted_field(sprite_text, "tile_set"))
            local default_animation = parse_quoted_field(sprite_text, "default_animation")
            if not tile_set or not default_animation or default_animation == "" then
                errors[#errors + 1] = string.format("Sprite '%s' is missing tile_set or default_animation.", rel_path)
            else
                local atlas_rel_path = tile_set:gsub("^/", "")
                local atlas_text = read_project_text(atlas_rel_path)
                if not atlas_text then
                    errors[#errors + 1] = string.format(
                        "Sprite '%s' references missing atlas %s.",
                        rel_path,
                        tile_set
                    )
                else
                    local animation = atlas_animation_info(atlas_text, default_animation)
                    if not animation then
                        errors[#errors + 1] = string.format(
                            "Sprite '%s' default_animation '%s' is missing from %s.",
                            rel_path,
                            default_animation,
                            tile_set
                        )
                    elseif animation.playback == "PLAYBACK_NONE" then
                        errors[#errors + 1] = string.format(
                            "Sprite '%s' default_animation '%s' uses PLAYBACK_NONE in %s; spawned combat sprites must render from a playable animation.",
                            rel_path,
                            default_animation,
                            tile_set
                        )
                    else
                        local image_rule = COMBAT_SPRITE_IMAGE_RULES[rel_path]
                        if image_rule and image_rule.animation == default_animation then
                            for _, image_path in ipairs(animation.images or {}) do
                                local label = image_rule.forbidden_images[image_path]
                                if label then
                                    errors[#errors + 1] = string.format(
                                        "Sprite '%s' default_animation '%s' uses %s image %s in %s; spawned combat sprites need dedicated projectile art.",
                                        rel_path,
                                        default_animation,
                                        label,
                                        image_path,
                                        tile_set
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return errors, scanned
end

-- Guard the shared enemy atlas and generated per-skin sprites against the
-- malformed asset shapes implicated in native sprite vertex generation. This
-- remains a static Validate All check: it never rewrites or regenerates art.
function M.collect_enemy_sprite_asset_errors(deps)
    deps = deps or {}
    local errors = {}
    local stats = { animations = 0, sprites = 0, skins = 0 }

    local function read_project_text(rel_path)
        if type(deps.read_project_text) == "function" then
            return deps.read_project_text(rel_path)
        end
        return read_file(project_path(deps, rel_path))
    end

    local function read_project_binary(rel_path)
        if type(deps.read_project_binary) == "function" then
            return deps.read_project_binary(rel_path)
        end
        return read_file(project_path(deps, rel_path))
    end

    local atlas_text = deps.enemy_atlas_text or read_project_text(ENEMY_ATLAS_PATH)
    if not atlas_text then
        errors[#errors + 1] = string.format("Enemy atlas could not be read: %s.", ENEMY_ATLAS_PATH)
        return errors, stats
    end

    local animations, atlas_err = atlas_animation_entries(atlas_text)
    if atlas_err then
        errors[#errors + 1] = atlas_err
    end
    local atlas_ids = {}
    for index, animation in ipairs(animations) do
        stats.animations = stats.animations + 1
        local id = animation.id
        if id and id ~= "" then
            atlas_ids[id] = true
        end
        if #(animation.images or {}) == 0 then
            errors[#errors + 1] = string.format(
                "Enemy atlas animation '%s' has zero images in %s.",
                id or ("<unnamed #" .. tostring(index) .. ">"),
                ENEMY_ATLAS_PATH
            )
        end
    end

    local _, generated_files = list_project_directory(deps, GENERATED_ENEMY_SPRITE_DIR)
    for _, filename in ipairs(generated_files) do
        if tostring(filename):lower():match("%.sprite$") then
            stats.sprites = stats.sprites + 1
            local rel_path = GENERATED_ENEMY_SPRITE_DIR .. "/" .. filename
            local sprite_text = read_project_text(rel_path)
            if not sprite_text then
                errors[#errors + 1] = string.format("Generated enemy sprite could not be read: %s.", rel_path)
            else
                local default_animation = parse_quoted_field(sprite_text, "default_animation")
                if not default_animation or default_animation == "" then
                    errors[#errors + 1] = string.format("Generated enemy sprite '%s' has no default_animation.", rel_path)
                elseif not atlas_ids[default_animation] then
                    errors[#errors + 1] = string.format(
                        "Generated enemy sprite '%s' default_animation '%s' is absent from %s.",
                        rel_path,
                        default_animation,
                        ENEMY_ATLAS_PATH
                    )
                end
            end
        end
    end

    local png_dimensions = deps.png_dimensions
    if type(png_dimensions) ~= "function" then
        local ok_sync, EnemySkinSync = pcall(require, "mvtk.enemies.enemy_skin_sync")
        if ok_sync and EnemySkinSync and type(EnemySkinSync.png_dimensions_from_bytes) == "function" then
            png_dimensions = EnemySkinSync.png_dimensions_from_bytes
        end
    end

    local skin_folders = list_project_directory(deps, ENEMY_ART_DIR)
    for _, folder in ipairs(skin_folders) do
        if folder ~= "generated" then
            stats.skins = stats.skins + 1
            local skin_dir = ENEMY_ART_DIR .. "/" .. folder
            local _, frame_files = list_project_directory(deps, skin_dir)
            local expected_width, expected_height, expected_file = nil, nil, nil
            for _, filename in ipairs(frame_files) do
                if tostring(filename):lower():match("%.png$") then
                    local rel_path = skin_dir .. "/" .. filename
                    local bytes = read_project_binary(rel_path)
                    local width, height = nil, nil
                    if type(png_dimensions) == "function" and bytes then
                        width, height = png_dimensions(bytes)
                    end
                    if width and height then
                        if not expected_width then
                            expected_width, expected_height, expected_file = width, height, filename
                        elseif width ~= expected_width or height ~= expected_height then
                            errors[#errors + 1] = string.format(
                                "Enemy skin '%s' mixes frame sizes: %s is %dx%d, but %s is %dx%d.",
                                tostring(folder),
                                tostring(expected_file),
                                expected_width,
                                expected_height,
                                tostring(filename),
                                width,
                                height
                            )
                        end
                    end
                end
            end
        end
    end

    return errors, stats
end

-- V1: every collectible animation must exist in the atlas that its baked
-- sprite will use. Entries without an explicit sprite use the shared gameplay
-- atlas, matching the collectible baker and runtime fallback.
function M.collect_collectible_animation_errors(deps)
    deps = deps or {}
    local errors = {}
    local stats = { entries = 0, pairs = 0 }
    local types = deps.collectible_types
    if type(types) ~= "table" then
        types = load_lua_table_from_deps(deps, "developer/config/collectible_types.lua")
    end
    if type(types) ~= "table" then
        errors[#errors + 1] = "Could not load developer/config/collectible_types.lua."
        return errors, stats
    end

    local cache = {}
    for _, type_id in ipairs(sorted_map_keys(types)) do
        local entry = types[type_id]
        if type(entry) == "table" then
            stats.entries = stats.entries + 1
            local animation = entry.animation
            if animation ~= nil and tostring(animation) ~= "" then
                stats.pairs = stats.pairs + 1
                local atlas_path = normalize_resource_path(entry.sprite or DEFAULT_COLLECTIBLE_ATLAS)
                if not atlas_path then
                    errors[#errors + 1] = string.format(
                        "Collectible '%s' has animation '%s' but no usable sprite atlas.",
                        tostring(type_id), tostring(animation))
                else
                    local present, err = atlas_contains_animation(deps, atlas_path, animation, cache)
                    if present == nil then
                        errors[#errors + 1] = string.format(
                            "Collectible '%s' could not validate animation '%s' in %s: %s.",
                            tostring(type_id), tostring(animation), atlas_path, tostring(err))
                    elseif not present then
                        errors[#errors + 1] = string.format(
                            "Collectible '%s' animation '%s' is missing from %s.",
                            tostring(type_id), tostring(animation), atlas_path)
                    end
                end
            end
        end
    end
    return errors, stats
end

-- V2: npc_types.lua is authored independently of the NPC prefab, so resolve
-- the prefab's real sprite atlas instead of assuming gameplay_visuals forever.
function M.collect_npc_animation_errors(deps)
    deps = deps or {}
    local errors = {}
    local stats = { entries = 0, sprites = 0 }
    local types = deps.npc_types
    if type(types) ~= "table" then
        types = load_lua_table_from_deps(deps, "developer/config/npc_types.lua")
    end
    if type(types) ~= "table" then
        errors[#errors + 1] = "Could not load developer/config/npc_types.lua."
        return errors, stats
    end

    local atlas_path = normalize_resource_path(deps.npc_atlas)
    if not atlas_path then
        local prefab_text = read_text_from_deps(deps, deps.npc_prefab_path or NPC_PREFAB_PATH)
        atlas_path = prefab_text and first_atlas_path(prefab_text) or nil
    end
    if not atlas_path then
        errors[#errors + 1] = "Could not resolve the sprite atlas used by " .. NPC_PREFAB_PATH .. "."
        return errors, stats
    end

    local cache = {}
    for _, npc_type in ipairs(sorted_map_keys(types)) do
        local entry = types[npc_type]
        if type(entry) == "table" then
            stats.entries = stats.entries + 1
            local sprite = entry.sprite
            if sprite ~= nil and tostring(sprite) ~= "" then
                stats.sprites = stats.sprites + 1
                local present, err = atlas_contains_animation(deps, atlas_path, sprite, cache)
                if present == nil then
                    errors[#errors + 1] = string.format(
                        "NPC type '%s' could not validate sprite '%s' in %s: %s.",
                        tostring(npc_type), tostring(sprite), atlas_path, tostring(err))
                elseif not present then
                    errors[#errors + 1] = string.format(
                        "NPC type '%s' sprite '%s' is missing from %s.",
                        tostring(npc_type), tostring(sprite), atlas_path)
                end
            end
        end
    end
    return errors, stats
end

local function supplied_file_paths(files)
    local out = {}
    for key, value in pairs(files or {}) do
        local path = type(key) == "number" and value or key
        if type(path) == "string" then out[#out + 1] = path:gsub("\\", "/") end
    end
    return sorted_values(out)
end

local function supplied_file_text(files, path)
    if type(files) ~= "table" then return nil end
    if type(files[path]) == "string" then return files[path] end
    return nil
end

-- V3: a prefab with an animation_controller must have a usable initial state
-- in the atlas its target sprite actually references. Omitted default_state
-- inherits the controller script's `idle`; explicitly empty values are a
-- configuration error because the controller will attempt to play an empty id.
function M.collect_animation_controller_default_errors(deps)
    deps = deps or {}
    local errors = {}
    local stats = { prefabs = 0, controllers = 0 }
    local supplied = deps.prefab_files
    local paths
    if type(supplied) == "table" then
        paths = supplied_file_paths(supplied)
    else
        paths = collect_project_files(deps, deps.prefab_dirs or {
            "developer/game",
            GENERATED_ROOM_DIR,
            "mvtk",
        }, function(path)
            return path:lower():match("%.go$") ~= nil
        end)
    end

    local cache = {}
    for _, rel_path in ipairs(paths) do
        local go_text = supplied_file_text(supplied, rel_path) or read_text_from_deps(deps, rel_path)
        if go_text then
            stats.prefabs = stats.prefabs + 1
            local records = collect_go_component_records(go_text)
            for _, record in ipairs(records) do
                if is_animation_controller(record) then
                    stats.controllers = stats.controllers + 1
                    local use_spine = component_property_value(record.text, "use_spine")
                    local spine_only = use_spine == "1" or use_spine == "1.0" or use_spine == "true"
                    local state = component_property_value(record.text, "default_state")
                    if spine_only then
                        -- Spine animation names live in the Spine resource,
                        -- not an atlas; V3 intentionally validates only the
                        -- sprite flipbook path.
                    elseif state == "" then
                        errors[#errors + 1] = string.format(
                            "Prefab '%s' animation_controller '%s' has an empty default_state.",
                            rel_path, tostring(record.id or "<unnamed>"))
                    else
                        state = state or "idle"
                        local atlas_path = resolve_anim_controller_atlas(deps, records, record)
                        if not atlas_path then
                            errors[#errors + 1] = string.format(
                                "Prefab '%s' animation_controller '%s' has no resolvable sprite atlas.",
                                rel_path, tostring(record.id or "<unnamed>"))
                        else
                            local present, err = atlas_contains_animation(deps, atlas_path, state, cache)
                            if present == nil then
                                errors[#errors + 1] = string.format(
                                    "Prefab '%s' animation_controller '%s' could not validate default_state '%s' in %s: %s.",
                                    rel_path, tostring(record.id or "<unnamed>"), state, atlas_path, tostring(err))
                            elseif not present then
                                errors[#errors + 1] = string.format(
                                    "Prefab '%s' animation_controller '%s' default_state '%s' is missing from %s.",
                                    rel_path, tostring(record.id or "<unnamed>"), state, atlas_path)
                            end
                        end
                    end
                end
            end
        else
            errors[#errors + 1] = "Could not read animation-controller prefab " .. rel_path .. "."
        end
    end
    return errors, stats
end

-- V4 is deliberately a warning: it identifies a noisy composition that the
-- Phase B room-bake split fixes without rejecting a creator's project before
-- they have had a chance to rebuild generated rooms.
function M.collect_generated_tilemap_collision_warnings(deps)
    deps = deps or {}
    local warnings = {}
    local stats = { prefabs = 0, tilemap_prefabs = 0, collision_components = 0 }
    local supplied = deps.generated_go_files
    local paths
    if type(supplied) == "table" then
        paths = supplied_file_paths(supplied)
    else
        paths = collect_project_files(deps, { deps.generated_room_dir or GENERATED_ROOM_DIR }, function(path)
            return path:lower():match("%.go$") ~= nil
        end)
    end

    for _, rel_path in ipairs(paths) do
        local go_text = supplied_file_text(supplied, rel_path) or read_text_from_deps(deps, rel_path)
        if go_text then
            stats.prefabs = stats.prefabs + 1
            local records = collect_go_component_records(go_text)
            local tilemaps = {}
            for _, record in ipairs(records) do
                if is_tilemap_component(record) then
                    tilemaps[normalize_resource_path(record.component)] = true
                end
            end
            if next(tilemaps) ~= nil then
                stats.tilemap_prefabs = stats.tilemap_prefabs + 1
                for _, record in ipairs(records) do
                    if is_collision_component(record) then
                        stats.collision_components = stats.collision_components + 1
                        local shape_path = collision_shape_path(record.text)
                        if not shape_path or not tilemaps[shape_path] then
                            warnings[#warnings + 1] = string.format(
                                "Generated prefab '%s' has tilemap plus collision object '%s' using %s instead of that tilemap.",
                                rel_path,
                                tostring(record.id or "<unnamed>"),
                                shape_path or "an embedded/no collision_shape")
                        end
                    end
                end
            end
        end
    end
    return warnings, stats
end

-- V5: literal player URLs break whenever the collection factory changes a
-- room's instance path. Keep the needle assembled so this validator does not
-- report its own implementation as an offender.
function M.collect_literal_player_address_errors(deps)
    deps = deps or {}
    local errors = {}
    local stats = { files = 0, matches = 0 }
    local supplied = deps.source_files
    local paths
    if type(supplied) == "table" then
        paths = supplied_file_paths(supplied)
    else
        paths = collect_project_files(deps, deps.source_roots or {
            "mvtk",
            "developer/config",
            "developer/game",
            "hooks",
            "tools",
        }, function(path)
            return path:lower():match("%.lua$") ~= nil
                or path:lower():match("%.script$") ~= nil
                or path:lower():match("%.gui_script$") ~= nil
                or path:lower():match("%.go$") ~= nil
        end)
    end

    for _, rel_path in ipairs(paths) do
        local text = supplied_file_text(supplied, rel_path) or read_text_from_deps(deps, rel_path)
        if text then
            stats.files = stats.files + 1
            local line_no = 0
            for line in (text .. "\n"):gmatch("(.-)\n") do
                line_no = line_no + 1
                if line:find(PLAYER_ADDRESS_LITERAL, 1, true) then
                    stats.matches = stats.matches + 1
                    errors[#errors + 1] = string.format(
                        "Literal player address found at %s:%d; use C.URL.PLAYER or the colliding instance URL.",
                        rel_path, line_no)
                end
            end
        else
            errors[#errors + 1] = "Could not read source file " .. rel_path .. "."
        end
    end
    return errors, stats
end

function M.run_config_validation(info)
    info = info or function() end
    local ok, Validator = pcall(require, "mvtk.core.config_validator")
    if not ok or not Validator then
        info("[hooks.editor_script] Config validator unavailable: " .. tostring(Validator))
        return true
    end

    local ok_valid, valid = pcall(Validator.validate_all_configs)
    if not ok_valid then
        info("[hooks.editor_script] Config validation threw (non-fatal): " .. tostring(valid))
    elseif not valid then
        info("[hooks.editor_script] Config validation reported issues (non-fatal for menu registration).")
    end
    return true
end

-- Shared with Prepare & Check: a mixed toggle or forbidden Off-state content
-- must fail validation even when the project has no rooms yet.
function M.collect_spine_addon_errors(deps)
    deps = deps or {}
    local Addon = require "mvtk.editor.spine_addon"
    local Messages = require "hooks.spine_addon"
    local ok, files = pcall(function()
        return deps.files or Messages.collect({ root=deps.root, read=deps.read or read_file,
            list=deps.list_dir_filesystem })
    end)
    if not ok then return { "Could not inspect Spine add-on state: " .. tostring(files) }, "mixed" end
    local state, details = Addon.state(files)
    if state == "mixed" then return { Messages.mixed_message(details) }, state end
    local errors = {}
    if state == "off" then
        local inspected, reasons = pcall(Addon.refusal_reasons, files)
        if not inspected then
            errors[#errors + 1] = "Could not inspect Spine add-on settings: " .. tostring(reasons)
        else
            for _, reason in ipairs(reasons) do
                errors[#errors + 1] = Messages.off_message(reason.path) .. " " .. reason.message
            end
        end
    end
    return errors, state
end

function M.run_validate_all(deps)
    deps = deps or {}
    local info = deps.info or function() end
    local root = assert(deps.root, "run_validate_all requires root")
    local to_os_path = assert(deps.to_os_path, "run_validate_all requires to_os_path")
    local list_dir_filesystem = assert(deps.list_dir_filesystem,
        "run_validate_all requires list_dir_filesystem")
    local headless = deps.headless

    info("Validate All: starting")
    local load_fn = loadstring or load

    local function log_step(label, status, detail)
        local line = string.format("[VALIDATE] %s: %s", tostring(label), tostring(status))
        if detail and detail ~= "" then
            line = line .. " (" .. tostring(detail) .. ")"
        end
        info(line)
    end

    local function run(label, rel_path)
        local path = root .. "/" .. rel_path
        local fs_path = to_os_path(path)
        local fh = io.open(fs_path, "rb")
        if not fh then
            log_step(label, "SKIPPED", "not found: " .. rel_path)
            return true, "skipped"
        end

        local content = fh:read("*a")
        fh:close()

        local chunk, compile_err = load_fn(content, "@" .. fs_path)
        if not chunk then
            log_step(label, "FAILED", rel_path)
            info("[VALIDATE] " .. tostring(label) .. " compile error: " .. tostring(compile_err))
            return false, "failed"
        end

        if label == "tests" then
            for module_name, loaded in pairs(package.loaded) do
                if type(module_name) == "string" and module_name:match("^test%.") then
                    package.loaded[module_name] = nil
                elseif type(module_name) == "string"
                    and type(loaded) == "userdata"
                    and (module_name:match("^mvtk%.") or module_name:match("^developer%."))
                then
                    package.loaded[module_name] = nil
                end
            end

            local ok_env, env_err = pcall(require, "test.test_env")
            if not ok_env then
                log_step(label, "FAILED", "test/test_env.lua")
                info("[VALIDATE] tests runtime setup failed: " .. tostring(env_err))
                return false, "failed"
            end
        end

        local real_exit = os.exit
        os.exit = function(code)
            EXIT_SENTINEL.code = code
            error(EXIT_SENTINEL)
        end

        local ok_run, err_run = pcall(chunk)
        os.exit = real_exit

        if not ok_run then
            if err_run == EXIT_SENTINEL then
                if (EXIT_SENTINEL.code or 0) == 0 then
                    log_step(label, "OK", rel_path)
                    return true, "ok"
                end

                log_step(label, "FAILED", string.format("exit %s, %s",
                    tostring(EXIT_SENTINEL.code), rel_path))
                return false, "failed"
            end

            log_step(label, "FAILED", rel_path)
            info("[VALIDATE] " .. tostring(label) .. " runtime error: " .. tostring(err_run))
            return false, "failed"
        end

        log_step(label, "OK", rel_path)
        return true, "ok"
    end

    local function run_tiled_exports()
        local imported_ok,imported_error=pcall(require("developer.tools.preparation").require_exports,
            {root=root,list_dir_filesystem=list_dir_filesystem,map_files=deps.map_files,world_manifest=deps.world_manifest})
        if not imported_ok then
            log_step("tiled exports","FAILED",tostring(imported_error))
            return false,"failed"
        end
        local ok_mod, Validator = pcall(require, "tools.validate_tiled_export")
        if not ok_mod or type(Validator) ~= "table" then
            info("[VALIDATE] tiled exports module load failed, falling back to script runner: " .. tostring(Validator))
            return run("tiled exports", "tools/validate_tiled_export.lua")
        end

        local ok_validate, export_ok, summary = pcall(function()
            return Validator.validate_dir(nil, { quick = true, relationships = false })
        end)
        if not ok_validate then
            log_step("tiled exports", "FAILED", "tools/validate_tiled_export.lua")
            info("[VALIDATE] tiled exports runtime error: " .. tostring(export_ok))
            return false, "failed"
        end

        if Validator.print_summary and summary then
            pcall(Validator.print_summary, summary, { quick = true }, info)
        end

        if export_ok then
            log_step("tiled exports", "OK", "tools/validate_tiled_export.lua")
            return true, "ok"
        end

        log_step("tiled exports", "FAILED", "tools/validate_tiled_export.lua")
        return false, "failed"
    end

    local function read_project_text(rel_path)
        local path = root .. "/" .. rel_path
        local fs_path = to_os_path(path)
        local fh = io.open(fs_path, "rb")
        if not fh then
            return nil, fs_path
        end
        local text = fh:read("*a")
        fh:close()
        return text, fs_path
    end

    local function load_project_lua_table(rel_path)
        local text, fs_path = read_project_text(rel_path)
        if not text then
            return nil, "missing"
        end
        local chunk, compile_err = load_fn(text, "@" .. fs_path)
        if not chunk then
            return nil, compile_err
        end
        local ok_run, value = pcall(chunk)
        if not ok_run then
            return nil, value
        end
        return value, nil
    end

    local function write_project_text(rel_path, text)
        if type(deps.write_if_changed) == "function" then
            return deps.write_if_changed(root .. "/" .. rel_path, text)
        end
        local fs_path = to_os_path(root .. "/" .. rel_path)
        local fh, open_err = io.open(fs_path, "wb")
        if not fh then
            error("Could not write " .. rel_path .. ": " .. tostring(open_err), 0)
        end
        fh:write(text)
        fh:close()
        return true
    end

    local function run_atlas_manifest_sync()
        local ok_sync, result = AtlasManifest.sync_core({
            root = root,
            to_os_path = to_os_path,
            list_dir_filesystem = list_dir_filesystem,
            read_project_text = read_project_text,
            write_project_text = write_project_text,
        })
        if not ok_sync then
            log_step("atlas animations", "FAILED", "manifest generation")
            info("[VALIDATE] atlas animation manifest error: " .. tostring(result))
            return false, "failed"
        end

        log_step("atlas animations", "OK", string.format("%d atlas(es), %d animation(s)",
            tonumber(result.atlas_count) or 0,
            tonumber(result.animation_count) or 0))
        return true, "ok"
    end

    local function join_values(values)
        return table.concat(values or {}, "\0")
    end

    local function run_enemy_art_validation()
        local ok_mod, EnemySkinSync = pcall(require, "mvtk.enemies.enemy_skin_sync")
        if not ok_mod or type(EnemySkinSync) ~= "table" then
            log_step("enemy art", "FAILED", "mvtk/enemies/enemy_skin_sync.lua")
            info("[VALIDATE] enemy art module load failed: " .. tostring(EnemySkinSync))
            return false, "failed"
        end

        local atlas_text = read_project_text(ENEMY_ATLAS_PATH)
        if not atlas_text then
            log_step("enemy art", "FAILED", ENEMY_ATLAS_PATH)
            return false, "failed"
        end

        local manifest, manifest_err = load_project_lua_table("developer/config/enemy_skins_generated.lua")
        if manifest_err == "missing" then
            manifest = { skins = {} }
        elseif type(manifest) ~= "table" or type(manifest.skins) ~= "table" then
            log_step("enemy art", "FAILED", "developer/config/enemy_skins_generated.lua")
            info("[VALIDATE] enemy art manifest is invalid: " .. tostring(manifest_err or "expected table with skins"))
            return false, "failed"
        end

        local generated_ids = EnemySkinSync.parse_generated_atlas_ids(atlas_text)
        local errors = {}
        local warnings = {}
        local asset_errors, asset_stats = M.collect_enemy_sprite_asset_errors({
            root = root,
            to_os_path = to_os_path,
            list_dir_filesystem = deps.list_dir_filesystem,
            read_project_text = read_project_text,
            enemy_atlas_text = atlas_text,
        })
        for _, asset_error in ipairs(asset_errors) do
            errors[#errors + 1] = asset_error
        end
        local manifest_skin_set = {}
        local enum_skin_set = {}
        local manifest_skin_ids = EnemySkinSync.sorted_skin_keys_from_manifest(manifest)

        for _, skin_id in ipairs(manifest_skin_ids) do
            manifest_skin_set[skin_id] = true
            local skin = manifest.skins[skin_id] or {}
            local states = skin.states or {}
            if not states.idle then
                warnings[#warnings + 1] = string.format("Skin '%s' has no idle state.", tostring(skin_id))
            end
            for state, enabled in pairs(states) do
                if enabled then
                    local atlas_id = tostring(skin_id) .. "__" .. tostring(state)
                    if not generated_ids[atlas_id] then
                        errors[#errors + 1] = string.format("Manifest skin state '%s' has no generated atlas id.", atlas_id)
                    end
                end
            end
        end

        local enum_files = {
            { path = "MVTK.tiled-project" },
            { path = "tiled/custom_types/MV_ToolKit.custom-types.json" },
            { path = "tiled/custom_types/MV_ToolKit.custom-types.array.json" },
        }
        local canonical_values_key = nil
        local canonical_enemy_type_values_key = nil
        for _, entry in ipairs(enum_files) do
            local text = read_project_text(entry.path)
            if not text then
                if entry.optional then
                    info("[VALIDATE] enemy art: skipped optional enum file " .. entry.path)
                else
                    errors[#errors + 1] = "Missing required enum file: " .. entry.path
                end
            else
                local values, enum_err = EnemySkinSync.parse_enemy_skins_enum_values(text)
                if not values then
                    errors[#errors + 1] = tostring(enum_err) .. " in " .. entry.path
                else
                    local key = join_values(values)
                    if not canonical_values_key then
                        canonical_values_key = key
                    elseif key ~= canonical_values_key then
                        errors[#errors + 1] = "enemy_skins enum values differ in " .. entry.path
                    end
                    for _, value in ipairs(values) do
                        if value ~= "none" then
                            enum_skin_set[value] = true
                            if not manifest_skin_set[value] then
                                errors[#errors + 1] = string.format("enemy_skins enum value '%s' is missing from the generated manifest.", tostring(value))
                            end
                        end
                    end
                end

                local enemy_values, enemy_enum_err = EnemySkinSync.parse_enum_values(text, "enemies")
                if not enemy_values then
                    errors[#errors + 1] = tostring(enemy_enum_err) .. " in " .. entry.path
                else
                    local enemy_key = join_values(enemy_values)
                    if not canonical_enemy_type_values_key then
                        canonical_enemy_type_values_key = enemy_key
                    elseif enemy_key ~= canonical_enemy_type_values_key then
                        errors[#errors + 1] = "enemies enum values differ in " .. entry.path
                    end

                    local enemy_enum_set = {}
                    for _, value in ipairs(enemy_values) do
                        enemy_enum_set[value] = true
                        if not manifest_skin_set[value] then
                            errors[#errors + 1] = string.format(
                                "enemies enum value '%s' in %s is not a synced enemy art id.",
                                tostring(value),
                                entry.path
                            )
                        end
                    end
                    for _, skin_id in ipairs(manifest_skin_ids) do
                        if not enemy_enum_set[skin_id] then
                            errors[#errors + 1] = string.format("Manifest skin '%s' is missing from the enemies enum in %s.",
                                tostring(skin_id), entry.path)
                        end
                    end
                end
            end
        end

        for skin_id in pairs(manifest_skin_set) do
            if not enum_skin_set[skin_id] then
                errors[#errors + 1] = string.format("Manifest skin '%s' is missing from the enemy_skins enum.", tostring(skin_id))
            end
        end

        for _, warning in ipairs(warnings) do
            info("[VALIDATE] enemy art warning: " .. warning)
        end
        if #errors > 0 then
            log_step("enemy art", "FAILED", string.format("%d error(s)", #errors))
            for _, err in ipairs(errors) do
                info("[VALIDATE] enemy art error: " .. err)
            end
            return false, "failed"
        end

        local guard_detail = string.format(
            "%d animations, %d generated sprites, %d skin folders",
            asset_stats.animations,
            asset_stats.sprites,
            asset_stats.skins
        )
        local detail = (#warnings > 0)
            and string.format("%d warning(s); %s", #warnings, guard_detail)
            or ("atlas/enum/manifest lockstep; " .. guard_detail)
        log_step("enemy art", "OK", detail)
        return true, "ok"
    end

    local function run_animation_reference_validation()
        local shared_deps = {
            root = root,
            to_os_path = to_os_path,
            list_dir_filesystem = list_dir_filesystem,
            read_project_text = read_project_text,
            load_lua_table = load_project_lua_table,
        }
        local checks = {
            { label = "collectible", fn = M.collect_collectible_animation_errors },
            { label = "NPC", fn = M.collect_npc_animation_errors },
            { label = "animation controller", fn = M.collect_animation_controller_default_errors },
        }
        local errors = {}
        local details = {}
        for _, check in ipairs(checks) do
            local found, stats = check.fn(shared_deps)
            for _, err in ipairs(found or {}) do errors[#errors + 1] = err end
            if check.label == "collectible" then
                details[#details + 1] = string.format("%d collectible pair(s)", tonumber(stats.pairs) or 0)
            elseif check.label == "NPC" then
                details[#details + 1] = string.format("%d NPC sprite(s)", tonumber(stats.sprites) or 0)
            else
                details[#details + 1] = string.format("%d controller(s)", tonumber(stats.controllers) or 0)
            end
        end
        if #errors > 0 then
            log_step("animation references", "FAILED", string.format("%d error(s)", #errors))
            for _, err in ipairs(errors) do
                info("[VALIDATE] animation reference error: " .. err)
            end
            return false, "failed"
        end
        log_step("animation references", "OK", table.concat(details, ", "))
        return true, "ok"
    end

    local function run_elevator_layout_validation()
        local index, index_err = load_project_lua_table(
            "developer/config/elevators_generated.lua")
        if type(index) ~= "table" then
            log_step("elevator layout", "FAILED", "missing generated index")
            info("[VALIDATE] elevator layout error: " .. tostring(index_err))
            return false, "failed"
        end

        local manifest = index.manifest or index
        local elevator_count = #(manifest.ordered_ids or {})
        if elevator_count == 0 then
            for _ in pairs(manifest.elevators or {}) do elevator_count = elevator_count + 1 end
        end
        if elevator_count == 0 then
            log_step("elevator layout", "OK", "no authored elevators")
            return true, "ok"
        end

        local layout, layout_source = deps.layout, "prepared Tiled world"
        if not layout then layout,layout_source=load_project_lua_table("developer/runtime/layout/world_layout.local.lua") end
        if type(layout) ~= "table" then
            layout, layout_source = load_project_lua_table(
                "developer/runtime/layout/world_layout.lua")
        else
            layout_source = "world_layout.local.lua"
        end
        if type(layout) ~= "table" or type(layout.rooms) ~= "table" or #layout.rooms == 0 then
            log_step("elevator layout", "FAILED", "export the Layout Editor layout")
            info("[VALIDATE] elevator layout error: authored elevators require an exported runtime layout")
            return false, "failed"
        end

        local ok_resolver, Resolver = pcall(require, "mvtk.elevators.layout_resolver")
        if not ok_resolver or type(Resolver) ~= "table" or type(Resolver.resolve) ~= "function" then
            log_step("elevator layout", "FAILED", "resolver unavailable")
            info("[VALIDATE] elevator layout error: " .. tostring(Resolver))
            return false, "failed"
        end

        local resolved, diagnostics = Resolver.resolve(manifest, layout, {
            require_door_hints = true,
            require_reciprocal = true,
        })
        for _, diagnostic in ipairs(diagnostics or {}) do
            info(string.format(
                "[VALIDATE] elevator %s [%s] elevator=%s room=%s: %s",
                tostring(diagnostic.severity or "info"),
                tostring(diagnostic.code or "unknown"),
                tostring(diagnostic.elevator_id or "-"),
                tostring(diagnostic.room_id or diagnostic.from_room_id or "-"),
                tostring(diagnostic.message or "")
            ))
        end
        if not resolved or resolved.valid == false then
            log_step("elevator layout", "FAILED", string.format("%d error(s)",
                tonumber(resolved and resolved.error_count) or 1))
            return false, "failed"
        end
        local detail = string.format("%d route(s), %s", elevator_count,
            tostring(layout_source or "runtime layout"))
        log_step("elevator layout", "OK", detail)
        return true, "ok"
    end

    local function run_authored_relationship_validation()
        local Project = require "developer.tools.relationship_project"
        local report = Project.check({root=root, list_dir_filesystem=list_dir_filesystem,files=deps.map_files,layout=deps.layout})
        Project.publish_report(report, {root=root})
        for _,d in ipairs(report.diagnostics) do
            info("[VALIDATE] " .. require("developer.tools.content_relationships").format_diagnostic(d))
        end
        log_step("authored relationships", report.ok and "OK" or "FAILED",
            string.format("%d error(s), %d warning(s). %s", report.summary.errors, report.summary.warnings, Project.report_path))
        return report.ok, report.ok and "ok" or "failed"
    end

    local function run_tilemap_collision_composition_validation()
        local warnings, stats = M.collect_generated_tilemap_collision_warnings({
            root = root,
            to_os_path = to_os_path,
            list_dir_filesystem = list_dir_filesystem,
            read_project_text = read_project_text,
        })
        if #warnings > 0 then
            log_step("tilemap collision composition", "WARN", string.format("%d warning(s)", #warnings))
            for _, warning in ipairs(warnings) do
                info("[VALIDATE] tilemap collision warning: " .. warning)
            end
        else
            log_step("tilemap collision composition", "OK", string.format("%d tilemap prefab(s)",
                tonumber(stats.tilemap_prefabs) or 0))
        end
        return true, "ok"
    end

    local function run_player_address_validation()
        local errors, stats = M.collect_literal_player_address_errors({
            root = root,
            to_os_path = to_os_path,
            list_dir_filesystem = list_dir_filesystem,
            read_project_text = read_project_text,
        })
        if #errors > 0 then
            log_step("player addresses", "FAILED", string.format("%d error(s)", #errors))
            for _, err in ipairs(errors) do
                info("[VALIDATE] player address error: " .. err)
            end
            return false, "failed"
        end
        log_step("player addresses", "OK", string.format("%d source file(s)", tonumber(stats.files) or 0))
        return true, "ok"
    end

    local function run_collection_prefab_validation()
        local errors, scanned = M.collect_stale_collection_prefab_errors({
            root = root,
            to_os_path = to_os_path,
            list_dir_filesystem = deps.list_dir_filesystem,
        })

        if #errors > 0 then
            log_step("collection prefabs", "FAILED", string.format("%d error(s)", #errors))
            for _, err in ipairs(errors) do
                info("[VALIDATE] collection prefab error: " .. err)
            end
            return false, "failed"
        end

        local detail = scanned > 0 and string.format("%d collection(s)", scanned) or "no room collections"
        log_step("collection prefabs", "OK", detail)
        return true, "ok"
    end

    local function run_property_type_validation()
        local errors, stats = M.collect_property_type_errors({
            root = root,
            list_room_ids = deps.list_room_ids,
            world_manifest = deps.world_manifest,
            to_os_path = to_os_path,
            list_dir_filesystem = list_dir_filesystem,
            read_project_text = read_project_text,
        })
        if #errors > 0 then
            log_step("script property types", "FAILED", string.format("%d error(s)", #errors))
            for _, err in ipairs(errors) do
                info("[VALIDATE] " .. err)
            end
            return false, "failed"
        end
        log_step("script property types", "OK", string.format("%d resource(s)", stats.files))
        return true, "ok"
    end

    local function run_sprite_default_validation()
        local errors, scanned = M.collect_sprite_default_playback_errors({
            root = root,
            to_os_path = to_os_path,
        })

        if #errors > 0 then
            log_step("combat sprites", "FAILED", string.format("%d error(s)", #errors))
            for _, err in ipairs(errors) do
                info("[VALIDATE] combat sprite error: " .. err)
            end
            return false, "failed"
        end

        local detail = scanned > 0 and string.format("%d sprite(s)", scanned) or "no combat sprites"
        log_step("combat sprites", "OK", detail)
        return true, "ok"
    end

    local function run_steps()
        require("mvtk.editor.creator_settings_writer").recover(root .. "/developer")
        local spine_errors, spine_state = M.collect_spine_addon_errors({root=root,
            list_dir_filesystem=list_dir_filesystem})
        local spine_ok = #spine_errors == 0
        local spine_status = spine_ok and "ok" or "failed"
        log_step("Spine add-on", spine_ok and "OK" or "FAILED", spine_state)
        for _, problem in ipairs(spine_errors) do info("[VALIDATE] " .. problem) end
        local ok0, status0 = run_atlas_manifest_sync()
        local ok1, status1 = run("config", "tools/validate_config.lua")
        local ok2, status2 = true,"skipped"
        if not deps.allow_empty then ok2,status2=run("tiled maps", "developer/tools/tiled/validate_maps.lua")
        else log_step("tiled maps","SKIPPED","empty project") end
        -- Schema-aware export validator: complements the lightweight
        -- developer/tools/tiled/validate_maps.lua loader check by enforcing
        -- required Tiled top-level fields and the spawner-registry whitelist.
        local ok2b,status2b=true,"skipped"
        if not deps.allow_empty then ok2b,status2b=run_tiled_exports()
        else log_step("tiled exports","SKIPPED","empty project") end
        local ok2r, status2r = run_authored_relationship_validation()
        local ok2p,result2p=pcall(function()
            local P=require "developer.tools.progression_project"
            local opts={root=root,list_dir_filesystem=list_dir_filesystem,files=deps.map_files,layout=deps.layout}
            local result=P.check(opts); P.publish(result,opts)
            info(result.message); return result.ok
        end)
        local status2p=(ok2p and result2p) and "ok" or "failed"
        ok2p=ok2p and result2p
        log_step("progression analysis",ok2p and "OK" or "FAILED",tostring(result2p))
        local ok2i, status2i = run_elevator_layout_validation()
        local ok2c, status2c = run_enemy_art_validation()
        local ok2d, status2d = run_collection_prefab_validation()
        local ok2t, status2t = run_property_type_validation()
        local ok2e, status2e = run_sprite_default_validation()
        local ok2f, status2f = run_animation_reference_validation()
        local ok2g, status2g = run_tilemap_collision_composition_validation()
        local ok2h, status2h = run_player_address_validation()
        local ok3 = true
        local status3 = "ok"

        if headless and not deps.skip_tests then
            ok3, status3 = run("tests", "test/run_tests.lua")
        else
            status3 = "skipped"
            log_step("tests", "SKIPPED", deps.skip_tests and "run separately in disposable fixtures" or "editor runtime")
        end

        info(string.format("Validate All summary: spine_addon=%s, atlas_animations=%s, config=%s, tiled_maps=%s, tiled_exports=%s, authored_relationships=%s, elevator_layout=%s, enemy_art=%s, collection_prefabs=%s, script_property_types=%s, combat_sprites=%s, animation_references=%s, tilemap_collision_composition=%s, player_addresses=%s, tests=%s",
            tostring(spine_status), tostring(status0), tostring(status1), tostring(status2), tostring(status2b), tostring(status2r), tostring(status2i), tostring(status2c), tostring(status2d), tostring(status2t), tostring(status2e), tostring(status2f), tostring(status2g), tostring(status2h), tostring(status3)))

        local steps = {
            { label = "Spine add-on", status = spine_status },
            { label = "atlas animations", status = status0 },
            { label = "config", status = status1 },
            { label = "tiled maps", status = status2 },
            { label = "tiled exports", status = status2b },
            { label = "authored relationships", status = status2r },
            { label = "progression analysis", status = status2p },
            { label = "elevator layout", status = status2i },
            { label = "enemy art", status = status2c },
            { label = "collection prefabs", status = status2d },
            { label = "script property types", status = status2t },
            { label = "combat sprites", status = status2e },
            { label = "animation references", status = status2f },
            { label = "tilemap collision composition", status = status2g },
            { label = "player addresses", status = status2h },
            { label = "tests", status = status3 },
        }

        if spine_ok and ok0 and ok1 and ok2 and ok2b and ok2r and ok2p and ok2i and ok2c and ok2d and ok2t and ok2e and ok2f and ok2g and ok2h and ok3 then
            info("Validate All complete.")
            return true, M.build_validate_all_success_message(steps)
        end

        info("Validate All finished with errors (see above).")
        return false, M.build_validate_all_failure_message(steps)
    end

    return M.with_mvtk_bridge({
        ROOT = root,
        to_os_path = to_os_path,
        list_dir_filesystem = list_dir_filesystem,
    }, run_steps)
end

local function normalize_tiled_name(value)
    if value == nil then
        return nil
    end
    local s = tostring(value):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    return s ~= "" and s or nil
end

local function unwrap_tiled_prop_value(prop)
    if type(prop) ~= "table" then
        return prop
    end
    if prop.value ~= nil then
        return prop.value
    end
    if prop[1] ~= nil then
        return prop[1]
    end
    return nil
end

local function get_tiled_object_prop(object, field)
    if type(object) ~= "table" or not field then
        return nil
    end
    if field == "name" then
        return object.name
    end

    local direct = object[field]
    if direct ~= nil then
        return unwrap_tiled_prop_value(direct)
    end

    local props = object.properties
    if type(props) ~= "table" then
        return nil
    end

    local keyed = props[field]
    if keyed ~= nil then
        return unwrap_tiled_prop_value(keyed)
    end

    for _, prop in ipairs(props) do
        if type(prop) == "table" and (prop.name == field or prop.id == field) then
            return unwrap_tiled_prop_value(prop)
        end
    end

    return nil
end

local function has_nonempty_prop(object, field)
    local value = get_tiled_object_prop(object, field)
    return value ~= nil and tostring(value) ~= ""
end

local function object_looks_like_enemy(object, opts)
    opts = opts or {}
    if has_nonempty_prop(object, "enemy_type") then
        return true
    end

    local resolver = opts.resolve_object_type
    if type(resolver) == "function" then
        local ok, resolved = pcall(resolver, object)
        if ok and resolved == "enemy" then
            return true
        end
    end

    if normalize_tiled_name(object and object.type) == "enemy"
        or normalize_tiled_name(object and object.class) == "enemy"
        or normalize_tiled_name(object and object.className) == "enemy"
        or normalize_tiled_name(get_tiled_object_prop(object, "class")) == "enemy"
        or normalize_tiled_name(object and object.name) == "enemy" then
        return true
    end

    return false
end

local function layer_path(parent_path, layer)
    local name = tostring((layer and layer.name) or "<unnamed>")
    if parent_path and parent_path ~= "" then
        return parent_path .. "/" .. name
    end
    return name
end

--- Collect enemy-looking Tiled objects that Create Rooms will skip.
-- The generator on this branch flattens group layers, so group-contained object
-- layers are considered processed unless process_group_layers is explicitly
-- false in tests or future callers.
function M.collect_skipped_enemy_import_warnings(tiled_data, opts)
    opts = opts or {}
    local warnings = {}
    local process_group_layers = opts.process_group_layers ~= false
    local process_object_layer = opts.process_object_layer

    local function add_warning(object, path, reason)
        warnings[#warnings + 1] = {
            object_id = object and object.id,
            layer = path,
            enemy_type = get_tiled_object_prop(object, "enemy_type"),
            reason = reason,
        }
    end

    local function scan_object_list(objects, path, reason)
        if type(objects) ~= "table" then
            return
        end
        for _, object in ipairs(objects) do
            if type(object) == "table" and object_looks_like_enemy(object, opts) then
                add_warning(object, path, reason)
            end
        end
    end

    local function walk_layers(layers, parent_path, inside_group)
        if type(layers) ~= "table" then
            return
        end
        for _, layer in ipairs(layers) do
            if type(layer) == "table" then
                local path = layer_path(parent_path, layer)
                if layer.type == "group" and type(layer.layers) == "table" then
                    if process_group_layers then
                        walk_layers(layer.layers, path, true)
                    else
                        local function collect_group_objects(group_layers, group_path)
                            for _, child in ipairs(group_layers or {}) do
                                if type(child) == "table" then
                                    local child_path = layer_path(group_path, child)
                                    if child.type == "objectgroup" then
                                        scan_object_list(child.objects, child_path, "group_layer_not_processed")
                                    elseif child.type == "group" and type(child.layers) == "table" then
                                        collect_group_objects(child.layers, child_path)
                                    elseif type(child.objects) == "table" then
                                        scan_object_list(child.objects, child_path, "unsupported_layer_type")
                                    end
                                end
                            end
                        end
                        collect_group_objects(layer.layers, path)
                    end
                elseif layer.type == "objectgroup" then
                    local layer_processed = true
                    if type(process_object_layer) == "function" then
                        local ok, result = pcall(process_object_layer, layer, {
                            path = path,
                            inside_group = inside_group and true or false,
                        })
                        layer_processed = ok and result ~= false
                    end
                    if not layer_processed then
                        scan_object_list(layer.objects, path, "layer_not_processed")
                    else
                        for _, object in ipairs(layer.objects or {}) do
                            if type(object) == "table"
                                and object.visible == false
                                and object_looks_like_enemy(object, opts) then
                                add_warning(object, path, "object_hidden")
                            end
                        end
                    end
                elseif type(layer.objects) == "table" then
                    scan_object_list(layer.objects, path, "unsupported_layer_type")
                end
            end
        end
    end

    walk_layers(tiled_data and tiled_data.layers, "", false)
    table.sort(warnings, function(a, b)
        local la = tostring(a.layer or "")
        local lb = tostring(b.layer or "")
        if la ~= lb then
            return la < lb
        end
        return tostring(a.object_id or "") < tostring(b.object_id or "")
    end)
    return warnings
end

function M.register_menu(deps)
    deps = deps or {}
    local info = deps.info or function() end
    local editor_api = deps.editor_api
    local headless = deps.headless
    local run_validate_all = assert(deps.run_validate_all, "register_menu requires run_validate_all")

    if headless or not (editor_api and editor_api.register_menu_item) then
        info("Editor menu API unavailable; skipping menu registration (HEADLESS=" .. tostring(headless) .. ")")
        return
    end

    local ok, err = pcall(function()
        editor_api.register_menu_item("MV Toolkit/Validate All", function()
            run_validate_all()
        end)
    end)

    if ok then
        info("Registered menu item: MV Toolkit -> Validate All")
    else
        info("Failed to register menu item: " .. tostring(err))
    end
end

return M
