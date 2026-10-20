local CP=require "mvtk.core.checkpoint"
local Flags=require "mvtk.core.flags"
local Inventory=require "mvtk.core.inventory"
local Runtime=require "developer.config.runtime_settings"
local Baseline=require "developer.config.game_completion"
local Model=require "mvtk.core.creator_settings_model"
local State=require "mvtk.game.completion_state"
local M={active=false}
local cached_config, cached_revision
local function effective_config()
    local revision=Runtime.revision()
    if cached_revision~=revision then
        cached_config=Runtime.section("game_completion",Baseline)
        cached_revision=revision
    end
    return cached_config
end
function M.config()
    return Model.copy(effective_config())
end
local function return_point(cfg)
    if cfg.continue_policy~="explore" then return nil end
    local point=cfg.return_room~="" and {room_id=cfg.return_room,x=cfg.return_x,y=cfg.return_y} or CP.data.checkpoint
    if not point then return nil,"Set a return room/position or activate a checkpoint before finishing." end
    local layout=require("mvtk.rooms.layout_io").load({runtime_preferred=true})
    for _,room in ipairs(layout and layout.rooms or {}) do
        if room.id==point.room_id and point.x>=room.x and point.x<=room.x+room.w and point.y>=room.y and point.y<=room.y+room.h then return Model.copy(point) end
    end
    return nil,"Ending return checkpoint is outside its published room. Correct Ending settings and rebuild."
end
local state=State.new({has_flag=Flags.has,return_point=return_point,
    playing=function() local Game=require "mvtk.game.game_manager"; return Game.get_state()==Game.STATE.PLAYING end,
    busy=function() return require("mvtk.bosses.boss_manager").completion_pending() end,
    stats=function() return Model.copy(Inventory.export()) end,
    save=function(cfg,point)
        return CP.batch("game_completed",function()
            if cfg.reward_flag~="" then Flags.set(cfg.reward_flag,true) end
            if point then CP.set_checkpoint(point,point.room_id) end
        end)
    end})
CP.register_provider("game_completion",{version=1,order=200,
    capture=function() return Model.copy(state.data) end,
    apply=function(data) state:load(data) end,
    defaults=function() state:load({}) end})
function M.enter(id,token) state:enter(id,token) end
function M.leave(id,token) state:leave(id,token) end
function M.retry() state:retry() end
function M.data() return Model.copy(state.data) end
function M.begin_session() M.active=true; state.shown=false; state.regions={}; state.error=nil end
function M.update(dt) if M.active then return state:tick(dt,effective_config()) end end
return M
