-- mvtk/fx/fx.lua
-- moved from modules/fx/fx.lua

local M = {}
M.enabled = true

local function get_fx_manager()
  if not M.enabled then return nil end
  return msg.url("main:/fx_manager")
end

function M.on_land(ctx)
  if not M.enabled then return end
  local fx_manager = get_fx_manager()
  if fx_manager and go.exists(fx_manager) then
    local p = (ctx and ctx.pos) or go.get_position()
    pcall(msg.post, fx_manager, hash("play_fx"), { fx_type = "land", position = p })
  end
end

-- Play any effect registered in developer/config/fx_types.lua at a world position.
function M.play(fx_type, pos)
  if not M.enabled or type(fx_type) ~= "string" or fx_type == "" then return end
  local fx_manager = get_fx_manager()
  if fx_manager and go.exists(fx_manager) then
    local p = pos or go.get_position()
    pcall(msg.post, fx_manager, hash("play_fx"), { fx_type = fx_type, position = p })
  end
end

function M.on_dash(ctx)
  if not M.enabled then return end
  local fx_manager = get_fx_manager()
  if fx_manager and go.exists(fx_manager) then
    local p = (ctx and ctx.pos) or go.get_position()
    pcall(msg.post, fx_manager, hash("play_fx"), { fx_type = "dash", position = p })
  end
end

return M

