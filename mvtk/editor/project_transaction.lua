-- Recoverable multi-file authoring writes. Backups stay on disk until commit.
-- Relative targets are confined to the supplied authoring base directory.
local Model = require "mvtk.core.creator_settings_model"
local M = {}

local function read(path)
    local f, err, code = io.open(path, "rb")
    if not f then
        if code == 2 then return nil end
        if code == nil then
            if editor and type(editor.external_file_attributes) == "function" then
                -- The editor's Lua host omits errno and uses OS-localized error
                -- text. Query disk, including ignored .wizard files, rather
                -- than assuming the desktop Lua ENOENT message. Existing but
                -- unreadable journals must still stop recovery/publication.
                if editor.external_file_attributes(path).exists == false then return nil end
            elseif tostring(err):find("No such file or directory", 1, true) then
                return nil
            end
        end
        error("Cannot read " .. path .. ": " .. tostring(err))
    end
    local content, read_err = f:read("*a")
    local closed, close_err = f:close()
    assert(content and closed, read_err or close_err or ("Cannot read " .. path))
    return content
end

local function write(path, content)
    local directory = path:match("^(.*)/[^/]+$")
    if editor and editor.create_directory then
        -- Editor sandbox paths are resource-relative, unlike desktop game paths.
        local root = editor.external_file_attributes(".").path:gsub("\\", "/"):gsub("/$", "")
        local relative = directory:gsub("\\", "/")
        -- A file directly in the project folder (game.project, .defignore) has
        -- the root itself as its directory: nothing to create there.
        if relative:lower() == root:lower() then relative = ""
        elseif relative:sub(1,#root + 1):lower() == (root .. "/"):lower() then relative = relative:sub(#root+2) end
        relative = relative:gsub("^%./", "")
        assert(not relative:find(":",1,true), "Editor transaction path must be project-relative")
        if relative ~= "" then
            if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("create_directory") end
            editor.create_directory("/" .. relative:gsub("^/", ""))
        end
    else
        require("developer.tools.dev_helpers").ensure_dir(directory)
    end
    local f = assert(io.open(path, "wb"))
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
    local ok, err = f:write(content)
    local closed, close_err = f:close()
    assert(ok and closed, err or close_err or ("Cannot write " .. path))
end

local function remove(path)
    if read(path) == nil then return end
    -- Trust the filesystem, not the return value. The editor's Lua host does
    -- not report os.remove the way desktop Lua does: it can delete the file
    -- and still hand back a falsy value with no error message, which made
    -- `assert(os.remove(path))` fail with a bare "assertion failed!" after a
    -- successful delete and abort the on_build_finished hook. read() already
    -- works around the same host's io.open/errno differences above.
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
    os.remove(path)
    if read(path) ~= nil then
        error("Cannot delete " .. path)
    end
end

M.read = read
-- Exported so the editor-host deletion behaviour above stays under test.
M.remove = remove
local function target(base, relative)
    assert(type(relative) == "string" and relative ~= "", "Empty transaction target")
    assert(not relative:find("\\", 1, true) and not relative:find(":", 1, true)
        and relative:sub(1, 1) ~= "/", "Transaction target must be relative")
    for part in relative:gmatch("[^/]+") do
        assert(part ~= ".." and part ~= ".", "Transaction target escapes its base")
    end
    assert(relative:sub(1, 8) ~= ".wizard/", "Transaction cannot overwrite its journal")
    return base .. "/" .. relative
end

local function filesystem(opts)
    local fs = opts and opts.fs or {}
    return fs.read or read, fs.write or write, fs.remove or remove
end

function M.recover(base, opts)
    local get, put, del = filesystem(opts)
    local journal = base .. "/.wizard/journal.lua"
    local marker = base .. "/.wizard/committed"
    local prepared = base .. "/.wizard/prepared"
    local text = get(journal)
    if not text then
        del(marker)
        del(prepared)
        return false
    end
    if get(prepared) ~= "prepared" then
        -- A crash while creating the backup journal precedes all project writes.
        del(journal)
        del(marker)
        del(prepared)
        return true
    end
    local chunk = assert(loadstring and loadstring(text, "@" .. journal)
        or load(text, "@" .. journal, "t", {}))
    if setfenv then setfenv(chunk, {}) end
    local data = chunk()
    assert(type(data) == "table" and data.version == 1 and type(data.files) == "table", "Invalid wizard recovery journal")
    -- Validate every entry before restoring anything.
    for _, entry in ipairs(data.files) do
        target(base, entry.path)
        assert(type(entry.existed) == "boolean", "Invalid recovery record")
        assert(not entry.existed or type(entry.content) == "string", "Invalid recovery backup")
    end
    if get(marker) ~= "committed" then
        for _, entry in ipairs(data.files) do
            local path = target(base, entry.path)
            if entry.existed then put(path, entry.content) else del(path) end
        end
    end
    -- Remove journal first: a surviving marker alone cannot trigger rollback.
    del(journal)
    del(marker)
    del(prepared)
    return true
end

function M.commit(base, files, opts)
    local get, put, del = filesystem(opts)
    M.recover(base, opts)
    local changes, backups, seen = {}, {}, {}
    for _, entry in ipairs(files) do
        local path = target(base, entry.path)
        assert(not seen[path], "Duplicate transaction target: " .. path)
        seen[path] = true
        assert(type(entry.content) == "string", "Missing generated content: " .. path)
        local old = get(path)
        if old ~= entry.content then
            changes[#changes + 1] = entry
            backups[#backups + 1] = { path = entry.path, existed = old ~= nil, content = old }
        end
    end
    if #changes == 0 then return {} end
    local journal = base .. "/.wizard/journal.lua"
    local marker = base .. "/.wizard/committed"
    local prepared = base .. "/.wizard/prepared"
    -- The journal is fully closed before the first project file is touched.
    put(journal, "return " .. Model.encode({ version = 1, files = backups }) .. "\n")
    put(prepared, "prepared")
    local ok, err = pcall(function()
        for _, entry in ipairs(changes) do put(target(base, entry.path), entry.content) end
        if opts and opts.after_write then opts.after_write() end
        put(marker, "committed")
    end)
    if not ok then
        local restored, restore_err = pcall(M.recover, base, opts)
        error(tostring(err) .. (restored and " (previous files restored)"
            or ("; recovery is pending: " .. tostring(restore_err))), 0)
    end
    -- A cleanup failure does not undo a committed transaction. Next authoring
    -- launch sees the marker and only retries cleanup.
    local cleaned, cleanup_err = pcall(M.recover, base, opts)
    local written = {}
    for _, entry in ipairs(changes) do written[#written + 1] = target(base, entry.path) end
    return written, not cleaned and tostring(cleanup_err) or nil
end

return M
