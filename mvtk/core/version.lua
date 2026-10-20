-- mvtk/core/version.lua
-- Single source of truth for the MV Toolkit version string.
-- Update this value when cutting a new release; all generators read from here.

local M = {}

M.NAME    = "MV Toolkit"
M.VERSION = "1.0 Alpha"
M.STRING  = M.NAME .. " v" .. M.VERSION

return M
