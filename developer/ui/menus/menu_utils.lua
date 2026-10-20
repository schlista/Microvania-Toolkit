-- developer/ui/menus/menu_utils.lua
-- Shared GUI helpers for runtime-built menus.

local M = {}

function M.node(id)
    local ok, node = pcall(gui.get_node, id)
    return ok and node or nil
end

function M.set_active(self, on, input_controller)
    self.active = on and true or false
    msg.post(".", self.active and "enable" or "disable")
    if self.active then
        msg.post(".", "acquire_input_focus")
        if input_controller and input_controller.set_blocked then
            input_controller.set_blocked(true)
        end
    else
        msg.post(".", "release_input_focus")
        if input_controller and input_controller.set_blocked then
            input_controller.set_blocked(false)
        end
    end
end

function M.set_status(node, text, is_error, good_color, bad_color)
    gui.set_text(node, text or "")
    gui.set_color(node, is_error and bad_color or good_color)
end

return M
