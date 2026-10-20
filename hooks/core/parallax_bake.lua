-- Bake independent scenery GOs and split visual tile layers. No runtime spawning.
local Proto = require "mvtk.editor.proto_utils"
local Background = require "mvtk.editor.background_atlas"
local Props = require "mvtk.tiled.visual_ownership"
local Repeat = require "mvtk.tiled.parallax_repeat"
local M = {}

local function quote(s) return '"' .. Proto.proto_escape(s) .. '"' end
local function number(n) return string.format("%.6f", n or 0) end
local function moving(x,y) return x ~= 1 or y ~= 1 end
local function vector(...)
    local values={...}; for i,v in ipairs(values) do values[i]=number(v) end
    return table.concat(values,", ")
end

local function script(map, x, y, fx, fy, clip, opacity)
    local w,h=(map.width or 0)*(map.tilewidth or 0),(map.height or 0)*(map.tileheight or 0)
    local ox,oy=Repeat.map_origin(map)
    local rows={'components {','  id: "parallax"','  component: "/mvtk/tiled/parallax_motion.script"'}
    local properties={
        {"factor_x",number(fx),"NUMBER"},{"factor_y",number(fy),"NUMBER"},
        {"anchor_offset",vector(ox-x,oy-y,0),"VECTOR3"},
        {"clip_offset",vector(-x,-y,w-x,h-y),"VECTOR4"},
        {"clip_sprite",tostring(clip),"BOOLEAN"},{"opacity",number(opacity or 1),"NUMBER"},
    }
    for _,p in ipairs(properties) do
        rows[#rows+1]='  properties {\n    id: '..quote(p[1])..'\n    value: '..quote(p[2])..'\n    type: PROPERTY_TYPE_'..p[3]..'\n  }'
    end
    rows[#rows+1]='}\n'
    return table.concat(rows,"\n")
end

local function instance(rows,id,path,x,y,z)
    rows[#rows+1]='instances {\n  id: '..quote(id)..'\n  prototype: '..quote(path)..
        '\n  position {\n    x: '..number(x)..'\n    y: '..number(y)..'\n    z: '..number(z)..'\n  }\n}'
end

-- Each image object (including repeat copies) gets its own baked GO. Static
-- images also need initialization for room clipping and inherited opacity.
function M.sprites(context, rows, rid, map, components)
    for _,comp in ipairs(components) do
        local fx,fy=tonumber(comp.parallaxx) or 1,tonumber(comp.parallaxy) or 1
        local visual={}; for k,v in pairs(comp) do visual[k]=v end
        visual.id="sprite"; visual.pos_x=0; visual.pos_y=0; visual.pos_z=0
        local id=rid.."_"..comp.id
        local path="/developer/rooms/generated/"..id..".go"
        local content=context.gen_backgrounds_go(rid,{visual}).."\n"..
            script(map,comp.pos_x,comp.pos_y,fx,fy,true,comp.opacity)
        context.write_if_changed(context.join(context.ROOT,path:sub(2)),content)
        instance(rows,id,path,comp.pos_x,comp.pos_y,comp.pos_z)
    end
    return {}
end

-- Preserve complete protobuf layer blocks (including tile: 0 and flip flags).
function M.split_tiles(map,text,settings)
    local selected={}
    for _,entry in ipairs(Background.flatten_tiled_layers(map.layers)) do
        local layer=entry.layer
        if layer.type=="tilelayer" and moving(entry.parallaxx,entry.parallaxy) then
            local visual=(settings.tile_layers or {})[layer.name] or Props.property_value(layer,"parallax_visual")==true
            assert(visual,"Parallax on gameplay tile layer '"..tostring(layer.name).."' is unsupported; keep it at 1 or mark decorative artwork parallax_visual=true")
            assert(not selected[layer.name],"Duplicate moving tile layer: "..tostring(layer.name))
            selected[layer.name]=entry
        end
    end
    if not next(selected) then return text,{} end
    local top,static,parts={},{},{}
    local lines=Proto.split_proto_lines(text:gsub("\r\n","\n"))
    local i=1
    while i<=#lines do
        if lines[i]:match("^%s*layers%s*{") then
            local block,depth={},0
            repeat
                block[#block+1]=lines[i]; depth=depth+Proto.brace_delta(lines[i]); i=i+1
            until depth==0 or i>#lines
            assert(depth==0,"Unclosed tilemap layer")
            local content=table.concat(block,"\n")
            local name=content:match('id:%s*"([^"]+)"')
            if selected[name] then
                parts[#parts+1]={entry=selected[name],text=content,name=name}
            else static[#static+1]=content end
        else top[#top+1]=lines[i];i=i+1 end
    end
    local header=table.concat(top,"\n").."\n"
    for _,part in ipairs(parts) do part.text=header..part.text.."\n" end
    return header..table.concat(static,"\n").."\n",parts
end

local function tile_plan(context,rid,map)
    local text=context.read_text(context.join(context.PATH.tilemaps,rid..".tilemap"))
    if not text then return nil,{} end
    map=map or context.load_tiled_export(rid)
    if not map then return text,{} end
    local settings=context.load_project_lua_table("developer/config/parallax_settings.lua") or {tile_layers={}}
    return M.split_tiles(map,text,settings)
end

function M.prepare_tiles(context,rid)
    local text,parts=tile_plan(context,rid)
    if #parts==0 then return nil end
    local resource="/developer/rooms/generated/"..rid.."_static.tilemap"
    context.write_if_changed(context.join(context.ROOT,resource:sub(2)),text)
    return resource
end

function M.main_tilemap_text(context,rid)
    local text=tile_plan(context,rid)
    return text
end

function M.append_tiles(context,rows,rid,map)
    local _,parts=tile_plan(context,rid,map)
    for _,part in ipairs(parts) do
        local id=Repeat.tile_instance_id(rid,part.entry.layer.id)
        local resource="/developer/rooms/generated/"..id
        context.write_if_changed(context.join(context.ROOT,resource:sub(2)..".tilemap"),part.text)
        local content='components {\n  id: "tilemap"\n  component: '..quote(resource..".tilemap")..'\n}\n'..
            script(map,0,0,part.entry.parallaxx,part.entry.parallaxy,false)
        context.write_if_changed(context.join(context.ROOT,resource:sub(2)..".go"),content)
        instance(rows,id,resource..".go",0,0,0)
    end
end

M.motion_script = script
return M
