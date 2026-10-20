-- Windows editor accelerator. Every target is verified from disk afterwards;
-- the caller retains the ordinary writer as a complete fallback.
local M={}
-- Length-prefixed raw strings avoid a LuaJ loop and allocation for every three
-- content bytes. Lengths count bytes, preserving UTF-8, NULs and line endings.
function M.encode(entries)
    local chunks={"MVTK_WRITE_BUNDLE_2\n"}
    for _,entry in ipairs(entries) do
        local path=entry.resource_path:gsub("^/","")
        assert(path:match("^developer/") and not path:find("..",1,true) and not path:find("[:\\]"),"Unsafe bundle path")
        chunks[#chunks+1]=string.format("%d\t%d\n",#path,#entry.text)
        chunks[#chunks+1]=path
        chunks[#chunks+1]=entry.text
    end
    return table.concat(chunks)
end
function M.apply(root,entries,host)
    local log=host.info or function() end
    local started=os.clock()
    local bundle=root.."/.mvtk_tmp/write_bundle.txt"
    host.ensure_dir(root.."/.mvtk_tmp")
    log(string.format("[WRITE_BATCH] Packing %d changed resources...",#entries))
    local content=M.encode(entries)
    local f=assert(io.open(bundle,"wb"))
    local written,write_error=f:write(content)
    local closed,close_error=f:close()
    assert(written and closed,write_error or close_error)
    log(string.format("[WRITE_BATCH] Packed %d bytes in %d ms; applying files and refreshing editor resources...",#content,math.floor((os.clock()-started)*1000+.5)))
    host.stats.add("raw_writes")
    host.stats.add("reloading_executes")
    started=os.clock()
    local result=host.execute("powershell.exe","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
        "-File",root.."/hooks/tools/apply_write_bundle.ps1","-ProjectRoot",root,"-Bundle",bundle,
        {reload_resources=true,out="capture",err="stdout"})
    if result and result~="" then log(result) end
    log(string.format("[WRITE_BATCH] Helper and editor refresh finished in %d ms; verifying files...",math.floor((os.clock()-started)*1000+.5)))
end
return M
