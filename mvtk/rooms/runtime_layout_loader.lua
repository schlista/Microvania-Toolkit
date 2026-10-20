local M = {}

local RUNTIME_MODULE = "developer.runtime.layout.world_layout"
local LOCAL_LAYOUT_PATH = "./developer/runtime/layout/world_layout.local.lua"
local LOCAL_RESOURCE_PATH = "/developer/runtime/layout/world_layout.local.lua"

local function decode(src)
    local loader = loadstring or load
    if not loader or type(src) ~= "string" or src == "" then
        return nil, "Exported world layout is empty or unreadable. Run Layout Editor Export."
    end
    local chunk, compile_err = loader(src)
    if not chunk then
        return nil, compile_err
    end
    local ok_eval, data = pcall(chunk)
    if not ok_eval or type(data) ~= "table" or type(data.rooms) ~= "table" then
        return nil, "Invalid exported world layout: " .. tostring(data)
    end
    return data
end

local function load_from_disk(path)
    if not (io and io.open) then return nil end
    local fh = io.open(path, "r")
    if not fh then return nil end
    local src = fh:read("*a")
    fh:close()
    return decode(src)
end

function M.load(opts)
    opts = opts or {}

    local disk_data, disk_err = load_from_disk(opts.local_path or LOCAL_LAYOUT_PATH)
    if type(disk_data) == "table" then
        return disk_data, "disk"
    end
    if disk_err then return nil, disk_err end

    -- A bundled custom resource is inside the game archive, not a loose file.
    if sys and sys.load_resource then
        local ok, src = pcall(sys.load_resource, opts.resource_path or LOCAL_RESOURCE_PATH)
        if ok and src then
            local data, err = decode(src)
            if data then return data, "resource" end
            return nil, err
        end
    end

    if package and package.loaded and opts.reload_module and package.loaded[RUNTIME_MODULE] then
        package.loaded[RUNTIME_MODULE] = nil
    end

    -- Keep this require literal so Bob includes the compiled fallback module.
    local ok_mod, runtime = pcall(function()
        return require "developer.runtime.layout.world_layout"
    end)
    if ok_mod and type(runtime) == "table" then
        return runtime, "module"
    end

    return nil, disk_err or runtime
end

return M
