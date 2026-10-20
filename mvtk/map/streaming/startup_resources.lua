-- Resource-only startup warming. Baked room collections still instantiate via
-- the ordinary streamer. Unvisited resources retain a lease until first use;
-- then the ordinary bounded resource cache owns their lifetime.
local M = {}

function M.new(resources, rooms, factory_url)
    local queue, retained, claimed = {}, {}, {}
    for id in pairs(rooms) do queue[#queue + 1] = id end
    table.sort(queue)
    local index, active = 1, nil
    local service = {}

    function service.ready() return index > #queue end

    function service.claim(id)
        claimed[id] = true
        if retained[id] then
            resources.release(retained[id])
            retained[id] = nil
        end
    end

    function service.update()
        if service.ready() then return end
        local id = queue[index]
        if not active and claimed[id] then index = index + 1; return end
        if not active then
            local url = factory_url(id)
            if not url then
                print('[ROOM_MANAGER] Cannot warm room with missing factory: ' .. id)
                index = index + 1
                return
            end
            active = {}
            active.resource = resources.acquire(active, url)
            retained[id] = active
        end
        resources.start(active)
        local err = resources.error(active)
        if active.resource.state == 'ready' or err then
            if err then
                -- An unrelated broken room must not prevent starting the game.
                -- Ordinary arrival reports/retries its error when needed.
                print('[ROOM_MANAGER] Room resource warmup failed: ' .. id .. ': ' .. tostring(err))
                resources.release(active)
                retained[id] = nil
            end
            active = nil
            index = index + 1
        end
    end

    function service.release_all()
        for _, owner in pairs(retained) do resources.release(owner) end
        retained = {}
        active = nil
        index = #queue + 1
    end

    return service
end

return M
