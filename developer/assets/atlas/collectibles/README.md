# Collectible source art

Most files in this folder are the toolkit's existing collectible sprites and
atlases. `key_gold.png` was created for the four-room Tiled template test world
on 2026-07-10 using OpenAI image generation, then chroma-keyed and reduced with
nearest-neighbor sampling to an original 64 x 64 RGBA pixel-art sprite. It is
used by the `gold` animation in `keys.atlas` and the `key_gold` collectible
configuration.

Creators can replace `key_gold.png` with their own 64 x 64 transparent RGBA
art without changing framework code. Keep the filename and atlas animation ID
stable, or update the corresponding entry in `keys.atlas` and
`developer/config/collectible_types.lua` together.
