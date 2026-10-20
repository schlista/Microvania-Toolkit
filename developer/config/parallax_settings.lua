-- Tiled built-in Parallax X/Y factors multiply through parent groups.
-- 1 follows the world, 0 stays with the camera, >1 is foreground scrolling.
-- Image layers and decorative image objects inherit these factors automatically.
return {
    -- Only decorative tile layers may move independently of room collision.
    -- Add a custom scenery layer name here, or set its Tiled boolean property
    -- parallax_visual=true. Keep solid/bounds/doors and gameplay layers at 1.
    tile_layers = {
        background_far=true, background=true, background_near=true,
        foreground_far=true, foreground=true, foreground_near=true,
    },
}
