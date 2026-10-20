-- Recoverable publication of a standalone project. All work stays in fixed
-- project-owned directories; publication uses directory renames, never copying.
local M = {}

local POSIX_HELPER = [=[
root=$1
mode=$2
plan=$3
fail() { printf 'MVTK_EXPORT_ERROR=%s\n' "$*"; exit 0; }
[ -d "$root" ] || fail 'Export project root does not exist.'
root=$(cd "$root" && pwd -P) || fail 'Cannot resolve the export project root.'
[ "$root" != / ] || fail 'Refusing to use the filesystem root.'
[ -f "$root/game.project" ] || fail 'Export workspace requires a project containing game.project.'
build="$root/.build"
stage="$build/export-stage"
previous="$build/export-previous"
export="$root/export"
check_tree() {
    target=$1
    [ ! -L "$target" ] || fail "Export workspace contains a symbolic link: $target"
    if [ -e "$target" ]; then
        [ -d "$target" ] || fail "Export workspace path is not a directory: $target"
        links=$(find "$target" -type l -print) || fail "Cannot inspect export workspace: $target"
        [ -z "$links" ] || fail "Export workspace contains symbolic links: $target"
    fi
}
filesystem_identity() {
    # POSIX df -P has one data row and puts the mount path after five fields.
    # Include that path as well as the device: distinct bind mounts can report
    # the same device while rename between them still fails with EXDEV.
    df -P "$1" | awk 'NR==2 { id=$1; for (i=6; i<=NF; i++) id=id " " $i; print id }'
}
check_filesystems() {
    root_filesystem=$(filesystem_identity "$root") || fail 'Cannot inspect the export filesystem.'
    [ -n "$root_filesystem" ] || fail 'Cannot identify the export filesystem.'
    for candidate in "$build" "$stage" "$previous" "$export"; do
        if [ "$mode" = recover ] && [ "$candidate" = "$stage" ]; then continue; fi
        if [ -d "$candidate" ]; then
            candidate_filesystem=$(filesystem_identity "$candidate") || fail "Cannot inspect export filesystem: $candidate"
            [ "$candidate_filesystem" = "$root_filesystem" ] || fail 'Export staging and the published project must use the same filesystem and mount; copying during publication is not allowed.'
        fi
    done
}
[ ! -L "$build" ] || fail 'The .build directory cannot be a symbolic link.'
if [ -e "$build" ]; then [ -d "$build" ] || fail '.build is not a directory.'; fi
check_tree "$previous"
recover_previous() {
    if [ -d "$previous" ]; then
        check_tree "$export"
        check_filesystems
        if [ -d "$export" ]; then
            rm -rf "$previous" || fail 'The previous export is retained; cannot finish its cleanup.'
        else
            mv "$previous" "$export" || fail 'Cannot restore the previous export; it remains in .build/export-previous.'
        fi
    fi
}
if [ "$mode" = recover ]; then
    recover_previous
    printf 'MVTK_EXPORT_RECOVERED=1\n'
elif [ "$mode" = prepare ]; then
    check_tree "$export"
    check_tree "$stage"
    mkdir -p "$build" || fail 'Cannot create .build for export staging.'
    check_filesystems
    recover_previous
    if [ -d "$stage" ]; then rm -rf "$stage" || fail 'Cannot discard interrupted export staging.'; fi
    mkdir -p "$stage" || fail 'Cannot create export staging.'
    printf 'MVTK_EXPORT_READY=1\n'
elif [ "$mode" = stage ]; then
    check_tree "$stage"
    [ -d "$stage" ] || fail 'Export staging is missing; prepare the workspace first.'
    [ -n "$plan" ] && [ -f "$plan" ] && [ ! -L "$plan" ] || fail 'Export staging requires a regular plan file inside .build/.'
    plan_parent=$(cd "$(dirname "$plan")" && pwd -P) || fail 'Cannot resolve the export plan directory.'
    case "$plan_parent/" in "$build/"*) ;; *) fail 'Export plan must be inside .build/.' ;; esac
    # Validate all records in one pass. No directories or files are written until
    # syntax, cross-record conflicts, and every source/destination have passed.
    plan_data=$(LC_ALL=C awk '
        function reject(message) { print message; invalid=1; exit 1 }
        NR==1 { if ($0 != "MVTK_EXPORT_PLAN_1") reject("Invalid export plan header."); next }
        {
            if (substr($0,2,1) != "\t" || (substr($0,1,1) != "D" && substr($0,1,1) != "C"))
                reject("Invalid export plan record.")
            kind=substr($0,1,1); path=substr($0,3)
            if (path == "" || path ~ /^\// || path ~ /\\/ || path ~ /:/ || path ~ /[[:cntrl:]]/)
                reject("Invalid relative path in export plan.")
            n=split(path,parts,"/")
            for (i=1; i<=n; i++) if (parts[i] == "" || parts[i] == "." || parts[i] == "..")
                reject("Invalid path segment in export plan.")
            if (kind == "C") {
                if (copies[path]++) reject("Duplicate copy target in export plan.")
            } else directories[path]=1
            records[++count]=$0; targets[path]=1
        }
        END {
            if (invalid) exit 1
            if (NR == 0) reject("Invalid export plan header.")
            for (path in targets) {
                if (copies[path] && directories[path]) reject("A copy target is also a directory in export plan.")
                parent=path
                while (sub(/\/[^\/]*$/, "", parent)) {
                    if (copies[parent]) reject("A copy target is a parent directory in export plan.")
                }
            }
            for (i=1; i<=count; i++) print records[i]
        }
    ' "$plan") || fail "$plan_data"
    tab=$(printf '\t')
    planned_dirs='
'
    while IFS="$tab" read -r kind rel; do
        [ -n "$kind" ] || continue
        if [ "$kind" = D ]; then
            parent=$rel
            while :; do
                [ ! -e "$stage/$parent" ] || [ -d "$stage/$parent" ] || fail "Export staging directory is a file: $parent"
                planned_dirs="$planned_dirs$parent
"
                case "$parent" in */*) parent=${parent%/*} ;; *) break ;; esac
            done
        fi
    done <<MVTK_PLAN
$plan_data
MVTK_PLAN
    while IFS="$tab" read -r kind rel; do
        [ -n "$kind" ] || continue
        if [ "$kind" = C ]; then
            [ -f "$root/$rel" ] && [ -r "$root/$rel" ] || fail "Export source is not a readable regular file: $rel"
            [ ! -e "$stage/$rel" ] && [ ! -L "$stage/$rel" ] || fail "Export staging destination already exists: $rel"
            case "$rel" in
                */*)
                    parent=${rel%/*}
                    case "$planned_dirs" in *"
$parent
"*) ;; *) [ -d "$stage/$parent" ] || fail "Export staging directory missing for $rel" ;; esac
                    ;;
            esac
        fi
    done <<MVTK_PLAN
$plan_data
MVTK_PLAN
    while IFS="$tab" read -r kind rel; do
        [ -n "$kind" ] || continue
        if [ "$kind" = D ]; then mkdir -p "$stage/$rel" || fail "Cannot create export staging directory: $rel"; fi
    done <<MVTK_PLAN
$plan_data
MVTK_PLAN
    copied=0
    while IFS="$tab" read -r kind rel; do
        [ -n "$kind" ] || continue
        if [ "$kind" = C ]; then
            cp -- "$root/$rel" "$stage/$rel" || fail "Cannot copy export source: $rel"
            copied=$((copied+1))
        fi
    done <<MVTK_PLAN
$plan_data
MVTK_PLAN
    printf 'MVTK_EXPORT_STAGED=%s\n' "$copied"
elif [ "$mode" = publish ]; then
    check_tree "$export"
    check_tree "$stage"
    [ -d "$stage" ] || fail 'Export staging is missing; prepare the workspace first.'
    [ -f "$stage/game.project" ] || fail 'Export staging has no game.project; the current export has been preserved.'
    [ ! -e "$previous" ] || fail 'A previous export needs recovery; prepare the workspace first.'
    check_filesystems
    had_export=0
    if [ -d "$export" ]; then
        mv "$export" "$previous" || fail 'Cannot move the current export; it has been preserved.'
        had_export=1
    fi
    if ! mv "$stage" "$export"; then
        if [ "$had_export" = 1 ]; then
            mv "$previous" "$export" || fail 'Export publication failed and recovery is pending in .build/export-previous.'
        fi
        fail 'Cannot publish export staging; the previous export has been restored.'
    fi
    if [ "$had_export" = 1 ]; then
        rm -rf "$previous" || printf 'MVTK_EXPORT_WARNING=Export published; previous export cleanup will be retried next time.\n'
    fi
    printf 'MVTK_EXPORT_PUBLISHED=1\n'
else
    fail 'Unknown export workspace operation.'
fi
]=]

local function normalized_root(root)
    assert(type(root) == "string" and root ~= "", "Export workspace requires a project root")
    root = root:gsub("\\", "/"):gsub("/+$", "")
    assert(root ~= "" and not root:match("^%a:$"), "Refusing to use a filesystem root for export")
    return root
end

function M.build_process(root, operation, opts)
    root = normalized_root(root)
    opts = opts or {}
    assert(operation == "recover" or operation == "prepare" or operation == "stage" or operation == "publish", "Invalid export workspace operation")
    if operation == "stage" then
        assert(type(opts.plan_path) == "string" and opts.plan_path ~= "", "Export staging requires a plan path")
    end
    local separator = opts.dir_sep or package.config:sub(1, 1)
    local options = {capture=true, reload_resources=false}
    if separator == "\\" then
        local args = {"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", root .. "/hooks/export_workspace.ps1", "-ProjectRoot", root,
            "-Operation", operation}
        if operation == "stage" then args[#args+1] = "-Plan"; args[#args+1] = opts.plan_path end
        return "powershell.exe", args, options
    end
    local args = {"-c", POSIX_HELPER, "mvtk-export-workspace", root, operation}
    if operation == "stage" then args[#args+1] = opts.plan_path end
    return "sh", args, options
end

local function run(root, operation, opts)
    opts = opts or {}
    local process = assert(opts.run_process, "Export workspace requires run_process")
    local command, args, options = M.build_process(root, operation, opts)
    local ok, code, output = process(command, args, options)
    assert(ok, "Export workspace " .. operation .. " failed: " .. tostring(output or code or "process failed"))
    output = tostring(output or "")
    local err = output:match("MVTK_EXPORT_ERROR=([^\r\n]+)")
    assert(not err, err)
    if operation == "stage" then
        local count = output:match("MVTK_EXPORT_STAGED=(%d+)[\r\n]*$")
        assert(count, "Export workspace helper did not confirm stage: " .. output)
        return tonumber(count)
    end
    local expected = ({recover="MVTK_EXPORT_RECOVERED=1",prepare="MVTK_EXPORT_READY=1",
        publish="MVTK_EXPORT_PUBLISHED=1"})[operation]
    assert(output:find(expected, 1, true), "Export workspace helper did not confirm " .. operation .. ": " .. output)
    return output:match("MVTK_EXPORT_WARNING=([^\r\n]+)")
end

function M.recover(root, opts)
    run(normalized_root(root), "recover", opts)
    return true
end

function M.prepare(root, opts)
    root = normalized_root(root)
    run(root, "prepare", opts)
    return root .. "/.build/export-stage"
end

function M.publish(root, opts)
    local warning = run(normalized_root(root), "publish", opts)
    return true, warning
end

function M.stage(root, plan_path, opts)
    local stage_opts = {}
    for key, value in pairs(opts or {}) do stage_opts[key] = value end
    stage_opts.plan_path = plan_path
    return run(normalized_root(root), "stage", stage_opts)
end

return M
