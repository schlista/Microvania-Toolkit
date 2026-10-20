#!/bin/sh
#
# tools/set_tiled_export_path.sh
#
# Reconfigure this extracted toolkit in place. All work is delegated to
# installer/setup_paths.sh.

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
REPO_ROOT=$(CDPATH= cd -P "$SCRIPT_DIR/.." 2>/dev/null && pwd)

if [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/installer/setup_paths.sh" ]; then
    printf '%s\n' '[set-export-path] ERROR: installer/setup_paths.sh was not found.'
    exit 1
fi

sh "$REPO_ROOT/installer/setup_paths.sh" "$REPO_ROOT"
STATUS=$?
printf '\n%s\n' 'Restart Tiled, then reopen MVTK.tiled-project so the extension uses the new path.'
exit "$STATUS"
