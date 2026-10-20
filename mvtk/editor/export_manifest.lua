-- Runtime dependency selection for Export Game. No source directories are
-- copied wholesale unless the creator explicitly declares a custom resource.
local ResourceText = require "mvtk.editor.resource_text"
local M = {}

local proto_extensions = {}
for extension in ("collection go collectionproxy collectionfactory factory gui atlas sprite tilemap tilesource collisionobject convexshape material font label sound particlefx render display_profiles model mesh camera spinescene spinemodel textureset texture_profiles"):gmatch("%S+") do
    proto_extensions[extension] = true
end
local text_extensions = {lua=true, script=true, gui_script=true, render_script=true,
    vp=true, fp=true, glsl=true, json=true, appmanifest=true, input_binding=true}

local function safe_path(path)
    assert(type(path) == "string", "Unsafe export path: " .. tostring(path))
    assert(not path:find("[%z\1-\31]") and not path:find(string.char(127),1,true),
        "Unsupported character in export path: " .. path)
    path = path:gsub("^%./", ""):gsub("^/", "")
    assert(path ~= "" and not path:find("\\", 1, true) and not path:find(":", 1, true), "Unsafe export path: " .. path)
    for part in path:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "Export path escapes the project: " .. path)
    end
    return path
end
M.safe_path = safe_path

local function extension(path) return path:match("%.([^./]+)$") end

function M.directory_signature(dirs, files)
    local entries = {}
    for _,name in ipairs(dirs or {}) do entries[#entries+1]="directory:" .. name end
    for _,name in ipairs(files or {}) do entries[#entries+1]="file:" .. name end
    table.sort(entries)
    return table.concat(entries,"\n")
end

local function source_only(path)
    return path:find("/__pycache__/", 1, true) or path:match("%.mvtk%-source$")
        or path:match("%.aseprite$") or path:match("%.tmx$") or path:match("%.tsx$")
        or path:match("%.world$") or path:match("%.pyc$") or path:match("%.py$")
        or path:match("/%.keepdir$") or path:match("/%.test$")
end

local function project_values(content)
    local values, section = {}, ""
    for line in (content .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        section = line:match("^%s*%[([^%]]+)%]") or section
        local key, value = line:match("^%s*([%w_#]+)%s*=%s*(.-)%s*$")
        if key then values[section .. "." .. key] = value end
    end
    return values
end

local function set_resource_list(content, key, paths)
    local value = table.concat(paths, ", ")
    local lines, section, inserted = {}, "", false
    local ending = content:find("\r\n",1,true) and "\r\n" or "\n"
    for line in (content:gsub("\r\n","\n") .. "\n"):gmatch("([^\n]*)\n") do
        local next_section = line:match("^%s*%[([^%]]+)%]")
        if next_section then
            if section == "project" and not inserted then
                lines[#lines+1] = key .. " = " .. value; inserted=true
            end
            section = next_section
        end
        if section == "project" and line:match("^%s*" .. key .. "%s*=") then
            assert(not inserted,"Duplicate game.project " .. key)
            line = key .. " = " .. value; inserted=true
        end
        lines[#lines+1] = line
    end
    if section == "project" and not inserted then lines[#lines+1]=key .. " = " .. value; inserted=true end
    assert(inserted,"game.project is missing [project]")
    return table.concat(lines,ending):gsub("%s*$", "") .. ending
end

-- Decode literals rather than searching escaped protobuf text. This handles
-- adjacent data strings and arbitrarily nested embedded gameobjects.
local function proto_strings(content, visit)
    local doc = ResourceText.parse(content)
    local function walk(node)
        for _, entry in ipairs(node.entries) do
            if entry.node then walk(entry.node)
            elseif type(entry.value) == "string" then
                if entry.name == "data" then proto_strings(entry.value, visit)
                else visit(entry.value, true) end
            end
        end
    end
    walk(doc.root)
end

-- Generated tilemaps consist mostly of numeric cell fields. Avoid building a
-- protobuf tree for those lines. Unusual formatting, escapes and embedded data
-- retain the full parser so concatenation, comments and decoding stay exact.
local function tilemap_strings(content, visit)
    -- The editor's LuaJ throws on %f frontier patterns, so check the
    -- preceding character explicitly (start of text counts as a boundary).
    if content:find("\\", 1, true) or content:find("^data%s*:") or content:find("[^%w_]data%s*:") then
        return proto_strings(content, visit)
    end
    local values = {}
    for line in (content .. "\n"):gmatch("([^\r\n]*)[\r\n]+") do
        if line:find('["\']') then
            local value = line:match('^%s*[%w_]+%s*:%s*"([^"]*)"%s*$')
            if value == nil then return proto_strings(content, visit) end
            values[#values+1] = value
        elseif line:find(":%s*[%a_]") then
            -- ResourceText also visits enum/bool scalars as strings. Preserve
            -- that ordered sequence, even though they are not resource paths.
            local value = line:match("^%s*[%w_]+%s*:%s*([%a_][%w_]*)%s*$")
            if not value then return proto_strings(content, visit) end
            values[#values+1] = value
        end
    end
    for _, value in ipairs(values) do visit(value, true) end
end

M.proto_strings = proto_strings
M.tilemap_strings = tilemap_strings

local authoring_only = {
    ["developer/assets/minimap/updated_map.atlas"] = true,
    ["developer/assets/minimap/updated_map.png"] = true,
    ["developer/assets/minimap/updated_map.lua"] = true,
}

local bundle_platforms = {ios=true, android=true, osx=true,
    win32=true, linux=true, web=true, switch=true}
local function bundle_file(path, base)
    local relative = path:sub(#base+2)
    local first = relative:match("^([^/]+)/")
    return first and (first == "common" or bundle_platforms[first]
        or bundle_platforms[first:match("^.+%-([%w_]+)$")]) or false
end

-- Lua strings also carry optional modules, registry entries, and paths passed
-- through Util.require_config/require_module. Ignore comments, including long
-- comments, so examples cannot accidentally pull authoring tools into a game.
local function lua_strings(content, visit)
    local position = 1
    while position <= #content do
        local character = content:sub(position,position)
        local comment = character == "-" and content:sub(position,position+1) == "--"
        local start = comment and 3 or 1
        local equals = content:match("^%[(=*)%[", position+start-1)
        if equals then
            local close = "]" .. equals .. "]"
            local last = content:find(close, position + start + #equals + 1, true)
            assert(last, "Unclosed Lua long string/comment")
            if not comment then
                local literal = content:sub(position,last+#close-1)
                local prefix = content:sub(math.max(1,position-100),position-1)
                visit(assert((loadstring or load)("return " .. literal))(), prefix:match("require%s*%(?%s*$") ~= nil, position)
            end
            position = last + #close
        elseif comment then
            position = content:find("\n", position, true) or (#content + 1)
        elseif character == '"' or character == "'" then
            local quote, last = character, position + 1
            while last <= #content and content:sub(last,last) ~= quote do
                if content:sub(last,last) == "\\" then last = last + 1 end
                last = last + 1
            end
            assert(last <= #content, "Unclosed Lua string")
            local chunk = assert((loadstring or load)("return " .. content:sub(position,last)))
            local prefix = content:sub(math.max(1,position-100),position-1)
            visit(chunk(), prefix:match("require%s*%(?%s*$") ~= nil, position)
            position = last + 1
        else position = position + 1 end
    end
end

-- Shader examples and disabled includes are not runtime dependencies. Keep
-- quoted include paths intact while removing line and block comments.
local function shader_source(content)
    local parts, position = {}, 1
    while position <= #content do
        local pair = content:sub(position,position+1)
        local character = content:sub(position,position)
        if pair == "//" then
            position = content:find("\n",position+2,true) or (#content+1)
            parts[#parts+1] = "\n"
        elseif pair == "/*" then
            local last = assert(content:find("*/",position+2,true), "Unclosed shader comment")
            parts[#parts+1] = content:sub(position,last+1):gsub("[^\r\n]"," ")
            position = last+2
        elseif character == '"' or character == "'" then
            local quote, last = character, position+1
            while last <= #content and content:sub(last,last) ~= quote do
                if content:sub(last,last) == "\\" then last=last+1 end
                last=last+1
            end
            parts[#parts+1] = content:sub(position,last)
            position = last+1
        else
            parts[#parts+1] = character
            position = position+1
        end
    end
    return table.concat(parts)
end

-- Evaluate data configuration from the same frozen source bytes that will be
-- exported. The runtime resolver owns defaults, nested-path precedence, and
-- directory normalization; a second literal parser would disagree with Lua
-- expressions and config modules that derive their paths from other modules.
local function configured_stream_paths(get, selected)
    local loaded, loading, unsupported = {}, {}, nil
    local guidance = "Export Game cannot resolve stream_settings paths. Use data-only Lua config modules and project resource paths; avoid engine, filesystem, or environment-dependent path calculation. "
    local function reject(message)
        unsupported = unsupported or message
        error(message, 0)
    end
    local function copied_library(library, excluded)
        local copy = {}
        for key, value in pairs(library) do
            if not excluded or not excluded[key] then copy[key] = value end
        end
        return copy
    end
    local load_module
    local config_bridge = {require_config = function(name, fallback)
        local path = safe_path(name:gsub("%.", "/") .. ".lua")
        if not get(path) then return fallback end
        local value = load_module(name)
        assert(type(value) == "table", "Config module must return a table: " .. path)
        return value
    end}
    load_module = function(name)
        if type(name) ~= "string" or not name:match("^[%a_][%w_.]*$")
            or name:match("%.$") or name:find("..",1,true) then
            reject("Unsupported config module name: " .. tostring(name))
        end
        if loaded[name] ~= nil then return loaded[name] end
        if loading[name] then reject("Circular stream config dependency: " .. name) end
        local path = safe_path(name:gsub("%.", "/") .. ".lua")
        local content = get(path)
        if not content then reject("Cannot read stream config dependency: " .. path) end
        selected(path)
        loading[name] = true
        local env = {
            assert=assert, error=error, ipairs=ipairs, next=next, pairs=pairs,
            pcall=pcall, select=select, tonumber=tonumber, tostring=tostring,
            type=type, unpack=unpack or table.unpack, xpcall=xpcall,
            getmetatable=getmetatable, setmetatable=setmetatable,
            rawget=rawget, rawset=rawset, rawequal=rawequal,
            math=copied_library(math,{random=true,randomseed=true}),
            string=copied_library(string), table=copied_library(table),
        }
        for _,key in ipairs({"random","randomseed"}) do
            env.math[key] = function() reject("Unsupported math." .. key .. " in " .. path) end
        end
        env._G = env
        env.require = function(dependency)
            if name == "mvtk.rooms.stream_paths" and dependency == "mvtk.core.util" then
                return config_bridge
            end
            return load_module(dependency)
        end
        setmetatable(env,{__index=function(_,key)
            reject("Unsupported global '" .. tostring(key) .. "' in " .. path)
        end})
        local chunk, err
        if setfenv then
            chunk, err = (loadstring or load)(content, "@export_stream/" .. path)
            if chunk then setfenv(chunk,env) end
        else
            chunk, err = load(content, "@export_stream/" .. path, "t", env)
        end
        if not chunk then reject(tostring(err)) end
        local value = chunk()
        loading[name] = nil
        loaded[name] = value == nil and true or value
        return loaded[name]
    end
    local ok, resolver = pcall(load_module,"mvtk.rooms.stream_paths")
    assert(ok and not unsupported, guidance .. tostring(unsupported or (not ok and resolver) or ""))
    local function resolve(method, id)
        local success, path = pcall(resolver[method],id)
        assert(success and not unsupported, guidance .. tostring(unsupported or (not success and path) or ""))
        local valid, normalized = pcall(safe_path,path)
        assert(valid, guidance .. tostring(not valid and normalized or ""))
        return normalized
    end
    return function(id)
        return resolve("tiled_map_lua",id), resolve("tiled_tilemap",id), resolve("backgrounds_meta",id)
    end
end

function M.build(opts)
    local read, list = assert(opts.read), assert(opts.list)
    local root = assert(opts.root):gsub("\\", "/"):gsub("/$", "")
    local entries, ordered, raw, originals, seen_dirs, inventories = {}, {}, {}, {}, {}, {}
    local warnings = {}
    local published = assert(opts.layout)
    local room_ids = {}
    for _, room in ipairs(published.rooms or {}) do room_ids[safe_path(room.id)] = true end
    local project = assert(read(root .. "/game.project"), "Cannot read game.project")
    local settings = project_values(project)
    local local_roots = {developer=true,mvtk=true,renderer=true}
    local root_dirs = list(root .. "/",{force_process=true})
    for _,name in ipairs(root_dirs or {}) do local_roots[name]=true end

    local function get(path)
        if originals[path] == nil then originals[path] = read(root .. "/" .. path) or false end
        return originals[path] ~= false and originals[path] or nil
    end

    local function patch(path, content)
        if path == "mvtk/boot/simple_host.go" then
            local doc = ResourceText.parse(content)
            for _, item in ipairs(ResourceText.all(doc.root, "components")) do
                if ResourceText.value(item.node, "id") == "editor_cp" then ResourceText.remove(doc,item) end
            end
            return ResourceText.render(doc)
        elseif path == "developer/ui/menus/boot_start_screen.gui" then
            local doc = ResourceText.parse(content)
            ResourceText.replace(doc, assert(ResourceText.one(doc.root,"script")), "/mvtk/boot/standalone_start_screen.gui_script")
            return ResourceText.render(doc)
        elseif path == "mvtk/core/build_deps.lua" then
            -- The runtime dependency manifest also contains development-only
            -- requires. Keep its runtime section and closing block.
            local first = assert(content:find("    -- Editor & tools", 1, true), "Missing authoring dependency section")
            return content:sub(1,first-1) .. "end\n\nreturn true\n"
        elseif path == "mvtk/core/config_validator.lua" then
            -- The importer registry is an authoring-only optional descriptor.
            -- Runtime validation must not load its filesystem helpers/artwork.
            local lines = {}
            for line in (content .. "\n"):gmatch("([^\n]*)\n") do
                if not line:find('path = "developer.config.tileset_mapping"',1,true) then lines[#lines+1]=line end
            end
            return table.concat(lines,"\n")
        elseif path == "developer/rooms/factories/factory_holder.go" then
            local doc = ResourceText.parse(content)
            for _, item in ipairs(ResourceText.all(doc.root,"components")) do
                local id = (ResourceText.value(item.node,"id") or ""):match("^room_factory_(.+)$")
                if id and not room_ids[id] then ResourceText.remove(doc,item) end
            end
            return ResourceText.render(doc)
        elseif path == "developer/config/rooms_config.lua" then
            local chunk = assert((loadstring or load)(content,"@export_rooms_config"))
            if setfenv then setfenv(chunk,{}) end
            local config = chunk()
            assert(type(config)=="table" and type(config.factories)=="table", "Invalid generated rooms_config")
            for key in pairs(config.factories) do
                local id = key:match("([^/]+)$")
                if not room_ids[id] then config.factories[key] = nil end
            end
            return "-- Published room factories; generated by Export Game.\nreturn "
                .. require("mvtk.core.creator_settings_model").encode(config) .. "\n"
        end
        return content
    end

    local function add(path, reason, required, custom)
        path = safe_path(path)
        if path == "developer/config/tileset_mapping.lua" then
            assert(not required, "Runtime references the authoring-only tileset importer: " .. reason)
            return
        end
        if authoring_only[path] then
            assert(not required, "Runtime references an authoring-only resource: " .. path .. " (" .. reason .. ")")
            return
        end
        if custom then raw[path] = true end
        if entries[path] then return end
        local content = get(path)
        if not content then
            assert(not required, "Missing export dependency: " .. path .. " (" .. reason .. ")")
            return
        end
        entries[path] = {path=path, content=patch(path,content), reason=reason}
        ordered[#ordered+1] = entries[path]
    end

    local function walk(path, accept, custom, required, scope)
        path = safe_path(path)
        if get(path) then
            if not accept or accept(path) then add(path,"declared resource",required,custom) end
            return
        end
        local seen_key = (scope or "resources") .. ":" .. path
        if seen_dirs[seen_key] then return end
        seen_dirs[seen_key] = true
        local dirs, files = list(root .. "/" .. path, {force_process=true})
        inventories[path] = M.directory_signature(dirs,files)
        assert(not required or dirs or files, "Cannot list declared export resources: " .. path)
        for _, file in ipairs(files or {}) do
            local child = safe_path(path .. "/" .. file)
            local accepted = not accept or accept(child)
            if accepted and not source_only(child) then add(child,"declared resource",true,custom) end
        end
        for _, dir in ipairs(dirs or {}) do
            if dir:sub(1,1) ~= "." and dir ~= "__pycache__" then walk(path .. "/" .. dir,accept,custom,false,scope) end
        end
    end

    local function source_resource(path)
        local ext = extension(path)
        if ext and ext:sub(-1) == "c" then
            local source_ext = ext:sub(1,-2)
            if proto_extensions[source_ext] or text_extensions[source_ext] then path = path:sub(1,-2) end
        end
        return path
    end
    for key,value in pairs(settings) do
        if key ~= "project.custom_resources" and key ~= "project.bundle_resources"
            and value:sub(1,1) == "/" and extension(value) then
            local path = source_resource(value):gsub("^/", "")
            if not path:match("^builtins/") then add(path,"game.project " .. key,true) end
        end
    end
    for path in (settings["project.custom_resources"] or ""):gmatch("[^,]+") do
        path = safe_path(path:match("^%s*(.-)%s*$"))
        -- Toolkit defaults are expanded selectively below. Other explicit
        -- custom resources retain their creator-declared contents.
        if path ~= "developer/tools" and path ~= "developer/runtime" and path ~= "developer/config"
            and path ~= "developer/rooms/generated" and path ~= "developer/assets/tiled/maps"
            and path ~= "developer/assets/minimap"
            and path ~= "developer/rooms/my_first_room.lua" then
            walk(path,nil,true,true)
        end
    end
    local bundle_roots = {}
    for path in (settings["project.bundle_resources"] or ""):gmatch("[^,]+") do
        path = safe_path(path:match("^%s*(.-)%s*$"))
        bundle_roots[#bundle_roots+1] = path
        local skipped = {}
        walk(path,function(child)
            if bundle_file(child,path) then return true end
            skipped[#skipped+1] = child == path and child:match("[^/]+$") or child:sub(#path+2)
            return false
        end,false,false,"bundle:" .. path)
        if #skipped > 0 then
            table.sort(skipped)
            warnings[#warnings+1] = string.format("%d file(s) in /%s are not inside a platform folder (common/, win32/, ...) and Defold will not bundle them: %s",
                #skipped,path,table.concat(skipped,", "))
        end
    end
    add("developer/assets/minimap/layout_map.lua","minimap metadata (sys.load_resource)",true,true)
    local layout_path = get("developer/runtime/layout/world_layout.local.lua") and "developer/runtime/layout/world_layout.local.lua"
        or "developer/runtime/layout/world_layout.lua"
    assert(get(layout_path) == opts.layout_text,
        "Published world changed during export. Retry Export Game.")
    add(layout_path,"published world",true,true)
    entries[layout_path].content = assert(opts.layout_text)
    add("developer/runtime/layout/world_layout.lua","canonical published world",true,true)
    entries["developer/runtime/layout/world_layout.lua"].content = opts.layout_text

    local runtime_module_paths = {}
    local room_paths = configured_stream_paths(get,function(path)
        runtime_module_paths[path] = true
        add(path,"stream path configuration",true)
    end)
    for id in pairs(room_ids) do
        local map, geometry, backgrounds = room_paths(id)
        add(map,"published room data",true,true)
        add(geometry,"published room geometry",true,true)
        add(backgrounds,"room backgrounds",false,true)
    end

    local function visit(value,strict,from)
        if value:sub(1,2) == "./" then value=value:sub(2) end
        if value:sub(1,1) == "/" and extension(value) and not value:find("[<>%%#]") then
            local path = source_resource(value):sub(2)
            if path:match("^builtins/") then return end
            -- Dependency namespaces are resolved by Defold Fetch Libraries.
            local local_root = path:match("^([^/]+)/")
            local local_path = local_roots[local_root] or not local_root
            if get(path) or local_path then add(path,"referenced by " .. from,strict and local_path) end
        elseif value:match("^[%a_][%w_]*%.[%w_.]+$") and not value:match("%.$") then
            local path = value:gsub("%.","/") .. ".lua"
            local local_path = local_roots[path:match("^([^/]+)/")]
            local content = get(path)
            if content then runtime_module_paths[path] = true end
            if content or (strict and local_path) then add(path,"module used by " .. from,strict and local_path) end
        end
    end
    local index = 1
    while ordered[index] do
        local entry = ordered[index]
        local ext = extension(entry.path)
        local function accept(value,strict,first)
            visit(value,strict,entry.path)
            if first and value:sub(1,1)=="/" then
                local prefix = entry.content:sub(math.max(1,first-100),first-1)
                if prefix:match("sys%.load_resource%s*%(?%s*$") or prefix:match("sys%.load_resource%s*,%s*$") then
                    local path=source_resource(value):sub(2)
                    if entries[path] then raw[path]=true end
                end
            end
        end
        if ext == "tilemap" then tilemap_strings(entry.content,accept)
        elseif proto_extensions[ext] then proto_strings(entry.content,accept)
        elseif ext == "lua" or ext == "script" or ext == "gui_script" or ext == "render_script" then lua_strings(entry.content,accept)
        elseif text_extensions[ext] then
            local scan = entry.content
            if ext=="vp" or ext=="fp" or ext=="glsl" then scan=shader_source(scan) end
            for value in scan:gmatch('["\']([^"\'\r\n]+)["\']') do accept(value,false) end
            if ext=="vp" or ext=="fp" or ext=="glsl" then
                for include in scan:gmatch('#include%s+["<]([^">]+)[">]') do
                    if include:sub(1,1)=="/" then
                        visit(include,true,entry.path)
                    else
                        local parts={}
                        local relative=(entry.path:match("^(.*)/") or "") .. "/" .. include
                        for part in relative:gmatch("[^/]+") do
                            if part==".." then assert(#parts>0,"Shader include escapes the project"); table.remove(parts)
                            elseif part~="." then parts[#parts+1]=part end
                        end
                        add(table.concat(parts,"/"),"shader include in " .. entry.path,true)
                    end
                end
            end
        end
        index = index + 1
    end
    -- Bob does not reliably discover optional/indirect module imports. Seed
    -- literal requires for selected code modules in the existing unreachable
    -- runtime dependency manifest, so archived builds match loose-file tests.
    local build_deps = entries["mvtk/core/build_deps.lua"]
    if build_deps then
        local modules = {}
        for path in pairs(entries) do
            if path:match("%.lua$") and path ~= build_deps.path
                and (runtime_module_paths[path] or path:match("^mvtk/") or path:match("^developer/config/")
                    or path:match("^developer/tools/") or path:match("^developer/game/") or path:match("^developer/ui/")) then
                modules[#modules+1] = path:gsub("%.lua$",""):gsub("/",".")
            end
        end
        table.sort(modules)
        local requires = {}
        for _,module in ipairs(modules) do requires[#requires+1] = string.format("    require(%q)",module) end
        build_deps.content = build_deps.content:gsub("end\n\nreturn true\n$",function()
            return table.concat(requires,"\n") .. "\nend\n\nreturn true\n"
        end,1)
    end
    -- Raw Lua config/module fallbacks and text geometry are essential even
    -- when Bob does not discover their indirect runtime loads.
    for path in pairs(entries) do
        if path:match("^developer/config/.*%.lua$") or path:match("^developer/runtime/.*%.lua$")
            or path:match("^developer/rooms/generated/.*%.lua$")
            or extension(path)=="tilesource" or extension(path)=="particlefx" then raw[path] = true end
    end
    local custom = {}
    for path in pairs(raw) do if entries[path] then custom[#custom+1] = "/" .. path end end
    table.sort(custom)
    table.sort(ordered,function(a,b) return a.path < b.path end)
    local adjusted = opts.prepare_project and opts.prepare_project(project) or project
    local bundles = {}
    for _,base in ipairs(bundle_roots) do
        for path in pairs(entries) do
            if path:sub(1,#base+1) == base .. "/" and bundle_file(path,base) then bundles[#bundles+1]="/" .. base; break end
        end
    end
    adjusted = set_resource_list(adjusted,"custom_resources",custom)
    if settings["project.bundle_resources"] then adjusted=set_resource_list(adjusted,"bundle_resources",bundles) end
    ordered[#ordered+1] = {path="game.project",content=adjusted,reason="standalone project settings"}
    originals["game.project"] = project
    return {files=ordered, originals=originals, inventories=inventories,
        custom_resources=custom, bundle_resources=bundles, warnings=warnings, room_count=#(published.rooms or {})}
end

return M
