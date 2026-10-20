-- Validate a Tiled export using only its project-local input copies. External
-- authoring paths are attribution; only Tiled can check those originals.
local Source=require "developer.tools.project_source"
local M={}
-- Share disk reads only within one uninterrupted validation pass. Shared art
-- can appear in hundreds of room manifests; reopening it for every room turns
-- a small input set into gigabytes of I/O. Later checks get a fresh reader.
function M.check_context(opts)
    local context={}
    for key,value in pairs(opts) do context[key]=value end
    local read=opts.read or Source.read
    local seen={}
    context.read=function(path)
        local content=seen[path]
        if content==nil then
            content=read(path)
            seen[path]=content or false
        end
        if content==false then return nil end
        return content
    end
    return context
end
-- Shared tilesets/art recur in every room. Cache signatures for this check only;
-- a later command always reads and fingerprints the current imported bytes.
function M.memo_fingerprint(fingerprint)
    local seen={}
    return function(content)
        local signature=seen[content]
        if not signature then signature=fingerprint(content);seen[content]=signature end
        return signature
    end
end
function M.relative(path)
    if type(path)~="string" or path=="" or path:find("\\",1,true) or path:find(":",1,true) or path:sub(1,1)=="/" then return false end
    for part in path:gmatch("[^/]+") do if part==".." or part=="." then return false end end
    return true
end
function M.check(opts,map,id,fingerprint)
    local issues={}
    local function issue(path,message) issues[#issues+1]={status="export_needed",path=path,message=message.." Re-export the room from Tiled, then Prepare & Check."} end
    local provenance=map and map.mvtk_provenance
    local tmx="developer/assets/tiled/maps/"..id..".tmx"
    if not provenance or provenance.version~=2 then issue(tmx,"This export needs the project-copy input manifest.");return issues end
    local read=opts.read or Source.read
    local found=false
    for _,dep in ipairs(provenance.dependencies or {}) do
        if not M.relative(dep.path) then issue(tmx,"An imported dependency is not project-relative.")
        else
            local content=read((opts.root or ".").."/"..dep.path)
            if not content then issue(dep.path,"An imported input is missing.")
            else
                if not dep.binary then content=content:gsub("^\239\187\191", ""):gsub("\r\n","\n") end
                local signature=fingerprint(content)
                if signature~=dep.fingerprint then issue(dep.path,"An imported input changed since its Tiled export.") end
                if dep.path==tmx then
                    found=true
                    if signature~=map.mvtk_source_signature then issue(tmx,"The imported TMX and Lua export do not match.") end
                end
            end
        end
    end
    if not found then issue(tmx,"The imported TMX is missing from the export manifest.") end
    return issues
end
return M
