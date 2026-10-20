-- Keep the actionable error in the UI; traceback details stay in the console.
local M={}
function M.message(err)
    local reason=tostring(err or "Unknown export error. See the console.")
    reason=reason:gsub("\r\n","\n"):gsub("\nstack traceback:.*$","")
    reason=reason:gsub("^[^\n]-:%d+:%s*","")
    return "Export stopped. Previous published files were kept.\n\n"..reason
        .."\n\nPress a key or click to return."
end
return M
