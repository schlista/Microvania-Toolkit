-- developer/config/biomes.lua
-- Define biomes with metadata used across systems (colors, audio, tilesets, etc.)

local v4 = vmath and vmath.vector4 or function(r,g,b,a) return {x=r,y=g,z=b,w=a} end

local M = {
  cavern = {
    name = "Crystal Cavern", -- Shared biome for the twenty-room 16px demo.
    color = v4(0.58, 0.54, 0.71, 1.00), -- Slate map tint; wet rooms use their Tiled teal tint.
  },
  ice = {
    name = "Ice Cavern", -- Biome shared by the ten-room 32px sample.
    color = v4(0.46, 0.80, 0.91, 1.00), -- Cyan map tint; Tiled room colors take precedence.
  },
  default = {
    name  = "Default",
    color = v4(0.80, 0.93, 0.99, 1.00), -- minimap outline tint
  },
  factory = {
    name  = "Factory",
    color = v4(0.95, 0.80, 0.20, 1.00),
  },
  forest = {
    name  = "Duskwood Cliffs", -- Lanternfall's twilight cliffs and hanging pines.
    color = v4(0.36, 0.53, 0.85, 1.00),
  },
  graveyard = {
    name  = "Graveyard",
    color = v4(0.70, 0.70, 0.80, 1.00),
  },
  catacombs = {
    name  = "Moonlit Sanctuary", -- Aureole's violet final vaults and star halls.
    color = v4(0.55, 0.52, 0.68, 1.00),
  },
  ruins = {
    name  = "Gilded Approach", -- Lanternfall's sunset palace, where the journey starts.
    color = v4(0.89, 0.63, 0.29, 1.00),
  },
  foundry = {
    name  = "Molten Capital", -- Lanternfall's lava sea and foundry spires.
    color = v4(0.88, 0.35, 0.16, 1.00),
  },
  sanctum = {
    name  = "Amethyst Hollow", -- Lanternfall's crystal caves and the Rite of Dawn.
    color = v4(0.75, 0.38, 0.82, 1.00),
  },
}

return M
