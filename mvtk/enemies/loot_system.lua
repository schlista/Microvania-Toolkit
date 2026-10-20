-- mvtk/enemies/loot_system.lua
-- Enemy loot drop system with weighted random drops

local M = {}

-- Loot table configuration
M.loot_tables = {
    common = {
        { item = "health_small", chance = 0.7 },
        { item = "energy_small", chance = 0.5 },
        { item = "currency_small", chance = 0.3, amount = {5, 10} }
    },
    uncommon = {
        { item = "health_medium", chance = 0.5 },
        { item = "energy_medium", chance = 0.4 },
        { item = "currency_medium", chance = 0.6, amount = {10, 25} },
        { item = "upgrade_material", chance = 0.1 }
    },
    rare = {
        { item = "health_large", chance = 0.3 },
        { item = "energy_large", chance = 0.3 },
        { item = "upgrade_material", chance = 0.4 },
        { item = "currency_large", chance = 0.8, amount = {25, 50} },
        { item = "rare_item", chance = 0.05 }
    },
    boss = {
        { item = "ability_unlock", chance = 1.0 },  -- Guaranteed
        { item = "health_large", chance = 1.0 },
        { item = "currency_boss", chance = 1.0, amount = {100, 200} },
        { item = "boss_key", chance = 0.5 }
    },
    miniboss = {
        { item = "health_large", chance = 1.0 },
        { item = "energy_large", chance = 1.0 },
        { item = "currency_large", chance = 1.0, amount = {50, 100} },
        { item = "upgrade_material", chance = 0.8 },
        { item = "rare_item", chance = 0.3 }
    }
}

-- Item definitions for spawning
M.item_definitions = {
    health_small = { sprite = "icon_health_small", value = 10 },
    health_medium = { sprite = "icon_health_medium", value = 25 },
    health_large = { sprite = "icon_health_large", value = 50 },
    energy_small = { sprite = "icon_energy_small", value = 10 },
    energy_medium = { sprite = "icon_energy_medium", value = 25 },
    energy_large = { sprite = "icon_energy_large", value = 50 },
    currency_small = { sprite = "icon_coin", type = "currency" },
    currency_medium = { sprite = "icon_coin", type = "currency" },
    currency_large = { sprite = "icon_coin_large", type = "currency" },
    currency_boss = { sprite = "icon_coin_gold", type = "currency" },
    upgrade_material = { sprite = "icon_material", type = "material" },
    rare_item = { sprite = "icon_rare", type = "rare" },
    ability_unlock = { sprite = "icon_ability", type = "ability" },
    boss_key = { sprite = "icon_key", type = "key" }
}

--- Roll for loot drops based on table
-- @param loot_table_name Name of loot table (common, uncommon, rare, boss, miniboss)
-- @param position World position to spawn drops
-- @return Table of drops to spawn
function M.roll_drops(loot_table_name, position)
    local drops = {}
    local loot_table = M.loot_tables[loot_table_name]

    if not loot_table then
        print(string.format("[LOOT] Warning: Unknown loot table '%s'", tostring(loot_table_name)))
        return drops
    end

    for _, entry in ipairs(loot_table) do
        local roll = math.random()
        if roll < entry.chance then
            local drop = {
                item = entry.item,
                position = position,
                amount = 1
            }

            -- Handle variable amounts
            if entry.amount then
                drop.amount = math.random(entry.amount[1], entry.amount[2])
            end

            table.insert(drops, drop)
            print(string.format("[LOOT] Rolled: %s (x%d) from '%s' table", entry.item, drop.amount, loot_table_name))
        end
    end

    return drops
end

--- Spawn dropped items in world
-- @param drops Table of drops from roll_drops()
function M.spawn_drops(drops)
    if not drops or #drops == 0 then return end

    for i, drop in ipairs(drops) do
        -- Offset drops slightly so they don't overlap
        local offset_angle = (i / #drops) * math.pi * 2
        local offset_dist = 20
        local offset = vmath.vector3(
            math.cos(offset_angle) * offset_dist,
            math.sin(offset_angle) * offset_dist,
            0
        )

        local spawn_pos = drop.position + offset
        local item_def = M.item_definitions[drop.item]

        if item_def then
            -- Spawn the drop
            local ok, id = pcall(factory.create, "#drop_factory", spawn_pos, nil, {
                item_type = hash(tostring(drop.item or "")),
                amount = drop.amount,
                sprite = hash(tostring(item_def.sprite or ""))
            })

            if not ok then
                print(string.format("[LOOT] Failed to spawn drop: %s - %s", drop.item, tostring(id)))
            end
        else
            print(string.format("[LOOT] Unknown item definition: %s", drop.item))
        end
    end

    print(string.format("[LOOT] Spawned %d drops", #drops))
end

--- Configure custom loot table
-- @param table_name Name of new loot table
-- @param entries Table of loot entries
function M.add_loot_table(table_name, entries)
    M.loot_tables[table_name] = entries
    print(string.format("[LOOT] Added custom loot table: %s", table_name))
end

--- Configure custom item definition
-- @param item_name Item identifier
-- @param definition Item properties
function M.add_item_definition(item_name, definition)
    M.item_definitions[item_name] = definition
    print(string.format("[LOOT] Added item definition: %s", item_name))
end

--- Get loot table by name
-- @param table_name Name of loot table
-- @return Loot table or nil
function M.get_loot_table(table_name)
    return M.loot_tables[table_name]
end

return M
