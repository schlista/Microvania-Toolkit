-- Asset reference checks shared by editor preparation and the command line.
-- Callers supply I/O so the editor can read staged resources. No writes,
-- subprocesses, host exits, or persistent filesystem caches belong here.
local M = {}

function M.scan(opts)
    local root = opts.root:gsub("\\", "/"):gsub("/+$", "")
    local report = {missing = {}, warnings = {}}
    local existence = {}
    local function missing(message) report.missing[#report.missing + 1] = message end
    local function warn(message) report.warnings[#report.warnings + 1] = message end
    local function exists(path)
        if existence[path] == nil then existence[path] = opts.exists(path) == true end
        return existence[path]
    end
    local function visit(relative, extension, required, check)
        local directory = root .. "/" .. relative
        local dirs, files = opts.list(directory)
        if not dirs and not files then
            if required then warn("Asset directory missing: " .. directory) end
            return
        end
        for _, name in ipairs(files or {}) do
            if name:match(extension) then
                local path = directory .. "/" .. name
                local text = opts.read(path)
                if text then check(path, text)
                else missing("Cannot read asset definition: " .. path) end
            end
        end
    end
    local function check_tilesource(path, text, required)
        local target = text:match('tile_set:%s*"([^"]+)"')
        if not target then
            if required then warn("No tile_set in " .. path) end
        else
            local absolute = root .. "/" .. target:gsub("^/", "")
            if not exists(absolute) then missing("tile_set for " .. path .. ": " .. absolute) end
        end
    end
    visit("developer/assets/tiled/maps", "%.tilemap$", true, function(path, text)
        check_tilesource(path, text, true)
    end)
    for _, directory in ipairs({"developer/assets/sprites", "developer/game"}) do
        visit(directory, "%.sprite$", false, check_tilesource)
    end
    local function check_images(path, text)
        local count = 0
        for image in text:gmatch('image:%s*"([^"]+)"') do
            count = count + 1
            local absolute = root .. "/" .. image:gsub("^/", "")
            if not exists(absolute) then missing("atlas image in " .. path .. ": " .. absolute) end
        end
        if count == 0 then warn("No images referenced in " .. path) end
    end
    visit("developer/assets/atlas", "%.atlas$", true, check_images)
    visit("developer/assets/atlas", "%.tilesource$", false, check_images)
    table.sort(report.missing)
    table.sort(report.warnings)
    report.ok = #report.missing == 0
    return report
end

function M.format(report, limit)
    local lines = {}
    for _, group in ipairs({{report.missing, "FAIL", "Missing assets"}, {report.warnings, "WARN", "Warnings"}}) do
        local entries = group[1]
        if #entries > 0 then
            lines[#lines + 1] = string.format("[%s] %s (%d):", group[2], group[3], #entries)
            local shown = math.min(#entries, limit or #entries)
            for i = 1, shown do lines[#lines + 1] = " - " .. entries[i] end
            if shown < #entries then lines[#lines + 1] = " - " .. (#entries - shown) .. " additional finding(s)." end
        end
    end
    if #lines == 0 then lines[1] = "[OK] Asset scan passed (tilemaps, sprites, atlases)" end
    return table.concat(lines, "\n")
end

return M
