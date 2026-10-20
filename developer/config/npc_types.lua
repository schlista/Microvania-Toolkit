--- NPC Type Definitions
-- Define reusable NPC types for your game
-- Referenced by Tiled object spawning
--
-- @module npc_types

local M = {}

-- Story NPCs
M.guide = {
    name = "Mentor",
    sprite = "npc_mentor",
    dialogue_id = "mentor_tutorial",
}

M.lore_keeper = {
    name = "Sage",
    sprite = "npc_sage",
    dialogue_id = "sage_lore",
}

-- Functional NPCs
M.save_point_keeper = {
    name = "Guardian",
    sprite = "npc_guardian",
    dialogue_id = "save_point_dialogue",
}

M.fast_travel_operator = {
    name = "Mystic",
    sprite = "npc_mystic",
    dialogue_id = "fast_travel_dialogue",
}

-- Desert NPCs
M.desert_hermit = {
    name = "Desert Hermit",
    sprite = "npc_elder",
}

M.desert_coyote = {
    name = "Desert Coyote",
    sprite = "npc_idle",
}

-- Generic NPCs
M.villager_male = {
    name = "Villager",
    sprite = "npc_villager_male",
    dialogue_id = "generic_villager",
}

M.villager_female = {
    name = "Villager",
    sprite = "npc_villager_female",
    dialogue_id = "generic_villager",
}

return M
