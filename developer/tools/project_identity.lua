-- Project identity authoring, used by the desktop wizard and headless tooling.
-- Planning is read-only; callers publish stage() with the settings transaction.
local Paths = require "mvtk.core.save_paths"
local Model = require "mvtk.core.creator_settings_model"
local Transaction = require "mvtk.editor.project_transaction"
local M = {}

-- Template for a missing persistence_settings.lua; the shipped file is the
-- documented source of truth for these values.
local DEFAULT_SHARED_TITLES = { "microvania toolkit", "metroidvania toolkit", "mv_toolkit" }

local function config(text)
    if not text then return { game_id = "", shared_titles = Model.copy(DEFAULT_SHARED_TITLES) } end
    local fn = assert(loadstring and loadstring(text, "@persistence_settings.lua")
        -- Lua 5.2+ hosts only; the linter's Lua 5.1 load() takes two arguments.
        ---@diagnostic disable-next-line: redundant-parameter
        or load(text, "@persistence_settings.lua", "t", {}))
    if setfenv then setfenv(fn, {}) end
    local value = fn()
    assert(type(value) == "table" and type(value.game_id) == "string", "Invalid persistence settings")
    return value
end

local function project_title(text, replacement)
    assert(type(text) == "string", "Cannot read game.project")
    local active, title, count = false, nil, 0
    local result = text:gsub("([^\r\n]*)(\r?\n?)", function(line, ending)
        local section = line:match("^%s*%[([^%]]+)%]%s*$")
        if section then active = section == "project" end
        if active then
            local prefix, value = line:match("^(%s*title%s*=%s*)(.-)%s*$")
            if prefix then
                count = count + 1; title = value
                if replacement then line = prefix .. replacement end
            end
        end
        return line .. ending
    end)
    assert(count == 1, "game.project must contain exactly one [project] title")
    return title, result
end

-- Lower-cased toolkit placeholder titles from persistence_settings.shared_titles.
-- A config without the key keeps the shipped defaults so the migration safety
-- rule cannot vanish silently; an explicit empty list disables the check.
function M.shared_titles(cfg)
    cfg = cfg or require("developer.config.persistence_settings")
    local titles = cfg.shared_titles
    if titles == nil then titles = DEFAULT_SHARED_TITLES end
    local out = {}
    for _, title in ipairs(type(titles) == "table" and titles or {}) do
        out[#out + 1] = tostring(title):lower()
    end
    return out
end

-- True when a Game Name still carries a toolkit placeholder, which would make
-- the game indistinguishable from other toolkit games (and their pre-ID saves).
function M.is_shared_title(title, cfg)
    title = tostring(title or ""):lower()
    for _, shared in ipairs(M.shared_titles(cfg)) do
        if shared ~= "" and title:find(shared, 1, true) then return true end
    end
    return false
end

function M.new_id()
    -- Use the OS UUID generator, never a time-seeded gameplay random sequence.
    local value
    if editor and editor.execute then
        if editor.platform == "x86_64-win32" then
            value = editor.execute("powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
                "-Command", "[guid]::NewGuid().ToString('N')", {out="capture", reload_resources=false})
        else value = editor.execute("uuidgen", {out="capture", reload_resources=false}) end
    else
        local command = package.config:sub(1,1) == "\\"
            and 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "[guid]::NewGuid().ToString(\'N\')"'
            or "uuidgen"
        local pipe = assert(io.popen(command, "r"), "Cannot generate a game ID")
        value = pipe:read("*a"); pipe:close()
    end
    value = tostring(value):lower():gsub("[%s%-]", "")
    assert(#value == 32 and value:match("^[0-9a-f]+$"), "OS UUID generation failed")
    return "game_" .. value
end

function M.inspect(root, opts)
    opts = opts or {}
    local read = opts.read or Transaction.read
    local project = read(root .. "/game.project")
    local persistence = read(root .. "/developer/config/persistence_settings.lua")
    local cfg = config(persistence)
    local title = project_title(project)
    return {title=title, game_id=cfg.game_id, shared_titles=M.shared_titles(cfg), project_text=project, persistence_text=persistence,
        source=Paths.for_identity(cfg.game_id ~= "" and cfg.game_id or title)}
end

function M.propose(current, opts)
    opts = opts or {}
    local out = Model.copy(current)
    out.previous_game_id = current.game_id
    if current.game_id == "" or opts.new_game then out.game_id = (opts.new_id or M.new_id)() end
    assert(out.game_id:match("^[%w_.-]+$"), "Game ID must use letters, digits, _, . or -")
    if opts.new_game then assert(out.game_id ~= current.game_id, "A new game needs a different ID") end
    out.destination = Paths.for_identity(out.game_id)
    out.new_game = opts.new_game == true
    return out
end

-- Shared field and transaction validation; no file access.
function M.name_issue(name)
    if type(name) ~= "string" or name:find("[%c]") or not name:match("%S") then
        return "Enter a nonempty, single-line game name"
    end
    if #name:match("^%s*(.-)%s*$") > 120 then return "Game name must be at most 120 bytes" end
end

function M.stage(root, name, proposal, opts)
    opts = opts or {}
    local current = M.inspect(root, opts)
    assert(not M.name_issue(name), M.name_issue(name))
    name = name:match("^%s*(.-)%s*$")
    proposal = proposal or (current.game_id ~= "" and M.propose(current) or nil)
    assert(proposal, "A game ID proposal is required for this project's first save")
    assert(current.project_text == proposal.project_text and current.persistence_text == proposal.persistence_text,
        "Project identity changed since review. Reopen the wizard before saving.")
    assert(proposal.game_id:match("^[%w_.-]+$"), "Invalid game ID")
    if current.game_id ~= proposal.game_id then
        assert(current.game_id == "" or proposal.new_game, "To give a project copy a different game, set game_id to \"\" in persistence_settings.lua and Save once")
        assert(opts.choice == "fresh" or (current.game_id == "" and opts.choice == "copy"), "Review the identity change before saving")
    end
    local cfg = config(current.persistence_text)
    cfg.game_id = proposal.game_id
    local persistence
    if current.persistence_text then
        local count
        persistence, count = current.persistence_text:gsub('([\r\n]%s*game_id%s*=%s*)["\'][^"\'\r\n]*["\']', function(prefix)
            return prefix .. string.format("%q", cfg.game_id)
        end)
        assert(count == 1, "persistence_settings.lua needs one literal game_id assignment on its own line")
    else
        persistence = "-- Permanent save identity, assigned on the wizard's first Save. Renaming the\n"
            .. "-- display title keeps this ID; set it to \"\" in a project copy to make a different game.\n"
            .. "-- shared_titles: toolkit placeholder names that trigger the rename warning.\nreturn " .. Model.encode(cfg) .. "\n"
    end
    local _, project = project_title(current.project_text, name)
    return {
        {path="game.project", content=project},
        {path="developer/config/persistence_settings.lua", content=persistence},
    }, {title=name, game_id=cfg.game_id, source=proposal.source, destination=proposal.destination}
end

return M
