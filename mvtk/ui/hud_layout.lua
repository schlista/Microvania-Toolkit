-- Pure HUD placement shared by runtime and designer preview.
local Model=require "mvtk.core.creator_settings_model"
local Letterbox=require "mvtk.render.letterbox"
local M={}
function M.theme(baseline,layout,overrides)
    local theme=Model.copy(baseline)
    local presets=require "developer.config.ui_theme_examples"
    Model.merge(theme,presets[layout.theme_preset] or {})
    return Model.merge(theme,overrides or {})
end
function M.entry(layout,name,overrides)
    local entry=Model.copy(layout[name] or {})
    Model.merge(entry,((layout.presets or {})[layout.active_preset] or {})[name] or {})
    Model.merge(entry,(overrides or {})[name] or {})
    return entry
end
-- Width, height and element extents below are design pixels, never window pixels.
function M.position(entry,width,height)
    local anchor=entry.anchor or "top_left"; local offset=entry.offset or {}
    local right=anchor:find("right",1,true); local center=anchor:find("center",1,true)
    local bottom=anchor:find("bottom",1,true)
    local x=right and width or center and width/2 or 0
    local y=bottom and 0 or height
    -- Existing layout offsets are signed: negative Y moves down from the top.
    x=x+(right and -math.abs(offset.x or 0) or (offset.x or 0)); y=y+(bottom and math.abs(offset.y or 0) or (offset.y or 0))
    return x,y,bottom and (right and "SE" or center and "S" or "SW") or (right and "NE" or center and "N" or "NW")
end
function M.top_left(entry,width,height,element_width,element_height)
    local x,y,pivot=M.position(entry,width,height)
    if pivot=="NE" or pivot=="SE" then x=x-element_width
    elseif pivot=="N" or pivot=="S" then x=x-element_width/2 end
    if pivot=="SW" or pivot=="SE" or pivot=="S" then y=y+element_height end
    return x,y
end
-- Global HUD nodes can be children of different authored roots. Resolve their
-- configured design position once, then convert for gui.set_screen_position.
function M.screen_top_left(entry,rect,element_width,element_height)
    if not rect then return nil,nil end
    local x,y=M.top_left(entry,rect.design_w,rect.design_h,element_width,element_height)
    return Letterbox.design_to_screen(x,y,rect)
end
return M
