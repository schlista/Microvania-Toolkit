-- tools/reset_config_tables.lua
--
-- Build-time helper for the sample-asset strip (tools/lib_sample_strip.ps1).
-- Empties the config tables whose entries belong to the maintainer's worlds in
-- a STAGED copy of the project, keeping each file's documentation:
--   developer/config/secret_rooms.lua       (training-world secret rooms)
--   developer/config/narrative/cutscenes.lua (sample cutscenes)
--   developer/config/narrative/videos.lua    (sample video clips)
-- Uses the same module as Reset Project to Empty
-- (mvtk/editor/config_table_reset.lua).
--
-- Operates only on the staging directory passed as the first argument; it must
-- never be pointed at the live working tree. A missing file is left missing.
--
-- Usage:  lua tools/reset_config_tables.lua <staging_root>

local CONFIG_TABLES = {
    "developer/config/secret_rooms.lua",
    "developer/config/narrative/cutscenes.lua",
    "developer/config/narrative/videos.lua",
}

local staging = arg and arg[1]
if not staging or staging == "" then
    io.stderr:write("reset_config_tables: missing <staging_root> argument\n")
    os.exit(1)
end
staging = staging:gsub("\\", "/"):gsub("/+$", "")

-- Use the staged copy of the reset module as the single definition of "empty".
package.path = staging .. "/?.lua;" .. package.path
local ok, Reset = pcall(require, "mvtk.editor.config_table_reset")
if not ok then
    io.stderr:write("reset_config_tables: cannot load mvtk.editor.config_table_reset from staging: " .. tostring(Reset) .. "\n")
    os.exit(1)
end

for _, relative in ipairs(CONFIG_TABLES) do
    local path = staging .. "/" .. relative
    local fh = io.open(path, "rb")
    if fh then
        local text = fh:read("*a")
        fh:close()
        local emptied, err = Reset.empty(text)
        if not emptied then
            io.stderr:write("reset_config_tables: " .. relative .. ": " .. tostring(err) .. "\n")
            os.exit(1)
        end
        local out = assert(io.open(path, "wb"))
        out:write(emptied)
        out:close()
    end
end
