local M = {}

local function build_env(module)
    local env = { _G = _G }
    return setmetatable(env, {
        __index = _G,
        __newindex = module,
    })
end

local function load_chunk(path, env)
    if type(loadfile) ~= "function" then
        return nil, "loadfile unavailable"
    end

    if setfenv then
        local chunk, err = loadfile(path)
        if not chunk then
            return nil, err
        end
        setfenv(chunk, env)
        return chunk
    end

    return loadfile(path, "bt", env)
end

function M.load(path)
    local module = {}
    local env = build_env(module)
    local chunk, err = load_chunk(path, env)
    if not chunk then
        error(string.format("Failed to load Defold script module '%s': %s", tostring(path), tostring(err)))
    end

    local result = chunk()
    if type(result) == "table" then
        return result
    end
    return module
end

return M
