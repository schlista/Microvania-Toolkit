-- Leaf module: do not depend on resolved config or save providers here.
local Config = require "developer.config.persistence_settings"
local M = {}

function M.identity()
    local identity = Config.game_id
    if type(identity) ~= "string" or identity:match("^%s*$") then
        identity = sys and sys.get_config and sys.get_config("project.title", "Microvania Toolkit")
            or "Microvania Toolkit"
    end
    return tostring(identity)
end

function M.for_identity(identity, scope)
    identity = tostring(identity)
    -- Keep paths portable while distinguishing titles that sanitize identically.
    local checksum = 0
    for i = 1, #identity do checksum = (checksum * 131 + identity:byte(i)) % 2147483647 end
    local name = identity:lower():gsub("[^a-z0-9_-]", "_"):sub(1, 48)
    local app = "mvtk_" .. name .. "_" .. string.format("%08x", checksum)
    if scope and scope ~= "player" then app = app .. "_" .. scope end
    return app
end

function M.app_id(scope) return M.for_identity(M.identity(), scope) end

function M.game_id() return Config.game_id end

function M.path(file, scope)
    if sys and sys.get_save_file then return sys.get_save_file(M.app_id(scope), file) end
    return M.app_id(scope) .. "/" .. file
end

return M
