-- Layout Editor progression controls. Analysis is explicit, never per-frame.
local Session=require "developer.tools.progression_session"
local UI=require "mvtk.editor.layout_editor.ui"
local Defaults=require "developer.config.progression_analysis"
local M={}
local modes={"areas","edges","objectives","diagnostics","abilities","items","flags","presets","start"}
local mode_labels={areas="Areas",edges="Gates",objectives="Objectives",diagnostics="Diagnostics",abilities="Abilities",items="Items",flags="Flags",presets="Presets",start="Start"}
local function color(settings,status)
    local c=settings[status] or {0.95,0.95,0.95,1}; return vmath.vector4(c[1],c[2],c[3],c[4])
end
-- size is relative to settings.scale; both default to the editor button size.
local function text(parent,x,y,value,size,settings)
    local n=gui.new_text_node(vmath.vector3(x,y,0.01),value)
    gui.set_parent(n,parent,false); gui.set_font(n,settings.font or "ui_font")
    local scale=(settings.scale or 1)*(size or 1)
    gui.set_pivot(n,gui.PIVOT_NW); gui.set_scale(n,vmath.vector3(scale,scale,1))
    return n
end
local function button(p,parent,x,y,w,label,fn)
    local n=gui.new_box_node(vmath.vector3(x,y,0.01),vmath.vector3(w,28,0))
    gui.set_parent(n,parent,false); gui.set_pivot(n,gui.PIVOT_NW)
    gui.set_color(n,vmath.vector4(0.13,0.22,0.3,1))
    text(n,6,-5,label,1,p.settings)
    p.buttons[#p.buttons+1]={node=n,run=fn}; return n
end
local function clear(p)
    if p.panel then gui.delete_node(p.panel); p.panel=nil end
    p.buttons={}
end
local function restore(self)
    for _,r in pairs(self.rooms or {}) do
        if r._progression_label and r.label_node then
            gui.set_text(r.label_node,r._progression_label); gui.set_color(r.label_node,r._progression_color)
            r._progression_label=nil; r._progression_color=nil
        end
    end
end
local function annotate(self,result,settings)
    restore(self)
    for id,r in pairs(self.rooms or {}) do
        local statuses,lines={},{}
        for area,value in pairs(result.areas) do if result.graph.areas[area].room==id:gsub("^/+","") then
            statuses[value.status]=true; lines[#lines+1]="[" .. value.status .. "] " .. area:match(":(.*)$")
        end end
        table.sort(lines)
        if r.label_node and #lines>0 then
            r._progression_label=gui.get_text(r.label_node); r._progression_color=gui.get_color(r.label_node)
            gui.set_text(r.label_node,r._progression_label .. "\n" .. table.concat(lines,"\n"))
            gui.set_color(r.label_node,color(settings,statuses.unknown and "unknown" or statuses.blocked and "blocked" or "reachable"))
        end
    end
end
local draw
local function signature(self)
    local out={}
    for id,r in pairs(self.rooms or {}) do
        local pos=r.base_pos or {}; out[#out+1]=id .. ":" .. tostring(pos.x) .. ":" .. tostring(pos.y) .. ":" .. tostring(r.group)
    end
    table.sort(out); return table.concat(out,"|")
end
local function run(self)
    local p=self.progression_panel
    local ok,result=pcall(function() return Session.run(p.session,{root=p.root(),layout=p.layout()}) end)
    p.error=not ok and tostring(result) or nil
    if ok then p.settings=result.config.ui or p.settings; annotate(self,result,p.settings); p.signature=signature(self)
    else p.session.result=nil; restore(self) end
    draw(self)
end
draw=function(self)
    local p=self.progression_panel; clear(p)
    if not p.open then restore(self); return end
    local c=self.canvas
    p.panel=gui.new_box_node(vmath.vector3(c.x+8,c.y+c.h-72,0.9),vmath.vector3(math.min(c.w-16,650),430,0))
    gui.set_parent(p.panel,self.n_root,false); gui.set_pivot(p.panel,gui.PIVOT_NW)
    gui.set_color(p.panel,vmath.vector4(0.04,0.07,0.1,0.98))
    local s=p.session; local r=s.result
    button(p,p.panel,8,-8,62,"Run",function() run(self) end)
    button(p,p.panel,76,-8,130,mode_labels[s.mode],function()
        for i,m in ipairs(modes) do if m==s.mode then s.mode=modes[i%#modes+1]; s.selected=1; s.page=1; break end end; draw(self)
    end)
    button(p,p.panel,212,-8,68,"Apply",function() Session.edit(s,1); run(self) end)
    button(p,p.panel,286,-8,32,"+",function() Session.edit(s,1); run(self) end)
    button(p,p.panel,324,-8,32,"-",function() Session.edit(s,-1); run(self) end)
    button(p,p.panel,362,-8,60,"Close",function() p.open=false; draw(self) end)
    local title=p.error and "Analysis failed; see Console" or r and
        ((r.complete and "Snapshot" or "INCOMPLETE") .. " | " .. r.preset .. " | campaign: " .. r.campaign) or "Run to analyze current placement"
    text(p.panel,10,-43,title,1,p.settings)
    if p.error then print("[PROGRESSION] " .. p.error) end
    local rows=Session.rows(s); local count=math.max(1,math.min(10,p.settings.rows or 10))
    local first=(s.page-1)*count+1
    for i=first,math.min(#rows,first+count-1) do
        local row=rows[i]; local index=i
        local n=button(p,p.panel,10,-70-(i-first)*25,math.min(c.w-40,620),
            (s.selected==i and "> " or "") .. row.text,function() s.selected=index; draw(self) end)
        local tint=color(p.settings,row.status)
        gui.set_color(n,vmath.vector4(tint.x*0.2,tint.y*0.2,tint.z*0.2,1))
    end
    button(p,p.panel,10,-329,65,"Prev",function() s.page=math.max(1,s.page-1); draw(self) end)
    button(p,p.panel,82,-329,65,"Next",function() s.page=math.min(math.max(1,math.ceil(#rows/count)),s.page+1); draw(self) end)
    text(p.panel,155,-335,string.format("Page %d / %d",s.page,math.max(1,math.ceil(#rows/count))),1,p.settings)
    local detail=(rows[s.selected] and rows[s.selected].detail) or p.error or "Choose a row. Colored map labels also show status text."
    -- Wrap long acquisition paths; the complete path is always in the report.
    local lines={}; for chunk in detail:gmatch("[^\n]+") do
        while #chunk>88 do lines[#lines+1]=chunk:sub(1,88); chunk=chunk:sub(89) end; lines[#lines+1]=chunk
    end
    text(p.panel,10,-365,table.concat(lines,"\n",1,math.min(3,#lines)),0.9,p.settings)
    text(p.panel,10,-412,"Full paths: developer/assets/tiled/progression_diagnostics.txt",0.8,p.settings)
end
function M.init(self,root,layout)
    if not (Defaults.ui and Defaults.ui.enabled) then return end
    local p={root=root,layout=layout,session=Session.new(),settings=Defaults.ui or {},buttons={}}
    self.progression_panel=p
    p.toggle=gui.new_box_node(vmath.vector3(self.canvas.x+140,self.canvas.y+self.canvas.h-22,0.9),vmath.vector3(160,30,0))
    gui.set_parent(p.toggle,self.n_root,false); gui.set_pivot(p.toggle,gui.PIVOT_NW)
    gui.set_color(p.toggle,vmath.vector4(0.13,0.22,0.3,1))
    text(p.toggle,8,-6,"Progression",1,p.settings)
end
function M.on_input(self,id,action)
    local p=self.progression_panel
    if not p or not action or not action.pressed or (id~=hash("touch") and id~=hash("mouse_button_1")) then return false end
    if UI.point_in_node(p.toggle,action.x,action.y) then p.open=not p.open; if p.open then run(self) else draw(self) end; return true end
    for _,b in ipairs(p.buttons) do if UI.point_in_node(b.node,action.x,action.y) then b.run(); return true end end
    return p.open and UI.point_in_node(p.panel,action.x,action.y) or false
end
function M.update(self)
    local p=self.progression_panel
    if p and p.open and p.signature and p.signature~=signature(self) then
        restore(self); p.session.result=nil; p.signature=nil
        p.error="Placement changed. Run analysis again."; draw(self)
    end
end
function M.resize(self)
    local p=self.progression_panel; if not p then return end
    gui.set_position(p.toggle,vmath.vector3(self.canvas.x+140,self.canvas.y+self.canvas.h-22,0.9))
    if p.open then draw(self) end
end
return M
