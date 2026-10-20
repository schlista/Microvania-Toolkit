-- Placement ownership after an empty-project reset.
return {
    owner = "layout_editor", -- Manual placement until a Tiled world is explicitly selected.
    manifest = "assets/tiled/worlds/active.lua", -- Developer-relative selected world snapshot.
    seen_export = "", -- Last reviewed export fingerprint; empty prompts on the next world import.
}
