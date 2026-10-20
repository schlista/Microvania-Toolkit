-- Disposable Tiled export: ordinary room baking creates every platform/object.
local Model=require "mvtk.core.creator_settings_model"
local PNG=require "mvtk.editor.layout_editor.png_writer"
local M={}
function M.files(cfg,tile)
    local w,h=cfg.floor_tiles,16
    local tw,th=tile.width,tile.height
    local gap=math.floor(w*0.6)
    assert(gap+cfg.gap_tiles<w-2,"Dash gap leaves no landing platform; increase course length or reduce gap")
    local solid,bounds={},{}
    for y=0,h-1 do for x=0,w-1 do
        bounds[#bounds+1]=(x==0 or x==w-1 or y==0 or y==h-1) and 1 or 0
        local floor=y>=h-3 and not (x>=gap and x<gap+cfg.gap_tiles)
        local step=x>=math.floor(w*0.3) and x<math.floor(w*0.3)+2 and y>=h-3-cfg.step_tiles
        solid[#solid+1]=(floor or step or x==0 or x==w-1) and 1 or 0
    end end
    local function layer(id,name,data,visible)
        return {id=id,name=name,type="tilelayer",width=w,height=h,x=0,y=0,visible=visible,opacity=1,encoding="lua",data=data,properties={}}
    end
    local room={version="1.10",luaversion="5.1",orientation="orthogonal",renderorder="right-down",
        width=w,height=h,tilewidth=tw,tileheight=th,properties={is_starting_room=true},
        tilesets={{name="designer_course",firstgid=1,filename="../tilesets/designer_course.tsx"}},
        layers={layer(1,"bounds",bounds,false),layer(2,"solid",solid,true),
            {id=3,name="templates",type="objectgroup",visible=true,opacity=1,objects={
                {id=1,name="Player Start",type="spawn_point",shape="point",x=tw*3,y=th*(h-5),width=0,height=0,
                    properties={spawn_type="player",is_default=true,facing=1,checkpoint_id="preview_start"}},
            }}}}
    local layout={version=8,rooms={{id="designer_course",x=0,y=0,w=w*tw,h=h*th,ox=0,oy=0,doors={}}}}
    local layout_text="return "..Model.encode(layout).."\n"
    return {
        {path="developer/assets/tiled/maps/designer_course.lua",content="return "..Model.encode(room).."\n"},
        {path="developer/assets/tilesheets/designer_course.png",content=PNG.encode_png(tw,th,string.rep(string.char(70,145,170,255),tw*th))},
        {path="developer/assets/tiled/tilesets/designer_course.tsx",content=string.format([[<?xml version="1.0" encoding="UTF-8"?>
<tileset version="1.10" name="designer_course" tilewidth="%d" tileheight="%d" tilecount="1" columns="1">
 <image source="../../tilesheets/designer_course.png" width="%d" height="%d"/>
 <tile id="0"><objectgroup><object id="1" x="0" y="0" width="%d" height="%d"/></objectgroup></tile>
</tileset>
]],tw,th,tw,th,tw,th)},
        {path="developer/runtime/layout/world_layout.lua",content=layout_text},
        {path="developer/runtime/layout/world_layout.local.lua",content=layout_text},
        -- The disposable copy keeps the project's world selection. A selected
        -- Tiled world would make room generation demand its deleted rooms, so
        -- the course's own layout above owns placement instead.
        {path="developer/config/world_layout_source.lua",content=
            "-- Placement owner: tiled or layout_editor. Disposable course preview: layout_editor.\n"
            .."return { owner = \"layout_editor\" }\n"},
    }
end
-- The course replaces every room, so no end_game region is left for an enabled
-- ending to require. The disposable copy saves the draft with the ending off;
-- the caller's draft is never changed.
function M.document(document)
    local copy=Model.copy(document)
    copy.overrides=copy.overrides or {}
    copy.overrides.game_completion=copy.overrides.game_completion or {}
    copy.overrides.game_completion.enabled=false
    return copy
end
return M
