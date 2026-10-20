#!/bin/sh
#
# installer/setup_paths.sh
#
# POSIX source of truth for per-machine path setup. This mirrors
# installer/setup_paths.ps1 for macOS and Linux and is called by
# tools/set_tiled_export_path.sh.

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    printf '%s\n' "[setup_paths] ERROR: install dir does not exist: ${1-}"
    exit 1
fi

ROOT=$(CDPATH= cd -P "$1" 2>/dev/null && pwd)
if [ -z "$ROOT" ] || [ ! -f "$ROOT/game.project" ]; then
    printf '%s\n' "[setup_paths] ERROR: game.project not found under: $ROOT"
    exit 1
fi

case $(uname -s 2>/dev/null) in
    Darwin)
        PLATFORM=macOS
        GLOBAL_EXTENSIONS=$HOME/Library/Preferences/Tiled/extensions
        ;;
    Linux)
        PLATFORM=Linux
        GLOBAL_EXTENSIONS=${XDG_CONFIG_HOME:-$HOME/.config}/tiled/extensions
        ;;
    *)
        printf '%s\n' "[setup_paths] ERROR: unsupported POSIX host: $(uname -s 2>/dev/null)"
        exit 1
        ;;
esac

RESULTS=
FAILURES=0

add_result() {
    STATUS=$1
    shift
    LINE="[$STATUS] $*"
    RESULTS="${RESULTS}${LINE}
"
    if [ "$STATUS" = FAIL ]; then
        FAILURES=$((FAILURES + 1))
    fi
    printf '  %s\n' "$LINE"
}

run_step() {
    STEP_NAME=$1
    shift
    if "$@"; then
        add_result OK "$STEP_NAME"
    else
        add_result FAIL "$STEP_NAME"
    fi
}

write_export_path() {
    DESTINATION=$1
    {
        printf '%s\n' '# MV Toolkit - Tiled export path override (written by setup_paths.sh)'
        printf '%s\n' '# Delete or blank this file to fall back to auto-detect.'
        printf '%s\n' "$ROOT"
    } > "$DESTINATION"
}

write_project_export_path() {
    write_export_path "$ROOT/tiled/extensions/export_path.txt"
}

write_project_path() {
    printf '%s\n' "$ROOT" > "$ROOT/hooks/project_path.txt"
}

create_global_extensions() {
    mkdir -p "$GLOBAL_EXTENSIONS"
}

copy_extension() {
    NAME=$1
    SOURCE=$ROOT/tiled/extensions/$NAME
    DESTINATION=$GLOBAL_EXTENSIONS/$NAME
    [ -f "$SOURCE" ] || return 1
    cp -f "$SOURCE" "$DESTINATION" || return 1
    cmp -s "$SOURCE" "$DESTINATION"
}

write_global_export_path() {
    write_export_path "$GLOBAL_EXTENSIONS/export_path.txt"
}

write_where_things_are() {
    {
        printf '%s\n' '================================================================================'
        printf '%s\n' '  MICROVANIA TOOLKIT - WHERE THINGS ARE'
        printf '%s\n' '================================================================================'
        printf '\nThis toolkit is installed at:\n\n    %s\n\n' "$ROOT"
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '%s\n' '  OPEN THESE TWO FILES FIRST'
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '\n  In Defold (Open Project):\n      %s/game.project\n' "$ROOT"
        printf '\n  In Tiled (Open File or Project):\n      %s/MVTK.tiled-project\n' "$ROOT"
        printf '\n  The Tiled extensions were also installed globally here:\n      %s\n\n' "$GLOBAL_EXTENSIONS"
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '%s\n' '  WHERE YOUR WORK GOES'
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '\n  Tiled room exports:\n      %s/developer/assets/tiled/maps\n' "$ROOT"
        printf '\n  Your tilesets (.tsx) and tilesheet images:\n'
        printf '      %s/developer/assets/tiled/tilesets   (.tsx)\n' "$ROOT"
        printf '      %s/developer/assets/tilesheets        (.png/.jpg)\n' "$ROOT"
        printf '\n  Game settings saved by Project > Game Settings...:\n      %s/developer/config\n' "$ROOT"
        printf '\n  Generated rooms (after Project > Create Rooms):\n'
        printf '      %s/developer/rooms/collections\n' "$ROOT"
        printf '      %s/developer/rooms/factories\n' "$ROOT"
        printf '      %s/developer/rooms/generated\n' "$ROOT"
        printf '      %s/developer/config/rooms_config.lua\n' "$ROOT"
        printf '\n  Recoverable cleanup backups (safe to delete to reclaim space):\n'
        printf '      %s/developer/.trash\n\n' "$ROOT"
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '%s\n' '  GUIDES'
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '\n  Complete creator guide: %s/docs/CREATOR_WORKFLOW.html\n' "$ROOT"
        printf '  Template property guide: %s/tiled/templates/README.html\n\n' "$ROOT"
        printf '%s\n' '================================================================================'
    } > "$ROOT/WHERE_THINGS_ARE.txt"
}

printf '%s\n' "[setup_paths] Configuring toolkit at: $ROOT"
run_step 'Tiled export path (project copy)' write_project_export_path
run_step 'Defold project path (hooks/project_path.txt)' write_project_path
run_step 'Global Tiled extensions folder' create_global_extensions
run_step 'Global Tiled extension: export_lua_and_defold.js' copy_extension export_lua_and_defold.js
run_step 'Global Tiled extension: export_tiled_world.js' copy_extension export_tiled_world.js
run_step 'Global Tiled extension: content_relationships.js' copy_extension content_relationships.js
run_step 'Global Tiled extension: grouped_property_schema.js' copy_extension grouped_property_schema.js
run_step 'Global Tiled extension: new_room_blank.js' copy_extension new_room_blank.js
run_step 'Global Tiled extension: world_setup.js' copy_extension world_setup.js
run_step 'Remove retired Tiled grouped-property upgrade' rm -f "$GLOBAL_EXTENSIONS/upgrade_grouped_properties.js" "$ROOT/tiled/extensions/upgrade_grouped_properties.js"
run_step 'Tiled export path (global copy)' write_global_export_path
run_step 'WHERE_THINGS_ARE.txt' write_where_things_are

{
    printf '%s\n' 'Microvania Toolkit - path setup log'
    printf 'when:    %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf 'platform: %s\n' "$PLATFORM"
    printf 'install: %s\n' "$ROOT"
    printf 'tiled global extensions: %s\n\n' "$GLOBAL_EXTENSIONS"
    printf '%s' "$RESULTS"
    printf '\n'
    if [ "$FAILURES" -eq 0 ]; then
        printf '%s\n' 'RESULT: all steps OK.'
    else
        printf 'RESULT: %s step(s) failed. Close Tiled, then run sh tools/set_tiled_export_path.sh again.\n' "$FAILURES"
    fi
} > "$ROOT/post_install_log.txt" 2>/dev/null || \
    printf '%s\n' '[setup_paths] WARN: could not write post_install_log.txt'

if [ "$FAILURES" -eq 0 ]; then
    printf '%s\n' "[setup_paths] Path setup complete for $ROOT"
else
    printf '%s\n' "[setup_paths] Path setup finished with $FAILURES failure(s); see post_install_log.txt"
fi

# Partial setup is recorded in the log; callers should still finish normally.
exit 0
