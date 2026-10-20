-- hooks/toolkit_setup.lua
-- Project > Set Up This Toolkit: the cross-platform replacement for running
-- INSTALL first.
--
-- The command only writes inside the project folder (Defold editor scripts may
-- not write anywhere else), so the same Lua runs on Windows, macOS and Linux
-- with nothing to install:
--   hooks/project_path.txt  pins Defold's project root (as INSTALL does)
--   MVTK.tiled-project      optionally lists the creator's Tiled maps folder in
--                           Tiled's Project panel
--   WHERE_THINGS_ARE.txt    the paths a creator opens and exports to
-- Tiled needs nothing written: it exports to the toolkit whose
-- MVTK.tiled-project is open (tiled/extensions/export_lua_and_defold.js).
-- M.run is the command; hooks/editor_commands.lua passes it the editor API and
-- the project writer, so everything here also runs (and is tested) headlessly.
-- The Tiled side (starting a world) lives in
-- tiled/extensions/world_setup.js.

local M = {}

-- Forward slashes, no trailing slash (a bare drive or "/" keeps its slash).
-- A network path keeps its leading "//".
function M.normalize(path)
    local p = tostring(path or ""):gsub("\\", "/")
    local network = p:sub(1, 2) == "//"
    p = p:gsub("//+", "/")
    if network then p = "/" .. p end
    if #p > 1 and p:sub(-1) == "/" and not p:match("^%a:/$") then
        p = p:sub(1, -2)
    end
    return p
end

function M.is_absolute(path)
    local p = M.normalize(path)
    return p:match("^%a:/") ~= nil or p:sub(1, 1) == "/"
end

-- Comparison key: Windows drive paths are case-insensitive.
local function key(path)
    local p = M.normalize(path)
    if p:match("^%a:/") then p = p:lower() end
    return p
end

-- True when path is root itself or anything below it.
function M.is_inside(path, root)
    local p, r = key(path), key(root)
    if r == "" then return false end
    if p == r then return true end
    if r:sub(-1) ~= "/" then r = r .. "/" end
    return p:sub(1, #r) == r
end

-- The folder containing path ("C:/Toolkit" -> "C:/", "/toolkit" -> "/").
function M.parent(path)
    local p = M.normalize(path)
    local up = p:match("^(.*)/[^/]+$")
    if up == nil then return p end
    if up == "" then return "/" end
    if up:match("^%a:$") then return up .. "/" end
    return up
end

-- Why folder cannot hold the creator's Tiled maps, or nil when it can. Maps
-- are originals: inside the toolkit, Reset Project could clear them, and a
-- folder that contains the toolkit would list its exported copies in Tiled.
function M.maps_folder_problem(folder, root)
    if M.is_inside(folder, root) then
        return "That folder is inside the toolkit. Choose a folder outside it, for example a new Tiled_worlds folder next to the toolkit folder."
    end
    if M.is_inside(root, folder) then
        return "That folder contains the toolkit. Choose a folder beside it instead, for example a new Tiled_worlds folder next to the toolkit folder."
    end
    return nil
end

-- Parse Tiled's last successful world command without touching the filesystem.
-- Existence is checked by M.run through its injected editor API; keeping this
-- helper pure also makes malformed/stale hints harmless in headless tests.
function M.read_worlds_hint(text, root)
    if type(text) ~= "string" then return nil end
    local hint = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local name, value = line:match("^([%a_]+)=(.*)$")
        if name == "folder" or name == "world" or name == "kind" then
            hint[name] = value
        end
    end
    -- Only Start a New World writes hints ("new"). Sample worlds open like any
    -- world, so a "sample" hint left by an older Tiled extension is ignored.
    if hint.kind ~= "new" then return nil end
    for _, name in ipairs({ "folder", "world" }) do
        local path = hint[name]
        if not path or path:find("[%c]") or not M.is_absolute(path) then return nil end
        path = M.normalize(path)
        -- Tiled writes absolute, resolved paths. Do not let a hand-edited hint
        -- hide an inside-toolkit path behind dot segments.
        for segment in path:gmatch("[^/]+") do
            if segment == "." or segment == ".." then return nil end
        end
        hint[name] = path
    end
    if M.maps_folder_problem(hint.folder, root) then return nil end
    if not hint.world:lower():match("%.world$") then return nil end
    return hint
end

-- The path and a newline, as installer/setup_paths.sh writes it; editor_core
-- reads the first line.
function M.project_path_text(root)
    return M.normalize(root) .. "\n"
end

local function json_string(text)
    return '"' .. tostring(text):gsub('[\\"]', function(c) return "\\" .. c end) .. '"'
end

-- The string values inside a JSON array's text, unescaped (enough for paths:
-- \\ and \" and \/). Lua patterns have no alternation, so scan by hand.
local function json_strings(body)
    local out, i, n = {}, 1, #body
    while i <= n do
        local quote = body:find('"', i, true)
        if not quote then break end
        local j, buf = quote + 1, {}
        while j <= n do
            local c = body:sub(j, j)
            if c == "\\" then
                buf[#buf + 1] = body:sub(j + 1, j + 1)
                j = j + 2
            elseif c == '"' then
                break
            else
                buf[#buf + 1] = c
                j = j + 1
            end
        end
        out[#out + 1] = table.concat(buf)
        i = j + 1
    end
    return out
end

-- Make folder the first entry of the "folders" list of an MVTK.tiled-project
-- file (JSON text), adding it when missing. The first folder outside the
-- toolkit is the maps folder (see first_external_folder), which Tiled's world
-- commands offer by default; other entries stay listed in their order.
-- Returns new_text, changed. The rest of the file is untouched.
function M.add_project_folder(text, folder)
    text = tostring(text or "")
    local wanted = M.normalize(folder)
    if wanted == "" then return text, false end
    local start_pos, end_pos, body = text:find('"folders"%s*:%s*(%b[])')
    if not start_pos then
        -- No list yet: add one right after the opening brace.
        local brace = text:find("{", 1, true)
        if not brace then return text, false end
        local entry = '\n    "folders": [\n        ' .. json_string(wanted) .. '\n    ],'
        return text:sub(1, brace) .. entry .. text:sub(brace + 1), true
    end
    local existing_entries = json_strings(body:sub(2, -2))
    if existing_entries[1] and key(existing_entries[1]) == key(wanted) then return text, false end
    local entries = { wanted }
    for _, existing in ipairs(existing_entries) do
        if key(existing) ~= key(wanted) then entries[#entries + 1] = existing end
    end
    -- Keep Tiled's layout: the indentation of the "folders" key, and of the
    -- existing items (one level deeper when the list is empty).
    local line_start = text:sub(1, start_pos):match(".*\n()") or 1
    local indent = text:sub(line_start, start_pos - 1):match("^(%s*)") or "    "
    local item_indent = body:match('\n([ \t]*)"')
        or (indent .. (indent:find("\t", 1, true) and "\t" or "    "))
    local lines = {}
    for i, value in ipairs(entries) do
        lines[i] = item_indent .. json_string(value)
    end
    local list = '"folders": [\n' .. table.concat(lines, ",\n") .. "\n" .. indent .. "]"
    return text:sub(1, start_pos - 1) .. list .. text:sub(end_pos + 1), true
end

-- The first folder listed in MVTK.tiled-project that lies outside root, as an
-- absolute path (relative entries resolve against root), or nil.
function M.first_external_folder(text, root)
    local body = tostring(text or ""):match('"folders"%s*:%s*(%b[])')
    if not body then return nil end
    for _, value in ipairs(json_strings(body:sub(2, -2))) do
        local folder = M.normalize(value)
        if not M.is_absolute(folder) then
            folder = M.normalize(M.normalize(root) .. "/" .. folder)
            -- Fold "dir/../" segments so the inside/outside test is exact.
            local folded
            repeat
                folded = folder
                folder = folder:gsub("/[^/]+/%.%./", "/", 1)
            until folder == folded
            folder = folder:gsub("/[^/]+/%.%.$", "")
        end
        if not M.is_inside(folder, root) then return folder end
    end
    return nil
end

-- path with the platform's separators for display. platform: editor.platform
-- ("x86_64-win32", "x86_64-macos", ...); nil keeps forward slashes.
function M.os_path(path, platform)
    local p = M.normalize(path)
    if tostring(platform or ""):find("win32", 1, true) then p = p:gsub("/", "\\") end
    return p
end
local os_path = M.os_path

-- WHERE_THINGS_ARE.txt for this toolkit. opts.maps_folder: the creator's Tiled
-- maps folder, if known. opts.platform: editor.platform (for path separators).
function M.where_things_are_text(root, opts)
    opts = opts or {}
    local platform = opts.platform
    local function at(rel) return "      " .. os_path(M.normalize(root) .. (rel ~= "" and ("/" .. rel) or ""), platform) end
    local lines = {
        "================================================================================",
        "  MICROVANIA TOOLKIT - WHERE THINGS ARE",
        "  (written by Project > Set Up This Toolkit; run it again after moving the folder)",
        "================================================================================",
        "",
        "This toolkit is at:",
        "",
        at(""),
        "",
        "--------------------------------------------------------------------------------",
        "  OPEN THESE TWO FILES",
        "--------------------------------------------------------------------------------",
        "",
        "  In Defold (File > Open Project...):",
        at("game.project"),
        "",
        "  In Tiled (File > Open File or Project..., then Enable Extensions if Tiled asks):",
        at("MVTK.tiled-project"),
        "",
        "  Tiled's defold and lua plugins must be ticked: Edit > Preferences... > Plugins.",
        "",
        "  Tiled exports go to the toolkit whose MVTK.tiled-project is open.",
        "",
        "--------------------------------------------------------------------------------",
        "  YOUR TILED MAPS (keep them outside this folder)",
        "--------------------------------------------------------------------------------",
        "",
    }
    if opts.maps_folder and opts.maps_folder ~= "" then
        lines[#lines + 1] = "      " .. os_path(opts.maps_folder, platform)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  It is listed in Tiled's Project panel. In Tiled, File > Start a New World..."
        lines[#lines + 1] = "  offers it as the place for new worlds."
    else
        lines[#lines + 1] = "  Not chosen yet. Run Project > Set Up This Toolkit in Defold to choose one,"
        lines[#lines + 1] = "  or pick any folder outside the toolkit when Tiled asks."
    end
    local rest = {
        "",
        "--------------------------------------------------------------------------------",
        "  WHERE EXPORTS GO (inside this toolkit)",
        "--------------------------------------------------------------------------------",
        "",
        "  Rooms (.lua / .tilemap):",
        at("developer/assets/tiled/maps"),
        "  Tilesets (.tsx) and their images:",
        at("developer/assets/tiled/tilesets"),
        at("developer/assets/tilesheets"),
        "  Game settings (Project > Game Settings... and config files):",
        at("developer/config"),
        "",
        "--------------------------------------------------------------------------------",
        "  GUIDES",
        "--------------------------------------------------------------------------------",
        "",
        at("START_HERE.txt"),
        at("docs/CREATOR_WORKFLOW.html"),
        "",
    }
    for _, line in ipairs(rest) do lines[#lines + 1] = line end
    return table.concat(lines, "\n")
end

-- An absolute project root: the hooks normally resolve one; otherwise ask the
-- editor where game.project is.
local function absolute_root(root, editor)
    root = M.normalize(root)
    if M.is_absolute(root) then return root end
    local ok, attrs = pcall(editor.external_file_attributes, "game.project")
    if ok and attrs and attrs.exists and attrs.path then
        local resolved = M.parent(attrs.path)
        if M.is_absolute(resolved) then return resolved end
    end
    return nil
end

-- The editor can inspect external originals even though writes stay in the
-- toolkit. Missing paths or API errors simply make a saved hint unusable.
local function external_path_exists(editor, path, attribute)
    local ok, attrs = pcall(editor.external_file_attributes, path)
    return ok and attrs and attrs.exists and attrs[attribute] == true
end

-- Ask for the maps folder until it is usable; nil when the creator skips.
local function choose_maps_folder(deps, root, current)
    local ui = deps.editor.ui
    local start = current or M.parent(root)
    while true do
        local picked = ui.show_external_directory_dialog({
            path = start,
            title = "Choose the folder for your Tiled worlds and maps",
        })
        if not picked or picked == "" then return nil end
        picked = M.normalize(picked)
        local problem = M.maps_folder_problem(picked, root)
        if not problem then return picked end
        local again = deps.dialog("Choose Another Folder", {
            problem,
            "Your Tiled maps are the originals; the toolkit keeps only exported copies, which Reset Project can clear.",
        }, {
            cancel_text = "Skip",
            cancel_result = "skip",
            extra_buttons = { ui.dialog_button({ text = "Choose Again...", result = "again" }) },
        })
        if again ~= "again" then return nil end
        start = M.parent(root)
    end
end

-- Project > Set Up This Toolkit. deps, from hooks/editor_commands.lua:
--   editor    the Defold editor API (editor.ui dialogs, external_file_attributes,
--             open_external_file, platform)
--   headless  true when there is no editor UI
--   root      the project root the hooks resolved
--   read      read_text(path) -> text, or nil when missing
--   write     write_if_changed(path, text)
--   info      log(message)
--   dialog    show_editor_status_dialog(title, lines, opts) -> the chosen result
-- Returns true when done or cancelled; errors are shown by the menu wrapper.
function M.run(deps)
    local editor = deps.editor
    local ui = editor and editor.ui
    if deps.headless or not (ui and ui.show_external_directory_dialog and ui.dialog_button) then
        error("Set Up This Toolkit runs from the Defold editor's Project menu.", 0)
    end
    local root = absolute_root(deps.root, editor)
    if not root then
        error("Could not find this project's folder on disk. Restart Defold, then run Project > Set Up This Toolkit again.", 0)
    end
    local platform = type(editor.platform) == "string" and editor.platform or nil
    local function shown(path) return M.os_path(path, platform) end
    local function at(rel) return M.normalize(root .. "/" .. rel) end

    local project_file = at("MVTK.tiled-project")
    local project_text = deps.read(project_file)
    local current = project_text and M.first_external_folder(project_text, root) or nil
    local hint = M.read_worlds_hint(deps.read(at("TILED_WORLDS_FOLDER.txt")), root)
    if hint and not external_path_exists(editor, hint.folder, "is_directory") then hint = nil end
    local offered_hint = not current and hint or nil
    local folder_line = current and ("Your Tiled maps folder: " .. shown(current))
        or (offered_hint and ("Your Tiled worlds folder (from Tiled): " .. shown(offered_hint.folder)))
        or "You can also choose a folder for your Tiled worlds and maps, outside this toolkit. Tiled then lists it in its Project panel and offers it when you start a world."
    local buttons
    if offered_hint then
        buttons = {
            ui.dialog_button({ text = "Set Up", result = "setup" }),
            ui.dialog_button({ text = "Choose Another Folder...", result = "choose" }),
        }
    else
        buttons = {
            ui.dialog_button({ text = current and "Change Maps Folder..." or "Choose Maps Folder...", result = "choose" }),
            ui.dialog_button({ text = current and "Set Up" or "Set Up Without Folder", result = "setup" }),
        }
    end
    local choice = deps.dialog("Set Up This Toolkit", {
        "This toolkit is at: " .. shown(root),
        "Set Up records where the toolkit is and writes WHERE_THINGS_ARE.txt with the paths you need. It changes nothing outside this folder.",
        folder_line,
    }, {
        cancel_text = "Cancel",
        cancel_result = "cancel",
        extra_buttons = buttons,
    })
    if choice ~= "choose" and choice ~= "setup" then
        deps.info("Set Up This Toolkit: cancelled.")
        return true
    end

    local maps_folder = current
    local project_changed = false
    local picked
    if choice == "choose" then
        picked = choose_maps_folder(deps, root, current or (offered_hint and offered_hint.folder))
    elseif offered_hint then
        picked = offered_hint.folder
    end
    if picked and project_text then
        local new_text, changed = M.add_project_folder(project_text, picked)
        if changed then
            deps.write(project_file, new_text)
            project_changed = true
        end
        maps_folder = picked
    end
    deps.write(at("hooks/project_path.txt"), M.project_path_text(root))
    local where_file = at("WHERE_THINGS_ARE.txt")
    deps.write(where_file, M.where_things_are_text(root, { maps_folder = maps_folder, platform = platform }))
    deps.info("Set Up This Toolkit: root=" .. root .. " maps=" .. tostring(maps_folder))

    local next_step = "Next, in Tiled: tick the defold and lua plugins under Edit > Preferences... > Plugins."
        .. " Then choose File > Open File or Project..., pick " .. shown(project_file)
        .. " and click Enable Extensions if Tiled asks. Tiled exports to the toolkit whose project is open."
    local world_step = "Then use File > Start a New World... for your own game. To try a downloaded sample world,"
        .. " follow the START_HERE.txt in its folder."
    if hint and external_path_exists(editor, hint.world, "is_file") then
        next_step = "Next, in Defold: Project > Reload Editor Scripts."
        world_step = "Then paint and export your first room in Tiled, following Creator Guide section 4 (docs/CREATOR_WORKFLOW.html)."
    end
    -- Empty lines are skipped by the dialog.
    local lines = {
        "This toolkit: " .. shown(root),
        maps_folder and ("Your Tiled maps folder: " .. shown(maps_folder))
            or "Tiled maps folder: not chosen. Tiled asks for a folder when you start a world.",
        project_text and "" or "MVTK.tiled-project is missing from the toolkit folder, so no maps folder could be listed. Restore it from the toolkit download.",
        next_step,
        world_step,
        project_changed and "If Tiled already has this project open, open it again so it shows the new folder." or "",
        "These paths are saved in WHERE_THINGS_ARE.txt in the toolkit folder.",
    }
    local can_open = editor.open_external_file ~= nil
    local after = deps.dialog("Toolkit Set Up", lines, {
        -- Button text is mnemonic-parsed: a single "_" is swallowed, "__" shows one.
        extra_buttons = can_open and { ui.dialog_button({ text = "Open WHERE__THINGS__ARE.txt", result = "open" }) } or nil,
    })
    if after == "open" and can_open then
        local ok_open, err = pcall(editor.open_external_file, shown(where_file))
        if not ok_open then deps.info("Set Up This Toolkit: could not open WHERE_THINGS_ARE.txt: " .. tostring(err)) end
    end
    return true
end

return M
