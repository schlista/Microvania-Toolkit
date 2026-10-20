-- developer/config/items.lua
-- Define items available in the game

local M = {
  potion_small = { id = "potion_small", name = "Small Potion", price = 25, desc = "Heals a small amount.", heal = 1 },
  potion_large = { id = "potion_large", name = "Large Potion", price = 75, desc = "Heals a large amount.", heal = 3 },
  map_fragment = { id = "map_fragment", name = "Map Fragment", price = 50, desc = "Reveals nearby rooms.", reveal_radius = 1600 },
  charm_slot   = { id = "charm_slot", name = "Charm Slot", price = 120, desc = "Adds a charm slot." },
  upgrade_material = { id = "upgrade_material", name = "Upgrade Material", price = 40, desc = "Used for crafting and upgrades." },
}

return M
