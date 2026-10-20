-- mvtk/core/rumble.lua
-- Platform-friendly rumble/vibrate wrapper. No-ops where unsupported.

local M = {}

-- strength: 0..1, duration_ms: integer
function M.play(strength, duration_ms)
  -- Desktop gamepad rumble is not available in stock Defold; this stub uses
  -- sys.vibrate on mobile platforms as a fallback.
  local info = sys.get_sys_info and sys.get_sys_info() or {}
  local osname = info.system_name or ""
  if osname == "Android" or osname == "iPhone OS" then
    local secs = math.max(0.01, (tonumber(duration_ms) or 50) / 1000)
    pcall(sys.vibrate, secs)
  end
end

return M


