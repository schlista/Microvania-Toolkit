-- Read-only identity audit for room renames/copies. No Tiled or generated files
-- are rewritten here. Phase 3's relationship validator supplies typed link checks.
local Model = require "mvtk.core.creator_settings_model"
local Objects = require "hooks.core.tiled_objects"
local Properties = require "mvtk.tiled.property_flattener"
local Proto = require "mvtk.editor.proto_emit"
local M = {}

function M.snapshot(maps)
    local out = {version=1,rooms={},objects={}}
    for room, map in pairs(maps) do
        out.rooms[room] = true
        for _,layer in ipairs(map.layers or {}) do
            if layer.name == "templates" then
                for _,object in ipairs(layer.objects or {}) do
                    local kind = Objects.resolve_object_type(object) or object.type or "unknown"
                    local id = Proto.generated_object_id(room,kind,object.id)
                    assert(not out.objects[id], "Duplicate baked object identity: " .. id)
                    out.objects[id] = {room=room,object_id=object.id,type=kind,name=object.name,
                        properties=Properties.flatten(object.properties or {})}
                end
            end
        end
    end
    return out
end

function M.compare(before, after, remap)
    assert(before.version==1 and after.version==1,"Unsupported content identity snapshot")
    remap=remap or {rooms={},objects={}}
    local report={version=1,changes={},aliases={}}
    local function change(code,id,to) report.changes[#report.changes+1]={code=code,id=id,to=to} end
    for _, namespace in ipairs({"rooms","objects"}) do
        local destinations={}
        for from,to in pairs(remap[namespace] or {}) do
            assert(before[namespace][from],"Unknown old " .. namespace .. " identity: " .. from)
            assert(after[namespace][to],"Missing new " .. namespace .. " identity: " .. to)
            assert(not after[namespace][from],"Remapping a copy would share progress with its original: " .. from)
            assert(not destinations[to],"Ambiguous many-to-one identity remap: " .. to)
            destinations[to]=from
        end
        for id,entry in pairs(before[namespace]) do
            local to=(remap[namespace] or {})[id]
            if not after[namespace][id] then change(to and "remapped_" .. namespace or "removed_" .. namespace,id,to)
            elseif namespace=="objects" and not require("mvtk.core.save_migrations").equal(entry.properties,after.objects[id].properties) then
                change("review_changed_properties",id)
            end
        end
    end
    local function alias(path,mode,from,to)
        report.aliases[#report.aliases+1]={path=path,mode=mode,from=from,to=to}
    end
    for from,to in pairs(remap.rooms or {}) do
        alias({"checkpoint","room_id"},"value",from,to)
        alias({"explored"},"key",from,to)
        alias({"modules","map_discovery","data","rooms"},"key",from,to)
        alias({"modules","world","data","current_room"},"value",from,to)
    end
    -- Never guess how arbitrary provider IDs are encoded. Known flag stores use
    -- these runtime prefixes; both the provider payload and mirror need aliases.
    for from,to in pairs(remap.objects or {}) do
        local old,new=before.objects[from],after.objects[to]
        assert(old.type==new.type,"Object remap changes type: " .. from)
        local field,prefix
        if old.type=="chest" then field,prefix="chest_id","chest_opened_"
        elseif old.type=="breakable_wall" then field,prefix="wall_id","wall_broken_" end
        if field then
            local old_key=old.properties[field]; if old_key==nil or old_key=="" then old_key=from end
            local new_key=new.properties[field]; if new_key==nil or new_key=="" then new_key=to end
            if old_key~=new_key then
                alias({"flags"},"key",old_key,new_key)
                report.aliases[#report.aliases].hash_prefix=prefix
                alias({"modules","flags","data"},"key",old_key,new_key)
                report.aliases[#report.aliases].hash_prefix=prefix
            end
        else change("provider_alias_review_required",from,to) end
    end
    -- Surface stale literal references anywhere in flattened Tiled properties.
    -- These are review candidates, not a claim that every string is a typed link.
    local persistent={}
    for id,object in pairs(after.objects) do
        local field=object.type=="chest" and "chest_id" or (object.type=="breakable_wall" and "wall_id")
        if field then
            local value=object.properties[field]
            if value==nil or value=="" then value=id end
            local key=field .. ":" .. tostring(value)
            if persistent[key] then change("duplicate_persistent_id",id,persistent[key]) else persistent[key]=id end
        end
        for field,value in pairs(object.properties) do
            if (remap.rooms or {})[value] or (remap.objects or {})[value] then
                change("review_stale_reference",id .. "." .. field,tostring(value))
            end
        end
    end
    table.sort(report.changes,function(a,b) return a.code .. a.id < b.code .. b.id end)
    table.sort(report.aliases,function(a,b) return Model.encode(a)<Model.encode(b) end)
    return report
end

return M
