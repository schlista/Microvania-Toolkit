# Preparation and endings

Prepare & Check opens a progress window before scanning files. Click **Continue**
there to begin. The window shows the current stage while the existing
Continue/Cancel menus still appear between stages. When preparation completes,
the same window shows the saved result and next action, and **Close** becomes
available. There is no second completion dialog to dismiss. A failed operation
displays its error in this window.

The stage total is planned once per run from the current project changes. A full
Tiled-world preparation has seven stages; it has six when Import Assets is
already current, and four when imports, player settings and room generation are
all current. Manual layouts and empty projects need fewer stages. Continue
prompts list unchanged work that was skipped, and the final result explicitly
reports **Completed N of N stages** using the same total as those prompts.
The final view is refreshed after resource synchronization settles so the saved
result appears without pressing Refresh status.

After installing or updating toolkit scripts, stop the game and run **Project → Reload Editor Scripts**. Export your saved maps from Tiled, then choose **Project → Prepare & Check** in Defold. It saves editor buffers before changing resources, checks imported Tiled copies, imports changed assets, creates rooms and synchronizes resources, then validates the result. You can cancel between complete stages. These individual stages are no longer separate menu choices. Preparation also rebakes player geometry from saved effective settings without publishing unsaved Game Settings edits.

With Tiled World selected, preparation publishes the exported world placement and minimap. With Layout Editor selected, Build, open Layout Editor, rescan and review placements, then **Layout Export** publishes the layout and minimap together. Stop and Build again before playing the newly published world. **Export Game** packages that publication without regenerating rooms underneath an older minimap.

**Project → Preparation Status** explains the next action and lists affected files. Statuses distinguish Tiled export needed, preparation needed, layout publication needed, rebuild needed, ready, failed, and legacy unverified exports. Re-export older maps once to record the imported inputs; re-export an older world with **Export All Maps and Tiled World**. External originals can then be offline or inaccessible to Defold. Ready means the imported export is prepared, not that unexported changes in Tiled have been imported.

Tiled validates the originals during export and records project-relative fingerprints for the localized TMX, tilesets, templates and artwork. Defold validates those imported inputs before Import Assets or Create Rooms; missing or modified copies require re-export. Original paths are retained for attribution, not reopened by Defold. **Export Current Room** updates content without changing exported world placement; resizing rooms, changing the starting room, or rearranging world membership requires **Export All Maps and Tiled World**. Import Assets regenerates tilemaps from imported Lua, so regenerated tilemaps are not treated as stale source copies.

Preparation records successful revisions only. A layout publication records room/settings/generator revisions and the exact minimap outputs. Draft placement edits invalidate publication. A file changing during minimap rendering cancels publication. Failed or cancelled preparation leaves the previously published layout and minimap intact; successfully completed preparation stages can still have updated generated room files.

Reports live in `developer/assets/tiled/preparation_status.json` and `preparation_run.json`. Automation can run `lua tools/prepare_project.lua --status`; `lua tools/prepare_project.lua` performs preparation and returns a failing exit code on errors. Run mutating automation with Defold stopped, preferably in a disposable project. Imported art and the TMX/TSX tile dimensions determine tile size; Game Settings does not offer a tile-size picker.

## Preparation checksum performance

Preparation, source checks, tileset cache keys and minimap PNG encoding share a
portable Lua Adler-32 implementation. It processes sixteen bytes per string call
and reduces the sums once per bounded block. Fingerprints and PNG checksums stay
identical to the previous implementation; binary data stays binary, and only
text-source checks normalize BOM/CRLF. No native extension or external program
is needed by this optimization on Windows, macOS or Linux. Every existing
freshness check still reads current file contents.

On 2026-09-27, a read-only comparison of the same preparation snapshot (5,654
files, 92,544,875 bytes) under standalone Windows Lua 5.1 took 5.351/5.944 seconds
with the previous loop and 1.580/1.488 seconds with the shared checksum. All
snapshot entries matched. This measures snapshot scanning, not total Defold
preparation time; editor integration and timings still need native verification.
Regression coverage is in `test/adler32_tests.lua` and the preparation tests.
The isolated full suite passed 1,459 tests; four failures in player-scale,
Tiled-enum and starting-ability checks reproduced with the original checksum.
Preparation, imported-input, world-layout and PNG/reset checks passed.

After this module update, **restart Defold**, then **Reload Editor Scripts →
Prepare & Check → Build**. Reload alone can leave required Lua modules cached.
The first preparation also records the updated generator sources.

## Preparation I/O and timings

Shared imported files are read once within each freshness check. Each later
check starts with fresh disk reads, including publication-time checks. World
members are validated once per pass, and preparation no longer repeats the
entire world check before step 1. No freshness checks are skipped across runs.

On 2026-09-29, read-only profiling of the 307-room project in standalone Lua
measured a world check at 32.241 s / 21,888 file opens before the change and
1.986 s / 734 opens afterward. Step-1 provenance checks fell from 62.252 s /
43,775 opens to 2.349 s / 734 opens. These are individual check timings, not
full Defold preparation timings; native UI behavior and total time need an
editor check after a full restart.

The performance update normalizes blank lines in generated prototypes once. It also
canonicalizes equivalent `-0` values to `0` in the generated art manifest. The next
unchanged generation should perform no generated-resource rewrites. Tiled objects
remain baked, editable gameobjects in their room collections.

Prepare & Check prints one `[PERF]` report on success, failure or cancellation.
Stage and total times exclude the Continue dialogs. The report distinguishes
unchanged files, existing rewrites, new batched resources, raw writes, estimated
resource synchronizations, and full/partial snapshots. Synchronizations are an
estimate from filesystem operations, not a Defold internal profiler counter.
Repeated disk writes with different content produce a churn warning.

`developer/config/editor_performance.lua` controls Windows batching, its minimum
file count, and debug-log rotation. The console explicitly reports when preparation
is waiting for a Continue/Cancel dialog between stages.
Preparation and world-publication commands reject overlapping invocations with
an "already running" message naming the active stage. A retry cannot reset the
active run's staged files or timing counters. The guard clears after completion,
cancellation, or failure.
Existing changed resources are written through
one PowerShell bundle and verified by reading each target back. The bundle stores
length-prefixed raw bytes instead of encoding every content byte in editor Lua.
Console timings distinguish packing, helper validation/writing, and the combined
helper/editor refresh wait. Failures fall back
to the ordinary writer. Other platforms retain ordinary writes. `.mvtk_tmp` is
ignored by Defold and excluded from releases. At the first logged editor command
of a session, a Windows debug log larger than 5 MiB rotates to `debug_output.txt.1`.
Repeated invisible-object warnings list object IDs together per room/layer/type.

See [measured results](archive/PREPARE_AND_CHECK_PERFORMANCE_RESULTS.md) for the native
Defold benchmark, output comparisons and test limitations. Fully restart Defold
after this update, then Reload Editor Scripts, Prepare & Check, and Build.

## Configure an ending

Stop the game, choose **Project ▸ Game Settings…** in Defold, then click **Ending**. These fields share the window's unsaved draft. Hover over a name or field for help, use the row's **x** to restore its default, and use **Edit lines…** for body text or credits. Click **Save and Prepare & Check**, finish the preparation prompts, then Build to play with the saved ending.

The commented baseline is `developer/config/game_completion.lua`. One stable ending ID identifies completion in each save slot. Choose a condition:

| Condition | Authoring |
| --- | --- |
| Region | Place `tiled/templates/logic/end_game.tx` on a top-level `templates` layer. Set its `completion_id` to the configured ending ID. Resize its rectangle in Tiled. |
| Flag | Set the flag name that existing gameplay grants. Completion waits until that flag is set. |
| Boss | Set the boss preset or persistent boss identity used by `boss_defeated_<id>`. Completion waits for rewards and arena cleanup. |

The region becomes a visible, editable gameobject in the baked room collection, with its own rectangle and script properties. Its editor collision outline is disabled during play; the script checks player entry. It is never created again by the runtime Tiled spawner. Version 2.8 adds the ending template while keeping supported 2.x templates readable.

An ending is also a required progression objective. Boss combat and unmodeled flag sources remain uncertain in progression analysis; a route in that model still needs a gameplay check. Relationship validation catches a region referring to an unknown ending or a boss ending referring to a missing boss.

Reset Project to Empty clears ending settings. Re-exporting maps restores their
authored ending regions, but does not restore the project ending configuration.
While completion is disabled, a region with a different ending ID produces a
warning and permits preparation/build. Open **Project ▸ Game Settings… ▸ Ending**,
set its ID to the region's `completion_id`, enable completion and click
**Save and Prepare & Check**, then Build. An ID mismatch blocks preparation/publication
once completion is enabled. After this validation update, restart Defold before
**Reload Editor Scripts → Prepare & Check → Build** to clear cached Lua modules.

## Presentation and Continue

Title, body and newline-separated credit entries are data. Music uses an existing Sync Music track ID. For artwork, add your image/animation to `developer/ui/game/completion.atlas`, then enter its animation ID in the Ending page. Leave music or artwork blank to omit it. The GUI's font and text scale are configurable in the baseline file. Credits support Enter/A/Right for the next page, Left for the previous page, and Escape/B to return to the menu.

**Preview ending…** shows the unsaved title, body and credit pages in an editor dialog. Previous and Next move between pages. It uses the game's page-building rules with sample values of zero minutes and zero items, and shows the artwork animation's first image when available. Missing artwork and Ending-field issues are displayed in the dialog. Preview does not set flags, change checkpoints, complete a slot, or save player data. Music plays only in the game.

**Completed** Continue shows the completion screen again. **Explore** Continue resumes at the configured return room and world coordinates, or the last saved checkpoint when the return room is blank. A return point must lie inside its published room; configure it somewhere safe and outside hazards. Revisiting the ending region does not trigger completion again.

The completion provider records the ending ID, gameplay time and an inventory snapshot (items held and currency). These are supported snapshot statistics, not a lifetime collectible percentage. An optional reward flag and the return checkpoint are committed with completion in one checkpoint save. Boss rewards are processed by the boss system before this transition. A failed save shows an error and Retry; it does not claim completion or unload the game. Keep Playing dismisses the error without claiming the save succeeded.

The empty toolkit leaves completion disabled. Reset Project to Empty and the empty release builder clear authored ending settings. Preparation reports and layout draft metadata are excluded from game packages.

## Acceptance checks in Defold

Headless tests exercise revisions, cancellation, baking, save/retry/reload, slot isolation and navigation logic. They cannot establish native rendering, input focus, physics, music or editor buffer reload behavior. Check the native workflow after Reload Editor Scripts: prepare, build, rescan/publish, rebuild, test each ending condition, retry a failed save, restart both Continue policies, and launch an exported game under its own save namespace.
