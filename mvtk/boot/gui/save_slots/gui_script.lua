local Loader = require "mvtk.core.script_module_loader"

local source = debug.getinfo(1, "S").source or ""
local wrapper_path = source:sub(1, 1) == "@" and source:sub(2) or source
wrapper_path = wrapper_path:gsub("\\", "/")
local wrapper_dir = wrapper_path:match("^(.*)/[^/]+$") or "."

return Loader.load(wrapper_dir .. "/../save_slots.gui_script")
