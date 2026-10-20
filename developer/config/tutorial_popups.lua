-- developer/config/tutorial_popups.lua
-- Tutorial popup definitions and triggers.
-- Each entry: id key -> { title/body text, trigger_flag to set, condition.event it listens for, position hint }.

return {
    popups = {
        jump = {
            title = "Jump",
            body = "Use your Jump action to clear obstacles.",
            trigger_flag = "first_jump_shown", -- Flag set after showing (prevents repeats)
            condition = { event = "first_jump" }, -- Raised from input_controller on first jump
        },
        dash = {
            title = "Dash",
            body = "Use your Slide / Air Dash action. Hold it after a ground slide to run when Dash is unlocked.",
            trigger_flag = "first_dash_shown", -- Prevent repeats
            condition = { event = "first_dash" }, -- Shared Slide / Air Dash press in input_controller
        },
        map = {
            title = "Map",
            body = "Open the map to see explored rooms.",
            trigger_flag = "map_popup_shown", -- Prevent repeats
            condition = { event = "opened_map" }, -- From input_controller when map opened
            position = "top", -- Optional: "top"|"center"|"bottom"
        },
    }
}
