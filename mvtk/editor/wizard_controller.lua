-- Editing sessions own drafts. Runtime never reads machine-local wizard files.
-- Keeping this independent of GUI code makes review, reset and save testable.
local Model = require "mvtk.core.creator_settings_model"
local M = {}
local Session = {}
Session.__index = Session

function M.new(baseline, document, legacy)
    document = Model.copy(Model.validate(document))
    return setmetatable({ baseline = Model.copy(baseline), original = document,
        draft = Model.copy(document), legacy = Model.copy(legacy) }, Session)
end

function Session:values() return Model.controls(self.draft.overrides, self.baseline) end

function Session:set(key, value)
    assert(Model.fields[key], "Unknown creator setting: " .. tostring(key))
    self.draft = Model.from_controls({ [key] = value }, self.draft,
        self.baseline.player or { units_version = self.draft.player_units or 1 })
    self.review = nil
end

function Session:preset(values)
    self.draft = Model.from_controls(values, self.draft,
        self.baseline.player or { units_version = self.draft.player_units or 1 })
    self.review = nil
end

function Session:reset(key)
    Model.reset(self.draft, key)
    self.review = nil
end

function Session:restore_saved()
    self.art_import=nil
    self.draft = Model.copy(self.original)
    self.review = nil
end

function Session:field(key)
    local spec = assert(Model.fields[key], "Unknown creator setting")
    local raw = Model.get(self.draft.overrides, spec.path)
    local baseline = Model.controls({}, self.baseline)[key]
    return { value = self:values()[key], inherited = baseline,
        source = raw ~= nil and "Project override" or "Inherited",
        help = spec.help, units = spec.units, label = spec.label }
end

local function diff(before, after, path, rows)
    local keys = {}
    for key in pairs(before or {}) do keys[key] = true end
    for key in pairs(after or {}) do keys[key] = true end
    for key in pairs(keys) do
        local old, value = (before or {})[key], (after or {})[key]
        local name = path == "" and tostring(key) or path .. "." .. tostring(key)
        if type(old) == "table" and type(value) == "table" then
            diff(old, value, name, rows)
        elseif type(value) == "table" then
            diff({}, value, name, rows)
        elseif old ~= value then rows[#rows + 1] = { path = name, before = old, after = value } end
    end
end

-- Effective values (baseline + overrides) so re-selecting an inherited value,
-- or cycling a preset back, is not reported as a change.
local function effective_changes(baseline, before, after)
    local rows = {}
    diff(Model.merge(Model.copy(baseline or {}), (before or {}).overrides or {}),
        Model.merge(Model.copy(baseline or {}), (after or {}).overrides or {}), "", rows)
    return rows
end

--- True when the draft differs from the last saved project settings (or an
-- art import is waiting for Save). Closing Game Settings checks this first.
function Session:is_dirty()
    if self.art_import ~= nil then return true end
    return #effective_changes(self.baseline, self.original, self.draft) > 0
end

--- True when saved project settings have not been built yet.
-- compiled: the creator document this build started with.
-- current: the in-memory project document (Save swaps it in this session).
-- disk_text: developer/config/creator_settings.lua as saved on disk, when
-- readable (games launched from the Defold editor run in the project folder;
-- exported games have no such file and pass nil).
function M.build_required(compiled, current, disk_text, baseline_player)
    baseline_player = baseline_player or require "developer.config.player_settings"
    if type(compiled) ~= "table" then return false end
    if type(current) == "table" and #effective_changes({}, compiled, current) > 0 then
        return true
    end
    if type(disk_text) == "string" and disk_text ~= "" then
        local chunk = (loadstring or load)(disk_text, "@creator_settings.lua")
        if chunk then
            if setfenv then setfenv(chunk, {}) end
            local ok, doc = pcall(chunk)
            if ok and type(doc) == "table" then
                local valid, loaded = pcall(Model.load_document, doc, baseline_player)
                if not valid or #effective_changes({}, compiled, loaded) > 0 then return true end
            end
        end
    end
    return false
end

function Session:review_legacy()
    assert(type(self.legacy) == "table", "No legacy local wizard settings were found")
    local candidate = Model.copy(self.draft)
    candidate.published = true
    Model.merge(candidate.overrides, self.legacy)
    Model.validate(candidate)
    local rows = {}
    diff(Model.merge(Model.copy(self.baseline), self.draft.overrides),
        Model.merge(Model.copy(self.baseline), candidate.overrides), "", rows)
    table.sort(rows, function(a,b) return a.path < b.path end)
    self.review = { document = candidate, rows = rows }
    return Model.copy(rows)
end

function Session:save(options, reviewed_legacy)
    options = options or {}
    options.save_options=options.save_options or {}
    options.save_options.art_import=self.art_import
    local doc = Model.copy(self.draft)
    if reviewed_legacy then
        assert(self.review, "Review legacy changes before applying them")
        doc = Model.copy(self.review.document)
    end
    doc.published = true
    local run = options.run or require("developer.tools.setup_wizard").run_noninteractive
    local result = run({ project_name = options.project_name,
        identity_proposal = options.identity_proposal, identity_choice = options.identity_choice,
        identity_review = options.identity_review, ownership_confirmed = options.ownership_confirmed,
        player_key = "custom", custom_player = self:values(),
        creator_document = doc, expected_document = self.original,
        save_options = options.save_options,
    })
    if result and result.ok then
        self.art_import=nil
        self.original = Model.copy(result.out.creator_document)
        self.draft = Model.copy(self.original)
        self.review = nil
        if reviewed_legacy then self.legacy = nil end
    end
    return result
end

return M
