-- Pure, copy-on-read save upgrades. Call only after checking stored integrity.
local M = { VERSION = 2 }

function M.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = M.copy(item) end
    return out
end

function M.equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k,v in pairs(a) do if not M.equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function M.check(data, providers, game_id)
    if type(data) ~= "table" or (data.meta ~= nil and type(data.meta) ~= "table")
        or (data.modules ~= nil and type(data.modules) ~= "table") then return false, "invalid_save" end
    local meta = data.meta or {}
    if meta.identity_aliases ~= nil and type(meta.identity_aliases) ~= "table" then return false, "invalid_identity_history" end
    local version = meta.version or 1
    if type(version) ~= "number" or version % 1 ~= 0 or version < 1 then return false, "invalid_version" end
    if version > M.VERSION then return false, "future_version" end
    if meta.game_id and game_id and game_id ~= "" and meta.game_id ~= game_id then return false, "different_game" end
    for id, payload in pairs(data.modules or {}) do
        if type(payload) ~= "table" then return false, "invalid_provider:" .. tostring(id) end
        local stored = payload.version or 1
        if type(stored) ~= "number" or stored < 1 or stored % 1 ~= 0 then return false, "invalid_provider_version:" .. tostring(id) end
        local provider = (providers or {})[id]
        if provider and stored > provider.version then return false, "future_provider:" .. id end
        if provider then
            for v = stored, provider.version - 1 do
                if not (provider.migrations and provider.migrations[v]) then return false, "missing_provider_migration:" .. id end
            end
        end
    end
    return true
end

-- Exact-path aliases avoid accidentally rewriting dialogue text or unrelated IDs.
-- Keep old keyed identities as aliases; conflicting destinations are never merged.
function M.validate_aliases(aliases)
    assert(type(aliases)=="table", "Identifier aliases must be a list")
    local graphs={}
    for _,a in ipairs(aliases) do
        assert(type(a.path)=="table" and #a.path>0 and a.path[1]~="meta", "Invalid alias path")
        assert(a.mode=="key" or a.mode=="value", "Invalid alias mode")
        assert(type(a.from)=="string" and type(a.to)=="string" and a.from~="" and a.to~="" and a.from~=a.to,"Invalid alias IDs")
        assert(a.hash_prefix==nil or type(a.hash_prefix)=="string", "Invalid hash prefix")
        local scope=table.concat(a.path,"/") .. ":" .. a.mode .. ":" .. (a.hash_prefix or "")
        local graph=graphs[scope] or {}; graphs[scope]=graph
        assert(not graph[a.from] or graph[a.from]==a.to,"Ambiguous alias source: " .. a.from)
        for from,to in pairs(graph) do assert(to~=a.to or from==a.from,"Ambiguous alias destination: " .. a.to) end
        graph[a.from]=a.to
    end
    for _,graph in pairs(graphs) do
        for from in pairs(graph) do
            local seen,at={},from
            while graph[at] do assert(not seen[at],"Cyclic identifier aliases"); seen[at]=true; at=graph[at] end
        end
    end
    return true
end

function M.aliases(data, aliases, encode_hash)
    M.validate_aliases(aliases or {})
    for _, alias in ipairs(aliases or {}) do
        local parts={alias.mode,alias.hash_prefix or "",alias.from,alias.to}
        for _,part in ipairs(alias.path) do parts[#parts+1]=tostring(part) end
        for i,part in ipairs(parts) do parts[i]=#part .. ":" .. part end
        local rule=table.concat(parts,"|")
        local applied=data.meta and data.meta.identity_aliases or {}
        if not applied[rule] then
            if alias.hash_prefix then
                assert(encode_hash,"Hashed identifier aliases require Defold's hash encoder")
                alias=M.copy(alias)
                alias.from=alias.hash_prefix .. encode_hash(alias.from)
                alias.to=alias.hash_prefix .. encode_hash(alias.to)
            end
            assert(type(alias.path) == "table" and #alias.path > 0, "Alias requires a path")
            assert(type(alias.from) == "string" and alias.from ~= "" and type(alias.to) == "string"
                and alias.to ~= "" and alias.from ~= alias.to, "Invalid identifier alias")
            assert(alias.mode == "key" or alias.mode == "value", "Alias mode must be key or value")
            local parent = data
            for i = 1, #alias.path - 1 do parent = type(parent) == "table" and parent[alias.path[i]] or nil end
            local key = alias.path[#alias.path]
            local changed=false
            if type(parent) == "table" then
                if alias.mode == "value" and parent[key] == alias.from then parent[key] = alias.to; changed=true end
                local map = parent[key]
                if alias.mode == "key" and type(map) == "table" and map[alias.from] ~= nil then
                    local old, dest = map[alias.from], map[alias.to]
                    if dest ~= nil then
                        assert(M.equal(old,dest), "Conflicting save alias: " .. alias.from .. " -> " .. alias.to)
                    else map[alias.to] = M.copy(old) end
                    changed=true
                end
            end
            if changed then
                data.meta=data.meta or {}
                data.meta.identity_aliases=data.meta.identity_aliases or {}
                data.meta.identity_aliases[rule]=true
            end
        end
    end
    return data
end

function M.upgrade(data, providers, game_id, aliases, encode_hash)
    local valid, reason = M.check(data, providers, game_id)
    if not valid then return nil, reason end
    local out = M.copy(data)
    out.meta = out.meta or {}
    out.meta.version = M.VERSION
    out.modules = out.modules or {}
    for id, payload in pairs(out.modules) do
        local provider = (providers or {})[id]
        if provider then
            for v = payload.version or 1, provider.version - 1 do
                payload.data = assert(provider.migrations[v](M.copy(payload.data)), "Migration returned no data: " .. id)
                payload.version = v + 1
            end
        end
    end
    return M.aliases(out, aliases, encode_hash)
end

function M.preferences(data)
    if type(data) ~= "table" then return nil, "invalid_settings" end
    for _, section in ipairs({"audio", "graphics", "gameplay"}) do
        if data[section] ~= nil and type(data[section]) ~= "table" then return nil, "invalid_settings_section:" .. section end
    end
    local version = data.version or 0
    if version ~= 0 and version ~= 1 then return nil, "unsupported_settings_version" end
    local out = M.copy(data)
    out.version = 1
    return out
end

return M
