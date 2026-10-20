local Source=require "developer.tools.project_source"
local Model=require "mvtk.core.creator_settings_model"
local M={}
function M.load(root,read)
    read=read or Source.read
    local text=read(root.."/developer/config/game_completion.lua")
    local cfg=text and assert(Source.load_table(text,"game_completion.lua")) or {enabled=false,id="ending"}
    local creator=Source.load_table(read(root.."/developer/config/creator_settings.lua"),"creator_settings.lua")
    if creator and creator.published then Model.merge(cfg,(creator.overrides or {}).game_completion or {}) end
    return cfg
end
function M.validate(cfg,index,bosses,layout)
    local ds={}; local regions,placed_regions=0,0
    local placed={}; for _,room in ipairs(layout and layout.rooms or {}) do placed[room.id]=true end
    local function issue(code,message,o,property,severity,fix)
        ds[#ds+1]={severity=severity or "error",code=code,message=message,file=o and o.file or "developer/config/game_completion.lua",
            room=o and o.room,layer=o and o.layer,object_id=o and o.object_id,property=property or "game_completion",fix=fix}
    end
    for _,o in ipairs(index.objects or {}) do if o.visible and o.type=="end_game" then
        regions=regions+1
        if placed[o.room] then placed_regions=placed_regions+1 end
        if o.properties.completion_id~=cfg.id then
            local message="Region completion ID '"..tostring(o.properties.completion_id).."' must match configured ending ID '"..tostring(cfg.id).."'."
            -- Reset disables completion before creators re-import their maps.
            -- Allow the first build so they can reach the in-game Ending wizard.
            if not cfg.enabled then message=message.." Ending is disabled; use Project > Game Settings... > Ending to match the ID before enabling completion." end
            issue("unknown_completion_id",message,o,"completion_id",cfg.enabled and "error" or "warning",
                "Match the ID in Project > Game Settings... > Ending or correct this region's completion_id and export again.")
        end
        if not cfg.enabled then issue("ending_disabled","This region is inactive until completion is enabled in Project > Game Settings... > Ending.",o,nil,"warning") end
    end end
    if not cfg.enabled then return ds end
    if type(cfg.id)~="string" or not cfg.id:match("^[%w_%-]+$") then issue("invalid_completion_id","Ending ID must be nonempty letters, digits, underscores or hyphens.") end
    if cfg.condition=="region" then
        if regions==0 then issue("missing_ending_region","Place an end_game template on a top-level templates layer.") end
        if next(placed) and regions>0 and placed_regions==0 then issue("unpublished_ending_region","Place a room containing this end_game region in Layout Editor before publishing the world.") end
    elseif cfg.condition=="flag" then
        if type(cfg.flag)~="string" or cfg.flag=="" then issue("missing_ending_flag","Flag ending requires a flag name.") end
    elseif cfg.condition=="boss" then
        local found=bosses and bosses[cfg.boss_id]
        for _,o in ipairs(index.objects or {}) do if o.type=="boss" and (o.properties.boss_id==cfg.boss_id or o.properties.boss_preset==cfg.boss_id or o.properties.boss_type==cfg.boss_id) then found=true end end
        if not cfg.boss_id or cfg.boss_id=="" or not found then issue("unknown_ending_boss","Boss ending must name an existing boss preset or persistent boss identity.") end
    else issue("invalid_ending_condition","Ending condition must be region, flag, or boss.") end
    if cfg.continue_policy~="explore" and cfg.continue_policy~="completed" then issue("invalid_continue_policy","Continue must be explore or completed.") end
    if cfg.continue_policy=="explore" and cfg.return_room~="" and layout then
        local valid=false
        for _,r in ipairs(layout.rooms or {}) do
            if r.id==cfg.return_room and type(cfg.return_x)=="number" and type(cfg.return_y)=="number" and cfg.return_x>=r.x and cfg.return_x<=r.x+r.w and cfg.return_y>=r.y and cfg.return_y<=r.y+r.h then valid=true end
        end
        if not valid then issue("invalid_ending_return","Return point must lie inside its published room (world coordinates).") end
    end
    return ds
end
return M
