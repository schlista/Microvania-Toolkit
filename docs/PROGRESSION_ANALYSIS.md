# Checking progression

The optional **Layout Editor → Progression** panel analyzes current placement
without publishing it. It is hidden by default; set `ui.enabled=true` in
`developer/config/progression_analysis.lua` to show its preview controls.
**Project → Analyze Progression** analyzes the exported world. **Validate All**,
**Layout Export**, and **Export Game** also check the model. Reload editor scripts
and rebuild after updating the toolkit.

The search follows doors, teleporters, logical areas, pickups and supported gates.
Inventory, collected rewards, opened locks and visited objectives remain separate
for each route. Preview state never changes a player save.

## Results

- **Reachable:** a modeled route satisfies the requirements. Select an objective
  for acquisition steps. This does not prove platforming or combat is playable.
- **Blocked:** completed search found no satisfying modeled route. Select Gates
  or Objectives for unmet requirements or an obstruction.
- **Unknown:** geometry or unsupported behavior prevents a conclusion.
- **INCOMPLETE:** a time/state bound was reached. Known paths remain useful;
  unreached results are unknown, not proven impossible.

The campaign asks whether **one run** can visit every required objective. Two
routes spending the same key cannot be combined. Optional objectives have their
own results. With no required objectives, the report explicitly says so.

## Tiled annotations

Add custom properties to existing maps/objects. They describe connectivity;
they never change collisions, grant rewards or create new runtime objects.

| Where | Property | Type | Meaning |
| --- | --- | --- | --- |
| Map | `progression_open` | Bool | Asserts an unsplit room is internally traversable; its area is `main`. |
| Map | `progression_areas` | String | Comma-separated internally traversable areas: `entry,upper,vault`. No connections between areas are assumed. |
| Map | `progression_doors` | String | Door assignments: `left=entry,right=vault,up=upper`. |
| Map | `progression_required` | Bool | Requires reaching the first declared area. |
| Pickup, teleporter, objective object | `progression_area` | String | Area containing this object. |
| Existing gate/locked door/barrier | `progression_from`, `progression_to` | String | Areas on either side of the barrier. |
| Existing barrier | `progression_one_way` | Bool | Asserts physical traversal is only from → to; does not change gameplay. |
| Any existing visible object | `progression_objective` | String | Unique objective ID at this location. |
| Objective object | `progression_optional` | Bool | Excludes it from required campaign visits. |

Area names use letters, digits, underscores, dots or hyphens. Config references
use `room_id:area_name`. Multiple doors on one side can use saved coordinates:
`right:512:128=vault`. Coordinates are `cx`/`cy` in the exported layout's `doors`,
not Tiled object coordinates. Neighbor records supply the actual room connections.

Example: declare `entry,vault`, assign `left=entry,right=vault`, put
`progression_from=entry` / `progression_to=vault` on the locked door, and
`progression_area=vault` on the upgrade. It cannot be collected from the entrance.

Unannotated rooms are unknown internally. Missing barrier endpoints make the
room uncertain even with `progression_open`. Incomplete split-room annotations
permit only speculative connections. Hidden objects supply no rewards; gameplay
objects nested in groups cannot establish a known route.

## Controls and configuration

Click the category button to cycle Areas, Gates, Objectives, Diagnostics,
Abilities, Items, Flags, Presets and Start. Select a row, then use **Apply** to
toggle an ability/flag, select a preset, or set the start area. **+ / −** changes
item counts. **Run** rereads project files and current placement. **Prev / Next**
pages results. Full paths remain in the text report.

Map labels show status words and color, including separate logical areas.
Placement changes clear stale results; disk edits need an explicit Run. Closing
the panel restores labels. Preview overrides last for the editor session.

New-game state uses ability metadata, then `ability_defaults.lua`, then published
wizard overrides. Presets and session edits overlay that state. No save slot or
local wizard draft is read. Default start is the first placed room's first area.

The commented `developer/config/progression_analysis.lua` defines presets,
objectives, bounds and optional map annotations for sources you cannot edit.
Objective conditions support `abilities={id=true}`, `items={key_red=2}`,
`flags={boss_defeated=true}`, and `resources={energy=3}`. Conditions are ANDed;
unknown predicates are unknown. Preset item aliases such as `red` normalize to
`key_red`. These settings describe analysis, not runtime gameplay rules.

## Runtime rules and limits

The pure requirement evaluator is also used by the runtime gate manager.
Locked doors check ability and key/item, consume one key when configured, and
remain open on that branch. Item gates honor preset consumption. Inventory and
ability collectible presets are read from configuration. Pickups are one-time
rewards; respawning inventory sources make the economy uncertain. True flag
requirements follow `Flags.has`, including non-boolean set values.

Teleporters are directed: `one_way=true` means receive-only. Explicit targets,
pair fallback and required flags follow runtime rules. No modeled return path
produces a one-way warning, allowing intentional routes.

Action/timed/custom gates, hazards, switches, destructible geometry, temporary
unlocks and persistent elevators require playtesting. Boss defeat flags enter
only the speculative search; reaching a boss does not prove it can be defeated.
Random loot, custom collectible callbacks and dialogue rewards are unknown.
Unmodeled reward/traversal sources keep otherwise blocked conclusions uncertain.
Preview inventory/flags can investigate a known post-event state.

Missing areas/rooms, duplicate objective IDs, malformed configuration and invalid
source data stop publication before replacing output. Reachability, cycles,
traps and uncertain geometry are warnings, not export blockers.

## Reports and verification

`developer/assets/tiled/progression_diagnostics.txt` contains paths/explanations;
`progression_analysis.json` contains machine-readable results. Both are disposable
and excluded from game/toolkit packages.

```powershell
lua tools/analyze_progression.lua
lua tools/analyze_progression.lua --preset=new_game --start=room_a:entry --ability=double_jump:true --item=red:1 --flag=boss_defeated:true
```

CLI exit 1 means a source/model error. Unknown or bounded results remain explicit
warnings. CLI/menu analysis uses published layout; the panel uses draft placement.

Fixtures cover valid ability routes, self-locks, cycles, disconnected/optional
objectives, internal barriers, one-way teleporters, competing key paths, persistent
unlocks, bounds, presets, publication preservation and preview input. Native GUI
and gameplay acceptance still require Reload Editor Scripts → Import Assets →
Create Rooms → Validate All → Build, then inspecting Progression and playtesting.
Headless checks do not prove Defold rendering or editor integration.

September 17 verification: 1,160 isolated Lua tests passed, zero failed/skipped,
including 24 progression scenarios; 12 release-helper checks and configuration
validation passed. Full log: `.build/tests-20260917-115516-e1b514c3/tests.log`.
Additional reports are under `.build/phase4/`.
