# Tiled object artwork and interaction areas

Player, enemy and boss rendering keep their existing setup. Other room objects
use artwork from Tiled collection-of-images or sprite-sheet tilesets. Create Rooms generates the
Defold rendering resources; do not select a prefab sprite or gameplay atlas.

## Rectangle templates with linked artwork

1. Place the gameplay template on the top-level `templates` object layer.
2. Resize its rectangle to the desired interaction area. Keys, abilities, save
   points, NPCs, signs, levers and stations now use rectangles. Image dimensions
   do not change a separately authored rectangle.
3. Insert an image or sprite-sheet tile as a **tile object**, set its Class to
   `object_art`, and select the gameplay template in its `owner_ref` property.
4. Position and resize the image independently. Several images can select the
   same owner. Use ordinary, non-parallax object layers for gameplay artwork.
5. Save the map and tileset, then Export Current Room.

An unowned `object_art` image is decoration. An owned image follows its owner's
translation and is removed when its owner is consumed. Ownership is explicit;
overlapping images are never automatically associated with a trigger.

## One image object with its own behavior

For a simple pickup, assign the image tile the `item_art` class in the tileset
editor and set `item_type` to the collectible type, such as `key` or
`health_small`. Place it with Insert Tile on `templates`. Its displayed image
rectangle is also its pickup area. Per-instance properties such as `key_id`,
`amount`, and `respawns` override the tile's defaults.

For another behavior, set the image object's Class to the existing behavior
type, for example `save_point` or `collectible`, and add that behavior's
properties. The rectangle-template workflow exposes the full grouped property
UI and is preferable when the interaction area differs from the artwork.

## Catalog images and dropped items

Collection-image tiles with a non-empty `item_type` or `asset_name` form the artwork
catalog. Their tileset must be added to at least one exported room. A tile does
not have to be placed in that room to be included in the catalog.

Use `asset_name` for named decoration selected by a rectangle's `art_item`,
such as save-point artwork. It does not give the image collectible behavior.
If both names are set, `item_type` selects the catalog entry's name.

Set the tile's `item_width` and `item_height` to its desired game-pixel size
for drops and inherited artwork. Zero uses the PNG's native size. This keeps
high-resolution source images from producing oversized pickups; placed image
objects still use the width and height drawn in Tiled.

Create Rooms generates the item atlas and config from these tiles. Enemy drops
use the catalog. A rectangle collectible without linked images also inherits
its collectible type's catalog image. Any behavior rectangle can select a
catalog image using `art_item`. Missing explicit selections and conflicting
catalog definitions stop generation with an error.

The simple currency-drop artwork is selected by `currency_item` in
`developer/config/object_art.lua`. Its reward amount remains independent.
Importing a catalog with no item images removes the old pickup placeholder;
add the image definitions before testing visible drops.

## Optional states

### Animated sprite-sheet artwork

Use Tiled's Tile Animation Editor on a sprite-sheet tile, then place that tile
as linked `object_art`. Create Rooms preserves its frame order and individual
frame durations. Resize the tile object to its intended game size; the source
sheet's frame dimensions do not have to match the map grid for object artwork.
The source PNG remains intact and all art instances are baked into the room.

For retractable hazards, set a Boolean `hazard_active` property on **each source
frame tile**: true for damaging frames, false for safe frames. Link the animated
tile to the hazard with `owner_ref`, and leave `art_state` as `default`. Its Tiled
frame timing then controls both the animation and damage cycle; `extend_time`
and `retract_time` remain the fallback for hazards without such animation.
`start_retracted` starts at the first safe frame. Use the same sequence for
multiple art tiles linked to one hazard, since they share its clock. Remove the
old painted spike cells to avoid drawing a static duplicate underneath.

Room 19's `pt4_retracting_spikes.tsx` demonstrates this: 2000 ms fully extended,
120 ms lowering, 120 ms nearly down, 2520 ms retracted, then two 120 ms rising
frames. Only the fully extended frame damages the player. The base remains
visible throughout the safe interval.

### State images

The image's `art_state` defaults to `default`. Use `always` for artwork that
should remain visible across state changes. Other images can use these states:

| Behavior | States |
|---|---|
| Chest | `closed`, `locked`, `opened` |
| Lever / pressure plate | `off`, `on` |
| Station | `default`, `depleted`, `used` where supported |
| Door / gate | `closed`, `opened` |

When an alternate state has no image, the default artwork remains. Existing
door settings that hide artwork when open still apply. Single-use chests and
stations retain their artwork; use count and availability do not imply removal.

## Optional feedback

Applicable templates expose an **art_feedback** group:

- `consume_effect`: particle ID played after a successful pickup or destruction.
- `interact_effect`: particle ID played after a successful retained interaction
  or opening. Both effect selections default to `none`.
- `effect_offset_x` / `effect_offset_y`: offset in game pixels from the object's
  center; positive Y is up.
- `effect_scale`: size multiplier for the particle component.
- `effect_cooldown`: minimum interval between interaction effects, in seconds.

Effect IDs resolve through `developer/config/particle_effects.lua`; put custom
particle resources under `developer/assets/fx/` and import assets. Interaction
effects must be one-shot. Their complete authored particle resource is baked,
including all emitters. An item tile's `consume_effect` configures its drops.

Consumed artwork and collision disappear immediately while a separately baked
effect holder lets the feedback finish. Loading a collected/opened state never
replays its interaction effects. Existing per-template sound choices continue
to control sound feedback.

## Identity and verification

Keep an object's Tiled ID when changing artwork. A blank `collectible_id` uses
the existing room/type/object ID; an explicit ID survives shape changes and is
checked for duplicates across the exported rooms. Clear an explicit ID when
duplicating a pickup that should be independently collectible.

Restart Defold after updating the editor Lua modules, then run **Reload Editor
Scripts → Import Assets → Create Rooms → Validate All → Build**. Re-export maps
after changing templates. Old generated collections keep their previous
resources until regenerated. Check trigger edges, consume/revisit/save-load,
retained interactions, and particle playback in-engine.
