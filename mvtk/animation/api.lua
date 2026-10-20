-- animation/api.lua
-- Thin helper to drive the controller via messages

local M = {}

local MSG_SET_STATE = hash("anim.set_state")
local MSG_PLAY_ONCE = hash("anim.play_once")
local MSG_SET_FACING= hash("anim.set_facing")

local function to_url(u)
  if type(u) == "userdata" or type(u) == "table" then return u end
  if type(u) == "string" then return msg.url(u) end
  return msg.url()
end

function M.set_state(url_or_nil, state, opts)
  local url = to_url(url_or_nil)
  local msgtbl = { state = state }
  if opts then
    if opts.once ~= nil then msgtbl.once = opts.once and true or false end
    if opts.force ~= nil then msgtbl.force = opts.force and true or false end
    if opts.blend then msgtbl.blend = tonumber(opts.blend) end -- spine only
    if opts.loop ~= nil then msgtbl.loop = opts.loop and true or false end -- spine override
  end
  msg.post(url, MSG_SET_STATE, msgtbl)
end

function M.play_once(url_or_nil, state, opts)
  local url = to_url(url_or_nil)
  local msgtbl = { state = state }
  if opts and opts.blend then msgtbl.blend = tonumber(opts.blend) end
  msgtbl.once = true
  msg.post(url, MSG_PLAY_ONCE, msgtbl)
end

function M.set_facing(url_or_nil, dir)
  local url = to_url(url_or_nil)
  -- dir: -1 for left, +1 for right
  msg.post(url, MSG_SET_FACING, { dir = (dir and dir < 0) and -1 or 1 })
end

return M

