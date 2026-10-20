-- hooks/core/filesystem.lua
--
-- Filesystem, shell, copy, and serialization helpers used by the editor hook
-- chunks. The module is configured by hooks/editor_core.lua after the project
-- root, editor API, and optional LuaFileSystem dependency have been resolved.

local path_utils = require("mvtk.editor.path_utils")
local file_utils = require("mvtk.editor.file_utils")

local M = {}
local Stats = require "hooks.core.io_stats"

local config = {
    root = ".",
    editor_api = nil,
    headless = true,
    info = function() end,
    profiler = nil,
    lfs_ok = false,
    lfs = nil,
}

local ensured_dirs = {}
local resource_write_batch = nil
local tilemap_staging
local info
local profiler_start
local profiler_stop

function M.configure(deps)
    deps = deps or {}
    for key, value in pairs(deps) do
        config[key] = value
    end
    ensured_dirs = {}
    resource_write_batch = nil
    tilemap_staging=nil
    file_utils.set_pending_reader(function(path)
        if tilemap_staging and tilemap_staging[path] then return tilemap_staging[path] end
        local entry=resource_write_batch and resource_write_batch.by_path[path]
        return entry and entry.text
    end)
end

function M.clear_ensure_dir_cache()
    ensured_dirs = {}
end

-- Regeneration restores cabin tiles which collection baking then extracts.
-- Keep that intermediate state readable without writing it to disk twice.
function M.begin_tilemap_staging() tilemap_staging=tilemap_staging or {} end
function M.cancel_tilemap_staging() tilemap_staging=nil end
function M.flush_tilemap_staging()
    local staged=tilemap_staging;tilemap_staging=nil
    local paths={};for path in pairs(staged or {}) do paths[#paths+1]=path end;table.sort(paths)
    for _,path in ipairs(paths) do M.write_if_changed(path,staged[path]) end
end

function M.begin_resource_write_batch()
    local editor_api = config.editor_api
    if config.headless or not (editor_api and type(editor_api.create_resources) == "function") then
        resource_write_batch = nil
        return false
    end
    local text=file_utils.read_disk(path_utils.join(config.root,"developer/config/editor_performance.lua"))
    local settings={}
    if text then
        local chunk=assert((loadstring or load)(text,"@editor_performance.lua"))
        settings=chunk()
    end
    local platform=editor_api.platform
    local windows=type(platform)=="string" and platform:match("%-win32$")
        or (platform==nil and path_utils.DIR_SEP=="\\")
    resource_write_batch = { order = {}, by_path = {},
        existing=windows and settings.batch_existing_writes~=false,
        threshold=math.max(1,tonumber(settings.existing_write_threshold) or 8) }
    return true
end

function M.cancel_resource_write_batch()
    resource_write_batch = nil
    M.cancel_tilemap_staging()
end

function M.flush_resource_write_batch()
    local batch = resource_write_batch
    if not batch or #batch.order == 0 then return 0 end

    profiler_start("flush_resource_write_batch")
    -- Keep batching active for later phases while this snapshot is committed.
    resource_write_batch = nil
    local resources,existing = {},{}
    for _, entry in ipairs(batch.order) do
        if entry.existing then
            if file_utils.read_disk(entry.fs_path)~=entry.text then existing[#existing+1]=entry
            else Stats.add("unchanged") end
        else
            Stats.observe(entry.fs_path,entry.text)
            resources[#resources + 1] = { entry.resource_path, entry.text }
        end
    end
    local started=os.clock()
    if #existing>=batch.threshold and type(config.editor_api.execute)=="function" then
        local ok,err=pcall(require("hooks.core.write_bundle").apply,config.root,existing,
            {ensure_dir=M.ensure_dir,execute=config.editor_api.execute,stats=Stats,info=info})
        Stats.add("write_seconds",os.clock()-started)
        if not ok then info("[WRITE_BATCH] Helper unavailable; using ordinary writes: "..tostring(err)) end
        for _,entry in ipairs(existing) do
            if file_utils.read_disk(entry.fs_path)==entry.text then
                Stats.observe(entry.fs_path,entry.text)
                Stats.written(entry.fs_path,true,os.clock());Stats.add("rewritten_batched")
            else M.write_if_changed(entry.fs_path,entry.text) end
        end
    else
        for _,entry in ipairs(existing) do M.write_if_changed(entry.fs_path,entry.text) end
    end
    if #resources>0 then
        Stats.add("create_resources")
        started=os.clock()
        local ok, err = pcall(config.editor_api.create_resources, resources)
        Stats.add("write_seconds",os.clock()-started)
        if ok then Stats.add("created_batched",#resources) end
        if not ok then
            resource_write_batch = nil
            profiler_stop("flush_resource_write_batch")
            error("batched generated-resource creation failed: " .. tostring(err), 0)
        end
    end
    resource_write_batch={order={},by_path={},existing=batch.existing,threshold=batch.threshold}
    profiler_stop("flush_resource_write_batch")
    info(string.format(
        "[WRITE_BATCH] Committed %d existing and %d new generated resource(s).",
        #existing,#resources
    ))
    return #resources+#existing
end

function M.end_resource_write_batch()
    M.flush_tilemap_staging()
    local count = M.flush_resource_write_batch()
    resource_write_batch = nil
    return count
end

info = function(msg)
    return (config.info or function() end)(msg)
end

profiler_start = function(label)
    local profiler = config.profiler
    if profiler and profiler.start then
        profiler.start(label)
    end
end

profiler_stop = function(label)
    local profiler = config.profiler
    if profiler and profiler.stop then
        profiler.stop(label)
    end
end

local function root()
    return path_utils.normalize(config.root or path_utils.get_root() or ".")
end

local normalize = path_utils.normalize
local join = path_utils.join
local to_os_path = path_utils.to_os_path
local is_absolute_path = path_utils.is_absolute_path
local to_project_fs_path = path_utils.to_project_fs_path
local to_project_resource_path = path_utils.to_project_resource_path
local path_dirname = path_utils.dirname
local path_basename = path_utils.basename
local DIR_SEP = path_utils.DIR_SEP
local unpack_values = table.unpack or unpack

local run_shell_command_with_exit_code
local run_process

local function lfs_available()
    return config.lfs_ok and config.lfs
end

local ensure_dir

ensure_dir = function(path, force_probe)
    if not path or path == "" then
        return not config.headless
    end

    local ROOT = root()
    path = normalize(path)

    -- Normalize relative paths to be under ROOT so the prefix check works
    -- regardless of whether ROOT is absolute or relative.
    if path:sub(1, 2) == "./" then
        if ROOT ~= "." then
            path = normalize(ROOT .. "/" .. path:sub(3))
        end
    elseif not path:match("^[A-Za-z]:") and path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "." then
        if ROOT ~= "." then
            path = normalize(ROOT .. "/" .. path)
        end
    end

    if not force_probe and ensured_dirs[path] then
        return true
    end

    -- Never try to create directories above the project root.
    if ROOT and normalize(ROOT) == path then
        ensured_dirs[path] = true
        return true
    end
    local norm_root = normalize(ROOT or "")
    if norm_root ~= "" and norm_root ~= "." and path:sub(1, #norm_root) ~= norm_root then
        return false
    end

    local lfs = lfs_available()
    if lfs and lfs.attributes then
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            ensured_dirs[path] = true
            return true
        end
    end

    local parent_dir = path:match("^(.*)[/\\][^/\\]+$")
    local is_root = (parent_dir == "/" or (parent_dir and parent_dir:match("^[A-Z]:$")))
    if parent_dir and parent_dir ~= "" and parent_dir ~= path and not is_root then
        ensure_dir(parent_dir)
    end

    if lfs and lfs.mkdir then
        local ok = lfs.mkdir(path)
        if ok then
            ensured_dirs[path] = true
            return true
        end
    end

    local mkdir_cmd
    if DIR_SEP == "\\" then
        mkdir_cmd = 'cmd /c mkdir "' .. to_os_path(path) .. '" 2>nul'
    else
        mkdir_cmd = 'mkdir -p "' .. path .. '" 2>/dev/null'
    end
    if os and os.execute and type(os.execute) == "function" then
        local result = os.execute(mkdir_cmd)
        if result == 0 or result == true then
            ensured_dirs[path] = true
            return true
        end
    end

    if io and io.popen then
        local ok_p, proc = pcall(io.popen, mkdir_cmd, "r")
        if ok_p and proc then
            proc:read("*a")
            proc:close()
        end
        if lfs and lfs.attributes then
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                ensured_dirs[path] = true
                return true
            end
        end
        if DIR_SEP == "\\" then
            local ok_c, check = pcall(io.popen, string.format('cmd /c if exist "%s" (echo 1) else (echo 0)', to_os_path(path)), "r")
            if ok_c and check then
                local line = check:read("*l")
                check:close()
                if line == "1" then
                    ensured_dirs[path] = true
                    return true
                end
            end
        end
    end

    local editor_api = config.editor_api
    if not config.headless and editor_api and editor_api.create_directory then
        local rel = path
        if ROOT and path:sub(1, #ROOT) == ROOT then
            rel = path:sub(#ROOT + 1)
        end
        rel = normalize(rel)
        if rel:sub(1, 1) ~= "/" then
            rel = "/" .. rel
        end
        Stats.add("create_directory")
        local ok = pcall(editor_api.create_directory, rel)
        if ok then
            ensured_dirs[path] = true
            return true
        end
    end

    return config.headless
end

local function open_output_file(fs_path)
    -- Most generated parent directories already exist. Opening first avoids
    -- hundreds of blocking `cmd mkdir` calls when LuaFileSystem is unavailable
    -- in Defold's editor-script runtime.
    local fh, err = io.open(fs_path, "wb")
    local dir = fs_path:match("^(.*)[/\\][^/\\]+$")
    if fh then
        if dir then ensured_dirs[normalize(dir)] = true end
        return fh
    end

    if dir then
        ensured_dirs[normalize(dir)] = nil
        ensure_dir(dir, true)
    end
    fh, err = io.open(fs_path, "wb")
    assert(fh, err)
    if dir then ensured_dirs[normalize(dir)] = true end
    return fh
end

-- Spine validation needs a complete disk snapshot, including files the editor
-- has not imported yet. Ordinary resource listings keep their existing fast
-- behavior; a scan shares this options table and launches one checked process.
local function spine_directory_inventory(opts)
    local scan_root = normalize(assert(opts.spine_scan_root)):gsub("/$", "")
    assert(scan_root ~= "" and not scan_root:find("[%c]"), "Invalid Spine scan root")
    local editor_api = not config.headless and config.editor_api
    if editor_api then
        assert(type(editor_api.external_file_attributes) == "function",
            "Spine scan requires editor.external_file_attributes")
        local attrs = editor_api.external_file_attributes(scan_root)
        assert(attrs.exists and attrs.is_directory, "Cannot enumerate Spine directory: " .. scan_root)
    end
    local command, args
    if DIR_SEP == "\\" then
        if not editor_api then
            -- The desktop process fallback passes through cmd; refuse its
            -- expansion characters rather than changing the requested path.
            assert(not scan_root:find('["%%!]') and not root():find('["%%!]'),
                "Unsupported shell character in Spine scan path")
        end
        command = "powershell"
        args = {"-NoProfile", "-NonInteractive", "-File",
            to_os_path(join(root(), "hooks/core/spine_scan.ps1")), "-Root", to_os_path(scan_root)}
        if editor_api then args[#args+1] = "-Utf8" end
    else
        command = "find"
        local Spine = require "mvtk.editor.spine_addon"
        args = {scan_root, "(", "!", "-regex", Spine.find_literal(scan_root), "(",
            "-name", ".*", "-o", "-name", "__pycache__"}
        local function prune(path)
            args[#args+1] = "-o"; args[#args+1] = "-regex"; args[#args+1] = path
        end
        for _, path in ipairs({"test", "tests", "build", "dist", "export", "developer/addons/spine"}) do
            prune(Spine.find_literal(scan_root .. "/" .. path))
        end
        local ignore, err = require("mvtk.editor.project_transaction").read(scan_root .. "/.defignore")
        assert(ignore ~= nil or err == nil, "Cannot read .defignore: " .. tostring(err))
        for _, pattern in ipairs(Spine.ignore_find_patterns(ignore,scan_root)) do prune(pattern) end
        for _, value in ipairs({")", ")", "-exec", "printf", "I\t%s\n", "{}", "+", "-prune", "-o", "-type", "d", "-exec", "printf", "D\t%s\n", "{}", "+",
            "-o", "-type", "f", "-exec", "printf", "F\t%s\n", "{}", "+",
            "-o", "-exec", "printf", "L\t%s\n", "{}", "+"}) do args[#args+1] = value end
    end
    local ok, _, output = run_process(command, args, {capture=true, reload_resources=false, err="stdout"})
    assert(ok and type(output) == "string", "Cannot enumerate Spine resources: " .. tostring(output))
    if DIR_SEP == "\\" then
        assert(output:match("MVTK_SPINE_SCAN_OK%s*$"), "Incomplete Spine resource inventory: " .. output)
        output = output:gsub("MVTK_SPINE_SCAN_OK%s*$", "")
    end
    local directories, seen, verified = {}, {}, {}
    local function directory(path)
        if not directories[path] then directories[path] = {dirs={}, files={}, omitted={}} end
        return directories[path]
    end
    for line in output:gmatch("[^\r\n]+") do
        local kind, path = line:match("^([DFI])\t(.*)$")
        assert(kind, "Cannot inspect Spine inventory entry: " .. line)
        if DIR_SEP ~= "\\" then
            assert(path == scan_root or path:sub(1,#scan_root+1) == scan_root .. "/",
                "Spine inventory path is outside its root: " .. path)
            path = path == scan_root and "" or path:sub(#scan_root+2)
        end
        assert(not path:find("[\\%c]") and not path:match("^/") and not path:match("/$"),
            "Invalid Spine inventory path: " .. path)
        for part in path:gmatch("[^/]+") do
            assert(part ~= "." and part ~= "..", "Invalid Spine inventory path: " .. path)
        end
        assert(not path:find("//",1,true) and not seen[path], "Duplicate Spine inventory path: " .. path)
        seen[path] = true
        if editor_api and kind ~= "I" then
            local absolute = scan_root .. (path ~= "" and "/" .. path or "")
            local attrs = editor_api.external_file_attributes(absolute)
            assert(attrs.exists and ((kind == "D" and attrs.is_directory) or (kind == "F" and attrs.is_file)),
                "Cannot classify Spine resource: " .. path)
        end
        if path ~= "" then
            local parent, name = path:match("^(.*)/([^/]+)$")
            if not parent then parent, name = "", path end
            local entry = directory(parent)
            local target = kind == "D" and entry.dirs or (kind == "I" and entry.omitted or entry.files)
            target[#target+1] = name
        end
        if kind == "D" then directory(path); verified[path] = true end
    end
    assert(verified[""], "Spine inventory is missing its root directory")
    for path, entry in pairs(directories) do
        assert(verified[path], "Incomplete Spine directory inventory: " .. path)
        table.sort(entry.dirs); table.sort(entry.files); table.sort(entry.omitted)
    end
    return {root=scan_root, directories=directories}
end

local function list_dir_filesystem(abs_dir, opts)
    opts = opts or {}
    if opts.spine_scan_root then
        if not opts.spine_inventory then opts.spine_inventory = spine_directory_inventory(opts) end
        local inventory = opts.spine_inventory
        local path = normalize(abs_dir):gsub("/$", "")
        assert(path == inventory.root or path:sub(1,#inventory.root+1) == inventory.root .. "/",
            "Spine directory is outside the scan root: " .. path)
        local relative = path == inventory.root and "" or path:sub(#inventory.root+2)
        local entry = assert(inventory.directories[relative], "Missing Spine directory inventory: " .. path)
        return entry.dirs, entry.files, entry.omitted
    end
    local dirs = {}
    local files = {}
    local editor_api = config.editor_api
    local lfs = lfs_available()

    local resource_dir = to_project_resource_path(abs_dir)
    local can_get_ok, can_get_result = pcall(function()
        return not opts.force_process
            and editor_api and editor_api.can_get and resource_dir
            and editor_api.can_get(resource_dir, "children")
    end)
    if can_get_ok and can_get_result then
        local ok, children = pcall(editor_api.get, resource_dir, "children")
        if ok and children then
            for _, child_path in ipairs(children) do
                if type(child_path) == "string" and child_path ~= "" then
                    local entry = child_path:match("([^/]+)$")
                    if entry and entry ~= "." and entry ~= ".." then
                        local is_fs_dir = false
                        if lfs and lfs.attributes then
                            local fs_path = to_os_path(to_project_fs_path(child_path))
                            is_fs_dir = (lfs.attributes(fs_path, "mode") == "directory")
                        elseif not entry:match("%.[^%.]+$") then
                            is_fs_dir = true
                        end
                        if is_fs_dir then
                            dirs[#dirs + 1] = entry
                        else
                            files[#files + 1] = entry
                        end
                    end
                end
            end
        end
    end

    abs_dir = to_os_path(abs_dir)

    if not opts.force_process and #dirs == 0 and #files == 0
        and lfs and lfs.attributes and lfs.dir
    then
        local mode = lfs.attributes(abs_dir, "mode")
        if mode == "directory" then
            for entry in lfs.dir(abs_dir) do
                if entry ~= "." and entry ~= ".." then
                    local full = abs_dir .. DIR_SEP .. entry
                    local emode = lfs.attributes(full, "mode")
                    if emode == "directory" then
                        dirs[#dirs + 1] = entry
                    elseif emode == "file" then
                        files[#files + 1] = entry
                    end
                end
            end
        end
    end

    -- Process listing is a last resort: run it only when neither the editor
    -- resource API nor lfs surfaced anything. Keep arguments separate so
    -- creator-controlled paths never pass through shell interpolation.
    if #dirs == 0 and #files == 0 and run_process then
        local function append_lines(output, target, take_basename)
            for line in tostring(output or ""):gmatch("[^\r\n]+") do
                if line ~= "" and line ~= "." and line ~= ".." then
                    target[#target + 1] = take_basename and path_basename(normalize(line)) or line
                end
            end
        end

        if DIR_SEP == "\\" then
            local win_dir = to_os_path(abs_dir):gsub('"', '""')
            local ok_dirs, _, dir_output = run_process(
                "cmd",
                { "/d", "/s", "/c", 'dir /b /ad "' .. win_dir .. '"' },
                { capture = true, reload_resources = false }
            )
            if ok_dirs then append_lines(dir_output, dirs, false) end
            local ok_files, _, file_output = run_process(
                "cmd",
                { "/d", "/s", "/c", 'dir /b /a-d "' .. win_dir .. '"' },
                { capture = true, reload_resources = false }
            )
            if ok_files then append_lines(file_output, files, false) end
        else
            -- `<dir>/. ! -name . -prune ...` is POSIX find syntax and avoids
            -- GNU-only depth and formatted-output extensions.
            local search_root = normalize(abs_dir) .. "/."
            local common = { search_root, "!", "-name", ".", "-prune", "-type" }
            local dir_args = {}
            for _, value in ipairs(common) do dir_args[#dir_args + 1] = value end
            dir_args[#dir_args + 1] = "d"
            dir_args[#dir_args + 1] = "-print"
            local ok_dirs, _, dir_output = run_process(
                "find", dir_args, { capture = true, reload_resources = false }
            )
            if ok_dirs then append_lines(dir_output, dirs, true) end

            local file_args = {}
            for _, value in ipairs(common) do file_args[#file_args + 1] = value end
            file_args[#file_args + 1] = "f"
            file_args[#file_args + 1] = "-print"
            local ok_files, _, file_output = run_process(
                "find", file_args, { capture = true, reload_resources = false }
            )
            if ok_files then append_lines(file_output, files, true) end
        end
    end

    if #dirs == 0 and #files == 0 then
        return nil
    end

    -- Defense in depth: no matter which discovery strategy ran, never hand a
    -- caller the same entry twice. Duplicate names otherwise read as spurious
    -- filename collisions in downstream tools (e.g. Sync Music).
    local function dedupe(list)
        local seen = {}
        local out = {}
        for _, entry in ipairs(list) do
            if not seen[entry] then
                seen[entry] = true
                out[#out + 1] = entry
            end
        end
        return out
    end

    return dedupe(dirs), dedupe(files)
end

local function copy_file_basic(src_path, dest_file_path)
    src_path = normalize(src_path)

    if not is_absolute_path(src_path) then
        src_path = join(root(), src_path)
    end

    local export_base = root() .. "/export"
    local dest_full_path = normalize(join(export_base, dest_file_path))

    local src_fh = io.open(src_path, "rb")
    if not src_fh then
        info("[EXPORT] WARNING: missing source file: " .. tostring(src_path) .. " (dest: " .. tostring(dest_file_path) .. ")")
        return false
    end
    local data = src_fh:read("*a")
    src_fh:close()

    local dest_dir = dest_full_path:match("^(.*)[/\\][^/\\]+$")
    if dest_dir then
        ensure_dir(dest_dir)
    end

    local dest_fh = io.open(dest_full_path, "wb")
    if not dest_fh then
        return false
    end
    dest_fh:write(data)
    dest_fh:close()

    return true
end

local function command_succeeded(a, b, c, max_success_code)
    max_success_code = max_success_code or 0

    local function code_ok(code)
        return type(code) == "number" and code >= 0 and code <= max_success_code
    end

    if type(a) == "number" then
        return code_ok(a)
    end

    if type(a) == "boolean" then
        if type(c) == "number" then
            return a and code_ok(c)
        end
        return a
    end

    if a == nil and type(c) == "number" then
        return code_ok(c)
    end

    return false
end

local function posix_shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function windows_shell_quote(value)
    local text = tostring(value or "")
    text = text:gsub("%%", "%%%%")
    text = text:gsub('"', '\\"')
    return '"' .. text .. '"'
end

local function build_process_command(command, args, separator)
    local quote = separator == "\\" and windows_shell_quote or posix_shell_quote
    local parts = { quote(command) }
    for _, arg in ipairs(args or {}) do
        parts[#parts + 1] = quote(arg)
    end
    return table.concat(parts, " ")
end

local function editor_execute_process(command, args, opts)
    local editor_api = config.editor_api
    if config.headless or not (editor_api and type(editor_api.execute) == "function") then
        return nil
    end

    opts = opts or {}
    local call_args = { command }
    for _, arg in ipairs(args or {}) do
        call_args[#call_args + 1] = tostring(arg)
    end
    call_args[#call_args + 1] = {
        reload_resources = opts.reload_resources == true,
        out = opts.capture and "capture" or (opts.out or "discard"),
        err = opts.err or "discard",
    }

    local result
    local ok, err = pcall(function()
        if call_args[#call_args].reload_resources then Stats.add("reloading_executes") end
        result = editor_api.execute(unpack_values(call_args))
    end)
    if ok then
        return true, 0, result or ""
    end
    return false, nil, tostring(err)
end

run_shell_command_with_exit_code = function(cmd, max_success_code)
    max_success_code = max_success_code or 0
    local sentinel = "__MVTK_EXIT__"

    local editor_api = config.editor_api
    if not config.headless and editor_api and type(editor_api.execute) == "function" then
        if DIR_SEP == "\\" then
            local script_path = normalize(join(root(), "hooks", ".mvtk_shell.cmd"))
            local fh = io.open(script_path, "w")
            if fh then
                if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
                fh:write("@echo off\r\n")
                fh:write(cmd .. "\r\n")
                fh:write("echo " .. sentinel .. "%ERRORLEVEL%\r\n")
                fh:close()
                local ok, _, output = editor_execute_process(
                    "cmd",
                    { "/q", "/d", "/c", to_os_path(script_path) },
                    { capture = true, reload_resources = false, err = "stdout" }
                )
                if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
                pcall(os.remove, script_path)
                if ok then
                    local exit_code = tostring(output or ""):match(sentinel .. "(%-?%d+)%s*$")
                    if exit_code then
                        exit_code = tonumber(exit_code)
                        return exit_code <= max_success_code, exit_code, output
                    end
                end
            end
        else
            local wrapped_script = cmd
                .. '; __mvtk_code=$?; printf "\\n' .. sentinel .. '%s\\n" "$__mvtk_code"; exit 0'
            local ok, _, output = editor_execute_process(
                "sh",
                { "-c", wrapped_script },
                { capture = true, reload_resources = false, err = "stdout" }
            )
            if ok then
                local exit_code = tostring(output or ""):match(sentinel .. "(%-?%d+)%s*$")
                if exit_code then
                    exit_code = tonumber(exit_code)
                    return exit_code <= max_success_code, exit_code, output
                end
            end
        end
    end

    if io and io.popen then
        if DIR_SEP == "\\" then
            local script_path = normalize(join(root(), "hooks", ".mvtk_shell.cmd"))
            local fh = io.open(script_path, "w")
            if fh then
                fh:write("@echo off\r\n")
                fh:write(cmd .. "\r\n")
                fh:write("echo " .. sentinel .. "%ERRORLEVEL%\r\n")
                fh:close()
            end

            local wrapped_cmd = 'cmd /q /c "' .. to_os_path(script_path):gsub('"', '""') .. '"'
            local ok_p, proc = pcall(io.popen, wrapped_cmd, "r")
            if ok_p and proc then
                local output = proc:read("*a") or ""
                proc:close()
                if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
                pcall(os.remove, script_path)
                local exit_code = output:match(sentinel .. "(%-?%d+)%s*$")
                if exit_code then
                    return tonumber(exit_code) <= max_success_code, tonumber(exit_code), output
                end
            else
                if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
                pcall(os.remove, script_path)
            end
        else
            local wrapped_script = cmd
                .. '; __mvtk_code=$?; printf "\\n' .. sentinel .. '%s\\n" "$__mvtk_code"; exit 0'
            local wrapped_cmd = "sh -c " .. posix_shell_quote(wrapped_script)
            local ok_p, proc = pcall(io.popen, wrapped_cmd, "r")
            if ok_p and proc then
                local output = proc:read("*a") or ""
                proc:close()
                local exit_code = output:match(sentinel .. "(%-?%d+)%s*$")
                if exit_code then
                    exit_code = tonumber(exit_code)
                    return exit_code <= max_success_code, exit_code, output
                end
            end
        end
    end

    if os and os.execute and type(os.execute) == "function" then
        local a, b, c = os.execute(cmd)
        if command_succeeded(a, b, c, max_success_code) then
            return true, c or a, nil
        end
    end

    return false, nil, nil
end

run_process = function(command, args, opts)
    assert(type(command) == "string" and command ~= "", "run_process requires a command")
    opts = opts or {}

    local editor_ok, editor_code, editor_output = editor_execute_process(command, args, opts)
    if editor_ok ~= nil then
        return editor_ok, editor_code, editor_output
    end

    local shell_command
    if DIR_SEP == "\\" and command:lower():match("^cmd%.?e?x?e?$") and #(args or {}) > 0 then
        local prefix = {}
        for index = 1, #args - 1 do prefix[#prefix + 1] = tostring(args[index]) end
        -- cmd /s /c strips the outer quote pair. Preserve quotes inside the
        -- command: doubling them leaves paths containing spaces unprotected.
        local inner = tostring(args[#args])
        shell_command = "cmd " .. table.concat(prefix, " ") .. ' "' .. inner .. '"'
    else
        shell_command = build_process_command(command, args, DIR_SEP)
    end
    local ok, code, output = run_shell_command_with_exit_code(shell_command, opts.max_success_code or 0)
    -- The shell wrapper's status marker is protocol, not command output. In
    -- particular directory listings must never see it as a file or directory.
    if output then output = output:gsub("__MVTK_EXIT__%-?%d+%s*$", "") end
    return ok, code, output
end

local remove_path_filesystem

local function remove_empty_directory_filesystem(abs_path)
    abs_path = normalize(abs_path)
    if not abs_path or abs_path == "" then
        return false, "empty path"
    end

    local os_path = to_os_path(abs_path)
    local lfs = lfs_available()
    if lfs and type(lfs.rmdir) == "function" then
        local ok, removed, remove_error = pcall(lfs.rmdir, os_path)
        if ok and removed then return true end
        if os_path ~= abs_path then
            local ok_normalized, removed_normalized, normalized_error = pcall(lfs.rmdir, abs_path)
            if ok_normalized and removed_normalized then return true end
            remove_error = normalized_error or remove_error
        end
        return false, remove_error or "directory is not empty"
    end

    -- Lua implementations differ on whether os.remove accepts empty
    -- directories, but it remains a safe, non-recursive fallback.
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
    local ok, removed, remove_error = pcall(os.remove, os_path)
    if ok and removed then return true end
    if os_path ~= abs_path then
        if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
        local ok_normalized, removed_normalized, normalized_error = pcall(os.remove, abs_path)
        if ok_normalized and removed_normalized then return true end
        remove_error = normalized_error or remove_error
    end
    return false, remove_error or "directory is not empty"
end

remove_path_filesystem = function(abs_path)
    abs_path = normalize(abs_path)
    if not abs_path or abs_path == "" then
        return false
    end

    local os_path = to_os_path(abs_path)
    local lfs = lfs_available()

    if lfs and lfs.attributes then
        local mode = lfs.attributes(os_path, "mode") or lfs.attributes(abs_path, "mode")
        if mode == "file" then
            if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
            local ok_remove, removed = pcall(os.remove, os_path)
            if ok_remove and removed then
                return true
            end
            if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
            local ok_remove_norm, removed_norm = pcall(os.remove, abs_path)
            if ok_remove_norm and removed_norm then
                return true
            end
        elseif mode == "directory" then
            for entry in lfs.dir(os_path) do
                if entry ~= "." and entry ~= ".." then
                    remove_path_filesystem(join(abs_path, entry))
                end
            end
            local ok_rmdir, removed_dir = pcall(lfs.rmdir, os_path)
            if ok_rmdir and removed_dir then
                return true
            end
            if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
            local ok_remove_dir, removed_dir_norm = pcall(os.remove, abs_path)
            if ok_remove_dir and removed_dir_norm then
                return true
            end
        elseif mode == nil then
            return true
        end
    end

    if DIR_SEP == "\\" then
        local target = os_path:gsub('"', '""')
        local cmd = string.format('if exist "%s" (rmdir /s /q "%s" 2>nul || del /f /q "%s" 2>nul)', target, target, target)
        local ok = run_shell_command_with_exit_code(cmd, 0)
        return ok and true or false
    end

    local target = abs_path:gsub("'", "'\\''")
    local ok = run_shell_command_with_exit_code("rm -rf '" .. target .. "'", 0)
    return ok and true or false
end

local function try_bulk_copy_directory(src_dir, dst_dir, relative_dir, skip)
    if not file_utils.file_exists_any(src_dir) then
        info("[EXPORT] Skipping missing directory: " .. tostring(relative_dir))
        return false
    end

    ensure_dir(dst_dir)

    local skip_dirs = {}
    local relative_prefix = normalize(relative_dir or "")
    for skip_path in pairs(skip or {}) do
        local normalized_skip = normalize(skip_path)
        if relative_prefix == ""
            or normalized_skip == relative_prefix
            or normalized_skip:sub(1, #relative_prefix + 1) == relative_prefix .. "/" then
            skip_dirs[#skip_dirs + 1] = normalize(join(root(), normalized_skip))
        end
    end

    if DIR_SEP == "\\" then
        local src_os = to_os_path(src_dir):gsub('"', '""')
        local dst_os = to_os_path(dst_dir):gsub('"', '""')
        local cmd = {
            'robocopy "' .. src_os .. '" "' .. dst_os .. '"',
            "/E",
            "/R:0",
            "/W:0",
            "/MT:16",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS",
            "/NC",
            "/NS",
            "/NP",
            "/XJ",
        }
        if #skip_dirs > 0 then
            cmd[#cmd + 1] = "/XD"
            for _, skip_dir in ipairs(skip_dirs) do
                cmd[#cmd + 1] = '"' .. to_os_path(skip_dir):gsub('"', '""') .. '"'
            end
        end

        local ok = run_shell_command_with_exit_code(table.concat(cmd, " "), 7)
        if ok then
            return true
        end
    else
        local src_unix = src_dir:gsub("'", "'\\''")
        local dst_unix = dst_dir:gsub("'", "'\\''")
        local cmd = { "mkdir -p '" .. dst_unix .. "' && " }
        if #skip_dirs > 0 then
            cmd[#cmd + 1] = "rsync -a"
            for _, skip_dir in ipairs(skip_dirs) do
                local rel_skip = normalize(skip_dir):sub(#normalize(src_dir) + 1):gsub("^/", "")
                if rel_skip ~= "" then
                    cmd[#cmd + 1] = " --exclude='" .. rel_skip:gsub("'", "'\\''") .. "'"
                end
            end
            cmd[#cmd + 1] = " '" .. src_unix .. "/' '" .. dst_unix .. "/'"
        else
            cmd[#cmd + 1] = "cp -R '" .. src_unix .. "/.' '" .. dst_unix .. "/'"
        end

        local ok = run_shell_command_with_exit_code(table.concat(cmd), 0)
        if ok then
            return true
        end
    end

    return false
end

local function copy_directory_filesystem(relative_dir, opts)
    opts = opts or {}
    local skip = {}
    if opts.skip then
        for _, s in ipairs(opts.skip) do
            skip[normalize(s)] = true
        end
    end

    local function is_skipped(path)
        local norm = normalize(path)
        for s in pairs(skip) do
            if norm:sub(1, #s) == s then
                return true
            end
        end
        return false
    end

    local ROOT = root()
    local abs_dir = normalize(join(ROOT, relative_dir))
    local export_dir = normalize(join(ROOT, "export", relative_dir or ""))

    if try_bulk_copy_directory(abs_dir, export_dir, relative_dir, skip) then
        info("[EXPORT] Bulk copied directory: " .. tostring(relative_dir))
        return true
    end

    info("[EXPORT] Bulk copy unavailable, using recursive fallback: " .. tostring(relative_dir))

    if relative_dir and relative_dir ~= "" then
        ensure_dir(export_dir)
    else
        ensure_dir(normalize(ROOT .. "/export"))
    end

    local dirs, files = list_dir_filesystem(abs_dir)
    if not dirs and not files then
        info("[EXPORT] No files or directories found in: " .. tostring(relative_dir))
        return false
    end

    if files then
        for _, file in ipairs(files) do
            local rel_path = relative_dir .. "/" .. file
            if not is_skipped(rel_path) then
                copy_file_basic(join(abs_dir, file), rel_path)
            end
        end
    end

    if dirs then
        for _, dir in ipairs(dirs) do
            local rel_path = relative_dir .. "/" .. dir
            if not is_skipped(rel_path) then
                copy_directory_filesystem(rel_path, opts)
            end
        end
    end

    return true
end

local function write_if_changed(path, text)
    local fs_path = to_project_fs_path(path)
    if tilemap_staging and fs_path:match("/developer/assets/tiled/maps/[^/]+%.tilemap$") then
        local previous=file_utils.read_text(fs_path)
        tilemap_staging[fs_path]=text
        if previous==text then Stats.add("unchanged");return false end
        return true
    end
    profiler_start("write_if_changed (all calls)")
    local queued = resource_write_batch and resource_write_batch.by_path[fs_path]
    if queued then
        if queued.text == text then
            Stats.add("unchanged")
            profiler_stop("write_if_changed (all calls)")
            return false
        end
        queued.text = text
        profiler_stop("write_if_changed (all calls)")
        return true
    end

    local prev = file_utils.read_text(fs_path)
    if prev == text then
        Stats.add("unchanged")
        profiler_stop("write_if_changed (all calls)")
        return false
    end

    -- New generated resources are expensive when created one by one: every
    -- close can synchronize Defold's resource graph. Queue them for a single
    -- editor.create_resources() transaction instead. On Windows, existing
    -- developer resources share a verified helper batch at the final flush.
    if resource_write_batch and (prev == nil or resource_write_batch.existing) then
        local resource_path = to_project_resource_path(fs_path)
        if type(resource_path) == "string" and (prev==nil or resource_path:match("^/developer/")) then
            local entry = {
                fs_path = fs_path,
                resource_path = resource_path,
                text = text,
                existing = prev~=nil,
            }
            resource_write_batch.by_path[fs_path] = entry
            resource_write_batch.order[#resource_write_batch.order + 1] = entry
            profiler_stop("write_if_changed (all calls)")
            return true
        end
    end

    Stats.observe(fs_path,text)
    local started=os.clock()
    local fh = open_output_file(fs_path)
    fh:write(text)
    fh:close()
    Stats.written(fs_path,prev~=nil,started)
    profiler_stop("write_if_changed (all calls)")
    return true
end

local function write_binary_if_changed(path, data)
    local fs_path = to_project_fs_path(path)
    local prev = file_utils.read_text(fs_path)
    if prev == data then
        Stats.add("unchanged")
        return false
    end
    Stats.observe(fs_path,data)
    local started=os.clock()
    local fh = open_output_file(fs_path)
    fh:write(data)
    fh:close()
    Stats.written(fs_path,prev~=nil,started)
    return true
end

local function is_array(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true
end

local function serialize_value(value, indent, step)
    indent = indent or ""
    step = step or "    "
    local t = type(value)
    if t == "number" then
        return string.format("%.10g", value)
    elseif t == "boolean" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        local next_indent = indent .. step
        if is_array(value) then
            local parts = {}
            for i = 1, #value do
                parts[#parts + 1] = serialize_value(value[i], next_indent, step)
            end
            return "{ " .. table.concat(parts, ", ") .. " }"
        else
            local parts = { "{" }
            for k, v in pairs(value) do
                local key_repr
                if type(k) == "string" and k:match("^[_%a][_%w]*$") then
                    key_repr = k .. " = " .. serialize_value(v, next_indent, step)
                else
                    key_repr = "[" .. serialize_value(k, next_indent, step) .. "] = " .. serialize_value(v, next_indent, step)
                end
                parts[#parts + 1] = next_indent .. key_repr .. ","
            end
            parts[#parts + 1] = indent .. "}"
            return table.concat(parts, "\n")
        end
    else
        return "nil"
    end
end

local function write_layout_module(layout, target_path)
    local dir = target_path:match("^(.*)[/\\][^/\\]+$")
    if dir then ensure_dir(dir) end
    local content = "return " .. serialize_value(layout, "", "    ") .. "\n"
    if write_if_changed(target_path, content) then
        info("Wrote layout module to " .. target_path)
    else
        info("Layout module unchanged at " .. target_path)
    end
end

local function copy_file_any(src_path, dst_path)
    src_path = normalize(src_path or "")
    dst_path = normalize(dst_path or "")
    if src_path == "" or dst_path == "" then
        info("[COPY] empty src or dst: src=" .. tostring(src_path) .. " dst=" .. tostring(dst_path))
        return false
    end

    local dst_dir = path_dirname(dst_path)
    if dst_dir ~= "" then
        ensure_dir(dst_dir)
    end

    local src_data = file_utils.read_binary_any(src_path)
    if src_data ~= nil then
        write_binary_if_changed(dst_path, src_data)
        return true
    end

    if io and io.popen then
        local ROOT = root()
        local abs_dst = dst_path
        if not dst_path:match("^[A-Za-z]:") and not dst_path:match("^/") then
            if ROOT:match("^[A-Za-z]:") or ROOT:match("^/") then
                local rel = dst_path
                if rel:sub(1, 2) == "./" then rel = rel:sub(3) end
                abs_dst = ROOT .. "/" .. rel
            end
        end

        if abs_dst:match("^[A-Za-z]:") or abs_dst:match("^/") then
            if DIR_SEP == "\\" then
                local cmd = string.format('cmd /c copy /Y "%s" "%s"', to_os_path(src_path), to_os_path(abs_dst))
                info("[COPY] Trying io.popen copy: " .. cmd)
                local ok_p, p = pcall(io.popen, cmd, "r")
                if ok_p and p then
                    local output = p:read("*a") or ""
                    p:close()
                    if output:match("1 file") then
                        info("[COPY] Success via io.popen copy")
                        return true
                    end
                end
            else
                local cmd = string.format("cp -f '%s' '%s'", src_path:gsub("'", "'\\''"), abs_dst:gsub("'", "'\\''"))
                local ok_p, p = pcall(io.popen, cmd, "r")
                if ok_p and p then
                    p:read("*a")
                    p:close()
                    return true
                end
            end
        end
    end

    info("[COPY] All methods failed: " .. src_path .. " -> " .. dst_path)
    return false
end

M.ensure_dir = ensure_dir
M.list_dir_filesystem = list_dir_filesystem
M.copy_file_basic = copy_file_basic
M.command_succeeded = command_succeeded
M.build_process_command = build_process_command
M.run_process = run_process
M.run_shell_command_with_exit_code = run_shell_command_with_exit_code
M.remove_empty_directory_filesystem = remove_empty_directory_filesystem
M.remove_path_filesystem = remove_path_filesystem
M.copy_directory_filesystem = copy_directory_filesystem
M.write_if_changed = write_if_changed
M.write_binary_if_changed = write_binary_if_changed
M.is_array = is_array
M.serialize_value = serialize_value
M.write_layout_module = write_layout_module
M.copy_file_any = copy_file_any

return M
