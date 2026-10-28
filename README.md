# Microvania Toolkit for Defold

Microvania Toolkit is a Tiled-first Defold toolkit for creating a short, two-to-three-hour exploration platformer. Creators build rooms and place gameplay objects in Tiled, connect rooms in the in-game Layout Editor, and tune the game without editing the framework under `mvtk/`.

The toolkit is empty: supply your own art and rooms, or start from a sample world.

## Download

- **Toolkit:** download `Microvania_Toolkit_<version>.zip` from the
  [Releases page](https://github.com/schlista/Microvania-Toolkit/releases), unzip it, and open
  **`START_HERE.html`** in a web browser. It shows a screenshot of every set-up step, from unzipping
  to playing a sample world. `START_HERE.txt` has the same steps as plain text.
- **Sample worlds:** the same Releases page has a sample worlds ZIP. Every world in it has its own
  `START_HERE.txt`.
- This repository holds the same files as the toolkit ZIP. If you use GitHub's **Code ▸ Download ZIP**
  instead, its files sit inside an extra `Microvania-Toolkit-main` folder: rename that folder to
  `Microvania_Toolkit` and follow START_HERE from there.

## What you need

- Defold **1.14.0**; later 1.14.x hotfixes are fine
- Tiled **1.12.2**, or a verified compatible 1.12.x release
- Windows is the verified platform. macOS and Linux use the same steps but are experimental.

## Start here

1. Unzip the toolkit into a folder for your game, next to a folder for your Tiled maps.
2. In Defold, open `game.project` and run **Project ▸ Set Up This Toolkit**.
3. In Tiled, tick the **defold** and **lua** plugins under **Edit ▸ Preferences... ▸ Plugins**, open
   `MVTK.tiled-project` with **File ▸ Open File or Project...**, and click **Enable Extensions** if
   Tiled asks.
4. Try a sample world, or open **[the Creator Guide](docs/CREATOR_WORKFLOW.html)** in a browser and
   follow **Start here — make three rooms, then play**.

`START_HERE.html` walks through each of these with pictures. No separate installation is needed.
Set Up writes **`WHERE_THINGS_ARE.txt`** with the exact paths for your toolkit.

## What the toolkit does

The toolkit provides room streaming, saves and checkpoints, ability/key gates, hazards and secrets, collectibles, simple enemies, compact Tiled-authored bosses, traversal objects including cross-room elevators, lightweight NPC/dialogue tools, audio/visual zones, and map tools. The live public surface is the **57 templates** under `tiled/templates/`, including lights, torches, grapple points and pushable blocks.

**Project ▸ Game Settings…** in Defold tunes the player, starting abilities, combat, optional currency recovery on death and the ending, and imports player art. Save and Prepare & Check, then Build to play. The title screen offers Play Game and Layout Editor; player preferences live in the pause menu's Settings. Difficulty profiles and first-use tutorial popups are configured in the commented game files.

## Known limitations

- macOS and Linux are experimental. On Linux, use Tiled's AppImage or a normal distribution package;
  Flatpak and Snap builds may need different extension paths and permissions. On macOS, say whether
  your Defold is the Apple Silicon (`arm64`) or Intel (`x86_64`) build when you report a problem.
- The sprite player is the supported player. Spine is an optional add-on
  (**Project ▸ Spine Add-on...**) and needs your own Spine Editor license.
- Saves are not guaranteed to load in a newer toolkit version. After updating, start a new save slot.

## Report a problem

Open an issue at <https://github.com/schlista/Microvania-Toolkit/issues>. Include your operating system,
the Defold and Tiled versions, the START_HERE or Creator Guide step, what you expected and what
happened, and the first red `[ERROR]` line from Defold's Console. The Creator Guide's troubleshooting
section lists what else helps.

## Folder map

| Path | Purpose |
| --- | --- |
| `developer/` | Your game assets, configuration, Tiled exports, generated rooms, and UI |
| `tiled/` | Tiled extensions, custom property types, and the live template catalog |
| `mvtk/` | Toolkit framework; creators should not edit it |
| `hooks/` | The toolkit's Defold editor commands (the Project menu items) |
| `docs/CREATOR_WORKFLOW.html` | Master creator documentation |
| `tiled/templates/README.html` | Generated property-by-property template reference |
| `tools/` | Command-line helpers for validation, previews and the Tiled export path |

## License

Free for personal, non-commercial use. Selling or monetizing a game made with the toolkit requires a paid Commercial License, one per person: see [`COMMERCIAL_LICENSE.txt`](COMMERCIAL_LICENSE.txt) and [`LICENSE`](LICENSE), or email MVTK@swishermail.com. The included art, music and sound are for demonstration only; replace them before you release a game.
