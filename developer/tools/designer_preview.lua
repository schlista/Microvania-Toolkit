-- Draft snapshots and disposable preview launching for the editor.
-- Every file/process operation runs after the native dialog has returned.
local Model=require "mvtk.core.creator_settings_model"
local Transaction=require "mvtk.editor.project_transaction"
local M={}
local editor_jobs={}
local function valid_id(id)
    assert(type(id)=="string" and id:match("^%d+_%d+$"),"Invalid preview job ID")
    return id
end
local function root(opts)
    return tostring(opts and opts.root or "."):gsub("\\","/"):gsub("/$","")
end
local function path(opts,relative)
    local base=root(opts)
    return base=="." and relative or base.."/"..relative
end
local function new_id()
    -- Defold's editor loads LuaJ's os.time and math.random. Integer formatting
    -- avoids exponent notation and LuaJ's unsupported floating precision.
    return valid_id(string.format("%d_%d",os.time(),math.random(100000,999999)))
end
function M.request(session,mode,id)
    assert(mode=="course" or mode=="rooms","Unknown preview mode")
    valid_id(id)
    local plan
    if session.art_import then
        plan={}
        for key,value in pairs(session.art_import) do
            if key~="frames" then plan[key]=Model.copy(value) end
        end
        -- Lua 5.1 dofile uses Windows text mode. Raw PNG bytes (notably Ctrl-Z)
        -- must never appear in a request source file, even inside a %q string.
        for _,file in ipairs(plan.files) do
            file.content_hex=file.content:gsub(".",function(c) return string.format("%02x",c:byte()) end)
            file.content=nil
        end
    end
    return {version=1,id=id,mode=mode,document=Model.copy(session.draft),art_import=plan}
end
function M.unpack_request(request)
    local result=Model.copy(request)
    if result.art_import then for _,file in ipairs(result.art_import.files) do
        local hex=assert(file.content_hex,"Preview PNG data is missing")
        assert(#hex%2==0 and not hex:find("[^0-9a-f]"),"Invalid preview PNG encoding")
        file.content=hex:gsub("..",function(pair) return string.char(tonumber(pair,16)) end)
        file.content_hex=nil
    end end
    return result
end

-- The editor and headless staging tools share this request format.
-- The request contains all user paths as Lua data, never command arguments.
function M.write_job(session,mode,id,opts)
    opts=opts or {}
    local job=".build/designer-preview/"..valid_id(id)
    local read=opts.read or Transaction.read
    assert(not read(path(opts,job.."/request.lua")),"Preview job already exists; try again")
    Transaction.commit(path(opts,job),{{path="request.lua",content="return "..Model.encode(M.request(session,mode,id)).."\n"}},opts.transaction)
    return job
end
function M.status(session,opts)
    local job=session.preview_job
    if not job then return nil end
    assert(job:match("^%.build/designer%-preview/%d+_%d+$"),"Invalid preview job path")
    return (opts and opts.read or Transaction.read)(path(opts,job.."/status.txt"))
end
function M.refresh(session,opts)
    local job=session.preview_job or editor_jobs[root(opts):lower()]
    if not job then return "No preview has been launched.",false end
    session.preview_job=job
    local status=M.status(session,opts)
    if not status or status:match("^%s*$") then
        return "Building preview… (see "..job.."/status.txt)",true
    end
    -- The builder keeps running while the preview game is open. A missing or
    -- intermediate status remains active; only its existing final states end
    -- the job. Reads never publish settings or alter the request snapshot.
    local complete=status:find("Preview closed.",1,true)==1
        or status:find("Preview failed:",1,true)==1
        or status:find("Preview built successfully.",1,true)==1
        or status:find("Staged successfully;",1,true)==1
    return status,not complete
end
function M.launch_editor(session,mode,opts)
    opts=opts or {}
    local host=assert(opts.editor or editor,"Editor host is required")
    if host.platform~="x86_64-win32" then return "Previews need Windows for now" end
    local previous=session.preview_job or editor_jobs[root(opts):lower()]
    if previous then
        session.preview_job=previous
        local status,busy=M.refresh(session,opts)
        if busy then return status end
    end
    local id=new_id()
    local job=M.write_job(session,mode,id,opts)
    -- execute waits for its direct process. cmd's start detaches pwsh; discard
    -- both streams so the editor does not wait for inherited output pipes.
    -- Reference: https://defold.com/llms/apis/editor-lua.md#editor.execute
    host.execute("cmd","/c","start",'""',"/min","pwsh.exe","-NoProfile","-NonInteractive",
        "-WindowStyle","Hidden","-File","tools/designer_preview.ps1","-JobId",id,
        {out="discard",err="discard",reload_resources=false})
    session.preview_job=job
    editor_jobs[root(opts):lower()]=job
    return "Building preview… (see "..job.."/status.txt)"
end
return M
