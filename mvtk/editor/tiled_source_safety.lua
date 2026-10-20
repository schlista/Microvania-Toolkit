-- Reset preflight for Tiled authoring data. No writes and no engine APIs.
-- Every disposable copy needs an exporter receipt naming an available original
-- outside this project, plus the fingerprint of the last exported copy.
local M = {}

local function clean(path)
    path = tostring(path or ""):gsub("\\", "/")
    local prefix = path:match("^[A-Za-z]:/") or (path:sub(1, 2) == "//" and "//")
        or (path:sub(1, 1) == "/" and "/") or ""
    local parts = {}
    for part in path:sub(#prefix + 1):gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return prefix .. table.concat(parts, "/")
end

function M.is_inside(path, root)
    path, root = clean(path), clean(root):gsub("/+$", "")
    if root:match("^[A-Za-z]:") or root:sub(1, 2) == "//" then
        path, root = path:lower(), root:lower()
    end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

M.fingerprint = require("mvtk.core.adler32").fingerprint

local source_extensions = {
    tmx=true, tsx=true, tx=true, world=true, png=true, jpg=true, jpeg=true,
    bmp=true, gif=true, webp=true, svg=true, aseprite=true,
}

local function read_receipt(path, read)
    return tostring(read(path .. ".mvtk-source") or ""):match("^([^\r\n]+)\r?\n([^\r\n]+)")
end

local function original_is_external(original, root)
    return original and (original:match("^[A-Za-z]:[/\\]") or original:sub(1, 1) == "/")
        and not M.is_inside(original, root)
end

-- Import Assets makes tileset-named aliases of exported images. Carry their
-- existing receipt only when both files match the recorded exported bytes.
-- Import uses project copies; availability of originals is checked at reset.
function M.receipt_for_copy(source, destination, root, read)
    local original, fingerprint = read_receipt(source, read)
    if not original_is_external(original, root) then return nil end
    local data = read(source)
    if not data or M.fingerprint(data) ~= fingerprint or read(destination) ~= data then
        return nil
    end
    return original .. "\n" .. fingerprint .. "\n"
end

function M.check_copy(path, root, read, external_attributes)
    local original, fingerprint = read_receipt(path, read)
    if not original then return "No verified external original: " .. path end
    if not original_is_external(original, root) then
        return "Original is not outside the Defold project: " .. original
    end
    -- Editor io.open cannot read outside the project. Query the external file
    -- API there; keep binary reads for the project copy and its fingerprint.
    -- Headless callers can still verify the original with their normal reader.
    local available
    if external_attributes then
        local ok, attrs = pcall(external_attributes, original)
        available = ok and type(attrs) == "table" and attrs.exists == true and attrs.is_file == true
    else
        available = read(original) ~= nil
    end
    if not available then return "External original is unavailable: " .. original end
    local copy = read(path)
    if not copy or M.fingerprint(copy) ~= fingerprint then
        return "Project copy changed since export; preserve these edits externally first: " .. path
    end
end

function M.check(root, list_dir, read, external_attributes)
    local errors = {}
    local function visit(dir)
        local dirs, files = list_dir(dir, { force_process = true })
        for _, name in ipairs(files or {}) do
            local path = dir .. "/" .. name
            local ext = name:match("%.([^%.]+)$")
            -- The reset baseline retains these engine bootstrap resources.
            if ext and source_extensions[ext:lower()] and
                path ~= root .. "/developer/assets/tilesheets/defold_sample.png" then
                local err = M.check_copy(path, root, read, external_attributes)
                if err then errors[#errors + 1] = err end
            end
        end
        for _, name in ipairs(dirs or {}) do visit(dir .. "/" .. name) end
    end
    for _, folder in ipairs({"maps", "tilesets", "backgrounds", "original_maps", "worlds"}) do
        visit(root .. "/developer/assets/tiled/" .. folder)
    end
    visit(root .. "/developer/assets/tilesheets")
    table.sort(errors)
    return #errors == 0, errors
end

return M
