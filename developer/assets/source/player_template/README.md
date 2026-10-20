# Sprite Player Source

The complete supported workflow is in **[the creator guide](../../../../docs/CREATOR_WORKFLOW.html#replace-the-player-sprite)**.

This folder is the source pack consumed by `developer/tools/generate_player_sprite_frames.py`. To use the existing importer:

1. Back up the project.
2. Copy `Mannequin/` to a new folder beside it, for example `MyPlayer/`, and replace its sheets with your art while preserving the expected folders, filenames, and sheet layout.
3. Install Python, Pillow (`py -m pip install Pillow`), and Lua if needed.
4. From the project root run `py developer/tools/generate_player_sprite_frames.py --source "developer/assets/source/player_template/MyPlayer"`.
5. Let Defold finish reloading the regenerated frames and `developer/assets/atlas/player.atlas`, then Build.

Your copy keeps the Mannequin's `pack.json`, which pins every sheet's ground
line 32 pixels above the bottom of its cell and keeps the game's sprite
geometry. Draw the feet on that line, or delete `pack.json` to let the
importer find the ground line in your art.

The generated folders are outputs; make future changes in this source pack and rerun the importer.
Draw and export frames at the size the player should appear in the game, and
leave Player Size at 1.00 (100%). Imports use source pixels 1:1. The supplied
48-pixel drawing grid is already enlarged into 192 × 192 cells with even
4 × 4 pixel blocks; wider attack cells keep their proportions. In Aseprite,
export an original-size drawing at 400%. Use `--target-height` or `--upscale`
only when importing art drawn at another size.

## Packs in this folder

- `Mannequin/` — the colour-coded template: head and hands grey, torso and arms blue, legs orange, feet dark. It has every pose the game uses, drawn by `py developer/tools/generate_player_model_pack.py --mannequin` from the same skeleton as Wayfarer, as PNG sheets. Copy its folder and file layout when you make your own art.
- `Wayfarer/` — the player the game currently uses. Its sheets are drawn by `developer/tools/generate_player_model_pack.py`. Run `py developer/tools/generate_player_model_pack.py` to redraw the sheets and import them. Edit the generator, not the PNGs, because the next run overwrites them. `Wayfarer/pack.json` holds its import settings: a pinned ground line, kept sprite geometry, and jump/fall frame choices.

To preview the template in the game, run `py developer/tools/generate_player_sprite_frames.py --source "developer/assets/source/player_template/Mannequin" --keep-geometry`.
Use `--fresh-geometry` when adopting a different canvas or replacing import
metadata from the old template size. Normal `--keep-geometry` imports reuse
the recorded 1.0 import scale, shared canvas and ground line.
