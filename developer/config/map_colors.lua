-- Shared fill colors for the exported minimap and full world map.
-- Rebuild and export the layout after changing these settings.
return {
    -- False uses default_fill for every room, ignoring biome colors globally.
    biome_colors_enabled = true,
    -- Fallback RGBA bytes (0..255) for rooms without a color or known biome.
    -- Alpha also controls opacity for all biome tints; Tiled color alpha is ignored.
    default_fill = { 42, 68, 92, 200 },
    -- In Tiled: Map Properties -> add a Color custom property named biome_color.
    -- Its RGB overrides developer/config/biomes.lua's color for that room's biome.
    -- Tiled's built-in Background Color does not affect the in-game maps.
}
