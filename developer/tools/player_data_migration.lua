-- Explicit desktop migration of player data only. Layout/wizard drafts are excluded.
local Model = require "mvtk.core.creator_settings_model"
local Upgrades = require "mvtk.core.save_migrations"
local M = {}

local function api(opts)
    local host = (opts or {}).sys or sys
    assert(host and host.load and host.save and host.get_save_file,
        "Player data inspection requires the running desktop wizard")
    return host
end

local function equal(a,b) return Model.encode(a) == Model.encode(b) end

function M.review(proposal, opts)
    opts = opts or {}
    local host = api(opts)
    local files = {{name="mvtk_settings", kind="settings"}, {name="mvtk_bindings_v2", kind="bindings"},
        {name="mvtk_last_slot", kind="last_slot"}}
    local slots = opts.max_slots or require("developer.config.game_config").progression.saves.max_slots
    for slot = 1, slots do
        for _, suffix in ipairs({"", "_backup", ".bak", "_pre_upgrade"}) do
            files[#files+1] = {name="mvtk_save_slot_" .. slot .. suffix, kind="save"}
        end
    end
    local review = {source=proposal.source, destination=proposal.destination, entries={}, errors={}}
    local validate = opts.validate_save or require("mvtk.core.checkpoint").validate_saved
    for _, file in ipairs(files) do
        local from = host.get_save_file(proposal.source, file.name)
        local to = host.get_save_file(proposal.destination, file.name)
        local read_ok, data = pcall(host.load, from)
        if not read_ok or type(data) ~= "table" then
            review.errors[#review.errors+1] = file.name .. ": unreadable source"
        elseif next(data) ~= nil then
            local valid, reason
            if file.kind == "save" then
                if data.__deleted == true then valid = true else valid, reason = validate(data) end
                local owner=data.meta and data.meta.game_id
                local expected=proposal.previous_game_id ~= "" and proposal.previous_game_id or proposal.title
                if owner and owner ~= "" and owner ~= expected then valid=false; reason="different_game" end
            elseif file.kind == "settings" then valid, reason = Upgrades.preferences(data)
            elseif file.kind == "bindings" then valid = data.version == 2 and type(data.bindings) == "table"
            else valid = type(data.slot) == "number" and data.slot >= 1 and data.slot <= slots and data.slot % 1 == 0 end
            if not valid then review.errors[#review.errors+1] = file.name .. ": " .. tostring(reason or "unsupported data") end
            local target_ok, target = pcall(host.load, to)
            if not target_ok or type(target) ~= "table" or (next(target) and not equal(target,data)) then
                review.errors[#review.errors+1] = file.name .. ": destination already contains different data"
            end
            review.entries[#review.entries+1] = {name=file.name, from=from, to=to, data=Model.copy(data)}
        end
    end
    -- Toolkit titles were shared by unrelated projects; title alone cannot prove ownership.
    if #review.entries > 0 and require("developer.tools.project_identity").is_shared_title(proposal.title) then
        review.errors[#review.errors+1] = "Shared toolkit namespace: ownership is ambiguous. Start fresh; originals will remain available."
    end
    return review
end

function M.copy(proposal, reviewed, opts)
    opts = opts or {}
    assert(opts.ownership_confirmed == true, "Confirm that these player files belong to this game")
    local host = api(opts)
    local current = M.review(proposal, opts)
    assert(#current.errors == 0, table.concat(current.errors,"\n"))
    assert(reviewed and equal(reviewed,current), "Player data changed since review. Review it again before copying.")
    -- Validate the entire batch before writing; retries accept identical destinations.
    for _, entry in ipairs(current.entries) do
        local target = host.load(entry.to)
        if next(target) == nil then
            local ok, result = pcall(host.save, entry.to, entry.data)
            assert(ok and result ~= false, "Player data copy failed: " .. entry.name)
        end
        assert(equal(host.load(entry.to),entry.data), "Player data verification failed: " .. entry.name)
    end
    return #current.entries
end

return M
