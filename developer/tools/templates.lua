-- developer/tools/templates.lua
-- Copy safe, style-agnostic templates into your project.
--
-- Usage:
--   lua developer/tools/templates.lua list
--   lua developer/tools/templates.lua copy enemy
--   lua developer/tools/templates.lua copy boss
--   lua developer/tools/templates.lua copy gate
--   lua developer/tools/templates.lua copy collectible

local H = require "developer.tools.dev_helpers"

local ROOT = H.get_project_root()
local TPL_DIR = ROOT .. "/mvtk/templates"
local DEST_DIR = ROOT .. "/developer/config"

local map = {
    enemy = { src = TPL_DIR .. "/enemy_examples.lua", dest = DEST_DIR .. "/enemy_examples.lua" },
    boss = { src = TPL_DIR .. "/boss_examples.lua", dest = DEST_DIR .. "/boss_examples.lua" },
    gate = { src = TPL_DIR .. "/gate_examples.lua", dest = DEST_DIR .. "/gate_examples.lua" },
    collectible = { src = TPL_DIR .. "/collectible_examples.lua", dest = DEST_DIR .. "/collectible_examples.lua" },
}

local function list()
    print("Available templates:")
    for key, cfg in pairs(map) do
        print(("- %-12s %s"):format(key, cfg.src))
    end
end

local function copy(kind)
    local cfg = map[kind]
    if not cfg then
        print("Unknown template kind: " .. tostring(kind))
        list()
        os.exit(1)
    end
    if H.file_exists(cfg.dest) then
        print("Skip: " .. cfg.dest .. " already exists")
        return
    end
    H.ensure_dir(cfg.dest, true)
    H.copy_file(cfg.src, cfg.dest)
    print("Copied " .. cfg.src .. " -> " .. cfg.dest)
end

local cmd = arg[1]
if cmd == "list" or cmd == nil then
    list()
elseif cmd == "copy" then
    copy(arg[2])
else
    print("Usage: lua developer/tools/templates.lua [list|copy <enemy|boss|gate|collectible>]")
end
