-- hooks/enemy_art_sync.lua
--
-- Editor-command helper for Project > Sync Enemy Art. Kept out of
-- editor_commands.lua so Defold's LuaJ compiler does not need to compile the
-- entire enemy-art sync implementation inside the already-large command chunk.

local ProjectTransaction = require "mvtk.editor.project_transaction"

local M = {}

local ENEMY_ART_DIR = "developer/assets/enemies"
local ENEMY_ATLAS = "developer/assets/atlas/enemy.atlas"
local ENEMY_SKINS_MANIFEST = "developer/config/enemy_skins_generated.lua"
local GENERATED_ENEMY_SPRITE_DIR = "developer/assets/enemies/generated"
local GENERATED_ENEMY_PREFAB_DIR = "developer/game/prefabs/generated"
local SKIN_COLLISIONOBJECT_FILENAME = "collisionobject.collisionobject"
local SHARED_ENEMY_COLLISIONOBJECT = "/developer/game/enemies/collisionobject.collisionobject"
local ENEMY_TEMPLATE = "tiled/templates/enemies/enemy.tx"
local ENEMY_SKIN_ENUM_FILES = {
    { path = "MVTK.tiled-project" },
    { path = "tiled/custom_types/MV_ToolKit.custom-types.json" },
    { path = "tiled/custom_types/MV_ToolKit.custom-types.array.json" },
}

local EnemySkinSync = nil
local enemy_skin_sync_load_err = nil

local function get_enemy_skin_sync()
    if EnemySkinSync then
        return EnemySkinSync
    end
    if enemy_skin_sync_load_err then
        return nil, enemy_skin_sync_load_err
    end
    local ok, mod = pcall(require, "mvtk.enemies.enemy_skin_sync")
    if not ok or type(mod) ~= "table" then
        enemy_skin_sync_load_err = "Could not load mvtk.enemies.enemy_skin_sync: " .. tostring(mod)
        return nil, enemy_skin_sync_load_err
    end
    EnemySkinSync = mod
    return EnemySkinSync
end

local function dep(deps, key, fallback)
    local value = deps and deps[key]
    if value ~= nil then
        return value
    end
    return fallback
end

local function sorted_copy(list)
    local out = {}
    for _, value in ipairs(list or {}) do
        out[#out + 1] = value
    end
    table.sort(out, function(a, b)
        local aa = tostring(a):lower()
        local bb = tostring(b):lower()
        if aa ~= bb then return aa < bb end
        return tostring(a) < tostring(b)
    end)
    return out
end

local function basename(value)
    if type(value) == "table" then
        value = value.filename or value.file or value.path
    end
    return tostring(value or ""):gsub("\\", "/"):match("([^/]+)$") or ""
end

local function split_skin_files(files)
    local animation_files = {}
    local collisionobject_file = nil
    for _, file in ipairs(files or {}) do
        local filename = basename(file)
        local lower = filename:lower()
        if lower == SKIN_COLLISIONOBJECT_FILENAME then
            collisionobject_file = filename
        elseif lower:sub(-#".mvtk-source") == ".mvtk-source" then
            -- Export receipts beside art linked from Tiled; bookkeeping, not frames.
        else
            animation_files[#animation_files + 1] = file
        end
    end
    return animation_files, collisionobject_file
end

local function apply_skin_collisionobject(prefab_text, collisionobject_path)
    if not collisionobject_path then
        return prefab_text
    end
    local escaped_path = tostring(collisionobject_path):gsub("\\", "\\\\"):gsub('"', '\\"')
    local rewritten, count = tostring(prefab_text or ""):gsub(
        '  component: "/developer/game/enemies/collisionobject%.collisionobject"',
        function()
            return string.format('  component: "%s"', escaped_path)
        end,
        1
    )
    if count ~= 1 then
        return nil, string.format(
            "Could not apply per-skin collision object '%s'; generated prefab no longer references %s",
            tostring(collisionobject_path), SHARED_ENEMY_COLLISIONOBJECT)
    end
    return rewritten
end

local function format_name_list(list, empty_label)
    if not list or #list == 0 then
        return empty_label or "none"
    end
    local limit = 8
    local shown = {}
    for i = 1, math.min(#list, limit) do
        shown[#shown + 1] = tostring(list[i])
    end
    if #list > limit then
        shown[#shown + 1] = string.format("and %d more", #list - limit)
    end
    return table.concat(shown, ", ")
end

local function set_from_list(list)
    local set = {}
    for _, value in ipairs(list or {}) do
        set[tostring(value)] = true
    end
    return set
end

local function compare_lists(old_ids, new_ids)
    local old_set = set_from_list(old_ids)
    local new_set = set_from_list(new_ids)
    local added = {}
    local removed = {}
    local unchanged = {}

    for _, id in ipairs(new_ids or {}) do
        if old_set[id] then
            unchanged[#unchanged + 1] = id
        else
            added[#added + 1] = id
        end
    end
    for _, id in ipairs(old_ids or {}) do
        if not new_set[id] then
            removed[#removed + 1] = id
        end
    end

    table.sort(added)
    table.sort(removed)
    table.sort(unchanged)
    return added, removed, unchanged
end

local function project_path(deps, path)
    if not path or path == "" then
        return path
    end
    if path:match("^[A-Za-z]:") or path:sub(1, 1) == "/" then
        return path
    end
    local join = dep(deps, "join", function(a, b) return tostring(a or ".") .. "/" .. tostring(b or "") end)
    return join(dep(deps, "root", "."), path)
end

local function read_required_text(deps, path)
    local read_text = dep(deps, "read_text")
    if type(read_text) ~= "function" then
        return nil, "read_text dependency unavailable"
    end
    local text = read_text(project_path(deps, path))
    if text == nil then
        return nil, "Could not read " .. tostring(path)
    end
    return text
end

local function filter_non_none(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do
        id = tostring(id or "")
        if id ~= "" and id ~= "none" then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

local function add_enemy_art_issue(issues, issue)
    issue = issue or {}
    issue.message = issue.message or tostring(issue.reason or issue.type or "Unknown enemy art issue")
    issues[#issues + 1] = issue
end

local function enemy_art_issue_message(issue)
    issue = issue or {}
    local skin = tostring(issue.skin_id or issue.folder or "unknown")
    local filename = tostring(issue.filename or "")
    if issue.type == "unknown_state" then
        local valid_states = issue.valid_states
        if not valid_states and EnemySkinSync and EnemySkinSync.CANONICAL_STATES then
            valid_states = table.concat(EnemySkinSync.CANONICAL_STATES, ", ")
        end
        return string.format("Skipped %s/%s: unknown animation state. Valid states: %s.",
            skin, filename, tostring(valid_states or "idle, walk, attack, hurt, death"))
    elseif issue.type == "unsupported_extension" then
        return string.format("Skipped %s/%s: only individual PNG frames are supported.", skin, filename)
    elseif issue.type == "missing_idle" then
        return string.format("Skipped skin '%s': add idle.png or idle_01.png so the generated sprite has a valid default animation.", skin)
    elseif issue.type == "invalid_folder" then
        return string.format("Skipped enemy skin folder '%s': %s.", tostring(issue.folder), tostring(issue.reason))
    elseif issue.type == "folder_collision" then
        return string.format("Skipped enemy skin folder '%s': sanitized id '%s' already came from '%s'.",
            tostring(issue.folder), tostring(issue.skin_id), tostring(issue.existing_folder))
    elseif issue.type == "empty_skin" then
        return string.format("Skipped enemy skin folder '%s': no valid PNG animation frames found.", tostring(issue.folder))
    elseif issue.type == "pixel_area" then
        return string.format("Skin '%s' is large (%.1f Mpx total); consider enabling paged atlas max_page_width/max_page_height.",
            skin, (tonumber(issue.pixel_area) or 0) / 1000000)
    elseif issue.type == "folder_sanitized" then
        return string.format("Enemy skin folder '%s' is available in Tiled as '%s'. Use lowercase snake_case folder names to avoid surprises.",
            tostring(issue.folder), tostring(issue.skin_id))
    end
    return tostring(issue.message or issue.reason or "Unknown enemy art issue")
end

local function append_enemy_art_issue_lines(lines, issues, skipped_enum_files)
    if skipped_enum_files and #skipped_enum_files > 0 then
        lines[#lines + 1] = "Skipped dev-only enum file (not in this install): "
            .. format_name_list(skipped_enum_files)
    end
    for _, issue in ipairs(issues or {}) do
        lines[#lines + 1] = issue.message or enemy_art_issue_message(issue)
    end
end

local function count_table_keys(t)
    local count = 0
    for _ in pairs(t or {}) do
        count = count + 1
    end
    return count
end

local function remove_project_file(deps, path)
    local abs = project_path(deps, path)
    local delete_file = dep(deps, "delete_file")
    if type(delete_file) == "function" then
        return delete_file(abs)
    end
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
    -- The editor can delete successfully while returning a falsy result.
    os.remove(abs)
    local readable, remaining = pcall(ProjectTransaction.read, abs)
    return readable and remaining == nil
end

local function prune_generated_enemy_artifacts(deps, skins)
    local sync = get_enemy_skin_sync()
    if not sync then
        return {}
    end

    local expected_sprites = {}
    local expected_prefabs = {}
    for _, skin in ipairs(skins or {}) do
        local skin_id = tostring(skin.skin_id or "")
        if skin_id ~= "" then
            expected_sprites[skin_id .. ".sprite"] = true
            expected_prefabs["enemy_" .. skin_id .. ".go"] = true
        end
    end

    local removed = {}
    local list_dir_filesystem = dep(deps, "list_dir_filesystem")
    if type(list_dir_filesystem) ~= "function" then
        return removed
    end

    local function prune_dir(rel_dir, pattern, expected)
        local _, files = list_dir_filesystem(project_path(deps, rel_dir))
        for _, file in ipairs(files or {}) do
            if tostring(file):match(pattern) and not expected[file] then
                local rel = rel_dir .. "/" .. file
                if remove_project_file(deps, rel) then
                    removed[#removed + 1] = rel
                end
            end
        end
    end

    prune_dir(GENERATED_ENEMY_SPRITE_DIR, "%.sprite$", expected_sprites)
    prune_dir(GENERATED_ENEMY_PREFAB_DIR, "^enemy_.+%.go$", expected_prefabs)
    table.sort(removed)
    return removed
end

local function skin_state_summary(skin)
    local sync, sync_err = get_enemy_skin_sync()
    if not sync then
        return string.format("%s (%s)", tostring(skin and skin.skin_id or "unknown"), tostring(sync_err))
    end
    local states = sync.skin_state_names(skin)
    local parts = {}
    for _, state in ipairs(states) do
        local frames = skin.states[state] or {}
        parts[#parts + 1] = string.format("%s:%d", state, #frames)
    end
    return string.format("%s (%d states, %d frames%s%s)",
        tostring(skin.skin_id),
        sync.skin_state_count(skin),
        sync.skin_frame_count(skin),
        #parts > 0 and ": " or "",
        table.concat(parts, ", "))
end

local function estimate_skin_pixel_area(deps, skin)
    local sync = get_enemy_skin_sync()
    if not sync then
        return 0
    end
    local read_binary_any = dep(deps, "read_binary_any")
    if type(read_binary_any) ~= "function" then
        return 0
    end
    local join = dep(deps, "join", function(a, b) return tostring(a or ".") .. "/" .. tostring(b or "") end)
    local total = 0
    local folder = skin.folder_name or skin.skin_id
    for _, state in ipairs(sync.skin_state_names(skin)) do
        for _, frame in ipairs(skin.states[state] or {}) do
            local path = join(join(join(dep(deps, "root", "."), ENEMY_ART_DIR), folder), frame)
            local data = read_binary_any(path)
            local width, height = sync.png_dimensions_from_bytes(data)
            if width and height then
                total = total + (width * height)
            end
        end
    end
    return total
end

local function collect_enemy_skins(deps)
    local sync, sync_err = get_enemy_skin_sync()
    if not sync then
        return nil, { { type = "load_failed", message = tostring(sync_err) } }
    end
    local join = dep(deps, "join", function(a, b) return tostring(a or ".") .. "/" .. tostring(b or "") end)
    local list_dir_filesystem = dep(deps, "list_dir_filesystem")
    if type(list_dir_filesystem) ~= "function" then
        return nil, { { type = "load_failed", message = "list_dir_filesystem dependency unavailable" } }
    end

    local enemy_dir_abs = join(dep(deps, "root", "."), ENEMY_ART_DIR)
    local dirs = list_dir_filesystem(enemy_dir_abs)
    dirs = sorted_copy(dirs or {})

    local skins = {}
    local issues = {}
    local seen = {}
    local pixel_warn_threshold = 4096 * 4096

    for _, folder in ipairs(dirs) do
        local skin_id, reason = nil, nil
        if folder ~= "generated" then
            skin_id, reason = sync.sanitize_skin_id(folder)
        end
        if folder == "generated" then
            -- Generated per-skin sprites live under the enemy art root but are
            -- outputs, not authored skin folders.
        elseif not skin_id then
            add_enemy_art_issue(issues, {
                type = "invalid_folder",
                folder = folder,
                reason = reason,
            })
        elseif seen[skin_id] then
            add_enemy_art_issue(issues, {
                type = "folder_collision",
                folder = folder,
                skin_id = skin_id,
                existing_folder = seen[skin_id],
            })
        else
            if skin_id ~= folder then
                add_enemy_art_issue(issues, {
                    type = "folder_sanitized",
                    folder = folder,
                    skin_id = skin_id,
                })
            end

            local skin_dir = join(enemy_dir_abs, folder)
            local _, files = list_dir_filesystem(skin_dir)
            files = sorted_copy(files or {})
            local animation_files, collisionobject_file = split_skin_files(files)
            local grouped = sync.group_skin_files(skin_id, animation_files)
            grouped.folder_name = folder
            if collisionobject_file then
                grouped.collisionobject_path = string.format("/%s/%s/%s",
                    ENEMY_ART_DIR, folder, collisionobject_file)
            end

            for _, issue in ipairs(grouped.issues or {}) do
                issue.folder = folder
                issue.message = enemy_art_issue_message(issue)
                add_enemy_art_issue(issues, issue)
            end

            if count_table_keys(grouped.states) == 0 then
                add_enemy_art_issue(issues, {
                    type = "empty_skin",
                    folder = folder,
                    skin_id = skin_id,
                })
            elseif not (type(grouped.states.idle) == "table" and #grouped.states.idle > 0) then
                -- group_skin_files already added the missing_idle issue above.
            else
                local pixel_area = estimate_skin_pixel_area(deps, grouped)
                grouped.pixel_area = pixel_area
                if pixel_area > pixel_warn_threshold then
                    add_enemy_art_issue(issues, {
                        type = "pixel_area",
                        skin_id = skin_id,
                        pixel_area = pixel_area,
                    })
                end
                seen[skin_id] = folder
                skins[#skins + 1] = grouped
            end
        end
    end

    table.sort(skins, function(a, b)
        return tostring(a.skin_id) < tostring(b.skin_id)
    end)
    return skins, issues
end

local function rewrite_enemy_template_default(template_text, default_enemy_type)
    default_enemy_type = tostring(default_enemy_type or "")
    local replaced = false
    local out = tostring(template_text or ""):gsub(
        '(<property%s+name="enemy_type"[^>]-value=")([^"]*)(")',
        function(prefix, _, suffix)
            replaced = true
            return prefix .. default_enemy_type .. suffix
        end,
        1
    )
    if not replaced then
        return nil, "Could not find enemy_type property in " .. ENEMY_TEMPLATE
    end
    return out
end

function M.sync_core(deps)
    deps = deps or {}
    local sync, sync_err = get_enemy_skin_sync()
    if not sync then
        return false, sync_err
    end
    local skins, issues = collect_enemy_skins(deps)
    if not skins then
        return false, (issues and issues[1] and issues[1].message) or "Could not collect enemy skins"
    end

    local atlas_text, atlas_err = read_required_text(deps, ENEMY_ATLAS)
    if not atlas_text then return false, atlas_err end
    local template_text, template_err = read_required_text(deps, ENEMY_TEMPLATE)
    if not template_text then return false, template_err end

    local enum_texts = {}
    local skipped_enum_files = {}
    local old_ids = {}
    for _, entry in ipairs(ENEMY_SKIN_ENUM_FILES) do
        local path = entry.path
        local text, err = read_required_text(deps, path)
        if not text then
            if entry.optional then
                skipped_enum_files[#skipped_enum_files + 1] = path
                local info = dep(deps, "info", function() end)
                info("[ENEMY_ART] Skipping optional enum file (not present): " .. tostring(path))
            else
                return false, err
            end
        else
            enum_texts[path] = text
            if #old_ids == 0 then
                local parsed = sync.parse_enemy_skins_enum_values(text)
                old_ids = filter_non_none(parsed or {})
            end
        end
    end

    local new_ids = sync.sorted_skin_ids(skins)
    local added, removed, unchanged = compare_lists(old_ids, new_ids)

    local template_default = new_ids[1] or ""
    local preferred_default = tostring(sync.DEFAULT_SKIN or "default")
    for _, skin_id in ipairs(new_ids) do
        if skin_id == preferred_default then
            template_default = skin_id
            break
        end
    end

    local new_atlas_text, atlas_rewrite_err = sync.rewrite_enemy_atlas(atlas_text, skins)
    if not new_atlas_text then
        return false, atlas_rewrite_err
    end
    local new_template_text, template_rewrite_err = rewrite_enemy_template_default(template_text, template_default)
    if not new_template_text then
        return false, template_rewrite_err
    end

    local writes = {
        { path = ENEMY_ATLAS, text = new_atlas_text },
        { path = ENEMY_SKINS_MANIFEST, text = sync.generate_skins_manifest(skins) },
        { path = ENEMY_TEMPLATE, text = new_template_text },
    }
    local skins_by_id = {}
    for _, skin in ipairs(skins) do
        skins_by_id[skin.skin_id] = skin
    end
    -- Read the render bands fresh: the editor keeps required modules cached
    -- for its whole session, which would ignore an edited enemy_z.
    package.loaded["developer.config.render_settings"] = nil
    package.loaded["mvtk.core.render_order"] = nil
    local enemy_z = require("mvtk.core.render_order").enemy_z()
    for _, write in ipairs(sync.generate_skin_artifact_writes(skins, { enemy_z = enemy_z })) do
        local skin = skins_by_id[write.skin_id]
        if write.kind == "prefab" and skin and skin.collisionobject_path then
            local rewritten, collision_err = apply_skin_collisionobject(write.text, skin.collisionobject_path)
            if not rewritten then
                return false, collision_err
            end
            write.text = rewritten
        end
        writes[#writes + 1] = write
    end
    for _, entry in ipairs(ENEMY_SKIN_ENUM_FILES) do
        local path = entry.path
        if enum_texts[path] ~= nil then
            local new_enum_text, enum_err = sync.rewrite_enemy_skins_enum(enum_texts[path], skins)
            if not new_enum_text then
                return false, enum_err .. " in " .. path
            end
            new_enum_text, enum_err = sync.rewrite_enum_values(new_enum_text, "enemies", new_ids)
            if not new_enum_text then
                return false, enum_err .. " in " .. path
            end
            writes[#writes + 1] = { path = path, text = new_enum_text }
        end
    end

    local write_if_changed = dep(deps, "write_if_changed")
    if type(write_if_changed) ~= "function" then
        return false, "write_if_changed dependency unavailable"
    end

    local changed_files = {}
    for _, write in ipairs(writes) do
        if write_if_changed(project_path(deps, write.path), write.text) then
            changed_files[#changed_files + 1] = write.path
        end
    end
    local removed_generated_files = prune_generated_enemy_artifacts(deps, skins)
    for _, path in ipairs(removed_generated_files) do
        changed_files[#changed_files + 1] = path
    end

    return true, {
        empty = #skins == 0,
        reason = (#skins == 0) and "no_skins" or nil,
        skins = skins,
        issues = issues,
        added = added,
        removed = removed,
        unchanged = unchanged,
        enemy_type_dropdown_count = #new_ids,
        changed_files = changed_files,
        removed_generated_files = removed_generated_files,
        skipped_enum_files = skipped_enum_files,
    }
end

function M.run(deps)
    deps = deps or {}
    local info = dep(deps, "info", function() end)
    info("[ENEMY_ART] Starting enemy art sync...")

    local ok, result = M.sync_core(deps)
    if not ok then
        return false, result
    end

    local lines
    if result.empty then
        lines = {
            "No enemy skin folders were found in " .. ENEMY_ART_DIR .. ".",
            string.format("enemy_type dropdown now lists %d synced art id(s).",
                tonumber(result.enemy_type_dropdown_count) or 0),
            (#result.changed_files > 0)
                and ("Changed files: " .. format_name_list(result.changed_files))
                or "No generated files changed.",
        }
    else
        local skin_lines = {}
        for _, skin in ipairs(result.skins or {}) do
            skin_lines[#skin_lines + 1] = skin_state_summary(skin)
        end
        lines = {
            string.format("Skins synced: %d (%d added, %d removed, %d unchanged).",
                #(result.skins or {}), #(result.added or {}), #(result.removed or {}), #(result.unchanged or {})),
            string.format("enemy_type dropdown now lists %d synced art id(s).",
                tonumber(result.enemy_type_dropdown_count) or 0),
            "Added: " .. format_name_list(result.added),
            "Removed: " .. format_name_list(result.removed),
            "Unchanged: " .. format_name_list(result.unchanged),
            "States: " .. format_name_list(skin_lines),
            (#result.changed_files > 0)
                and ("Changed files: " .. format_name_list(result.changed_files))
                or "No generated files changed.",
        }
    end

    append_enemy_art_issue_lines(lines, result.issues, result.skipped_enum_files)
    for _, line in ipairs(lines or {}) do
        info("[ENEMY_ART] " .. tostring(line))
    end
    local show_dialog = dep(deps, "show_dialog")
    if type(show_dialog) == "function" then
        show_dialog("Sync Enemy Art Complete", lines, { cancel_text = "Close" })
    end
    return true
end

return M
