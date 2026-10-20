-- Picture framing for every game screen, menu and creator tool.
-- The design size comes from game.project display.width/display.height.
-- Other window shapes fit that picture uniformly and show opaque bars.
return {
    -- Bar colour in RGB, with each component from 0 (none) to 1 (full).
    -- Alpha is always opaque so scenes cannot draw into the bars.
    -- Black is the default; for dark grey, use r = 0.08, g = 0.08, b = 0.08.
    letterbox_color = { r = 0, g = 0, b = 0 },
}
