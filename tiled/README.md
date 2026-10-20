# Tiled Authoring Resources

Open the root `MVTK.tiled-project`, not this folder by itself. The complete beginner workflow is **[the creator guide](../docs/CREATOR_WORKFLOW.html#4-build-a-three-room-starter-world-in-tiled)**.

Exports go to the toolkit whose `MVTK.tiled-project` is open.

Keep your original maps, worlds, tilesets and artwork **outside the Defold
project**. Add those folders to Tiled's project sidebar (Defold's **Project >
Set Up This Toolkit** can add your maps folder). If no maps folder is listed
yet, running Set Up after **Start a New World...** offers the worlds folder you
picked; click **Set Up**. If it asks instead, choose
that folder with **Choose Maps Folder...** (the folder holding the world folder,
not the world folder itself). To change an already listed folder, click
**Change Maps Folder...**. Reopen the Tiled project to see a newly added folder.
Export creates copies
under `developer/assets/`; never edit those copies. The exporter rejects internal
originals, and Reset Project checks external-source receipts before cleanup.
The templates and extensions below belong to the framework and stay here.

**Export All Maps and Tiled World** warns when the maps' tile dimensions differ
from the project, then updates `developer/config/tile_settings.lua` to match the
export. All maps in the world must use the same tile dimensions. A failed export
restores the previous settings. Run **Project > Prepare & Check** in Defold after
exporting to rebuild rooms at the matching scale.

| Path | Purpose |
| --- | --- |
| `extensions/` | Adds **new_room_blank**, **Export Current Room**, **Export All Maps and Tiled World**, and **Start a New World...** |
| `templates/` | The 49 supported creator object templates |
| `custom_types/` | Property dropdown types loaded by the Tiled project |

The generated **[template property reference](templates/README.html)** mirrors every live `.tx` default and property. `templates/README.md` is the paired generated inventory used by maintainers and validation tools.

Most templates keep their identity selector and required ID at the top level,
then place related tuning inside one-level collapsible groups. Existing maps can
continue to export with legacy flat overrides. Newly placed templates already
include the grouped properties; no upgrade step is needed.

Do not infer creator support from compatibility code elsewhere in the repository. A gameplay object is in Microvania's public surface only when its `.tx` template appears here and in the generated catalog.

With **MVTK.tiled-project** open and extensions enabled, creating or opening a
world automatically adds missing fields to **World Properties**. Set `world_name`, `default_biome`,
`default_music`, `default_ambience`, and `default_map_color`; room overrides win.
See [world defaults in the creator guide](../docs/CREATOR_WORKFLOW.html#world-name-and-room-defaults)
for inheritance, silence, tint, and export rules.
