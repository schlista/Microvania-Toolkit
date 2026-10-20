-- Owns factory references independently of spawned objects. Defold cannot
-- cancel an in-flight load: abandoned requests must finish, then unload.
-- Callbacks only publish results; all engine work stays on the owner's update.
local M = {}

function M.new(options, api)
    options = options or {}
    api = api or collectionfactory
    local records, leases = {}, {}
    local clock, active = 0, 0
    local limit = math.max(1, tonumber(options.resource_load_concurrency) or 2)
    local timeout = math.max(1, tonumber(options.resource_load_timeout) or 15)
    local retries = math.max(1, tonumber(options.resource_load_attempts) or 3)
    local retry_delay = math.max(0.1, tonumber(options.resource_retry_delay) or 1)
    local cache_limit = math.max(0, math.floor(tonumber(options.resource_cache_rooms) or 0))
    local stats = { loads = 0, unloads = 0, failures = 0, timeouts = 0, cache_hits = 0 }
    local service = {}

    function service.acquire(owner, url)
        assert(not leases[owner], "duplicate resource lease")
        local key = tostring(url)
        local r = records[key]
        if not r then
            r = { key = key, url = url, state = "queued", owners = {}, attempts = 0 }
            records[key] = r
        end
        if r.cached then stats.cache_hits = stats.cache_hits + 1 end
        r.cached = false
        r.owners[owner], leases[owner] = true, r
        return r
    end

    function service.release(owner)
        local r = leases[owner]
        if r then
            r.owners[owner], leases[owner] = nil, nil
            if not next(r.owners) then
                -- Only retain a successfully prepared resource. Abandoned or
                -- timed-out in-flight requests must still drain and unload.
                r.cached = r.state == "ready" and not r.timed_out and cache_limit > 0
                r.released_at = clock
            end
        end
    end

    local function fail(r, reason)
        r.state, r.error = "failed", tostring(reason)
        r.retry_at = clock + retry_delay
        stats.failures = stats.failures + 1
    end

    function service.start(owner)
        local r = leases[owner]
        if not r or r.state == "ready" or r.state == "loading" or r.state == "discard" then return end
        if r.state == "failed" and (r.attempts >= retries or clock < r.retry_at) then return end
        if active >= limit then return end
        r.attempts = r.attempts + 1
        local ok, status = pcall(api.get_status, r.url)
        if not ok then fail(r, status); return end
        if status == api.STATUS_LOADED then
            r.state, r.error = "ready", nil
            return
        end
        -- A previous owner must never be bypassed by a second load/create.
        if status == api.STATUS_LOADING then
            fail(r, "factory already loading outside room streamer")
            return
        end
        r.state, r.error, r.started, r.timed_out = "loading", nil, clock, false
        r.completed = nil
        active = active + 1
        stats.loads = stats.loads + 1
        local started, err = pcall(api.load, r.url, function(_, _, success)
            r.completed = success == true
        end)
        if not started then
            active = active - 1
            fail(r, err)
        end
    end

    function service.update(dt)
        clock = clock + math.max(0, dt or 0)
        local idle = {}
        for _, r in pairs(records) do
            if r.cached and not next(r.owners) then idle[#idle + 1] = r end
        end
        table.sort(idle, function(a, b)
            if a.released_at == b.released_at then return a.key < b.key end
            return a.released_at < b.released_at
        end)
        for i = 1, #idle - cache_limit do idle[i].cached = false end
        for key, r in pairs(records) do
            if r.state == "loading" then
                if r.completed ~= nil then
                    active = active - 1
                    local success = r.completed
                    r.completed = nil
                    if success and not r.timed_out then
                        r.state, r.error = "ready", nil
                    else
                        -- A late success still owns resources. Release them
                        -- before retrying; retain this record if unload fails.
                        r.state = success and "discard" or "failed"
                        r.error = r.error or "factory resource load failed"
                        r.retry_at = clock + retry_delay
                        stats.failures = stats.failures + 1
                    end
                elseif not r.timed_out and clock - r.started >= timeout then
                    r.timed_out, r.error = true, "factory resource load timed out"
                    stats.timeouts = stats.timeouts + 1
                end
            end
            if r.state ~= "loading" and ((not next(r.owners) and not r.cached) or r.state == "discard") then
                local ok, err = pcall(api.unload, r.url)
                if ok then
                    stats.unloads = stats.unloads + 1
                    if not next(r.owners) then records[key] = nil
                    else r.state = "failed" end
                else
                    r.error = "factory unload failed: " .. tostring(err)
                end
            end
        end
    end

    function service.error(owner)
        local r = leases[owner]
        if r and (r.timed_out or (r.state == "failed" and r.attempts >= retries)) then
            return r.error
        end
    end

    -- Only an explicit new arrival retries an exhausted request. A timed-out
    -- load still in flight cannot be restarted until its callback is drained.
    function service.retry(owner)
        local r = leases[owner]
        if r and r.state == "failed" then
            r.attempts, r.retry_at, r.timed_out, r.error = 0, clock, false, nil
            return true
        end
        return false
    end

    function service.release_all()
        for owner in pairs(leases) do service.release(owner) end
        for _, r in pairs(records) do r.cached = false end
        service.update(0)
    end

    function service.snapshot()
        local result = { loading = active, resident = 0, records = 0, leases = 0, cached = 0 }
        for k, v in pairs(stats) do result[k] = v end
        for _ in pairs(leases) do result.leases = result.leases + 1 end
        for _, r in pairs(records) do
            result.records = result.records + 1
            if r.cached then result.cached = result.cached + 1 end
            if r.state == "ready" or r.state == "discard" then result.resident = result.resident + 1 end
        end
        return result
    end
    return service
end

return M
