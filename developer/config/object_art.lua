-- Defaults for artwork imported from Tiled collection-of-images tilesets.
return {
    -- Tiled item_type used by the simple currency-drop prefab. This selects
    -- artwork only; the enemy's configured amount still controls the reward.
    -- Add this item_type to an image tile in a tileset used by an exported room.
    currency_item = "gem_small",

    -- Default depth for gameplay images. An image object's art_z property
    -- overrides this value. Higher depths draw in front within the same pass.
    default_z = 0.01,

    -- With only a default image, mirror the lever when it switches on so its
    -- used state is visible. The flip is relative to the image's authored
    -- orientation. Art explicitly assigned art_state="on" takes precedence;
    -- art_state="always" decorations are never mirrored by this fallback.
    -- Use an empty table to keep default art unchanged in every lever state.
    lever_state_fallbacks = {
        -- Missing "on" artwork uses the default image with a horizontal flip.
        on = { flip_horizontal = true },
    },
    -- With only a default (closed) chest image, dim it once opened so the
    -- player can see the chest was used. alpha multiplies the image's opacity
    -- (1 = unchanged, 0 = invisible). Art with art_state="opened" wins.
    chest_state_fallbacks = {
        opened = { alpha = 0.55 },
    },
    -- Same for one-shot stations (map, health, energy) once used/depleted.
    station_state_fallbacks = {
        used = { alpha = 0.55 },
        depleted = { alpha = 0.55 },
    },
}
