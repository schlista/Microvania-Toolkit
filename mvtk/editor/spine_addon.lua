-- Spine add-on state and text transforms, shared by editor commands and the CLI.
-- No filesystem or editor APIs: callers supply complete text snapshots and a
-- checked directory reader. State lives in the four existing project files.
local Text = require "mvtk.editor.resource_text"
local M = {}

M.ADDON_DIR = "developer/addons/spine"
M.DEPENDENCY_URL = "https://github.com/defold/extension-spine/archive/refs/tags/4.9.3.zip"
M.IGNORE_LINE = "/" .. M.ADDON_DIR
M.SPRITE_COLLECTION = "/developer/game/player/player_sprite.collection"
M.FACTORIES = {
    { path="developer/game/player/player_factory.collectionfactory", prototype="/developer/addons/spine/player/player.collection" },
    { path="developer/game/player/player_spine_factory.collectionfactory", prototype="/developer/addons/spine/player/player_spine.collection" },
}
M.CONTROL_PATHS = { "game.project", ".defignore", M.FACTORIES[1].path, M.FACTORIES[2].path }

local function normalized(path)
    return tostring(path):gsub("\\", "/"):gsub("^/+", ""):gsub("/+", "/"):gsub("/$", "")
end
local function sorted_keys(t)
    local keys = {}; for key in pairs(t) do keys[#keys+1] = key end
    table.sort(keys); return keys
end
local function lines(text)
    local out, pos = {}, 1
    while pos <= #text do
        local ending = text:find("\n", pos, true)
        local stop = ending or #text
        local raw = text:sub(pos, stop)
        out[#out+1] = { raw=raw, text=raw:gsub("[\r\n]+$", "") }
        pos = stop + 1
    end
    return out
end
local function newline(text) return text:find("\r\n", 1, true) and "\r\n" or "\n" end
local function is_spine_url(url) return url and url:find("extension-spine", 1, true) ~= nil end
local function project_sections(text)
    local count = 0
    for _, line in ipairs(lines(text)) do
        if line.text:match("^%s*%[project%]%s*$") then count = count + 1 end
    end
    return count
end
local function dependency_entries(text)
    local section, entries, used = nil, {}, {}
    for index, line in ipairs(lines(text)) do
        local heading = line.text:match("^%s*%[([^%]]+)%]%s*$")
        if heading then section = heading end
        local number, url = line.text:match("^%s*dependencies#(%d+)%s*=%s*(.-)%s*$")
        if number and section == "project" then
            used[tonumber(number)] = true
            if is_spine_url(url) then entries[#entries+1] = { line=index, index=tonumber(number), url=url } end
        end
    end
    return entries, used
end
local function ignored_addon(line)
    return line:match("^%s*(.-)%s*$"):gsub("/$", "") == M.IGNORE_LINE
end

-- Preserve unrelated text, dependency indices and the input newline convention.
-- Canonical Off -> On -> Off is byte-identical. Arbitrary removed dependency
-- spacing/indices and ignore-line placement cannot be recovered without metadata.
function M.dependency_text(text, enabled)
    text = text or ""
    assert(project_sections(text) == 1, "game.project must contain exactly one [project] section")
    local entries = dependency_entries(text)
    if enabled and #entries == 1 and entries[1].url == M.DEPENDENCY_URL then return text end
    if not enabled and #entries == 0 then return text end
    local remove = {}; for _, entry in ipairs(entries) do remove[entry.line] = true end
    local kept = {}
    for index, line in ipairs(lines(text)) do if not remove[index] then kept[#kept+1] = line.raw end end
    local output = table.concat(kept)
    if not enabled then return output end
    local _, used = dependency_entries(output)
    local index = 0; while used[index] do index = index + 1 end
    local source, section, insert_at = lines(output), nil, nil
    for i, line in ipairs(source) do
        local heading = line.text:match("^%s*%[([^%]]+)%]%s*$")
        if heading then
            if section == "project" then break end
            section = heading
            if section == "project" then insert_at = i + 1 end
        elseif section == "project" and line.text:match("^%s*dependencies#%d+%s*=") then insert_at = i + 1 end
    end
    assert(insert_at, "game.project is missing its [project] section")
    local eol = newline(text)
    if insert_at > 1 and source[insert_at-1].raw:sub(-1) ~= "\n" then
        source[insert_at-1].raw = source[insert_at-1].raw .. eol
    end
    table.insert(source, insert_at, {raw="dependencies#" .. index .. " = " .. M.DEPENDENCY_URL .. eol})
    local result = {}; for _, line in ipairs(source) do result[#result+1] = line.raw end
    return table.concat(result)
end

function M.ignore_text(text, enabled)
    text = text or ""
    local source, count = lines(text), 0
    for _, line in ipairs(source) do if ignored_addon(line.text) then count = count + 1 end end
    if not enabled and count == 1 then return text end
    if enabled and count == 0 then return text end
    local output = {}
    for _, line in ipairs(source) do if not ignored_addon(line.text) then output[#output+1] = line.raw end end
    local result = table.concat(output)
    if not enabled then
        local eol = newline(text)
        if result ~= "" and result:sub(-1) ~= "\n" then result = result .. eol end
        result = result .. M.IGNORE_LINE .. eol
    end
    return result
end

function M.factory_text(text, prototype)
    if not text then return 'prototype: "' .. prototype .. '"\n' end
    local doc = Text.parse(text)
    local fields = Text.all(doc.root, "prototype")
    assert(#fields <= 1, "Collection factory has duplicate prototype fields")
    if #fields == 0 then
        return text .. (text ~= "" and text:sub(-1) ~= "\n" and newline(text) or "")
            .. 'prototype: "' .. prototype .. '"' .. newline(text)
    end
    if fields[1].value == prototype then return text end
    Text.replace(doc, fields[1], prototype)
    return Text.render(doc)
end

function M.state(files)
    local details = {}
    local function record(path, state, message)
        details[#details+1] = {path=path, state=state, message=message}
    end
    local project = files["game.project"]
    if type(project) ~= "string" then record("game.project", "mixed", "missing game.project")
    elseif project_sections(project) ~= 1 then
        record("game.project", "mixed", "game.project must contain exactly one [project] section")
    else
        local entries = dependency_entries(project)
        local state = #entries == 0 and "off" or (#entries == 1 and entries[1].url == M.DEPENDENCY_URL and "on" or "mixed")
        record("game.project", state, state == "mixed" and "Spine dependency must use the supported URL exactly once" or "Spine dependency is " .. state)
    end
    local ignore = files[".defignore"]
    if type(ignore) ~= "string" then record(".defignore", "mixed", "missing .defignore")
    else
        local count = 0
        for _, line in ipairs(lines(ignore)) do if ignored_addon(line.text) then count = count + 1 end end
        local state = count == 0 and "on" or (count == 1 and "off" or "mixed")
        record(".defignore", state, state == "mixed" and "duplicate Spine ignore lines" or "Spine resources are " .. (state == "off" and "ignored" or "visible"))
    end
    for _, factory in ipairs(M.FACTORIES) do
        local ok, doc = pcall(Text.parse, files[factory.path])
        local values = ok and Text.all(doc.root, "prototype") or {}
        local prototype = #values == 1 and values[1].value
        local state = prototype == factory.prototype and "on" or (prototype == M.SPRITE_COLLECTION and "off" or "mixed")
        record(factory.path, state, state == "mixed" and "factory prototype does not match either add-on state" or "factory is " .. state)
    end
    local state = details[1].state
    for _, detail in ipairs(details) do if detail.state ~= state then return "mixed", details end end
    return state, details
end

-- Transaction entries use project-relative paths, suitable for
-- project_transaction.commit(project_root, entries). No writes happen here.
function M.plan(files, target)
    assert(target == "on" or target == "off", "Spine target must be on or off")
    local enabled, transformed, changes = target == "on", {}, {}
    for path, text in pairs(files) do transformed[path] = text end
    transformed["game.project"] = M.dependency_text(files["game.project"], enabled)
    transformed[".defignore"] = M.ignore_text(files[".defignore"], enabled)
    for _, factory in ipairs(M.FACTORIES) do
        transformed[factory.path] = M.factory_text(files[factory.path], enabled and factory.prototype or M.SPRITE_COLLECTION)
    end
    for _, path in ipairs(M.CONTROL_PATHS) do
        if files[path] ~= transformed[path] then changes[#changes+1] = {path=path, content=transformed[path]} end
    end
    assert(M.state(transformed) == target, "Spine state repair did not reach " .. target)
    return changes, transformed
end

local resource_types = {}
for extension in ("go collection collectionfactory factory collectionproxy gui atlas sprite collisionobject convexshape label font material model mesh particlefx sound camera render tilemap tilesource input_binding objectinterpolation spinescene spinemodel spinejson"):gmatch("%S+") do
    resource_types[extension] = true
end
local config_paths = {
    ["developer/config/game_config.lua"]=true, ["developer/config/player_settings.lua"]=true,
    ["developer/config/creator_settings.lua"]=true, ["developer/config/boss_types.lua"]=true,
    ["developer/config/boss_defaults.lua"]=true,
}
local function is_tiled_data(path) return path:match("^developer/assets/tiled/maps/.*%.lua$") ~= nil end
function M.eligible(path)
    path = normalized(path)
    return resource_types[path:match("%.([^./]+)$") or ""] == true or config_paths[path] == true or is_tiled_data(path)
end
local excluded_roots = { test=true, tests=true, build=true, dist=true, export=true }
-- ExportManifest expands these toolkit-owned declarations selectively rather
-- than copying their entire trees. Other custom roots retain all raw contents.
local selective_custom_roots = {
    ["developer/tools"]=true, ["developer/runtime"]=true, ["developer/config"]=true,
    ["developer/rooms/generated"]=true, ["developer/assets/tiled/maps"]=true,
    ["developer/assets/minimap"]=true, ["developer/rooms/my_first_room.lua"]=true,
}
-- Derived snapshot diagnostics only; this is never a path written to disk or
-- an add-on state flag. Deferring them to scan lets intentional On projects
-- remain usable while Turn Off and Off validation fail closed.
local scan_errors_key = ".spine_scan_errors"
local function project_resource_roots(project, key, selective)
    local roots, section = {}, nil
    for _, line in ipairs(lines(project or "")) do
        local heading = line.text:match("^%s*%[([^%]]+)%]%s*$")
        if heading then section = heading end
        local value = line.text:match("^%s*" .. key .. "%s*=%s*(.-)%s*$")
        if section == "project" and value then
            for declared in value:gmatch("[^,]+") do
                declared = declared:match("^%s*(.-)%s*$")
                local path = normalized(declared)
                if declared:sub(1,1) == "/" and not (selective and selective[path]) then roots[#roots+1] = path end
            end
        end
    end
    return roots
end
function M.custom_resource_roots(project)
    return project_resource_roots(project,"custom_resources",selective_custom_roots)
end
local function within(path, root)
    return root == "" or path == root or path:sub(1,#root+1) == root .. "/"
end
local function custom_root_for(path, roots, ancestors)
    for _, root in ipairs(roots) do
        if within(path,root) or (ancestors and within(root,path)) then return root end
    end
end
-- Match ExportManifest's platform filter: Export Game copies these subtrees
-- without .defignore. Non-platform descendants of a bundle root stay excluded.
local bundle_platforms = {ios=true, android=true, osx=true,
    win32=true, linux=true, web=true, switch=true}
local function bundle_root_for(path, roots, omission)
    for _, root in ipairs(roots) do
        -- A pruned root/ancestor cannot establish whether platform files exist.
        if omission and within(root,path) then return root end
        if within(path,root) then
            local relative = root == "" and path or path:sub(#root+2)
            local first = relative:match("^([^/]+)/")
            if omission and not first then first = relative end
            if first and (first == "common" or bundle_platforms[first]
                or bundle_platforms[first:match("^.+%-([%w_]+)$")]) then return root end
        end
    end
end
-- Defold 1.14 .defignore rules: '*'/'?' stay within one path segment;
-- '**' matches zero or more whole segments. A matched parent is ignored too.
-- https://defold.com/manuals/project-defignore/
local function path_parts(path)
    local parts = {}
    for part in (path .. "/"):gmatch("(.-)/") do parts[#parts+1] = part end
    return parts
end
local function ignore_patterns(text)
    local patterns = {}
    for _, line in ipairs(lines(text or "")) do
        local pattern = line.text:match("^%s*(.-)%s*$")
        if pattern:sub(1,1) == "/" then
            patterns[#patterns+1] = path_parts(pattern:sub(2):gsub("/$", ""))
        end
    end
    return patterns
end
local function matches_ignore(parts, pattern)
    local memo = {}
    local function match(i, j)
        if i > #pattern then return true end
        local key = i .. ":" .. j
        if memo[key] ~= nil then return memo[key] end
        local found
        if pattern[i] == "**" then
            found = match(i+1,j) or (j <= #parts and match(i,j+1))
        elseif j <= #parts then
            local segment = pattern[i]:gsub("([^%w])", "%%%1"):gsub("%%%*", ".*"):gsub("%%%?", ".")
            found = parts[j]:match("^" .. segment .. "$") ~= nil and match(i+1,j+1)
        end
        memo[key] = found == true
        return memo[key]
    end
    return match(1,1)
end

-- Common subset of GNU find's default regex and BSD find's basic regex.
-- Literal punctuation uses brackets so '+'/'?' cannot become GNU operators.
function M.find_literal(path)
    return (path:gsub("[.\\%[%]*^$+?(){}|]", function(char)
        if char == "\\" then return "\\\\" end
        if char == "]" then return "[]]" end
        return "[" .. char .. "]"
    end))
end
function M.ignore_find_patterns(text, root)
    local patterns = {}
    for _, parts in ipairs(ignore_patterns(text)) do
        local output = {M.find_literal(root)}
        for _, part in ipairs(parts) do
            if part == "**" then output[#output+1] = "\\(/[^/][^/]*\\)*"
            else
                local segment = {}
                for char in part:gmatch(".") do
                    segment[#segment+1] = char == "*" and "[^/]*" or (char == "?" and "[^/]" or M.find_literal(char))
                end
                output[#output+1] = "/" .. table.concat(segment)
            end
        end
        -- find matches the entire path. Descendants match an ignored parent.
        patterns[#patterns+1] = table.concat(output) .. "\\(/[^/][^/]*\\)*"
    end
    return patterns
end
function M.ignored(path, ignore_text)
    path = normalized(path)
    if path == M.ADDON_DIR or path:sub(1,#M.ADDON_DIR+1) == M.ADDON_DIR .. "/" then return true end
    if excluded_roots[path:match("^[^/]+") or ""] then return true end
    for part in path:gmatch("[^/]+") do if part:sub(1,1) == "." or part == "__pycache__" then return true end end
    local parts = path_parts(path)
    for _, pattern in ipairs(ignore_patterns(ignore_text)) do
        if matches_ignore(parts,pattern) then return true end
    end
    return false
end

-- Host-neutral scan adapter. list(absolute_dir) MUST return two arrays, even
-- for empty directories; nil/errors are refused, never treated as empty scans.
-- read(absolute_path) returns bytes or nil for a missing optional control file.
function M.collect(opts)
    local root = tostring(opts.root or "."):gsub("\\", "/"):gsub("/$", "")
    local read, list = assert(opts.read, "Spine scan needs read"), assert(opts.list, "Spine scan needs list")
    local files = {}
    for _, path in ipairs(M.CONTROL_PATHS) do
        local content, err = read(root .. "/" .. path)
        assert(content ~= nil or err == nil, "Cannot read " .. path .. ": " .. tostring(err))
        if content ~= nil then files[path] = content end
    end
    local custom_roots, omissions = M.custom_resource_roots(files["game.project"]), {}
    local bundle_roots = project_resource_roots(files["game.project"],"bundle_resources")
    local function check_omission(path)
        local custom = custom_root_for(path,custom_roots,true)
        if custom ~= nil then
            omissions[#omissions+1] = "Cannot inspect game.project custom_resources /" .. custom
                .. ": excluded path /" .. path .. ". Remove this resource declaration or its exclusion, then retry."
        end
        local bundle = bundle_root_for(path,bundle_roots,true)
        if bundle ~= nil then
            omissions[#omissions+1] = "Cannot inspect game.project bundle_resources /" .. bundle
                .. ": excluded path /" .. path .. ". Remove this resource declaration or its exclusion, then retry."
        end
    end
    local function walk(relative)
        local dirs, names, omitted = list(root .. (relative ~= "" and "/" .. relative or ""))
        assert(type(dirs) == "table" and type(names) == "table", "Cannot enumerate Spine references in " .. (relative ~= "" and relative or "."))
        local function child(name)
            assert(type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
                and not name:find("[/\\%c]"), "Invalid directory entry during Spine scan")
            return relative ~= "" and relative .. "/" .. name or name
        end
        for _, name in ipairs(omitted or {}) do check_omission(child(name)) end
        for _, name in ipairs(names) do
            local path = child(name)
            if M.ignored(path,files[".defignore"]) then check_omission(path)
            elseif M.eligible(path) then
                local content, err = read(root .. "/" .. path)
                assert(type(content) == "string", "Cannot read Spine scan resource " .. path .. ": " .. tostring(err))
                files[path] = content
            end
        end
        for _, name in ipairs(dirs) do
            local path = child(name)
            if M.ignored(path, files[".defignore"]) then check_omission(path) else walk(path) end
        end
    end
    walk("")
    if #omissions > 0 then table.sort(omissions); files[scan_errors_key] = table.concat(omissions,"\n") end
    return files
end

local function add_reason(reasons, path, kind, message)
    reasons[#reasons+1] = {path=path, kind=kind, message=message}
end
local function sort_reasons(reasons)
    table.sort(reasons, function(a,b) return a.path == b.path and a.message < b.message or a.path < b.path end)
    return reasons
end
local function spine_reference(value)
    if type(value) ~= "string" then return false end
    return value:find("/" .. M.ADDON_DIR .. "/", 1, true) ~= nil
        or value == "/" .. M.ADDON_DIR
        or value:find("%.spinescene") ~= nil or value:find("%.spinemodel") ~= nil or value:find("%.spinejson") ~= nil
end
local function managed_prototype(path, entry, opts)
    if not opts.exempt_managed_factories or entry.name ~= "prototype" then return false end
    for _, factory in ipairs(M.FACTORIES) do
        if path == factory.path and entry.value == factory.prototype then return true end
    end
    return false
end
-- Match boss.script / Util.normalize_hash_string without importing a runtime
-- module into the editor. Only userdata uses Defold's hash: [text] wrapper.
local function normalize_boss_string(value)
    if value == nil then return nil end
    local text = tostring(value)
    if type(value) == "userdata" then text = text:match("^hash:%s*%[(.-)%]$") end
    if not text then return nil end
    text = text:match("^%s*(.-)%s*$")
    if text == "" or text == "0000000000000000" or text:find("<unknown",1,true) then return nil end
    return text
end
local function normalize_visual_type(value)
    local text = normalize_boss_string(value)
    text = text and text:lower()
    if text == "spine" or text == "sprite" then return text end
end
local function spine_selection(visual_type, component)
    visual_type = normalize_visual_type(visual_type)
    if visual_type then return visual_type == "spine" end
    component = normalize_boss_string(component)
    return component ~= nil and component:lower():match("^spine") ~= nil
end
local function inspect_node(node, path, opts, depth)
    assert(depth < 20, "Embedded resource nesting exceeds the Spine scan limit")
    local visual_type, component
    for _, entry in ipairs(node.entries) do
        if entry.node then
            local name = Text.value(entry.node,"id") or Text.value(entry.node,"name")
            if name == "boss_visual_type" then visual_type = Text.value(entry.node,"value")
            elseif name == "visual_component" then component = Text.value(entry.node,"value") end
        end
    end
    if spine_selection(visual_type,component) then return "selects boss_visual_type = spine" end
    for _, entry in ipairs(node.entries) do
        if entry.node then
            local found = inspect_node(entry.node, path, opts, depth+1); if found then return found end
        elseif (entry.name == "type" and entry.value == "spinemodel")
            or (spine_reference(entry.value) and not managed_prototype(path, entry, opts)) then
            return "references a Spine resource or embedded Spine component"
        elseif entry.name == "data" and type(entry.value) == "string" and entry.value ~= "" then
            local found = inspect_node(Text.parse(entry.value).root, path, opts, depth+1); if found then return found end
        end
    end
end

local function inspect_project(text, reasons)
    local section
    for _, line in ipairs(lines(text or "")) do
        local heading = line.text:match("^%s*%[([^%]]+)%]%s*$")
        if heading then section = heading end
        local key, value = line.text:match("^%s*([%w_.#]+)%s*=%s*(.-)%s*$")
        if key and section then
            local list = key == "custom_resources" or key == "bundle_resources"
            if list and section == "project" then
                -- Explicit custom directories are exported recursively, even
                -- when .defignore hides their resources from the editor.
                -- Bundle roots only select their platform subfolders, so an
                -- ancestor of the add-on is not itself a bundle reference.
                for declared in value:gmatch("[^,]+") do
                    declared = declared:match("^%s*(.-)%s*$")
                    local path = normalized(declared)
                    local includes_addon = key == "custom_resources" and
                        (path == "" or M.ADDON_DIR:sub(1,#path+1) == path .. "/")
                    if declared:sub(1,1) == "/" and (includes_addon or spine_reference("/" .. path)) then
                        add_reason(reasons,"game.project","resource", "project." .. key .. " includes Spine resources: " .. declared)
                    end
                end
            elseif not list and value:sub(1,1) == "/" then
                -- Other resource settings may point straight into the add-on
                -- (for example bootstrap.main_collection) or at a Spine type.
                local path = normalized(value)
                local ext = path:match("%.([^./]+)$")
                if ext and (resource_types[ext] or resource_types[ext:gsub("c$", "")])
                    and spine_reference("/" .. path) then
                    add_reason(reasons,"game.project","resource",section .. "." .. key .. " references Spine resources: " .. value)
                end
            end
        end
    end
end

-- Only real resource formats are parsed. Framework Lua emitters and README
-- examples are implementation/documentation, not dependency references.
function M.scan(files, opts)
    opts = opts or {}; local reasons = {}
    inspect_project(files["game.project"],reasons)
    for problem in (files[scan_errors_key] or ""):gmatch("[^\n]+") do
        add_reason(reasons,"game.project","scan_error",problem)
    end
    local custom_roots = M.custom_resource_roots(files["game.project"])
    local bundle_roots = project_resource_roots(files["game.project"],"bundle_resources")
    for _, path in ipairs(sorted_keys(files)) do
        if (not M.ignored(path, files[".defignore"]) or custom_root_for(path,custom_roots)
            or bundle_root_for(path,bundle_roots))
            and resource_types[path:match("%.([^./]+)$") or ""] then
            if path:match("%.spinescene$") or path:match("%.spinemodel$") or path:match("%.spinejson$") then
                add_reason(reasons,path,"resource","Spine-typed resource must be inside " .. M.ADDON_DIR)
            else
                local ok, problem = pcall(function() return inspect_node(Text.parse(files[path]).root,path,opts,0) end)
                if not ok then add_reason(reasons,path,"scan_error","Cannot inspect resource: " .. tostring(problem))
                elseif problem then add_reason(reasons,path,"resource",problem) end
            end
        end
    end
    return sort_reasons(reasons)
end

-- Mirrors resolved_config: game_config plus published creator overrides.
-- player_settings is the migration baseline, not a second Config.player layer.
function M.resolve_config(files)
    local Source = require "developer.tools.project_source"
    local Model = require "mvtk.core.creator_settings_model"
    local function load(path, optional)
        if optional and files[path] == nil then return {} end
        local value, err = Source.load_table(files[path],path)
        assert(value, "Cannot inspect Spine settings in " .. path .. ": " .. tostring(err))
        return value
    end
    local game = load("developer/config/game_config.lua")
    local baseline = load("developer/config/player_settings.lua")
    local player = Model.copy(game.player or {})
    local creator = files["developer/config/creator_settings.lua"]
    if creator then
        local doc = Model.load_document(load("developer/config/creator_settings.lua"),baseline)
        if doc.published then Model.merge(player,doc.overrides.player or {}) end
    end
    return {player=player,bosses=load("developer/config/boss_types.lua",true),boss_defaults=load("developer/config/boss_defaults.lua",true)}
end
local function spine_boss(value, seen)
    if type(value) ~= "table" or seen[value] then return false end
    seen[value] = true
    local visual_type, component = value.boss_visual_type, value.visual_component
    -- Tiled may export properties as a dictionary, a class group or a list.
    for _, child in pairs(value) do
        if type(child) == "table" then
            local name = child.name or child.id
            if name == "boss_visual_type" then visual_type = child.value
            elseif name == "visual_component" then component = child.value end
        end
    end
    if spine_selection(visual_type,component) or ((value.name == "boss_visual_type" or value.id == "boss_visual_type")
        and normalize_visual_type(value.value) == "spine") then return true end
    for _, child in pairs(value) do if spine_boss(child,seen) then return true end end
    return false
end
function M.refusal_reasons(files, config, opts)
    local options = {}; for key,value in pairs(opts or {}) do options[key]=value end
    if options.exempt_managed_factories == nil then options.exempt_managed_factories=true end
    local reasons = M.scan(files,options)
    config = config or M.resolve_config(files)
    if not config.player or config.player.player_type ~= "sprite" then
        add_reason(reasons,"developer/config/game_config.lua","player","Resolved player.player_type must be sprite (check published developer/config/creator_settings.lua overrides too)")
    end
    for _, entry in ipairs({{"bosses","developer/config/boss_types.lua"},{"boss_defaults","developer/config/boss_defaults.lua"}}) do
        if spine_boss(config[entry[1]],{}) then add_reason(reasons,entry[2],"boss","Selects boss_visual_type = spine") end
    end
    local Source = require "developer.tools.project_source"
    for _, path in ipairs(sorted_keys(files)) do
        if is_tiled_data(path) and not M.ignored(path,files[".defignore"]) then
            local value,err = Source.load_table(files[path],path)
            if not value then add_reason(reasons,path,"scan_error","Cannot inspect Tiled boss settings: " .. tostring(err))
            elseif spine_boss(value,{}) then add_reason(reasons,path,"boss","Tiled object selects boss_visual_type = spine") end
        end
    end
    return sort_reasons(reasons)
end
return M
