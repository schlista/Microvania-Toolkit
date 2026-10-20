-- mvtk/editor/project_reset.lua
--
-- Fast, recoverable filesystem moves for Delete My Rooms and Reset Project.
-- The editor's Lua VM cannot reliably rename an open resource directory on
-- Windows, so a failed atomic rename is followed by one bulk OS process. The
-- recursive Lua path is retained only as a last-resort safety fallback.

local M = {}

local function now_seconds()
    return os.time()
end

local function elapsed(now, started)
    local value = (now() or 0) - (started or 0)
    if value < 0 then return 0 end
    return value
end

function M.build_bulk_move_process(
    dir_sep,
    source_path,
    destination_path,
    to_os_path,
    windows_helper_path,
    project_root,
    copy_only
)
    to_os_path = to_os_path or function(value) return value end
    if dir_sep == "\\" then
        assert(type(windows_helper_path) == "string" and windows_helper_path ~= "",
            "Windows project reset requires a bulk-move helper path")
        assert(type(project_root) == "string" and project_root ~= "",
            "Windows project reset requires a project root")
        local args = {
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            to_os_path(windows_helper_path),
            "-ProjectRoot",
            (to_os_path(project_root)),
            "-Source",
            (to_os_path(source_path)),
            "-Destination",
            -- Parentheses also collapse accidental multiple returns from a
            -- caller-provided converter before they can expand this argv list.
            (to_os_path(destination_path)),
        }
        if copy_only then
            args[#args + 1] = "-CopyOnly"
        end
        return "powershell", args, {
            capture = true,
            reload_resources = false,
        }
    end
    return "mv", { source_path, destination_path }, {
        capture = true,
        reload_resources = false,
    }
end

function M.build_refresh_process(dir_sep)
    if dir_sep == "\\" then
        return "cmd", { "/d", "/c", "exit /b 0" }, {
            capture = false,
            reload_resources = true,
        }
    end
    return "sh", { "-c", "true" }, {
        capture = false,
        reload_resources = true,
    }
end

local function required(deps, key)
    local value = deps[key]
    assert(type(value) == "function", "project reset requires " .. tostring(key))
    return value
end

function M.new(deps)
    deps = deps or {}
    local normalize = required(deps, "normalize")
    local join = required(deps, "join")
    local dirname = required(deps, "dirname")
    local is_path_safe = required(deps, "is_path_safe")
    local path_exists = required(deps, "path_exists")
    local ensure_dir = required(deps, "ensure_dir")
    local list_dir = required(deps, "list_dir")
    local run_process = required(deps, "run_process")
    local remove_empty_dir = required(deps, "remove_empty_dir")
    local to_os_path = deps.to_os_path or function(value) return value end
    local rename_path = deps.rename_path or os.rename
    local remove_file = deps.remove_file or os.remove
    local copy_file = deps.copy_file
    local read_binary = deps.read_binary
    local delete_directory = deps.delete_directory
    local now = deps.now or now_seconds
    local root = normalize(deps.root or "."):gsub("/+$", "")
    local dir_sep = deps.dir_sep or package.config:sub(1, 1)
    local windows_helper_path = deps.windows_helper_path
    local trash_base = normalize(join(root, "developer/.trash")):gsub("/+$", "")

    local stats = {
        moved_files = 0,
        moved_directories = 0,
        failed = {},
        stages = {},
        strategies = {
            rename = 0,
            bulk = 0,
            empty = 0,
            editor_delete = 0,
            per_file = 0,
        },
        process_calls = 0,
        refresh_requested = false,
        refresh_ok = nil,
        external_move_attempted = false,
        started_at = now(),
        elapsed_seconds = 0,
    }
    local ensured_dirs = {}
    local self = {}

    local function relative_to_root(path)
        local normalized = normalize(path or "")
        if root ~= "" and root ~= "." then
            local prefix = root .. "/"
            if normalized:sub(1, #prefix) == prefix then
                return normalized:sub(#prefix + 1)
            end
        end
        return normalized:gsub("^/+", "")
    end

    local function destination_for(path, trash_root)
        return normalize(join(trash_root, relative_to_root(path)))
    end

    local function is_trash_path(path)
        path = normalize(path or ""):gsub("/+$", "")
        return is_path_safe(path)
            and (path == trash_base or path:sub(1, #trash_base + 1) == trash_base .. "/")
    end

    local function add_failure(path, reason)
        stats.failed[#stats.failed + 1] = {
            path = tostring(path),
            reason = tostring(reason or "unknown failure"),
        }
    end

    local function ensure_once(path)
        path = normalize(path or "")
        if path == "" then return true end
        if ensured_dirs[path] then return true end
        local ok = ensure_dir(path)
        if ok == false then
            add_failure(path, "cannot create trash directory")
            return false
        end
        ensured_dirs[path] = true
        return true
    end

    local function try_rename(source, destination)
        local attempts = {
            { to_os_path(source), to_os_path(destination) },
        }
        if attempts[1][1] ~= source or attempts[1][2] ~= destination then
            attempts[#attempts + 1] = { source, destination }
        end

        local last_error = nil
        for _, attempt in ipairs(attempts) do
            local ok, renamed, rename_error = pcall(rename_path, attempt[1], attempt[2])
            if ok and renamed then
                return true
            end
            last_error = rename_error or renamed or last_error
        end
        return false, last_error or "rename returned false"
    end

    local function try_remove_file(path)
        local attempts = { to_os_path(path) }
        if attempts[1] ~= path then attempts[#attempts + 1] = path end
        local last_error = nil
        for _, attempt in ipairs(attempts) do
            local ok, removed, remove_error = pcall(remove_file, attempt)
            if ok and removed then return true end
            last_error = remove_error or removed or last_error
        end
        return false, last_error or "remove returned false"
    end

    local function copy_without_directory_probe(source, destination)
        if copy_file then
            local ok, copied, copy_error = pcall(copy_file, source, destination)
            if ok and copied then return true end
            return false, copy_error or copied or "copy returned false"
        end
        if not read_binary then
            return false, "no copy implementation"
        end
        local data = read_binary(source)
        if data == nil then return false, "cannot read source" end
        local ok_open, handle_or_error = pcall(io.open, to_os_path(destination), "wb")
        if not ok_open or not handle_or_error then
            return false, handle_or_error or "cannot open destination"
        end
        local handle = handle_or_error
        local ok_write, write_error = pcall(function()
            handle:write(data)
            handle:close()
        end)
        if not ok_write then
            pcall(function() handle:close() end)
            return false, write_error
        end
        return true
    end

    function self:move_file(source, trash_root)
        source = normalize(source or "")
        trash_root = normalize(trash_root or "")
        if source == "" then return false end
        if not is_path_safe(source) then
            add_failure(source, "unsafe source path")
            return false
        end
        if trash_root == "" or not is_trash_path(trash_root) then
            add_failure(trash_root, "unsafe trash path")
            return false
        end
        if not path_exists(source) then return false end

        local destination = destination_for(source, trash_root)
        if not is_path_safe(destination) then
            add_failure(destination, "unsafe destination path")
            return false
        end
        local destination_dir = dirname(destination)
        if not ensure_once(destination_dir) then return false end

        local renamed = try_rename(source, destination)
        if not renamed then
            local copied, copy_error = copy_without_directory_probe(source, destination)
            if not copied then
                add_failure(source, "copy fallback failed: " .. tostring(copy_error))
                return false
            end
            local removed, remove_error = try_remove_file(source)
            if not removed then
                -- Direct writes can make Defold refresh its resource tree while
                -- this move is in progress. If another synchronized operation
                -- already removed the source, the desired postcondition holds.
                if path_exists(source) then
                    add_failure(source, "backup written but source removal failed: " .. tostring(remove_error))
                    return false
                end
            end
        end

        stats.moved_files = stats.moved_files + 1
        return true
    end

    local function move_files_recursive(source_dir, trash_root, opts)
        local dirs, files = list_dir(source_dir, {
            -- The editor resource graph can remain stale after an external
            -- move. Last-resort recovery must enumerate the real filesystem.
            force_process = opts.force_process == true,
        })
        if not dirs and not files then return 0 end
        local count = 0
        for _, filename in ipairs(files or {}) do
            if (not opts.match) or opts.match(filename) then
                if self:move_file(normalize(join(source_dir, filename)), trash_root) then
                    count = count + 1
                end
            end
        end
        if opts.recursive then
            for _, child_dir in ipairs(dirs or {}) do
                local child_path = normalize(join(source_dir, child_dir))
                count = count + move_files_recursive(child_path, trash_root, opts)
                if opts.remove_empty_dirs then
                    -- This must be a non-recursive rmdir. A directory that
                    -- gained a file during cleanup is intentionally preserved.
                    pcall(remove_empty_dir, child_path)
                end
            end
        end
        return count
    end

    function self:move_files(source_dir, trash_root, opts)
        opts = opts or {}
        source_dir = normalize(source_dir or "")
        trash_root = normalize(trash_root or "")
        if source_dir == "" then return 0 end
        if not is_path_safe(source_dir) then
            add_failure(source_dir, "unsafe source directory")
            return 0
        end
        if trash_root == "" or not is_trash_path(trash_root) then
            add_failure(trash_root, "unsafe trash path")
            return 0
        end

        local started = now()
        local count = move_files_recursive(source_dir, trash_root, opts)
        if count > 0 then stats.strategies.per_file = stats.strategies.per_file + 1 end
        stats.stages[#stats.stages + 1] = {
            path = relative_to_root(source_dir),
            strategy = "selective",
            moved_files = count,
            elapsed_seconds = elapsed(now, started),
        }
        return count
    end

    local function bulk_move(source, destination, copy_only)
        local command, args, options = M.build_bulk_move_process(
            dir_sep,
            source,
            destination,
            to_os_path,
            windows_helper_path,
            root,
            copy_only
        )
        stats.process_calls = stats.process_calls + 1
        stats.external_move_attempted = true
        local ok, code, output = run_process(command, args, options)

        -- POSIX uses the native mv executable rather than the Windows helper,
        -- so there is no machine-readable MVTK_RESET_STRATEGY marker to parse.
        -- run_process already treats a non-zero exit as failure; a zero exit is
        -- the authoritative result and keeps macOS/Linux on the bounded bulk
        -- path when an in-process rename is unavailable.
        if dir_sep ~= "\\" then
            if ok then
                return true, nil, "bulk", nil, nil, nil, nil
            end
            return false, output or code or "mv process failed"
        end

        local output_text = tostring(output or "")
        local rename_error = output_text:match("MVTK_RESET_RENAME_ERROR=([^\r\n]+)")
        local elapsed_ms = tonumber(output_text:match("MVTK_RESET_ELAPSED_MS=(%d+)"))
        local copy_code = tonumber(output_text:match("MVTK_RESET_COPY_CODE=(%d+)"))
        local copy_warning = output_text:match("MVTK_RESET_COPY_WARNING=([^\r\n]+)")
        local helper_error = output_text:match("MVTK_RESET_ERROR=([^\r\n]+)")
        local strategy = output_text:match("MVTK_RESET_STRATEGY=([%w_%-]+)")
        if ok and not helper_error
            and (strategy == "rename" or strategy == "bulk" or strategy == "empty"
                or (copy_only and strategy == "copy"))
        then
            return true, nil, strategy, rename_error, elapsed_ms, copy_code, copy_warning
        end
        local failure = helper_error or output or code or "bulk process failed"
        if ok and not helper_error then
            failure = "bulk helper exited without an explicit success marker"
        end
        return false, failure, nil, rename_error, elapsed_ms,
            copy_code, copy_warning
    end

    function self:move_directory(source_dir, trash_root)
        source_dir = normalize(source_dir or "")
        trash_root = normalize(trash_root or "")
        if source_dir == "" then return 0 end
        if not is_path_safe(source_dir) then
            add_failure(source_dir, "unsafe source directory")
            return 0
        end
        if source_dir == root then
            add_failure(source_dir, "refusing to move the project root")
            return 0
        end
        if trash_root == "" or not is_trash_path(trash_root) then
            add_failure(trash_root, "unsafe trash path")
            return 0
        end
        if not path_exists(source_dir) then return 0 end

        local started = now()
        local destination = destination_for(source_dir, trash_root)
        if not is_path_safe(destination) then
            add_failure(destination, "unsafe destination path")
            return 0
        end

        local rename_error = nil
        if dir_sep ~= "\\" then
            if not ensure_once(dirname(destination)) then return 0 end
            local renamed
            renamed, rename_error = try_rename(source_dir, destination)
            if renamed then
                stats.moved_directories = stats.moved_directories + 1
                stats.strategies.rename = stats.strategies.rename + 1
                stats.stages[#stats.stages + 1] = {
                    path = relative_to_root(source_dir),
                    strategy = "rename",
                    moved_directories = 1,
                    elapsed_seconds = elapsed(now, started),
                }
                return 1
            end
        end

        local bulk_ok, bulk_error, helper_strategy, helper_rename_error, helper_elapsed_ms,
            helper_copy_code, helper_copy_warning =
            bulk_move(source_dir, destination, false)
        if bulk_ok then
            if helper_strategy == "empty" then
                stats.strategies.empty = stats.strategies.empty + 1
                stats.stages[#stats.stages + 1] = {
                    path = relative_to_root(source_dir),
                    strategy = "empty",
                    moved_files = 0,
                    elapsed_seconds = helper_elapsed_ms
                        and (helper_elapsed_ms / 1000) or elapsed(now, started),
                }
                return 0
            end
            local strategy = helper_strategy == "rename" and "rename" or "bulk"
            stats.moved_directories = stats.moved_directories + 1
            stats.strategies[strategy] = stats.strategies[strategy] + 1
            stats.stages[#stats.stages + 1] = {
                path = relative_to_root(source_dir),
                strategy = strategy,
                moved_directories = 1,
                rename_error = helper_rename_error or (rename_error and tostring(rename_error) or nil),
                copy_code = helper_copy_code,
                copy_warning = helper_copy_warning,
                elapsed_seconds = helper_elapsed_ms and (helper_elapsed_ms / 1000) or elapsed(now, started),
            }
            return 1
        end

        rename_error = rename_error or helper_rename_error or "atomic move in Windows helper failed"
        if dir_sep == "\\" then
            if type(delete_directory) == "function" then
                -- Some Defold versions keep generated resources open strongly
                -- enough that an external move can copy but cannot remove them.
                -- Stage a verified backup, then let Defold delete its own
                -- resource directory. This is both recoverable and bounded.
                local copy_ok, copy_error, copy_strategy, _, copy_elapsed_ms,
                    copy_code, copy_warning = bulk_move(source_dir, destination, true)
                if copy_ok and copy_strategy == "copy" then
                    local call_ok, deleted, delete_error = pcall(delete_directory, source_dir)
                    if call_ok and deleted == true and not path_exists(source_dir) then
                        stats.moved_directories = stats.moved_directories + 1
                        stats.strategies.editor_delete = stats.strategies.editor_delete + 1
                        stats.stages[#stats.stages + 1] = {
                            path = relative_to_root(source_dir),
                            strategy = "editor delete",
                            moved_directories = 1,
                            rename_error = tostring(rename_error),
                            bulk_error = tostring(bulk_error),
                            copy_code = copy_code,
                            copy_warning = copy_warning,
                            elapsed_seconds = copy_elapsed_ms
                                and (copy_elapsed_ms / 1000) or elapsed(now, started),
                        }
                        return 1
                    end
                    if call_ok and deleted == true and path_exists(source_dir) then
                        delete_error = "editor.delete_directory returned success, but the source directory still exists"
                    end
                    bulk_error = string.format(
                        "%s; verified backup succeeded but editor.delete_directory failed: %s",
                        tostring(bulk_error),
                        tostring(delete_error or deleted or "unknown error")
                    )
                else
                    bulk_error = string.format(
                        "%s; backup copy for editor deletion failed: %s",
                        tostring(bulk_error),
                        tostring(copy_error)
                    )
                end
            end
            -- Never revisit a Windows directory through editor-cached Lua file
            -- I/O after an external move. That was the source of multi-minute
            -- resets and misleading "source no longer exists" failures.
            add_failure(source_dir, string.format(
                "bulk helper failed; remaining source data was preserved (%s)",
                tostring(bulk_error)
            ))
            stats.stages[#stats.stages + 1] = {
                path = relative_to_root(source_dir),
                strategy = "bulk failed",
                moved_files = 0,
                rename_error = tostring(rename_error),
                bulk_error = tostring(bulk_error),
                elapsed_seconds = elapsed(now, started),
            }
            return 0
        end
        if not ensure_once(dirname(destination)) then return 0 end
        local before = stats.moved_files
        local failures_before = #stats.failed
        local moved = move_files_recursive(source_dir, trash_root, {
            recursive = true,
            remove_empty_dirs = true,
            force_process = true,
        })
        if moved > 0 and #stats.failed == failures_before then
            local ok_remove, removed, remove_error = pcall(remove_empty_dir, source_dir)
            if not ok_remove or not removed then
                add_failure(source_dir,
                    "moved files, but preserved the source tree because it was not empty: "
                    .. tostring(remove_error or removed or "rmdir failed"))
            end
            stats.strategies.per_file = stats.strategies.per_file + 1
        elseif moved > 0 then
            add_failure(source_dir,
                "per-file fallback was partial; remaining source data was preserved")
            stats.strategies.per_file = stats.strategies.per_file + 1
        else
            add_failure(source_dir, string.format(
                "directory rename failed (%s); bulk fallback failed (%s)",
                tostring(rename_error),
                tostring(bulk_error)
            ))
        end
        stats.stages[#stats.stages + 1] = {
            path = relative_to_root(source_dir),
            strategy = "per-file fallback",
            moved_files = stats.moved_files - before,
            rename_error = tostring(rename_error),
            bulk_error = tostring(bulk_error),
            elapsed_seconds = elapsed(now, started),
        }
        return moved
    end

    function self:finish()
        if stats.moved_files > 0 or stats.moved_directories > 0 or stats.external_move_attempted then
            local command, args, options = M.build_refresh_process(dir_sep)
            stats.process_calls = stats.process_calls + 1
            stats.refresh_requested = true
            local ok = run_process(command, args, options)
            stats.refresh_ok = ok and true or false
        end
        stats.elapsed_seconds = elapsed(now, stats.started_at)
        return stats
    end

    function self:get_stats()
        return stats
    end

    function self:record_failure(path, reason)
        add_failure(path, reason)
    end

    return self
end

return M
