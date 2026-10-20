-- Command-scoped editor I/O telemetry. No editor dependency; inactive at runtime.
local M = {}
local state, seen, log
local function fresh()
    return {unchanged=0, created_batched=0, rewritten_existing=0, rewritten_batched=0, raw_writes=0,
        removes=0, create_directory=0, create_resources=0, reloading_executes=0,
        write_seconds=0, rewritten_paths={}, churn={}}
end
function M.reset(logger)
    state, seen, log = fresh(), {}, logger or print
end
function M.finish() seen=nil end
function M.add(key, amount)
    if seen then state[key]=(state[key] or 0)+(amount or 1) end
end
function M.observe(path, content)
    if not seen then return end
    path=path:gsub("\\", "/")
    if seen[path] and seen[path]~=content then
        local warning="[PERF][WARNING] "..path.." written twice with different content in one run"
        state.churn[#state.churn+1]=path; log(warning)
    end
    seen[path]=content
end
function M.written(path, existing, started)
    if not seen then return end
    M.add(existing and "rewritten_existing" or "raw_writes")
    M.add("write_seconds",os.clock()-started)
    if existing and #state.rewritten_paths<50 then state.rewritten_paths[#state.rewritten_paths+1]=path end
end
function M.stats() return state or fresh() end
function M.lines()
    local s=M.stats(); local lines={}
    for _,key in ipairs({"unchanged","created_batched","rewritten_existing","rewritten_batched","raw_writes","removes","create_directory","create_resources","reloading_executes"}) do
        lines[#lines+1]="[PERF] "..key..": "..tostring(s[key])
    end
    lines[#lines+1]="[PERF] estimated resource syncs: "..tostring(s.rewritten_existing-s.rewritten_batched+s.raw_writes+s.removes+s.create_directory+s.create_resources+s.reloading_executes)
    lines[#lines+1]=string.format("[PERF] write time: %d ms",math.floor(s.write_seconds*1000+.5))
    for _,path in ipairs(s.rewritten_paths) do lines[#lines+1]="[PERF] rewritten: "..path end
    return lines
end
return M
