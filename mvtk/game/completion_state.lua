-- Pure completion state machine. Dependencies provide persistence and gameplay state.
local Model=require "mvtk.core.creator_settings_model"
local M={}
function M.new(deps)
    local self={data={},pending=false,error=nil,shown=false,regions={}}
    function self:load(data)
        self.data=Model.copy(data or {}); self.pending=false; self.error=nil; self.shown=false; self.regions={}
    end
    function self:enter(id,token)
        self.regions[id]=self.regions[id] or {}; self.regions[id][token or id]=true
    end
    function self:leave(id,token)
        if self.regions[id] then self.regions[id][token or id]=nil; if not next(self.regions[id]) then self.regions[id]=nil end end
    end
    function self:retry() self.error=nil end
    function self:tick(dt,cfg)
        if not cfg.enabled then return end
        if self.data.id==cfg.id then
            if not self.shown and cfg.continue_policy=="completed" then self.shown=true; return "show" end
            return
        end
        if deps.playing and not deps.playing() then return end
        self.data.playtime_s=(self.data.playtime_s or 0)+math.max(0,dt or 0)
        if self.error then return end -- one failure dialog; explicit Retry resumes saving
        local met=cfg.condition=="region" and self.regions[cfg.id]
            or cfg.condition=="flag" and cfg.flag~="" and deps.has_flag(cfg.flag)
            or cfg.condition=="boss" and cfg.boss_id~="" and deps.has_flag("boss_defeated_"..cfg.boss_id)
        if not met or (deps.busy and deps.busy()) then return end
        local point,err=deps.return_point(cfg)
        if cfg.continue_policy=="explore" and not point then self.error=err or "No valid return checkpoint"; return "save_failed",self.error end
        local before=Model.copy(self.data)
        self.data.id=cfg.id; self.data.stats=deps.stats(); self.data.return_point=point
        -- Required reward is a flag, so retrying is idempotent. The adapter groups
        -- reward/checkpoint/completion capture in one durable save operation.
        local called,ok,reason=pcall(deps.save,cfg,point)
        if not called or not ok then self.data=before; self.error=tostring(called and reason or ok); return "save_failed",self.error end
        self.shown=true; return "show"
    end
    return self
end
return M
