# Grappling

The toolkit defaults to **tagged surfaces**, a fixed rope, and no hooks on
untagged walls. Authors choose the swing routes and mark them with visible art,
so players can read where the hook catches. Stop the game and tune the behaviour in **Project ▸ Game Settings… ▸ Grapple**.
The tab edits the window’s draft; **Save** publishes it. **Camera ▸ Launch room
preview** tries the draft in a copy of your published rooms without saving it
to the project.

## Choose where the hook catches

`player.grapple.targets` has two modes:

- `surfaces` (default): only objects in the `grapple` collision group catch.
  Use painted `grapple` layers, Physics ▸ Grapple Box and Grapple Slope, or
  Grapple Surface rectangles to mark them.
- `ceilings`: tagged surfaces still catch, and the downward-facing underside
  of terrain in `player_actions.grapple.latch_groups` also catches. The
  default terrain groups are `solid` and `world`. **Catch walls** additionally
  permits untagged wall faces in this mode.

Defold allows 16 collision group names in a running game, and mask names count
too. The toolkit uses all 16. Don't add new group or mask names to your own
objects: once the limit is reached, whichever group loads last stops colliding,
and that can be `grapple`. Reuse an existing group instead.

Floors never catch in either mode. Terrain in `block_groups` stops the hook
and cuts an attached rope; one-way platforms are deliberately excluded.
Tagged surfaces overlapping rock can catch within `occlusion_tolerance_px`,
but tags behind an obstruction cannot catch through it. In `surfaces` mode,
a vertical Grapple Surface rectangle can mark a wall without enabling
untagged walls elsewhere.

## Tag a room in Tiled

Paint any non-empty tile on a tile layer named `grapple` over the bottom row
of rock that should catch the hook. `new_room_blank` creates this layer;
existing rooms can add it manually. Tile identity and flip flags do not matter.
Multiple layers combine their paint, including layers inside groups with offsets.
Use finite maps and keep parallax at 1.

The layer adds no player collision or artwork, and its painted tiles are
hidden in game. Paint visible hooks, rings, rails or another clear marker on
your art layers. Open-air paint makes a hanging anchor; give it visible art too.
Create Rooms merges contiguous painted cells into static Grapple Surface
gameobjects baked into the room collection. They are editable in Defold;
nothing is created at runtime.

For individual bars or vertical tags, place
`tiled/templates/navigation/grapple_surface.tx` on the top-level `templates`
object layer and resize its rectangle. Overlap a ceiling underside, or put it
in open air with a visible chain and bar. These rectangles also bake into
editable gameobjects. Keep their collision group and mask set to `grapple`:
the self-mask preserves ray visibility in the tested engine and excludes
player contacts. An empty mask can make the box invisible to raycasts.

Export the room, then run **Project → Reload Editor Scripts → Prepare & Check
→ Build**. Validate All checks every painted strip's baked instance and group.

## Individual Grapple Points

Place `tiled/templates/navigation/grapple_point.tx` on the top-level
`templates` object layer for a small circular hook target. It bakes into
an editable static gameobject with collision group `grapple`, alongside
its visual component. It has no script properties to tune: hook behavior
comes from the Game Settings Grapple tab. Paint clear anchor art at that point.
Keep the target reachable and outside obstructing terrain, or overlap the
rock it marks within the normal occlusion tolerance.

## Exact shapes: Grapple Box and Grapple Slope

Use **Physics ▸ Grapple Box** for rectangles with rotation or sub-tile sizes,
and **Physics ▸ Grapple Slope** for polygons and sloped ceilings. These exact
shapes avoid a painted `grapple` strip hanging below sloped rock. Resize,
rotate or edit the polygon in Tiled, and place each object on the top-level
`templates` object layer.

Both templates are hook tags only: they add no player collision or artwork.
Pair them with solid tiles, Solid Box or Solid Slope where the player should
collide, and mark the catch point with visible art. Downward or sideways faces
catch; upward faces never catch. Grapple Slope starts with its long edge
facing down, and rotating it changes which faces can catch.

Overlap the rock being marked within `occlusion_tolerance_px` of the first
terrain hit so the hook can reach the tag. A tag behind an obstruction cannot
catch through it. For an open-air anchor, hang the shape with visible art.
Each placed shape bakes into its own editable static gameobject in the room
collection with group and mask `grapple`.

**Navigation ▸ Grapple Surface still works** in existing rooms. Prefer
Physics ▸ Grapple Box for new rectangular targets; Grapple Surface keeps its
existing rectangle bake and does not apply Tiled rotation.

## Aim and launch

By default, hold Grapple to stay attached; Left/Right pumps the swing, with
analog stick tilt controlling how hard you push. Release Grapple or press Jump
to let go. With **Stay hooked** on, button release keeps the rope attached;
press Grapple again or Jump to let go. The second press does not cast another
hook in the same frame. Jump-release spends no air jump.

To chain hooks, aim at the next gold rail or bar and hold Grapple after a fresh
press. If that press misses, it keeps trying for `recast_window_s` (default
0.3 seconds) while held, catching a target as it comes into reach. Button up,
attachment or expiry clears the window; zero disables it. Holding through an
automatic impact, room or lost-anchor release does not start another window.
Release and press again to try the next hook.

With `default_aim = "up"`, neutral or Up aims straight up, and a side input
aims diagonally up. Down is ignored, including diagonally downward stick input.
`default_aim = "forward"` instead aims diagonally toward facing when neutral.
`diagonal_angle_deg` sets that diagonal's angle above horizontal (45° by
default). Aim assistance tries nearby rays when the main ray misses: up to
`aim_assist_deg` (12°) on the ground, or `aim_assist_air_deg` (20°) while
airborne. Both use `aim_assist_step_deg` and never aim below horizontal;
setting the relevant assist angle to zero disables its extra rays.

When attaching from the ground, the rope shortens automatically until its
bottom arc clears the floor by `ground_clearance_px`. A low anchor refuses
the cast if it cannot leave the minimum rope length. A neutral upward cast
lifts into a hang; a diagonal cast while running pulls into a swing. The lift
settles without inward radial speed before ordinary swinging begins.

The rope keeps the length captured at attachment, or after the ground launch.
Enable **Extend / retract rope** to let Up shorten and Down lengthen it at `reel_speed`, clamped
between the minimum rope length and reach.

## What ends a rope

| Release | Velocity and follow-up |
| --- | --- |
| Let go: button up (Stay hooked off), second Grapple press (Stay hooked on), Jump, or maximum duration | Scales swing velocity by Momentum Kept, adds release boost/lift, starts carry and delays ladder grabbing. |
| Room exit | Keeps velocity and starts carry/ladder delay, without a boost. |
| Lost anchor or terrain cutting the rope | Keeps velocity and starts carry/ladder delay, without a boost. |
| Impact: landing, a fast wall hit, or a rising ceiling hit | Keeps post-collision velocity; adds no boost, carry or ladder delay. |

**Momentum Kept** applies only to player let-go releases. Room exits, lost
anchors and impacts keep their existing velocity behavior.

The hook cannot attach in a different streamed room, and leaving the anchor's
room releases it even while that room's geometry still exists. Rope checks
also release when an anchor disappears or terrain obstructs the line.

**Break on impact** is on by default. Gentle wall touches keep the rope;
`impact_release_speed` controls the wall/ceiling threshold. The initial
`attach_grace_s` and automatic ground lift protect a new attachment from
immediate impact release. Ladders cannot grab during a swing. After a
momentum-preserving release, `ladder_grab_delay_s` briefly prevents a ladder
from catching the player. Dash, stun, swimming, climbing, death, and teleport cancel the grapple and
clear carry.

## Tune the feel

The Game Settings **Grapple** tab holds the main tuning controls. Values
in pixels, speed and acceleration are base values: `player_scale` scales them
when `scale_movement` is enabled. Seconds, angles, switches and drag do not scale.

| Setting | What it changes |
| --- | --- |
| Grapple style (`mode`) | Swing hangs from the rope and lets Left/Right pump it. Pull moves straight toward the hook. |
| Hook catches / Catch walls | Which untagged terrain faces catch. Keep `surfaces` for authored routes. |
| Stay hooked (`stay_hooked`) | Off: hold the button to keep the rope. On: release the button and keep swinging; press again or Jump to let go. |
| Range | Maximum cast distance. A 45° diagonal needs about 1.42 times the vertical gap. Presets preserve room reach. |
| Swing Power | How quickly Left/Right pumping builds speed. |
| Swing Top Speed | Pumping cap. Gravity can exceed it, preserving pendulum energy. |
| Swing Fade (`swing_drag`) | How quickly swinging fades without steering. 0 never fades; the default 0.12 fades slowly. |
| Extend / retract rope / Reel Speed | Enable rope-length control and choose its rate. Ground lift still works with it off. |
| Pull Speed (`pull_speed`) | Base pixels per second toward the hook in Pull style. |
| Momentum Kept (`release_momentum_mult`) | Speed retained on let-go: 1 keeps all, 0.5 half, 0 none; above 1 slingshots. Boost and lift are added afterwards. |
| Carry Time | How long neutral input or a slower same-direction target keeps horizontal speed (default 0.35 seconds). Faster same-direction input accelerates normally. |
| Let-go Float (`release_gravity_mult`) | Gravity multiplier during airborne release carry (default 0.6). Lower gives more time to re-hook; 1 uses base gravity. |
| Re-hook Time (`recast_window_s`) | Seconds to retry a fresh missed press while Grapple stays held (default 0.3); zero disables it. |
| Let-go Boost | Horizontal push on let-go; at speed, it follows travel even if the stick points back. |
| Let-go Lift | Extra upward speed on let-go. |
| Break on impact | Whether landing and fast wall/ceiling hits end a swing. |

Numeric fields accept exact typed values and show range errors. Controls dim
and disable when they do not affect the current style or hook targets; their
saved values are retained.
Swing, reel and fade settings are used only in Swing style. Pull arrives then
drops unless `hold_at_anchor` is enabled; Stay hooked changes button release,
and does not change that arrival behavior.

Opposite input brakes carried momentum at the reduced `release_carry_brake`
rate. Landing, wall contact, a new attachment or a hard cancel clears carry.
Set carry time to zero to resume normal air braking immediately.

During airborne carry after let-go, a room exit or a lost anchor, gravity uses
`release_gravity_mult` without the fall or early-jump-release multipliers.
Holding Down still fast-falls. Normal gravity rules return when carry ends;
impact releases receive no float. The multiplier and rehook seconds do not
scale with `player_scale`.

Other commented `player_settings.grapple` values include minimum and
optional airborne rope length, launch clearance/speed, obstruction slack,
pull arrival distance, and `swing_speed_limit`. A safety limit of zero uses
three times the pumping cap. `player_settings.grapple` owns the authored
style (`mode`), Stay hooked, Swing Fade, Momentum Kept and Pull Speed, and
Game Settings publishes overrides for them in `creator_settings.lua`. These settings
take precedence over matching fallback keys in `player_actions.grapple`.
Aim assistance, target groups, release timing and the `rope_*` appearance keys
remain in `player_actions.grapple`; `hold_at_anchor` controls Pull's arrival.

`rope_z` is an offset from the player's world Z. Keep the result inside the
world camera range, and keep the rope sprite's local Z at zero so its bounds
are not culled before the shader draws the line. The current 0.90 player Z
and 0.02 rope offset put the rope at 0.92 inside the -1..1 camera range.

## Grant the ability

Enable Grapple in **Project ▸ Game Settings… ▸ Abilities** to start with it, or set
`abilities.grapple = true` in `developer/config/ability_defaults.lua`. This
startup setting takes precedence over `starts_unlocked` on a fresh game.
For an ability pickup, keep the startup setting false and keep
`starts_unlocked = false` in `developer/config/abilities.lua`.
`starts_unlocked = true` force-unlocks it on save load and can hide the pickup.

The Abilities checkbox decides only whether a new game starts with Grapple.
Grapple tuning applies whenever the ability is unlocked, including pickups
and restored saves or checkpoints. Fields depend on the selected grapple style
and targets, not on the starting-ability checkbox.

## Verification

Feel, rope rendering, collision and editor integration are **unverified until
in-engine play**. Headless tests cover the math, settings and baked data.
Check all-hit raycasts in the installed engine, ground launch, impacts, room
seams, ladder passes, release carry/float, held re-hook attempts, airborne aim
assistance, and disposable previews.

Any `hooks/` change stales the published world. Before testing or Export Game,
run **Project → Reload Editor Scripts → Prepare & Check → Build**. Restart the
editor if errors cite lines that no longer contain that code: required Lua
modules can remain cached. Export Game refuses until preparation runs again.
