# Creator Assets

Use the task-based instructions in **[the complete creator guide](../../docs/CREATOR_WORKFLOW.html#11-assets-where-your-files-go)** before replacing art or audio.

| Folder | Put this here |
| --- | --- |
| `tilesheets/` | Tilesheet PNG/JPG files localized by the Tiled exporter |
| `tiled/tilesets/` | Localized external Tiled `.tsx` files |
| `tiled/backgrounds/` | Image-layer and image-collection art localized by Tiled |
| `music/` | `.ogg` and `.wav` room music copied by Create Rooms / Sync Music |
| `sfx/` | Sound-effect source files |
| `enemies/` | One folder of individual PNG frames per custom enemy type |
| `source/player_template/` | Source sheets for the supported sprite-player importer |
| `sprites/` and `atlas/` | Runtime-ready sprite frames and Defold atlases |
| `fonts/` | Defold font resources used by menus and HUDs |

Spine resources live separately in [`developer/addons/spine/`](../addons/spine/README.md).
The add-on ships off. Using it requires your own Spine Editor license and
**Project ▸ Spine Add-on… ▸ Turn On**; follow the command's library-refresh
instructions, then run **Prepare & Check**. Keep Spine scenes, models, rig data
and their artwork inside that add-on folder.

Do not hand-edit files in `generated_audio/`, `enemies/generated/`, generated atlas sections, or `*_generated.lua`. Rerun the owning sync/import command instead.
