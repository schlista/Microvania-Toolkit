# Game identity and save compatibility

In Defold, open **Project ▸ Game Settings… ▸ Game**. **Game name** is the display
title in `game.project`. The first Save quietly assigns the permanent game ID in
`developer/config/persistence_settings.lua`; **Game ID** shows it read-only.
Renaming the title keeps that ID and Continue data. A toolkit placeholder title
shows a warning on the name field without blocking Save. Give each game a name
that players can recognise.

A working copy of the same game should keep its ID. For a different game, copy
the project first, clear `game_id` in the copy's `persistence_settings.lua`, then
Save once in Game Settings. Export Game reports title and ID and refuses an
uninitialised identity. Empty toolkit packages reset the ID for the next creator;
exported games retain it.

Game Settings does not copy older player data or import machine-local authoring
settings. Beta saves are disposable; use a fresh slot when testing a new toolkit
or sample world. Player preferences and save slots share the game's player
namespace. Layout drafts use their own scope; export the layout before changing
identity so published project content remains available in the project.

The title, ID, creator overrides and player resources publish together through
the existing transaction journal in `developer/.wizard/`. Opening Game Settings
or running **Prepare & Check** recovers an interrupted project transaction. Do
not delete a pending journal. Keep the game stopped while editing, then Build
to play with the saved identity and settings.

## Supported payloads

| Store | Supported input | Upgrade behavior |
| --- | --- | --- |
| Checkpoint | Version 1 (including unversioned legacy structure), version 2 | Check integrity first; upgrade a copy to version 2, then migrate providers and identifier aliases. |
| Provider payload | Its registered version, or an older version with every migration step supplied | `migrations[old_version](copied_data)` returns the next payload. Missing steps and newer versions block loading/saving. Unknown providers are retained. |
| Player preferences | Unversioned, version 1 | Keep preference values; next successful save writes version 1. |
| Controller bindings | Version 2 | Other versions are not overwritten. |
| Project creator settings | Version 1 | Published project overrides are loaded; machine-local authoring values are not imported. Unknown project versions are rejected. |

Checksum-bearing saves must pass their stored checksum before migration code
runs. Historical saves without a checksum have structural/version checks only.
Checksums detect accidental changes; they are not authentication.
New saves use a versioned checksum with stable hexadecimal hash identities;
it does not depend on debug names registered during a particular game session.
Legacy checksums are still verified by their original algorithm. Saves rejected
by that older algorithm remain preserved until explicitly deleted. On the slot
screen, keyboard **X** or **Delete**, or controller **X**, clears an unavailable
slot as well as a readable one so it can be reused for a new game.
Migration never overwrites the original during load. Before applying an upgrade,
the first original is preserved and checked in `<slot>_pre_upgrade`. Normal
successful saves rotate `<slot>_backup`. Unversioned preferences are preserved
in `mvtk_settings_pre_upgrade_v0`. Backup failures block the corresponding
operation. Future/foreign saves never trigger fallback restoration; the slot
screen reports them unavailable and does not launch a fresh game over them.

## Stable authored identities

With the Defold 1.13.2 text-property update, new saves store authored gate,
collectible, inventory, fast-travel and flag IDs as text. Chest-opened and
wall-broken flags retain their hexadecimal hash suffixes, including secret-wall
visibility. Saves from earlier betas are not expected to carry over; this
change adds no identifier migration or legacy hash-key adoption. Start a fresh
slot when testing this update.

Room IDs come from the exported room name. Baked object IDs use the existing
`room_type_TiledObjectID` rule. Keep the room name, resolved object type and
Tiled numeric ID stable after release. Moving an object preserves its ID;
deleting/recreating it usually does not. Explicit IDs such as `chest_id`,
`wall_id`, boss and teleporter IDs must remain stable and must be changed when
making a separate copy that must not share state. Tiled gameplay objects stay
on the top-level `templates` layer. Regeneration does not mint new identities.

Before renaming or copying released content, capture a review snapshot:

```text
lua tools/audit_content_identity.lua snapshot .build/before.lua
```

After editing and exporting the rooms, compare it:

```text
lua tools/audit_content_identity.lua compare .build/before.lua .build/remap.lua
```

The optional remap file explicitly pairs removed IDs with their replacements:

```lua
return {
    rooms = {old_room = "new_room"},
    objects = {old_room_chest_7 = "new_room_chest_7"},
}
```

The audit reports removed identities, changed properties and literal references
still pointing to renamed identities. It rejects missing destinations,
many-to-one remaps, and remapping copies whose originals still exist. It emits
reviewable save aliases for checkpoint/world rooms, discovery, and chest/wall
flags. Other providers require explicit review. This audit does not rewrite
Tiled files or validate every typed relationship; that is Phase 3's work.

Review the report's `aliases`, then place the approved entries in
`developer/config/save_migrations.lua` under `identifier_aliases`. Paths target
the actual stored payload, including provider data and any legacy mirror.
Chest/wall aliases use `hash_prefix` because their runtime keys contain Defold
hex hashes. Keep those rules; changing their text changes their identity.
Each applied rule is recorded in save metadata so later progress at the new
identity is not overwritten by its retained old alias. Cycles, ambiguous
merges and conflicting first-time destination values block the upgrade.

Keep backups and test with an older save in a disposable project before
releasing a content rename. Re-export the layout and regenerate rooms; retain
the permanent game ID for a compatible update to the same game.

Completion uses the version 1 `game_completion` checkpoint provider. Older saves
without this provider begin incomplete; loading another slot clears the previous
slot's completion and playtime. Keep `game_completion.id` stable when changing
ending text, art or credits. Renaming it creates a different completion identity
and requires an explicit save migration if existing finished games should remain
finished. Test both Continue policies after changing a return room or checkpoint.
