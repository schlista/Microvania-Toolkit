local M = {}

-- Desktop CLI check: the camera config and GUI/project design dimensions must
-- agree. Parsing supplied text keeps filesystem access out of runtime validation.
function M.validate(config, project_text)
  local errors, display = {}, {}
  local section
  for line in (tostring(project_text or "") .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("[;#].*$", "")
    local heading = line:match("^%s*%[([^%]]+)%]%s*$")
    if heading then
      section = heading
    elseif section == "display" then
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key == "width" or key == "height" then display[key] = tonumber(value) end
    end
  end
  local window_config = type(config) == "table" and config.window or nil
  for _, axis in ipairs({ "width", "height" }) do
    local actual = display[axis]
    local target = type(window_config) == "table" and window_config["target_" .. axis] or nil
    if type(actual) ~= "number" or actual ~= actual or actual <= 0 or actual == math.huge or actual % 1 ~= 0 then
      errors[#errors + 1] = "game.project display." .. axis .. " must be a positive integer"
    elseif type(target) ~= "number" or target ~= actual then
      errors[#errors + 1] = "game_config.window.target_" .. axis .. " (" .. tostring(target)
        .. ") must match game.project display." .. axis .. " (" .. tostring(actual) .. ")"
    end
  end
  return errors
end

return M
