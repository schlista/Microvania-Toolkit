-- Pure argv builders for platform image-crop tools.
local M = {}

local function ps_single_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

function M.build_process(platform, tool, src_abs, dst_abs, x, y, w, h, to_os_path)
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    to_os_path = to_os_path or function(value) return value end

    if platform == "windows" then
        local script = string.format(
            "& { Add-Type -AssemblyName System.Drawing; " ..
            "$src=%s; $dst=%s; " ..
            "$bmp=[System.Drawing.Bitmap]::FromFile($src); " ..
            "try { $rect=New-Object System.Drawing.Rectangle(%d,%d,%d,%d); " ..
            "$crop=$bmp.Clone($rect, $bmp.PixelFormat); " ..
            "try { $crop.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png) } " ..
            "finally { $crop.Dispose() } } finally { $bmp.Dispose() } }",
            ps_single_quote(to_os_path(src_abs)),
            ps_single_quote(to_os_path(dst_abs)),
            x, y, w, h
        )
        return tool or "powershell", {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script,
        }
    elseif platform == "macos" then
        return tool or "sips", {
            "--cropOffset", tostring(y), tostring(x),
            "--cropToHeightWidth", tostring(h), tostring(w),
            tostring(src_abs), "--out", tostring(dst_abs),
        }
    end

    return tool or "magick", {
        tostring(src_abs),
        "-crop", string.format("%dx%d+%d+%d", w, h, x, y),
        "+repage",
        tostring(dst_abs),
    }
end

return M
