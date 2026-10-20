-- Project-owned wizard overrides. Authored baseline files are never replaced.
local Model = require "mvtk.core.creator_settings_model"
local Transaction = require "mvtk.editor.project_transaction"
local PlayerScaleWriter = require "mvtk.editor.player_scale_writer"
local PlayerScale = require "mvtk.player.player_scale"
local M = {}

local function load_table(content, path)
    local chunk = assert((loadstring or load)(content, "@" .. path))
    local value = chunk()
    assert(type(value) == "table", path .. " must return a table")
    return value
end

local function project_root(base, opts)
    if opts and opts.project_root then return opts.project_root end
    if base == "developer" then return "." end
    return base:match("^(.*)/developer$")
end

function M.recover(base, opts)
    base = base or "developer"
    local recovered = Transaction.recover(base, opts)
    local root = project_root(base, opts)
    if root then recovered = Transaction.recover(root, opts) or recovered end
    return recovered
end

-- Rebuild geometry from the saved effective settings without publishing drafts
-- or rewriting the wizard document. Called by Prepare & Check.
function M.prepare(opts)
    opts=opts or {}
    local base=(opts.base or "developer"):gsub("\\", "/"):gsub("/$", "")
    local ok,result=pcall(function()
        M.recover(base,opts)
        local read=opts.fs and opts.fs.read or Transaction.read
        local player=load_table(read(base.."/config/player_settings.lua"),"player_settings.lua")
        local text=read(base.."/config/creator_settings.lua")
        local doc=text and Model.load_document(load_table(text,"creator_settings.lua"),player)
        if doc and doc.published==true then Model.merge(player,doc.overrides.player or {}) end
        local errors=require("mvtk.core.config_validator").validate_config(player,
            require("mvtk.core.config_schemas").player_settings)
        assert(#errors==0,table.concat(errors,"; "))
        local files=PlayerScaleWriter.stage({base=base,read=read,player=player,
            previous=Model.copy(player),force_geometry=true})
        return Transaction.commit(base,files,opts)
    end)
    if ok then return result end
    return nil,{error="player_settings_prepare_failed",message=tostring(result)}
end

function M.save(data, opts)
    opts = opts or {}
    local base = (opts.base or "developer"):gsub("\\", "/"):gsub("/$", "")
    local function run()
        M.recover(base, opts)
        -- Existing callback is now a preflight: failure cannot publish settings.
        if opts.validate_generated_configs then
            local valid, message = opts.validate_generated_configs()
            if not valid then error(message or "Configuration validation failed", 0) end
        end
        local read = opts.fs and opts.fs.read or Transaction.read
        local player_path = base .. "/config/player_settings.lua"
        local baseline = load_table(read(player_path) or data.player_settings, player_path)
        local creator_path = base .. "/config/creator_settings.lua"
        local previous_text = read(creator_path)
        local previous = previous_text and load_table(previous_text, creator_path)
            or { version = Model.VERSION, player_units = Model.baseline_units(baseline), overrides = {} }
        previous = Model.load_document(previous, baseline)
        if data.expected_document then
            assert(Model.encode(previous) == Model.encode(Model.load_document(data.expected_document, baseline)),
                "Project settings changed since the wizard opened. Rebuild and reopen before saving.")
        end
        local values = Model.copy(data.player_preset or data.controls or {})
        if data.player_scale ~= nil then values.player_scale = data.player_scale end
        if data.scale_movement ~= nil then values.scale_movement = data.scale_movement end
        local doc = data.requested_document and Model.copy(Model.load_document(data.requested_document, baseline))
            or Model.from_controls(values, previous, baseline)
        doc.player_units = Model.baseline_units(baseline)
        -- A Save with no edits still retires runtime switches from older drafts.
        Model.prune_legacy(doc)
        doc.published = true
        local files = {}
        -- These compatibility outputs are only scaffolds for a missing baseline.
        for _, item in ipairs({
            { "config/player_settings.lua", data.player_settings },
            { "config/ability_defaults.lua", data.ability_defaults },
            { "config/combat_overrides.lua", data.combat_overrides },
        }) do
            if read(base .. "/" .. item[1]) == nil then
                assert(type(item[2]) == "string", "Missing baseline: " .. item[1])
                load_table(item[2], item[1])
                files[#files + 1] = { path = item[1], content = item[2] }
            end
        end
        local old_player = Model.merge(Model.copy(baseline), previous.overrides.player or {})
        local effective = Model.merge(Model.copy(baseline), doc.overrides.player or {})
        local Validator = require "mvtk.core.config_validator"
        local Schemas = require "mvtk.core.config_schemas"
        local errors = Validator.validate_config(effective, Schemas.player_settings)
        assert(#errors == 0, table.concat(errors, "; "))
        local ending_text=read(base.."/config/game_completion.lua")
        if ending_text then
            local ending=Model.merge(load_table(ending_text,"game_completion.lua"),doc.overrides.game_completion or {})
            local ending_errors=Validator.validate_config(ending,Schemas.game_completion)
            assert(#ending_errors==0,table.concat(ending_errors,"; "))
        end
        for _, file in ipairs(PlayerScaleWriter.stage({ base=base, read=read,
            player=effective, previous=old_player, force_geometry=opts.force_geometry })) do
            files[#files+1] = file
        end
        if opts.art_import then
            local cfg=Model.merge(PlayerScale.convert_units(load_table(assert(read(base.."/config/player_art.lua")),"player_art.lua"),
                "player_art",effective),doc.overrides.player_art or {})
            assert(Model.encode(cfg)==Model.encode(opts.art_import.config),"Player art settings changed after preview; import/preview again before Save.")
            local remaps=Model.copy((require("developer.config.game_config").player or {}).animation_overrides or {})
            Model.merge(remaps,effective.animation_overrides or {})
            require("developer.tools.player_art_import").validate_runtime(opts.art_import,remaps)
            local staged={}; for _,file in ipairs(files) do staged[file.path]=file.content end
            local art_files=require("developer.tools.player_art_import").stage(opts.art_import,effective,function(path)
                if path:sub(1,10)=="developer/" then return staged[path:sub(11)] or read(base.."/"..path:sub(11)) end
                return read(path)
            end)
            local replacements={}; for _,file in ipairs(art_files) do replacements[file.path]=true end
            local combined={}; for _,file in ipairs(files) do if not replacements[file.path] then combined[#combined+1]=file end end
            for _,file in ipairs(art_files) do combined[#combined+1]=file end
            files=combined
            doc.overrides.player=doc.overrides.player or {}; doc.overrides.player.player_type="sprite"
        end
        files[#files + 1] = { path = "config/creator_settings.lua", content = Model.serialize(doc, baseline) }
        local root = project_root(base, opts)
        local identity
        if root and read(root .. "/game.project") and data.project_name then
            local Identity = require "developer.tools.project_identity"
            local identity_files
            identity_files, identity = Identity.stage(root, data.project_name, data.identity_proposal,
                {read=read, choice=data.identity_choice})
            if data.identity_choice == "copy" then
                require("developer.tools.player_data_migration").copy(data.identity_proposal, data.identity_review,
                    {ownership_confirmed=data.ownership_confirmed, sys=opts.sys, max_slots=opts.max_slots})
            end
            for _, file in ipairs(files) do file.path = "developer/" .. file.path end
            for _, file in ipairs(identity_files) do files[#files+1] = file end
        else root = nil end
        local written, cleanup_warning = Transaction.commit(root or base, files, opts)
        data.creator_document = doc
        data.identity = identity
        data.cleanup_warning = cleanup_warning
        return written
    end
    local ok, result = pcall(run)
    if ok then return result end
    return nil, { error = "creator_settings_save_failed", message = tostring(result) }
end

return M
