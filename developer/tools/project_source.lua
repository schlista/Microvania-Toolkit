-- Leaf helpers for reading authored Lua tables. Validators depend on these
-- helpers, never on another validator, so Defold's build graph stays acyclic.
local M = {}

function M.read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local text = f:read("*a"); f:close(); return text
end

function M.load_table(text, path)
    if not text then return nil, "Missing " .. path end
    -- Data-only vector constructors let editor/headless validation read config
    -- literals without engine APIs or mutation of the host's vmath global.
    local env = setmetatable({ vmath = {
        vector3 = function(x,y,z) return {x=x or 0,y=y or 0,z=z or 0} end,
        vector4 = function(x,y,z,w) return {x=x or 0,y=y or 0,z=z or 0,w=w or 0} end,
    } }, { __index = _G })
    env._G = env
    local chunk, err
    if loadstring then
        chunk, err = loadstring(text, "@" .. path)
        if chunk then setfenv(chunk, env) end
    else
        -- Lua 5.2+ hosts only; the linter's Lua 5.1 load() takes two arguments.
        ---@diagnostic disable-next-line: redundant-parameter
        chunk, err = load(text, "@" .. path, "t", env)
    end
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then return nil, tostring(value) end
    return value
end

return M
