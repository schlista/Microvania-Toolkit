# Spine add-on

Spine is optional and **off in a fresh toolkit**. With it off, the game uses no Spine runtime or resources. The add-on contains the Buck (Jax Hunter) player rig, a boss placeholder using that rig, and their materials. Its files stay in this folder for later use. The shaders retain their Defold License notices.

## Credit

The Buck rig is "Jax Hunter 2D Animated Spine Character (Prime Series)" by Gamelauncher Studio, from the Unity Asset Store. It is included under the toolkit author's licence from its creator. It is a Demonstration Asset under the Microvania Toolkit License: do not reuse it, its images or its skeleton in your own projects. Use your own rig in your game.

## Turn it on

Everyone who builds with the Spine runtime needs their own Spine Editor license (Essential or higher); the free Trial does not cover the runtime. Read the [Spine Editor License Agreement](https://esotericsoftware.com/spine-editor-license) before enabling it.

1. Stop the game. In Defold choose **Project ▸ Spine Add-on…**, then **Turn On**.
2. Read the license notice and confirm **Turn On**.
3. Close the completion message and wait for the command to fetch libraries. If it instead asks you to run **Project ▸ Fetch Libraries**, follow that instruction.
4. Close and reopen Defold if it has not picked up the `.defignore` change. Run **Project ▸ Prepare & Check** before **Build** or **Export Game**.

The command updates the Spine dependency, the ignore rule and the two player factories together. The dialog reads their current state from the project files. If it reports **Mixed**, choose **Turn On** or **Turn Off** again to restore a consistent state; turning off still requires the cleanup below.

## Use the player

With the add-on on, set `player.player_type = "spine"` in `developer/config/game_config.lua`. Published Game Settings overrides in `developer/config/creator_settings.lua` take priority, so check that file if the baseline selection has no effect. Turning on the add-on leaves the selected player type unchanged; a game can use a sprite player and Spine bosses.

The player resources are all under `developer/addons/spine/player/`:

- `player.collection` and `player_spine.collection` contain the player and bone-collider gameobject instances.
- `player_spine_visual.go` contains the Spine component and its placement.
- `rig/` contains the model, scene, atlas, images and `buck/buck.spinejson` skeleton.

When updating the bundled player from another toolkit copy, keep the rig, visual gameobject and **both** collections together. Mixing their versions changes the displayed size. Preserve your own customized resources when upgrading.

Game Settings saves and **Prepare & Check** keep both add-on collections and the core bone-collider sizes in sync with **Player Size**, even while the add-on is off. Keep `developer/config/player_resources_generated.lua`: it records the previous geometry so later saves do not apply the same scale twice. For a custom player without that history, save its current size in Game Settings before changing the baseline size.

For a replacement rig, map gameplay animations through `player.animation_overrides` in `developer/config/game_config.lua`, review `player.spine_physics.bone_map` in that file, and check the bone names in `developer/config/combat_config.lua`. Keep Spine authoring originals outside the toolkit. The helper `player/rig/fix_spinejson.py` can flatten attachment references and bake a root scale into a JSON export. Run it with explicit `--images-dir`, `--output` and `--scale` options for your own rig; its defaults target the bundled Buck files. It checks the existing loose PNG set and does not create the images.

## Add a Spine boss

1. Turn the add-on on. Add your skeleton, images, atlas, `.spinescene` and `.spinemodel` under `developer/addons/spine/bosses/<your_boss>/`. Use `/developer/addons/spine/materials/spine.material` for the Spine model's material.
2. In Defold, open `developer/game/prefabs/boss_runtime.go` and add a Spine Model component with a unique ID, such as `spine_my_boss`. To try the placeholder, point it at `/developer/addons/spine/bosses/boss_placeholder/boss_placeholder.spinemodel`.
3. Add that component ID to `visual_components` in `developer/config/boss_visuals.lua`.
4. In the matching entry in `developer/config/boss_types.lua`, set `boss_visual_type = "spine"` and `visual_component = "spine_my_boss"`. Give the rig the clips listed in `developer/config/boss_animations.lua`, or adapt that configuration to your clips. Check the boss object's Tiled properties too: per-object values override its preset.
5. Place the boss through the supported Tiled templates, export, and run Prepare & Check. Tiled objects remain baked gameobject instances in the room collection.

The shared boss prefab has no Spine component by default. The placeholder is an example resource, not an automatically enabled boss.

## Turn it off

First select a sprite player, including any published Game Settings override. Replace Spine bosses with sprites in their presets and Tiled properties, and remove their Spine components from `boss_runtime.go` and IDs from `boss_visuals.lua`. Export the changed rooms and run **Prepare & Check** while the add-on is still on, so baked room collections use the sprite selections too. Keep all Spine-typed resources inside the add-on folder and remove references to them from other project resources. Remove explicit add-on resource declarations from `game.project`; a broad custom-resource folder such as `/developer` also includes the add-on.

Choose **Project ▸ Spine Add-on…**, then **Turn Off**. The command refuses while the project still selects or references Spine and names the files and settings to change. After the cleanup succeeds, let it refresh libraries, reopen Defold if requested, and run **Prepare & Check** before **Build** or **Export Game**. The ignored add-on files stay available for later use and are not compiled into the game while off.
