Custom Enemy Art
================

Full illustrated workflow: docs/CREATOR_WORKFLOW.html (Enemy art section).

Recommended: keep original enemy art outside the Defold project and link it
from Tiled. Place an enemy template and set its optional art file property
to any numbered frame in a skin folder, for example
enemies/moss_bug/idle_01.png beside your original maps. Linked folders use
<state>_<number>.png names and need idle_01.png. The folder name supplies the
skin id. Export copies the numbered frames here, then Project > Prepare &
Check syncs the skin and bakes the enemy as a gameobject instance in the
room collection.

Leave enemy_type=default to use the linked skin id as the enemy type. An
explicit preset keeps its stats, movement, attacks, audio and animation
choices; the link replaces its art. Linking another skin's frames to a
flying preset, for example, keeps that preset's flying behavior.

After editing, adding or removing original frames, export again, Prepare &
Check, then Build. Tiled refuses art links into the Defold project. If a
different source folder has the same skin id, Export keeps the existing
copy and warns; use different folder names for unrelated skins.

Dropping one folder per skin directly here still works. Leave the Tiled art
property empty, run Project > Prepare & Check (or Sync Enemy Art), and choose
the synced folder id from enemy_type. Create Rooms also runs that sync
automatically before rebuilding rooms.

The toolkit ships only the `default/` fallback art. Sample and training
worlds bring their own skins. Do not delete default/ unless you replace it
with another synced default skin. Skin-less enemies and legacy enemy types
use it automatically.

Folder layout:

developer/assets/enemies/
  ghost_blue/
    idle.png
    walk_01.png
    walk_02.png
    attack_01.png
    ranged_attack_01.png

Rules:

- Folder names should be lowercase snake_case. The Tiled enemy_type id comes
  from the sanitized folder name. Do not use "none".
- Synced folder ids are the only values shown in Tiled's enemy_type dropdown.
  Built-in preset names such as slime only appear there if you create matching
  art folders.
- If a folder id matches an existing enemy_types.lua preset, that preset keeps
  its stats and uses this art.
- New folder ids inherit starter slime stats until you add a matching entry in
  developer/config/enemy_types.lua. Add that entry when you want custom stats.
- Frames must be individual PNG files. Sprite strips and sheets are not
  supported by this pipeline because Defold atlas animations reference whole
  image files. Slice strips with an external tool before syncing.
- File names must start with one of these states:
  idle, walk, run, jump, fall, land, fly, fly_idle, hover, dive, patrol, alert,
  chase, search, return, attack, attack_alt, ranged_attack, charge,
  charge_windup, slam, block, spawn, hurt, stun, die, death, turret_idle,
  turret_aim, turret_fire
- Single-frame state: idle.png
- Multi-frame state: walk_01.png, walk_02.png, walk_03.png
- Unnumbered names such as idle.png remain supported for directly supplied
  project folders. The Tiled-linked workflow copies numbered frames only.
- Numeric suffixes sort numerically, so walk_2.png comes before walk_10.png.
  Zero padding is recommended.
- A skin must include idle.png or idle_01.png. If it does not, Sync Enemy Art
  skips that folder until the idle frame exists.
- Art should face right. The existing enemy runtime flips the sprite for left.
- Frames for one state should share dimensions.
- Very large skins may need paged atlas settings in developer/assets/atlas/enemy.atlas
  via max_page_width and max_page_height. Sync Enemy Art warns above about
  4096 x 4096 total pixels for one skin.
- For new rooms, choose enemy_type and optionally link original art through
  the art file property. Export manages the skin value in imported copies;
  do not hand-edit those generated files.
- Sync Enemy Art also writes per-skin sprites under
  developer/assets/enemies/generated/ and per-skin prefabs under
  developer/game/prefabs/generated/. Baked room enemy instances reference those
  prefabs so editor and runtime art match.

After updating the toolkit, fully restart Tiled to load the exporter and
template changes. Restart Defold after editor-module changes, then run
Project > Reload Editor Scripts > Prepare & Check > Build. Run Prepare &
Check again before Export Game. If you add a skin while Defold is still
importing files, wait for the resource view to finish refreshing before syncing.
