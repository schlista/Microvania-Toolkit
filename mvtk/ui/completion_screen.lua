local Viewport = require "mvtk.ui.viewport"
local Pages = require "mvtk.ui.completion_pages"
-- Shared runtime/temporary-preview presentation; this module never saves state.
local M={}
local function clear(s) if s.root then gui.delete_node(s.root); s.root=nil end end
local function text(s,x,y,value,scale,width)
    local n=gui.new_text_node(vmath.vector3(x,y,0),value)
    gui.set_parent(n,s.root,false); gui.set_font(n,s.font)
    gui.set_scale(n,vmath.vector3(scale,scale,1)); gui.set_size(n,vmath.vector3(width or 850,440,0))
    gui.set_line_break(n,true); return n
end
local function draw(s)
    clear(s)
    local w,h=Viewport.design_size()
    s.root=gui.new_box_node(vmath.vector3(w/2,h/2,0),vmath.vector3(w,h,0))
    gui.set_color(s.root,vmath.vector4(0.025,0.035,0.06,1))
    local page=s.content[s.page+1]
    local title,body=page.title,page.body
    if s.error then title="Completion could not be saved"; body=s.error.."\nProgress remains in this session. Retry saving before leaving." end
    local has_art=s.cfg.artwork~="" and not s.error and s.page==0 and s.artwork
    if has_art then
        local art=gui.new_box_node(vmath.vector3(-290,0,0),vmath.vector3(220,180,0))
        gui.set_parent(art,s.root,false); gui.set_texture(art,"artwork"); gui.play_flipbook(art,s.cfg.artwork)
    end
    text(s,0,210,title,s.cfg.text_scale or 0.8)
    text(s,has_art and 130 or 0,-20,body,s.cfg.text_scale or 0.8,has_art and 530 or 850)
    local help=s.error and "Enter / A: Retry save     Escape / B: Keep playing"
        or (s.page<s.pages and "Enter / A / Right: Credits / Next" or "Enter / A: Return to menu").."\nLeft: Previous     Escape / B: "..(s.preview and "Close preview" or "Return to menu")
    text(s,0,-230,help,0.55)
end
function M.open(cfg,data,opts)
    opts=opts or {}; local s={cfg=cfg,data=data or {},font=opts.font or cfg.font or "default",page=0,
        error=opts.error,preview=opts.preview,artwork=opts.artwork,close=opts.close,retry=opts.retry,credits={}}
    local metadata
    s.content,metadata=Pages.build(cfg,s.data)
    s.credits,s.per_page=metadata.credits,metadata.per_page
    s.pages=#s.content-1; draw(s); return s
end
function M.close(s) clear(s); if s.close then s.close() end end
function M.input(s,id,action)
    if not action.pressed then return true end
    if id==hash("key_escape") or id==hash("gamepad_rpad_right") then M.close(s)
    elseif id==hash("key_left") or id==hash("gamepad_lpad_left") then s.page=math.max(0,s.page-1); draw(s)
    elseif id==hash("key_enter") or id==hash("gamepad_rpad_down") or id==hash("key_right") or id==hash("gamepad_lpad_right") then
        if s.error then clear(s); if s.retry then s.retry() end
        elseif s.page>=s.pages then M.close(s)
        else s.page=s.page+1; draw(s) end
    end
    return true
end
return M
