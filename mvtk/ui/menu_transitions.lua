local Viewport = require "mvtk.ui.viewport"
-- mvtk/developer/ui/menu_transitions.lua
-- Animation library for menu transitions
-- Provides fade, slide, scale, and custom animations for GUI elements

local M = {}

-- Load UI theme for animation durations
local ThemeOk, Theme = pcall(require, "developer.config.ui_theme")
if not ThemeOk or not Theme then
  Theme = { animations = { menu_fade_in = 0.2, menu_fade_out = 0.15, menu_slide = 0.25 } }
end

-----------------------------------------------------------
-- Easing Functions
-----------------------------------------------------------

local easing = {}

-- Linear (no easing)
function easing.linear(t)
  return t
end

-- Ease in (accelerating)
function easing.ease_in(t)
  return t * t
end

-- Ease out (decelerating)
function easing.ease_out(t)
  return t * (2 - t)
end

-- Ease in-out (accelerate then decelerate)
function easing.ease_in_out(t)
  if t < 0.5 then
    return 2 * t * t
  else
    return -1 + (4 - 2 * t) * t
  end
end

-- Ease out cubic (smooth deceleration)
function easing.ease_out_cubic(t)
  local t1 = t - 1
  return t1 * t1 * t1 + 1
end

-- Ease in cubic (smooth acceleration)
function easing.ease_in_cubic(t)
  return t * t * t
end

-- Elastic (bouncy)
function easing.elastic(t)
  if t == 0 or t == 1 then return t end
  local p = 0.3
  local s = p / 4
  return math.pow(2, -10 * t) * math.sin((t - s) * (2 * math.pi) / p) + 1
end

-- Back (overshoot then settle)
function easing.back(t)
  local s = 1.70158
  return t * t * ((s + 1) * t - s)
end

-----------------------------------------------------------
-- Transition Functions
-----------------------------------------------------------

-- Fade in: Animate alpha from 0 to target
-- @param node: GUI node to animate
-- @param duration: Animation duration in seconds
-- @param target_alpha: Target alpha value (default 1.0)
-- @param ease_func: Easing function name (default "ease_out")
-- @param callback: Optional callback when complete
function M.fade_in(node, duration, target_alpha, ease_func, callback)
  if not node then return end

  duration = duration or Theme.animations.menu_fade_in or 0.2
  target_alpha = target_alpha or 1.0

  local color = gui.get_color(node)
  local start_alpha = 0
  color.w = start_alpha
  gui.set_color(node, color)
  gui.set_enabled(node, true)

  gui.animate(node, gui.PROP_COLOR, vmath.vector4(color.x, color.y, color.z, target_alpha),
              gui.EASING_LINEAR, duration, 0, callback)
end

-- Fade out: Animate alpha from current to 0
function M.fade_out(node, duration, ease_func, callback)
  if not node then return end

  duration = duration or Theme.animations.menu_fade_out or 0.15

  local color = gui.get_color(node)

  local function on_complete()
    gui.set_enabled(node, false)
    if callback then callback() end
  end

  gui.animate(node, gui.PROP_COLOR, vmath.vector4(color.x, color.y, color.z, 0),
              gui.EASING_LINEAR, duration, 0, on_complete)
end

-- Slide in from direction
-- @param direction: "left", "right", "up", "down"
function M.slide_in(node, direction, duration, ease_func, callback)
  if not node then return end

  duration = duration or Theme.animations.menu_slide or 0.25
  ease_func = ease_func or "ease_out_cubic"

  local final_pos = gui.get_position(node)
  local w, h = Viewport.design_size()
  local start_pos = vmath.vector3(final_pos)

  -- Calculate off-screen start position
  if direction == "left" then
    start_pos.x = -w
  elseif direction == "right" then
    start_pos.x = w
  elseif direction == "up" then
    start_pos.y = h
  elseif direction == "down" then
    start_pos.y = -h
  end

  gui.set_position(node, start_pos)
  gui.set_enabled(node, true)

  gui.animate(node, gui.PROP_POSITION, final_pos,
              gui.EASING_OUTCUBIC, duration, 0, callback)
end

-- Slide out to direction
function M.slide_out(node, direction, duration, ease_func, callback)
  if not node then return end

  duration = duration or Theme.animations.menu_slide or 0.25
  ease_func = ease_func or "ease_in_cubic"

  local w, h = Viewport.design_size()
  local final_pos = vmath.vector3(gui.get_position(node))

  -- Calculate off-screen end position
  if direction == "left" then
    final_pos.x = -w
  elseif direction == "right" then
    final_pos.x = w
  elseif direction == "up" then
    final_pos.y = h
  elseif direction == "down" then
    final_pos.y = -h
  end

  local function on_complete()
    gui.set_enabled(node, false)
    if callback then callback() end
  end

  gui.animate(node, gui.PROP_POSITION, final_pos,
              gui.EASING_INCUBIC, duration, 0, on_complete)
end

-- Scale in (from 0 to 1)
function M.scale_in(node, duration, target_scale, ease_func, callback)
  if not node then return end

  duration = duration or Theme.animations.menu_fade_in or 0.2
  target_scale = target_scale or 1.0
  ease_func = ease_func or "ease_out_cubic"

  gui.set_scale(node, vmath.vector3(0, 0, 1))
  gui.set_enabled(node, true)

  gui.animate(node, gui.PROP_SCALE, vmath.vector3(target_scale, target_scale, 1),
              gui.EASING_OUTCUBIC, duration, 0, callback)
end

-- Scale out (from current to 0)
function M.scale_out(node, duration, ease_func, callback)
  if not node then return end

  duration = duration or Theme.animations.menu_fade_out or 0.15
  ease_func = ease_func or "ease_in_cubic"

  local function on_complete()
    gui.set_enabled(node, false)
    if callback then callback() end
  end

  gui.animate(node, gui.PROP_SCALE, vmath.vector3(0, 0, 1),
              gui.EASING_INCUBIC, duration, 0, on_complete)
end

-----------------------------------------------------------
-- Combined Transitions
-----------------------------------------------------------

-- Fade + Scale combo (common for pop-up menus)
function M.popup_in(node, duration, callback)
  if not node then return end

  duration = duration or 0.25

  gui.set_scale(node, vmath.vector3(0.8, 0.8, 1))
  local color = gui.get_color(node)
  color.w = 0
  gui.set_color(node, color)
  gui.set_enabled(node, true)

  -- Animate scale
  gui.animate(node, gui.PROP_SCALE, vmath.vector3(1, 1, 1),
              gui.EASING_OUTCUBIC, duration)

  -- Animate alpha
  color.w = 1
  gui.animate(node, gui.PROP_COLOR, color,
              gui.EASING_OUTQUAD, duration, 0, callback)
end

function M.popup_out(node, duration, callback)
  if not node then return end

  duration = duration or 0.2

  local color = gui.get_color(node)

  local function on_complete()
    gui.set_enabled(node, false)
    if callback then callback() end
  end

  -- Animate scale
  gui.animate(node, gui.PROP_SCALE, vmath.vector3(0.8, 0.8, 1),
              gui.EASING_INCUBIC, duration)

  -- Animate alpha
  color.w = 0
  gui.animate(node, gui.PROP_COLOR, color,
              gui.EASING_INQUAD, duration, 0, on_complete)
end

-----------------------------------------------------------
-- Utility Transitions
-----------------------------------------------------------

-- Shake (for error feedback)
function M.shake(node, intensity, duration, callback)
  if not node then return end

  intensity = intensity or 5
  duration = duration or 0.3

  local original_pos = gui.get_position(node)
  local shake_count = 0
  local shake_interval = 0.05

  local function do_shake()
    shake_count = shake_count + 1
    if shake_count * shake_interval >= duration then
      gui.set_position(node, original_pos)
      if callback then callback() end
      return
    end

    local offset_x = (math.random() - 0.5) * intensity * 2
    local offset_y = (math.random() - 0.5) * intensity * 2
    local shake_pos = vmath.vector3(original_pos.x + offset_x, original_pos.y + offset_y, original_pos.z)

    gui.animate(node, gui.PROP_POSITION, shake_pos, gui.EASING_LINEAR, shake_interval, 0, do_shake)
  end

  do_shake()
end

-- Pulse (scale up and down)
function M.pulse(node, scale_max, duration, callback)
  if not node then return end

  scale_max = scale_max or 1.1
  duration = duration or 0.5

  local original_scale = gui.get_scale(node)

  local function pulse_out()
    gui.animate(node, gui.PROP_SCALE, original_scale,
                gui.EASING_INOUTSINE, duration / 2, 0, callback)
  end

  gui.animate(node, gui.PROP_SCALE, vmath.vector3(scale_max, scale_max, 1),
              gui.EASING_INOUTSINE, duration / 2, 0, pulse_out)
end

-- Flash (quick color change and back)
function M.flash(node, flash_color, duration, callback)
  if not node then return end

  flash_color = flash_color or vmath.vector4(1, 1, 0, 1)  -- Yellow
  duration = duration or 0.3

  local original_color = gui.get_color(node)

  local function flash_out()
    gui.animate(node, gui.PROP_COLOR, original_color,
                gui.EASING_LINEAR, duration / 2, 0, callback)
  end

  gui.animate(node, gui.PROP_COLOR, flash_color,
              gui.EASING_LINEAR, duration / 2, 0, flash_out)
end

-----------------------------------------------------------
-- Instant Transitions (No Animation)
-----------------------------------------------------------

function M.show(node)
  if not node then return end
  gui.set_enabled(node, true)
  local color = gui.get_color(node)
  color.w = 1
  gui.set_color(node, color)
end

function M.hide(node)
  if not node then return end
  gui.set_enabled(node, false)
end

-----------------------------------------------------------
-- Transition Presets by Name
-----------------------------------------------------------

-- Execute transition by name (for config-driven transitions)
function M.execute(node, transition_type, direction, duration, callback)
  if not node then return end

  transition_type = transition_type or "fade"

  if transition_type == "fade_in" then
    M.fade_in(node, duration, nil, nil, callback)
  elseif transition_type == "fade_out" then
    M.fade_out(node, duration, nil, callback)
  elseif transition_type == "slide_in" then
    M.slide_in(node, direction or "left", duration, nil, callback)
  elseif transition_type == "slide_out" then
    M.slide_out(node, direction or "left", duration, nil, callback)
  elseif transition_type == "scale_in" then
    M.scale_in(node, duration, nil, nil, callback)
  elseif transition_type == "scale_out" then
    M.scale_out(node, duration, nil, callback)
  elseif transition_type == "popup_in" then
    M.popup_in(node, duration, callback)
  elseif transition_type == "popup_out" then
    M.popup_out(node, duration, callback)
  elseif transition_type == "instant" or transition_type == "show" then
    M.show(node)
    if callback then callback() end
  elseif transition_type == "hide" then
    M.hide(node)
    if callback then callback() end
  else
    -- Default to fade
    M.fade_in(node, duration, nil, nil, callback)
  end
end

-----------------------------------------------------------
-- Stop all animations on a node
-----------------------------------------------------------

function M.cancel(node)
  if not node then return end

  gui.cancel_animations(node, gui.PROP_POSITION)
  gui.cancel_animations(node, gui.PROP_SCALE)
  gui.cancel_animations(node, gui.PROP_COLOR)
end

return M
