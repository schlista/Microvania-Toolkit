# Connecting authored objects

Use Tiled's object picker for links inside a room. Keep string IDs for links
between rooms and switches that deliberately control several listeners.

| Property | Available on | Selects |
| --- | --- | --- |
| `target_ref` (Object) | Lever, pressure plate | Timed door, hazard, elevator |
| `target_ref` (Object) | Teleporter | Another teleporter in this room |
| `boss_ref` (Object) | Boss arena, boss phase, boss phase trigger, weak point | Boss in this room |
| `arena_ref` (Object) | Boss, boss phase, boss phase trigger | Boss arena in this room |

The curated templates expose these optional pickers. Older objects can use
**Add Property → Object** with the same property name. An unset picker keeps
the existing string field. A selected picker takes precedence over its string
field. The exporter converts the link to a runtime string ID in the Lua export
and preserves the native link in the source TMX, including a localized project
copy of an external map. Direct Object-typed `target_id`, `boss_id`, and
`arena_id` properties are supported too.

Targets without an explicit ID receive a stable room/type/object ID in the Lua
export. Renaming an object's display name does not change that generated ID.
Duplicating or deleting objects is checked using Tiled's numeric object IDs;
the tool does not guess which replacement target you intended. Native links
cannot point into another map. When copying a room, review explicit global IDs:
they are intentionally preserved, and collisions are reported.

## String IDs and broadcasts

A lever's `target_id` is a trigger channel. Multiple timed doors or hazards may
share that channel. Elevators listen on both `elevator_id` and `trigger_id`.
Listeners in other streamed rooms work only while those rooms are loaded;
validation warns about that dependency. Persistent elevator controllers can
receive calls across rooms.

Teleporters use globally unique `teleporter_id` values. `target_id` identifies
a destination; `pair_id` can instead join two endpoints. Runtime can fall back
from a missing explicit target to a valid pair, which produces a warning.
An explicitly blank teleporter identity is an error because the unloaded-room
registry skips it. Set a unique ID or use a native reference to assign one.
Layout publication checks that destination rooms are actually placed, including
destinations that are currently unloaded.

Boss presets are reusable configurations, not unique encounter IDs. Explicit
boss IDs and tags identify encounters; blank IDs use baked instance identities.
Boss phase triggers use a numeric boss phase index and a boss or arena selector.
Arena IDs can resolve to Tiled objects or configured arenas.

Chest, breakable-wall, and save-point identities are checked for collisions
across rooms. Arbitrary shared flags and trigger channels are not treated as
unique object identities. `none` means no ability/key requirement. Unknown
custom keys produce a warning; undefined configured abilities and dialogues
produce errors, even if their configuration table is empty.

## Checks and freshness

Run **Export Current Room** in Tiled, then in Defold run **Reload Editor
Scripts → Import Assets → Create Rooms → Validate All → Build**. After updating
the toolkit, rerun the installer/path setup and restart Tiled to load its new
relationship extension.

Tiled checks native links and local IDs immediately. It uses
`developer/assets/tiled/content_index.json` for cross-room/configuration facts.
Create Rooms and Validate All refresh this disposable index after a successful
scan. File fingerprints detect changed, removed, or newly exported rooms and
changed configurations. Stale, missing, or incompatible index data is explicitly
reported as **unverified**; it is never used to claim that a cross-room link is
valid. Export all related rooms, then run the project checks to resolve this.

New exports also record the saved TMX fingerprint. Editing the TMX without
exporting it blocks publication. Legacy exports have no such provenance, so
they produce a freshness warning until exported once with the updated tool.
Save all open Tiled edits before running the project checks; Defold reads disk.

The project-side checks reload sources and configurations from disk on each
invocation. They run before Create Rooms, Validate All, Layout Export, Export
Game, and the normal editor Build. The standalone Tiled-export validator also
reports relationship errors. No relationship check creates gameplay objects
at runtime; room objects remain baked and editable in Defold.

## Fixing a diagnostic

Each diagnostic includes severity, a stable code, file, room, layer, object ID,
property, message, and suggested fix. On a blocked Tiled export, affected objects
in the open map are selected automatically. For another room, open its TMX and
find the reported numeric ID in the Objects view.

Defold writes the full report to
`developer/assets/tiled/relationship_diagnostics.txt` and logs diagnostics in
the Console. Open `developer/rooms/collections/<room>.collection` and select
`<room>_<type>_<object_id>` to inspect the corresponding baked gameobject.
Correct the source in Tiled and export again. The Layout Editor displays the
report path when publication is blocked; click or press a key to dismiss it.

Relationship errors stop publication before existing output is replaced.
Tiled retains the preceding Lua/tilemap pair; Create Rooms retains generated
collections; Layout Export retains the runtime layout and minimap; Export Game
retains the previous standalone project. Layout/minimap writes also use a
recoverable transaction so a write failure rolls back the group. Layout draft
autosaves remain editable and do not replace the published world. Run Export
Game again to copy a newly published layout into the standalone project.

## Maintainer verification

These checks run in the toolkit's source repository; release downloads leave
the test suite and its fixtures out.

- `lua test/run_tests.lua`
- `node test/content_relationships_tests.js`
- `lua tools/validate_tiled_export.lua --quick`
- `lua tools/validate_config.lua`
- Run `test/phase3_publication_tests.ps1 -FixtureRoot <isolated-test-project>`
  against a disposable project created by `tools/test.ps1`.
- Native Tiled: evaluate `tiled/extensions/content_relationships.js`, then
  `tiled/extensions/export_lua_and_defold.js`, then
  `developer/tools/tiled/test_relationships.js`. Pass absolute script paths.
  The result is in `.build/phase3-native/report.txt`; process exit code alone is
  insufficient for Tiled evaluator failures.
  Enable the `defold` plugin under Tiled Preferences > Plugins to include the
  successful paired Lua/tilemap export check. Without it that check is reported
  separately as skipped; native reference and failed-publication checks still run.

September 16 verification logs: `.build/tests-20260916-193100-f5b171d5/tests.log`
(1,136 passed, zero failed/skipped), `.build/phase3-native/report.txt`, and
`.build/tests-20260916-192740-ce929abc/phase3-native-bake.log` plus
`phase3-native-rebake.log`. The successful paired Tiled export check was skipped
because the local Defold plugin was disabled. Config and JavaScript checks passed.

Defold UI and in-game acceptance still require the documented native workflow.
Headless tests do not establish editor integration or runtime presentation.
