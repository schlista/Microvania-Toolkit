-- tools/generate_rooms.lua
-- Standalone script to generate room collections, factories, and configs.
-- Run this before building with bob.jar from the command line.
-- Usage: lua tools/generate_rooms.lua
--
-- This is automatically handled by the Defold editor hooks (hooks.editor_script),
-- but when building via bob.jar CLI (e.g., VSCode tasks or build_debug.bat), it
-- must be run manually or via the build scripts.
--
-- The hooks pipeline is split across four files (see hooks.editor_script):
--   1. hooks/editor_core.lua       — publishes shared context table
--   2. hooks/editor_script.lua     — populates more context (returns true)
--   3. hooks/editor_generators.lua — registers gen_collection helpers
--   4. hooks/editor_commands.lua   — returns the M module with get_maintenance_commands()
-- This script mirrors that boot order so the headless run produces the same
-- result as the Defold-editor hook path.

-- Ensure we're in the project root
local test = io.open("game.project", "r")
if not test then
    -- Try to cd to the project root
    local script_dir = arg and arg[0] and arg[0]:match("(.+)[/\\]") or "."
    local project_root = script_dir:match("(.+)[/\\]tools$") or script_dir:match("(.+)[/\\]")
    if project_root then
        local lfs_ok, lfs = pcall(require, "lfs")
        if lfs_ok and lfs.chdir then
            lfs.chdir(project_root)
        end
    end
    test = io.open("game.project", "r")
    if not test then
        print("[generate_rooms] ERROR: Must be run from project root (where game.project is)")
        os.exit(1)
    end
end
test:close()

-- Set up package path
package.path = package.path .. ";./?.lua;./?/init.lua"

print("[generate_rooms] Running room generation...")

-- Step 1: editor_core.lua — sets up hooks.core.context
local ok_core, core_err = pcall(dofile, "hooks/editor_core.lua")
if not ok_core then
    print("[generate_rooms] ERROR loading editor_core: " .. tostring(core_err))
    os.exit(1)
end

-- Step 2: editor_script.lua — populates more context (returns true)
local ok_script, script_err = pcall(dofile, "hooks/editor_script.lua")
if not ok_script then
    print("[generate_rooms] ERROR loading editor_script: " .. tostring(script_err))
    os.exit(1)
end

-- Step 3: editor_generators.lua — registers generator helpers
local ok_gen, gen_err = pcall(dofile, "hooks/editor_generators.lua")
if not ok_gen then
    print("[generate_rooms] ERROR loading editor_generators: " .. tostring(gen_err))
    os.exit(1)
end

-- Step 4: editor_commands.lua — returns the M module with get_maintenance_commands()
local ok_cmd, M = pcall(dofile, "hooks/editor_commands.lua")
if not ok_cmd then
    print("[generate_rooms] ERROR loading editor_commands: " .. tostring(M))
    os.exit(1)
end

if type(M) ~= "table" or type(M.get_maintenance_commands) ~= "function" then
    print("[generate_rooms] ERROR: editor_commands did not return a module with get_maintenance_commands()")
    os.exit(1)
end

local commands = M.get_maintenance_commands()
if type(commands) ~= "table" then
    print("[generate_rooms] ERROR: get_maintenance_commands() did not return a table")
    os.exit(1)
end

local regenerate
for _, command in ipairs(commands) do
    if command.id == "mvtk.regenerate_rooms" then
        regenerate = command
        break
    end
end

if not (regenerate and type(regenerate.run) == "function") then
    print("[generate_rooms] ERROR: mvtk.regenerate_rooms command not found")
    os.exit(1)
end

local gen_ok, gen_err2 = pcall(regenerate.run)
if not gen_ok then
    print("[generate_rooms] ERROR during generation: " .. tostring(gen_err2))
    os.exit(1)
end

print("[generate_rooms] Room generation completed successfully!")
