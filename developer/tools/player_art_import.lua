-- Pure import planning plus Defold's PNG decoder adapter. Nothing is published
-- until the shared wizard writer commits art, geometry and settings together.
local Model=require "mvtk.core.creator_settings_model"
local Transaction=require "mvtk.editor.project_transaction"
local Text=require "mvtk.editor.resource_text"
local PNG=require "mvtk.editor.layout_editor.png_writer"
local PlayerScale=require "mvtk.player.player_scale"
local Number=require "mvtk.editor.settings_number"
local M={}
local function integer(n,label) assert(type(n)=="number" and n>=1 and n==math.floor(n),label.." must be a positive integer"); return n end
function M.dimensions(cfg)
    local width=cfg.width==0 and cfg.frame_width or cfg.width
    local height=cfg.height==0 and cfg.frame_height or cfg.height
    assert(type(width)=="number" and width>0 and width<=7168,"Displayed width must be 0 (frame width) or a positive value up to 7168")
    assert(type(height)=="number" and height>0 and height<=7168,"Displayed height must be 0 (frame height) or a positive value up to 7168")
    return width,height
end
function M.is_stretched(cfg)
    local width,height=M.dimensions(cfg)
    return width~=cfg.frame_width or height~=cfg.frame_height
end
function M.mappings(text)
    local out={}
    for entry in (text or ""):gmatch("[^;]+") do
        local key,value=entry:match("^%s*([%w_]+)%s*=%s*([%w_]+)%s*$")
        assert(key,"Use gameplay=animation mappings separated by semicolons.")
        assert(not out[key],"Duplicate animation mapping: "..key); out[key]=value
    end
    return out
end
function M.decode(bytes)
    local img=assert(image.load(bytes,{premultiply_alpha=false,flip_vertically=false}),"Cannot decode PNG")
    local channels=img.type==image.TYPE_RGBA and 4 or img.type==image.TYPE_RGB and 3 or img.type==image.TYPE_LUMINANCE_ALPHA and 2 or 1
    if channels~=4 then
        local out={}
        for i=1,#img.buffer,channels do
            local a,b,c,d=img.buffer:byte(i,i+channels-1)
            out[#out+1]=channels==3 and string.char(a,b,c,255) or string.char(a,a,a,channels==2 and b or 255)
        end
        img.buffer=table.concat(out)
    end
    return img
end
local function crop(img,x,y,w,h)
    local rows={}
    for row=y,y+h-1 do local first=(row*img.width+x)*4+1; rows[#rows+1]=img.buffer:sub(first,first+w*4-1) end
    return table.concat(rows)
end
local function png(frame,w,h)
    local rows={}; for y=h-1,0,-1 do rows[#rows+1]=frame:sub(y*w*4+1,(y+1)*w*4) end
    return PNG.encode_png(w,h,table.concat(rows))
end
function M.gui_pixels(bytes)
    local out={}
    for i=1,#bytes,4 do
        local r,g,b,a=bytes:byte(i,i+3)
        out[#out+1]=string.char(math.floor(r*a/255+0.5),math.floor(g*a/255+0.5),math.floor(b*a/255+0.5),a)
    end
    return table.concat(out)
end
function M.prepare(cfg,opts)
    opts=opts or {}; local read=opts.read or Transaction.read; local decode=opts.decode or M.decode
    cfg=PlayerScale.convert_units(cfg,"player_art",opts.player or require("developer.config.player_settings"))
    local w,h=integer(cfg.frame_width,"Frame width"),integer(cfg.frame_height,"Frame height")
    M.dimensions(cfg)
    assert(w<=2048 and h<=2048,"Frame dimensions must be at most 2048 pixels")
    assert(type(cfg.source)=="string" and cfg.source~="","Choose a source PNG or sequence folder first.")
    local plan={config=Model.copy(cfg),animations={},files={},frames={},sources={},mappings=M.mappings(cfg.mappings)}
    local function load(path)
        local bytes=assert(read(path),"Missing source: "..path)
        assert(bytes:sub(1,8)=="\137PNG\r\n\026\n","Source must be PNG: "..path)
        plan.sources[path]=require("developer.tools.preparation").fingerprint(bytes)
        local img=decode(bytes); assert(img and #img.buffer==img.width*img.height*4,"Invalid decoded RGBA image: "..path); return img
    end
    local count=0
    local function frame(name,index,pixels)
        count=count+1; assert(count<=512 and count*w*h<=16777216,"Import exceeds 512 frames or 16 million total pixels; reduce frame dimensions/count.")
        local frames=plan.animations[name] or {}; plan.animations[name]=frames
        assert(not frames[index],"Duplicate frame "..name.."_"..index)
        local path=string.format("assets/sprites/player_import/%s_%04d.png",name,index)
        frames[index]=path; plan.frames[path]=pixels
        plan.files[#plan.files+1]={path=path,content=png(pixels,w,h)}
    end
    if cfg.mode=="sheet" then
        local img=load(cfg.source); assert(img.width%w==0 and img.height%h==0,"Sheet dimensions must divide exactly by frame size.")
        local columns=img.width/w; local total=columns*img.height/h
        for entry in (cfg.animations or ""):gmatch("[^;]+") do
            local name,first,last=entry:match("^%s*([%w_]+)%s*=%s*(%d+)%s*%-%s*(%d+)%s*$")
            assert(name,"Use name=first-last sheet ranges separated by semicolons.")
            first,last=tonumber(first),tonumber(last)
            assert(not plan.animations[name],"Duplicate animation: "..name)
            assert(first>=1 and last>=first and last<=total,"Frame range is outside sheet: "..entry)
            for i=first,last do local n=i-1; frame(name,i-first+1,crop(img,(n%columns)*w,math.floor(n/columns)*h,w,h)) end
        end
    else
        assert(cfg.mode=="sequence","Import mode must be sequence or sheet")
        local _,files=(opts.list or require("hooks.core.filesystem").list_dir_filesystem)(cfg.source)
        for _,file in ipairs(files or {}) do if file:lower():match("%.png$") then
            local name,index=file:match("^([%w_]+)_(%d+)%.png$")
            assert(name,"Name PNG sequences animation_001.png: "..file)
            index=integer(tonumber(index),"Frame number")
            local img=load(cfg.source.."/"..file)
            assert(img.width==w and img.height==h,"Frame geometry differs: "..file)
            frame(name,index,img.buffer)
        end end
    end
    local names={}
    for name,frames in pairs(plan.animations) do
        local maximum=0; for i in pairs(frames) do maximum=math.max(maximum,i) end
        for i=1,maximum do assert(frames[i],"Missing frame "..name.."_"..i.."; sequences must start at 1 without gaps.") end
        names[#names+1]=name
    end
    assert(#names>0,"No animations found in source."); table.sort(names); plan.names=names
    local required={idle=true,run=true,jump=true,fall=true}
    for name in (cfg.required or ""):gmatch("[^;%s]+") do
        assert(name:match("^[%w_]+$"),"Required animation names use letters, digits and underscores")
        required[name]=true
    end
    plan.fallbacks={}
    for name in pairs(required) do
        if not plan.animations[plan.mappings[name] or name] then
            assert(cfg.fallback and plan.animations[cfg.fallback],"Missing required animation: "..name..". Map it or explicitly choose a fallback animation.")
            plan.mappings[name]=cfg.fallback; plan.fallbacks[#plan.fallbacks+1]=name
        end
    end
    table.sort(plan.fallbacks)
    for key,value in pairs(plan.mappings) do assert(plan.animations[value],"Mapping "..key.." refers to missing animation "..value) end
    return plan
end
function M.body(player,read)
    read=read or Transaction.read
    local staged=require("mvtk.editor.player_scale_writer").stage({base="developer",read=read or Transaction.read,
        player=player,previous=player,force_geometry=true})
    local content=read("developer/game/player/collisionobject.collisionobject")
    for _,file in ipairs(staged) do if file.path=="game/player/collisionobject.collisionobject" then content=file.content end end
    if content then
        local doc=Text.parse(content)
        local shape=assert(Text.one(doc.root,"embedded_collision_shape")).node
        local box=assert(Text.one(shape,"shapes")).node
        local position=Text.one(box,"position")
        local data=Text.all(shape,"data")
        return {x=position and Text.value(position.node,"x") or 0,y=position and Text.value(position.node,"y") or 0,
            width=2*data[1].value,height=2*data[2].value}
    end
    error("Player body geometry was not staged")
end
function M.validate_runtime(plan,overrides)
    for _,target in pairs(overrides or {}) do
        if type(target)=="string" and target~="" then
            assert(plan.animations[plan.mappings[target] or target],
                "Existing player animation override needs "..target..". Add "..target.."=imported_animation to the art mappings before importing.")
        end
    end
end
function M.stage(plan,player,read)
    -- Detect source edits between preview and Save so the reviewed art is exact.
    for path,signature in pairs(plan.sources) do
        local bytes=read(path); assert(bytes and require("developer.tools.preparation").fingerprint(bytes)==signature,"Art source changed after preview; import it again: "..path)
    end
    local files=Model.copy(plan.files); local rows={"extrude_borders: 2"}
    local one_shots={}; for name in (plan.config.once or ""):gmatch("[^;%s]+") do one_shots[name]=true end
    local aliases=Model.copy(plan.mappings)
    for _,name in ipairs(plan.names) do aliases[name]=aliases[name] or name end
    local ids={}; for name in pairs(aliases) do ids[#ids+1]=name end; table.sort(ids)
    for _,name in ipairs(ids) do
        rows[#rows+1]='animations {\n  id: "'..name..'"'
        for _,path in ipairs(plan.animations[aliases[name]]) do rows[#rows+1]='  images { image: "/developer/'..path..'" }' end
        local once=one_shots[name]
        rows[#rows+1]='  fps: '..integer(plan.config.fps,"FPS")..'\n  playback: '..(once and "PLAYBACK_ONCE_FORWARD" or "PLAYBACK_LOOP_FORWARD")..'\n}'
    end
    files[#files+1]={path="assets/atlas/player.atlas",content=table.concat(rows,"\n").."\n"}
    local path="game/player/player_sprite.go"; local doc=Text.parse(assert(read("developer/"..path),"Player sprite resource is missing"))
    local found
    for _,entry in ipairs(Text.all(doc.root,"embedded_components")) do if Text.value(entry.node,"id")=="sprite" then assert(not found,"Ambiguous player sprite"); found=entry.node end end
    assert(found,"Player resource needs its embedded sprite component")
    local scale=player.player_scale or 1
    local cfg=PlayerScale.convert_units(plan.config,"player_art",player)
    local width,height=M.dimensions(cfg)
    local data=assert(Text.one(found,"data")); local inner=Text.parse(data.value)
    local textures=Text.all(inner.root,"textures"); assert(#textures==1,"Player sprite needs one texture sampler")
    Text.replace(inner,assert(Text.one(textures[1].node,"texture")),"/developer/assets/atlas/player.atlas")
    Text.replace(inner,assert(Text.one(inner.root,"default_animation")),"idle")
    local function scalar(doc,node,name,value)
        local e=Text.one(node,name); if e then Text.replace(doc,e,value) else Text.insert(doc,node,name..": "..tostring(value)) end
    end
    local size=Text.one(inner.root,"size")
    if size then scalar(inner,size.node,"x",width*scale); scalar(inner,size.node,"y",height*scale)
    else Text.insert(inner,inner.root,"size { x: "..Number.general(width*scale,9).." y: "..Number.general(height*scale,9).." }") end
    local mode=Text.one(inner.root,"size_mode")
    if mode then assert(mode.value=="SIZE_MODE_MANUAL","Set player sprite Size Mode to Manual in Defold before importing.") else Text.insert(inner,inner.root,"size_mode: SIZE_MODE_MANUAL") end
    Text.replace(doc,data,Text.render(inner))
    local position=Text.one(found,"position")
    if position then scalar(doc,position.node,"x",cfg.offset_x*scale); scalar(doc,position.node,"y",cfg.offset_y*scale)
    else Text.insert(doc,found,"position { x: "..Number.general(cfg.offset_x*scale,9).." y: "..Number.general(cfg.offset_y*scale,9).." }") end
    files[#files+1]={path=path,content=Text.render(doc)}
    return files
end
return M
