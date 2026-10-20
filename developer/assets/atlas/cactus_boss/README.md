# Cactus Boss Attack Sheet

`cactus_boss_attacks_sheet.png` is a 4-column by 3-row RGBA spritesheet.
Every cell is 362 x 362 pixels. Frames read from left to right:

- `attack_1`: double-arm ground slam
- `attack_2`: radial needle volley
- `attack_3`: horizontal charge toward screen-right

Each attack uses anticipation, wind-up, contact/release, and recovery poses.
Trigger the gameplay hit, projectile spawn, or dash burst on frame 3. The charge
frames can be flipped horizontally in the boss controller when moving left.

The sibling `cactus_boss.atlas` exposes the animations using the toolkit's
generic `attack_1`, `attack_2`, and `attack_3` boss animation contract. It also
provides a single-frame `idle` fallback using the final slam recovery pose. The
individual transparent frame PNGs are the runtime atlas inputs; the combined
sheet is retained as the editable/source asset.
