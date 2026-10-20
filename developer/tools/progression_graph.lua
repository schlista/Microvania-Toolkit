-- Convert the published door layout and normalized Tiled content into a graph.
-- Annotations describe connectivity, never create runtime objects or rewards.
local Keys = require "mvtk.core.key_ids"
local Properties = require "mvtk.tiled.property_flattener"
local Copy = require("developer.tools.progression_search").copy
local M = {}
local function text(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local function id(v) local s=text(v); return s~="" and s:lower()~="none" and s or nil end
local function words(v)
    if type(v)=="table" then return Copy(v) end
    local out={}; for s in text(v):gmatch("[^,]+") do out[#out+1]=text(s) end; return out
end
local function assignments(v)
    if type(v)=="table" then return Copy(v) end
    local out={}; for _,s in ipairs(words(v)) do local k,val=s:match("^([^=]+)=(.+)$"); if k then out[text(k)]=text(val) end end; return out
end
local barriers={gate=true,locked_door=true,timed_door=true,breakable_wall=true,hazard=true,pressure_plate=true}
function M.build(index,layout,config)
    config=config or {}
    local g={areas={},edges={},rewards={},objectives={},diagnostics={},outgoing={},rewards_by_area={},rooms={}}
    local function diag(severity,code,room,message,object)
        g.diagnostics[#g.diagnostics+1]={severity=severity,code=code,room=room,message=message,
            object_id=object and object.object_id,file=object and object.file,property="progression_area"}
    end
    local function area(room,name)
        local key=room .. ":" .. (id(name) or "main")
        if not g.areas[key] then diag("error","missing_progression_area",room,"Unknown logical area " .. key) end
        return key
    end
    local function edge(e)
        if not g.areas[e.from] or not g.areas[e.to] then return end
        g.edges[#g.edges+1]=e; g.outgoing[e.from]=g.outgoing[e.from] or {}; table.insert(g.outgoing[e.from],e)
    end
    for _,r in ipairs(layout.rooms or {}) do
        if not (index.room_set or {})[r.id] then diag("error","missing_progression_room",r.id,"Placed room has no normalized Tiled export.") end
        if g.rooms[r.id] then diag("error","duplicate_layout_room",r.id,"Room occurs more than once in the layout.") end
        local map=index.normalized_maps[r.id] or {}
        local p=Properties.flatten(map.properties or {})
        local c=(config.rooms or {})[r.id] or {}
        local names=words(p.progression_areas or c.areas)
        if #names==0 then names={"main"} end
        local explicit=#names>1 or p.progression_open==true or c.open==true
        for _,name in ipairs(names) do
            if type(name)~="string" or not name:match("^[%w_.-]+$") then
                diag("error","invalid_progression_area",r.id,"Area names use letters, digits, underscore, dot or hyphen.")
                name=tostring(name)
            end
            local key=r.id .. ":" .. name
            if g.areas[key] then diag("error","duplicate_progression_area",r.id,"Duplicate logical area " .. name) end
            g.areas[key]={id=key,room=r.id,name=name}
        end
        g.rooms[r.id]={layout=r,areas=names,doors=assignments(p.progression_doors or c.door_areas),
            explicit=explicit,default=names[1],properties=p}
        if not explicit then diag("warning","geometry_unknown",r.id,"Annotate progression_open or progression_areas; internal movement is unverified.") end
        if p.progression_required==true then g.objectives[#g.objectives+1]={id="room:" .. r.id,area=r.id .. ":" .. names[1],required=true} end
    end
    local function location(o,field)
        local r=g.rooms[o.room]; if not r then return end
        local name=id(o.properties[field or "progression_area"])
        local uncertain=not r.explicit or (#r.areas>1 and not name)
        return area(o.room,name or r.default),uncertain and "Object/door area or room movement is unannotated." or nil
    end
    -- Missing gate endpoints must not allow a declared open room to bypass it.
    for _,o in ipairs(index.objects) do
        local r=g.rooms[o.room]
        if r and o.visible and barriers[o.type] and (not id(o.properties.progression_from) or not id(o.properties.progression_to)) then
            r.explicit=false
            diag("warning","barrier_endpoints_unknown",o.room,"Barrier needs progression_from and progression_to; room traversal is unknown.",o)
        end
    end
    local function door_area(room,door,side)
        local r=g.rooms[room]; if not r then return end
        local key=door and string.format("%s:%g:%g",door.side or side,door.cx or 0,door.cy or 0)
        local name=(key and r.doors[key]) or r.doors[side]
        return area(room,name or r.default),not r.explicit or (#r.areas>1 and not name)
    end
    for room,r in pairs(g.rooms) do for _,name in ipairs(r.areas) do
        g.areas[room .. ":" .. name].unknown=not r.explicit
        if not r.explicit and name~=r.default then
            edge({id="unknown:" .. room .. ":" .. name,from=room .. ":" .. r.default,to=room .. ":" .. name,unknown="Internal barrier endpoints are incomplete."})
            edge({id="unknown:" .. room .. ":" .. name .. ":reverse",to=room .. ":" .. r.default,from=room .. ":" .. name,unknown="Internal barrier endpoints are incomplete."})
        end
    end end
    for _,r in ipairs(layout.rooms or {}) do
        for i,n in ipairs(r.neighbors or {}) do
            if not g.rooms[n.id] then diag("error","missing_neighbor_room",r.id,"Door destination " .. tostring(n.id) .. " is not placed.")
            else
                local from,u=door_area(r.id,n.door,n.side)
                local to,v=door_area(n.id,n.mate,n.mate and n.mate.side)
                edge({id="door:" .. r.id .. ":" .. i,from=from,to=to,unknown=(u or v) and "Door endpoints or internal geometry are unannotated." or nil})
            end
        end
    end
    local teleporters,pairs_by_id={},{}
    for _,o in ipairs(index.objects) do if o.visible and g.rooms[o.room] and o.type=="teleporter" then
        local tid=o.relationship_ids and o.relationship_ids.teleporter_id
        if tid then teleporters[tid]=o end
        local pair=id(o.properties.pair_id)
        if pair then pairs_by_id[pair]=pairs_by_id[pair] or {}; table.insert(pairs_by_id[pair],o) end
    end end
    for _,o in ipairs(index.objects) do if o.visible and g.rooms[o.room] then
        local p,t=o.properties,o.type
        if t=="elevator" or t=="elevator_node" or t=="elevator_controller" then
            g.unmodeled_traversal=true
            diag("warning","elevator_route_unknown",o.room,"Persistent elevator movement needs an in-engine traversal check; unreached areas remain unknown.",o)
        end
        local at,uncertain=location(o)
        if not o.top_level then uncertain="Gameplay objects in Tiled groups are not baked as runtime gameplay." end
        local req={abilities={},items={},flags={}}
        local cost={}
        local ability,item,flag,unknown,unlock
        if t=="locked_door" then
            if p.starts_locked~=false then
                ability=id(p.require_ability); item=id(p.require_key) or id(p.require_item)
                if item and p.consume_key~=false then cost[Keys.canonicalize(item)]=1 end
                -- No requirement can still open by interaction, but external
                -- puzzle triggers are not proved by this geometric analysis.
                if not ability and not item then unknown="Door has no automatic unlock requirement; interaction/puzzle needs playtesting." end
            end
            unlock=id(p.door_id) or o.instance_id
        elseif t=="gate" then
            local kind=id(p.gate_type) or "ability_requirement"
            local defaults=(config.gate_types or {})[kind] or {}
            local runtime_kind=defaults.type or kind
            if p.starts_open~=true then
                if runtime_kind=="ability_requirement" then ability=id(p.required_ability) or id(defaults.required_ability)
                elseif runtime_kind=="item_requirement" then
                    item=id(p.required_item) or id(p.required_key) or id(defaults.required_item)
                    if item and defaults.consume_item then cost[Keys.canonicalize(item)]=1 end
                else unknown="Gate kind " .. runtime_kind .. " depends on actions, movement, timing or custom logic." end
                if type(defaults.condition)=="function" or defaults.on_unlock then unknown="Custom gate callback requires playtesting." end
            end
            if p.stays_open~=false and p.persist_unlock~=false then unlock=id(p.gate_id) or o.instance_id end
            local duration=tonumber(defaults.timer_duration or (defaults.interaction or {}).timer_duration) or 0
            if duration>0 or p.persist_unlock==false or p.stays_open==false then
                unknown="Temporary gate unlock/streaming requires playtesting."
            end
            for _,custom in pairs(config.gates or {}) do
                if type(custom)=="table" and custom.id==(id(p.gate_id) or o.instance_id) then unknown="Instance gate configuration requires playtesting." end
            end
        elseif barriers[t] then unknown="Timing, combat, switches or collision geometry require playtesting."
        end
        if ability then req.abilities[ability]=true end
        if item then req.items[Keys.canonicalize(item)]=1 end
        if barriers[t] then
            local from=id(p.progression_from); local to=id(p.progression_to)
            if from and to then
                local a,b=area(o.room,from),area(o.room,to)
                local e={id=o.instance_id,from=a,to=b,requirements=req,cost=cost,unlock=unlock,
                    unknown=unknown or (not o.top_level and uncertain or nil),object_id=o.object_id,room=o.room}
                edge(e)
                if p.progression_one_way~=true then local back=Copy(e); back.id=e.id .. ":reverse"; back.from,back.to=b,a; edge(back) end
            end
        elseif t=="teleporter" and p.one_way~=true then
            local target=teleporters[id(p.target_id)]
            local pair=pairs_by_id[id(p.pair_id)] or {}
            if not target and #pair==2 then target=pair[1]==o and pair[2] or pair[1] end
            if target then
                local dest,u=location(target)
                flag=id(p.requires_flag); if flag then req.flags[flag]=true end
                edge({id=o.instance_id,from=at,to=dest,requirements=req,unknown=uncertain or u,room=o.room,object_id=o.object_id})
            end
        end
        local reward={id=o.instance_id,area=at,abilities={},items={},flags={},unknown=uncertain}
        local collectible=(config.collectible_types or {})[p.collectible_type] or {}
        if t=="ability" and id(p.ability_id) then reward.abilities[p.ability_id]=true
        elseif t=="collectible" and collectible.on_collect=="unlock_ability" and id(collectible.ability_id) then
            reward.abilities[collectible.ability_id]=true
        elseif (t=="collectible" and (p.collectible_type=="key" or collectible.on_collect=="add_to_inventory")) or t=="key" then
            local amount=tonumber(p.amount)
            if not amount or amount==0 then amount=collectible.value or 1 end
            if amount<1 or amount~=math.floor(amount) then diag("error","invalid_reward_count",o.room,"Key amount must be a positive integer.",o)
            else reward.items[Keys.canonicalize(id(p.item_id) or id(p.key_id) or collectible.item_id or "normal")]=amount end
            if p.respawns==true or (p.respawns==nil and collectible.respawns) then
                reward.unknown="Repeatable pickup economy requires playtesting."; g.unmodeled_rewards=true
            end
        elseif t=="boss" or t=="chest" or t=="npc" or t=="dialogue_trigger" then
            -- These sources may grant flags/items through user callbacks or loot.
            -- Do not conclude an otherwise blocked campaign is impossible.
            g.unmodeled_rewards=true
            diag("warning","reward_logic_unknown",o.room,"Combat, loot or dialogue rewards require playtesting or a preview-state flag/item.",o)
            if t=="boss" then
                local preset=id(p.boss_preset) or id(p.boss_type)
                if preset then
                    reward.flags["boss_defeated_" .. preset]=true
                    local boss=(config.boss_types or {})[preset] or {}
                    local flag=type(boss.on_defeat)=="table" and id(boss.on_defeat.unlock_flag)
                    if flag then reward.flags[flag]=true end
                    reward.unknown="Defeating this boss requires a combat playtest."
                end
            end
        elseif t=="collectible" and (type(collectible.on_collect)=="function" or not next(collectible)) then
            g.unmodeled_rewards=true
            diag("warning","reward_logic_unknown",o.room,"Custom collectible reward is not modeled.",o)
        end
        if next(reward.abilities) or next(reward.items) or next(reward.flags) then
            g.rewards[#g.rewards+1]=reward
            g.rewards_by_area[at]=g.rewards_by_area[at] or {}; table.insert(g.rewards_by_area[at],reward)
        end
        if t=="end_game" and (config.game_completion or {}).enabled and config.game_completion.condition=="region" then
            local goal_id="ending:"..tostring(p.completion_id)
            local goal
            for _,candidate in ipairs(g.objectives) do if candidate.id==goal_id and candidate.locations then goal=candidate; break end end
            if not goal then
                goal={id=goal_id,area=at,required=true,locations={}}
                g.objectives[#g.objectives+1]=goal
            end
            -- Entering any region with this ending ID completes the same goal.
            -- Keep uncertainty local so a speculative region cannot hide a known route.
            local unknown=uncertain or (g.areas[at] and g.areas[at].unknown)
            if not goal.locations[at] or not unknown then goal.locations[at]={unknown=unknown} end
        end
        if id(p.progression_objective) then g.objectives[#g.objectives+1]={id=p.progression_objective,area=at,required=p.progression_optional~=true,unknown=uncertain} end
    end end
    for _,o in ipairs(config.objectives or {}) do g.objectives[#g.objectives+1]=Copy(o) end
    local ending=config.game_completion or {}
    if ending.enabled and ending.condition~="region" and (layout.rooms or {})[1] then
        local first=layout.rooms[1]; local flag=ending.condition=="boss" and ("boss_defeated_"..tostring(ending.boss_id)) or ending.flag
        g.objectives[#g.objectives+1]={id="ending:"..ending.id,area=first.id..":"..g.rooms[first.id].default,
            anywhere=true,required=true,requirements={flags={[flag or ""]=true}}}
        local modeled=false
        for _,reward in ipairs(g.rewards) do if reward.flags and reward.flags[flag] then modeled=true; break end end
        if not modeled then
            g.unmodeled_rewards=true
            diag("warning","ending_flag_source_unknown",nil,"Ending flag "..tostring(flag).." has no modeled producer. Verify its gameplay source; use a preview flag to inspect the completed route.")
        end
    end
    local seen={}
    for _,o in ipairs(g.objectives) do
        if not id(o.id) or seen[o.id] then diag("error","invalid_objective_id",nil,"Objectives need unique, nonempty IDs.") end
        if o.id then seen[o.id]=true end
        if not g.areas[o.area] then diag("error","missing_objective_area",nil,"Objective " .. tostring(o.id) .. " names a missing area.") end
        if not o.locations and not o.anywhere and g.areas[o.area] and g.areas[o.area].unknown then o.unknown="Objective location has unverified internal geometry." end
        for field in pairs(o.requirements or {}) do
            if field~="abilities" and field~="items" and field~="flags" and field~="resources" then
                o.unknown="Unsupported objective condition: " .. field
                diag("warning","objective_condition_unknown",nil,o.unknown)
            end
        end
    end
    local first=(layout.rooms or {})[1]
    g.start=id(config.start) or (first and first.id .. ":" .. g.rooms[first.id].default)
    if g.start and not g.areas[g.start] then diag("error","missing_start_area",nil,"Start area is absent from the layout.") end
    return g
end
return M
