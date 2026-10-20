# Designer tools

Stop the game and open **Project ▸ Game Settings…** in Defold. Player art,
Camera, HUD and prompts, Map, Saves and checkpoints, and Movement test are tabs
in the same window. Edits stay in its draft until **Save**. **Save and Prepare &
Check** also prepares the project; finish its prompts, then Build.

Hover over a name or field for help. Names that differ from toolkit defaults
are blue; the row's **x** restores its default. Range errors appear on the field
and block Save. Enter confirms a typed value without closing the window.
Closing with unsaved changes offers **Discard** or **Keep editing**. Dialog
actions reopen the main window on Player while retaining the draft.

## Player art

Enter a project-relative PNG sheet path or a directory containing PNG sequences,
for example `idle_001.png`, `idle_002.png`, `run_001.png`. **Browse…** selects a
sheet; sequence folders use the validated source text field. Sequence numbers
start at 1 with no gaps, and all frames have the configured dimensions. Sheets
must divide exactly into those dimensions. Sheet ranges are row-major, starting
at 1: `idle=1-2;run=3-8;jump=9-9;fall=10-10`.

Map gameplay names to your animations with entries such as `run=running;hurt=damage`,
separated by semicolons. Required states are listed in the field help; add names
used by custom attacks. Missing states stop import. An explicit fallback can
supply missing required states, and the preview lists every state using it.
The non-looping animation list controls playback for gameplay IDs; other IDs loop.

Click **Import and preview…** to check PNGs, frame geometry, ranges and mappings.
The **Player art preview** window shows the selected animation's first frame,
its frame count, the green body box and the origin crosshair. The dropdown
changes the animation. Width and height `0` use the source frame dimensions;
explicit dimensions can stretch the art, which the preview reports. Player size
`1.00` uses the model's own in-game pixels.

**Use this art** keeps the import in the draft; **Cancel** discards that preview.
Save commits PNGs, atlas, sprite resource, geometry and settings together.
Changed source files, import settings or player size require another import.
Imports are limited to 512 frames and 16 million total pixels. The editor
accepts non-interlaced PNGs; re-export 16-bit images as 8-bit PNGs.

PNG import selects the sprite player. Spine is an optional add-on and ships off.
To use it, you need your own Spine Editor license: choose **Project ▸ Spine
Add-on…**, then **Turn On**, and follow its library-refresh instructions before
**Prepare & Check**. Add-on resources stay under `developer/addons/spine/`;
PNG import preserves them. See the [Spine add-on guide](../developer/addons/spine/README.md).
Custom sprite components and unrelated references are preserved. Ambiguous or
unsupported resource geometry stops the save with an error.

## Camera

Tune zoom, follow response, dead zones, framing offset, horizontal look-ahead,
vertical look, pixel snapping, respawn transitions and default shake. Look-ahead
smooths an input-directed offset of the follow target. Tiled camera zones and
boss arenas retain their authority; player shake preferences remain separate.

**Launch room preview** plays a disposable copy of the published rooms with the
draft's settings and pending player art. Publish a Tiled world with **Prepare &
Check** or export rooms from Layout Editor first. Use Movement test when the
project is still empty.

## HUD and prompts

Choose layout and theme presets, visibility, scale, health anchor and colour,
plus the default controller icon theme. Individual overrides apply after
presets. Gameplay can still hide unavailable resources, and player icon
preferences override creator defaults. Save and Build to check the result.

## Map

The map discovers the gameplay camera's visible area in enabled rooms. Set
whole-room discovery or an extra nearby reveal radius, fog and feathering,
map and minimap visibility, and screenshot-marker count and size. Presentation
changes do not erase explored cells. Secret-room rules, map stations and
streamed markers retain their existing Tiled and runtime settings.

## Saves and checkpoints

Set visible slots, timed autosave and its interval, room-change and collectible
save policies, and starting resource maxima. Death currency recovery is on the
**Game** tab. Hiding a slot preserves its file. Timed autosave also respects the
player's preference; interval `0` disables its timer. Explicit checkpoints,
ending commits and progression providers can still save. Room-change saves
retain the existing checkpoint location.

Restart loads the saved checkpoint; invalid room or position data falls back
to a valid spawn. It restores full health and resets motion and death state.
Other resource and progression values follow their checkpoint providers.
Display, audio and input preferences remain separate from progression.

## Movement test and room previews

On **Movement test**, set the course length, jump-step height and dash-gap width,
then click **Launch test course**. Both preview buttons build a separate project
under `.build/designer-preview/<job>/project`, applying the unsaved settings and
pending imported art. The course uses ordinary editable gameobjects baked into
its room collection. The live project and its saved settings stay unchanged.

Previews require Windows, Lua, PowerShell 7 (`pwsh.exe`) and a Defold installation
located by `tools/defold_bob.bat` (`DEFOLD_PACKAGES_DIR` and `DEFOLD_HOME` are
supported). Dependency downloads need network access. On other platforms the
buttons say **Previews need Windows for now** and are disabled.

The Game Settings window reopens while the preview builds. Click **Refresh
status** to read its progress. Launching again during a build shows the current
job status. In the preview, F5 / controller Back restarts, F6 / left-stick click
selects an ability, and F7 / right-stick click toggles it. Use the game's normal
movement controls. Close the preview game when finished; the draft remains in
Game Settings, ready for another experiment or Save.

The copy has a unique identity and keeps progress in its own `preview_saves`
directory. Job folders are excluded from release packages and can be removed
after the preview closes. `status.txt`, `stage.log`, `course.log`,
`generation.log` and `build.log` report progress or failures. A failed build
does not publish the draft or alter creator progress.

## Grapple and ending

Tune the **Grapple** tab and use **Camera ▸ Launch room preview** to try its
settings in your rooms. See [Grappling](GRAPPLING.md).

The **Ending** tab's **Preview ending…** opens an editor dialog with the unsaved
title, body, artwork's first image and paged credits. Previous and Next move
between pages. Playtime and item counts are sample values; music plays only in
the game. The dialog shows the same validation issues as the Ending tab. See
[Preparation and endings](PREPARATION_AND_ENDINGS.md).

## Verification boundary

Automated tests check validation, import planning, transactions, draft isolation,
course generation and shared ending page rules. Check rendering, physics,
controller behaviour, camera zones and ending music in the running game.
After changing required editor Lua modules, restart Defold, run **Project ▸
Reload Editor Scripts**, then **Prepare & Check** before **Export Game**.
