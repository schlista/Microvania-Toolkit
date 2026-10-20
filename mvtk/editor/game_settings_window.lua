-- Native Project > Game Settings. Layout and field metadata are shared data;
-- the draft uses the shared settings session and transactional project writer.
-- Render functions and callbacks only edit memory. M.run owns all file work
-- after show_dialog returns to the Project command's long-running context.
local Model = require "mvtk.core.creator_settings_model"
local Wizard = require "mvtk.editor.wizard_controller"
local Layout = require "developer.tools.game_settings_layout"
local Presets = require "developer.tools.game_settings_presets"
local Identity = require "developer.tools.project_identity"
local Context = require "mvtk.editor.game_settings_context"
local Number = require "mvtk.editor.settings_number"
local M = { TITLE = "Game Settings" }

M.CONFIG = {
    runtime = "developer/config/runtime_settings.lua",
    creator = "developer/config/creator_settings.lua",
}

function M.tabs() return Layout.tabs end
local function specification(key) return assert(Model.fields[key] or Model.identity_fields[key], "Unknown setting: " .. key) end
function M.label(key) return assert(specification(key).title, "Missing field title: " .. key) end

local function root_path(deps)
    return tostring(deps.root or "."):gsub("\\", "/"):gsub("/$", "")
end

-- Authored map color configs use vector4 constructor syntax. Read those colors
-- as plain data in this private config environment; the editor has no vmath
-- namespace and must never call a game-engine API just to read settings.
local function color_data(r, g, b, a)
    return { x = r, y = g, z = b, w = a }
end

local function load_table(text, name, env)
    local chunk, err
    if loadstring then
        chunk, err = loadstring(text, "@" .. name)
        if chunk and setfenv then setfenv(chunk, env) end
    else
        chunk, err = load(text, "@" .. name, "t", env)
    end
    assert(chunk, "Cannot read " .. name .. ": " .. tostring(err))
    local ok, value = pcall(chunk)
    assert(ok and type(value) == "table", "Cannot read " .. name .. ": " .. tostring(ok and "it returns no table" or value))
    return value
end

-- Execute a fresh copy of the existing runtime resolver with fresh config
-- dependencies. Its authored_snapshot includes combat unit conversions and
-- every Designer baseline before opening the draft. This local
-- cache lives for one load only; package.loaded is never changed or trusted
-- for project values. Framework modules remain ordinary shared dependencies.
function M.load(deps)
    local root, loaded = root_path(deps), {}
    local function fresh(name)
        if not name:match("^developer%.config%.") then return require(name) end
        if loaded[name] then return loaded[name] end
        local path = name:gsub("%.", "/") .. ".lua"
        local source = deps.read(root .. "/" .. path)
        if source == nil and path == M.CONFIG.creator then
            loaded[name] = { version = Model.VERSION,
                player_units = Model.baseline_units(fresh("developer.config.player_settings")), overrides = {} }
        else
            assert(source, "Cannot read " .. path)
            local env = setmetatable({ require = fresh, vmath = { vector4 = color_data } }, { __index = _G })
            env._G = env
            loaded[name] = load_table(source, path, env)
        end
        return loaded[name]
    end
    local runtime = fresh("developer.config.runtime_settings")
    local session = Wizard.new(runtime.authored_snapshot(), runtime.project_document())
    session.identity = Identity.inspect(root, { read = deps.read })
    return session
end

local function pretty(value)
    local text = (tostring(value):gsub("_", " "))
    return (text:gsub("^%l", string.upper))
end

-- LuaJ ignores %.Nf precision, so range labels use integer rounding.
function M.format_number(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return (Number.fixed(n, 2):gsub("0+$", ""):gsub("%.$", ""))
end

local function same(a, b) return a == b end

local function problem(key, value)
    local spec = assert(Model.fields[key], "Unknown setting: " .. key)
    if type(value) ~= spec.type then return "Enter a " .. spec.type .. "." end
    if spec.choices then
        for _, choice in ipairs(spec.choices) do if value == choice then return nil end end
        return "Choose an option from the list."
    end
    if spec.type ~= "number" then return nil end
    if value ~= value or value == math.huge or value == -math.huge then return "Enter a finite number." end
    if spec.integer and value ~= math.floor(value) then return "Enter a whole number." end
    if (spec.min and value < spec.min) or (spec.max and value > spec.max) then
        if spec.min and spec.max then
            return "Allowed: " .. M.format_number(spec.min) .. " to " .. M.format_number(spec.max) .. "."
        end
        return spec.min and ("Must be at least " .. M.format_number(spec.min) .. ".")
            or ("Must be at most " .. M.format_number(spec.max) .. ".")
    end
end

function M.range_issue(ui, key, value)
    local message = problem(key, value)
    return message and { severity = ui.ISSUE_SEVERITY.ERROR, message = message } or false
end

local function each_field(fn)
    for _, tab in ipairs(Layout.tabs) do
        for _, section in ipairs(tab.sections) do
            for _, key in ipairs(section.fields) do if Model.fields[key] then fn(key) end end
        end
    end
end

local function initial_values(session)
    local all, out = session:values(), {}
    each_field(function(key) out[key] = all[key] end)
    out.project_name = session.project_name or (session.identity and session.identity.title) or ""
    return out
end

local function starting_values(session, values) return Model.copy(values or initial_values(session)) end

local function with_value(values, key, value)
    local out = Model.copy(values)
    out[key] = value
    return out
end

local function count(values, other)
    local n = 0
    each_field(function(key) if not same(values[key], other[key]) then n = n + 1 end end)
    return n
end

-- Count underlying choices as well as visible invalid edits. A parent can mask
-- a child without erasing it; changing that child then switching its parent off
-- is still an unsaved change even when the displayed values look unchanged.
function M.unsaved_count(session, values, document, art_import)
    local extra = values.project_name ~= nil and session.identity and values.project_name ~= session.identity.title and 1 or 0
    if art_import or (art_import == nil and session.art_import) then extra = extra + 1 end
    if not document then return count(values, initial_values(session)) + extra end
    local before = Model.merge(Model.copy(session.baseline), session.original.overrides)
    local after = Model.merge(Model.copy(session.baseline), document.overrides)
    local saved, draft = {}, {}
    each_field(function(key)
        local spec = Model.fields[key]
        saved[key], draft[key] = Model.get(before, spec.path), Model.get(after, spec.path)
        if saved[key] == nil then saved[key] = spec.default end
        if draft[key] == nil then draft[key] = spec.default end
        if problem(key, values[key]) then draft[key] = values[key] end
    end)
    return count(draft, saved) + extra
end

function M.has_errors(values)
    local invalid = false
    each_field(function(key) if problem(key, values[key]) then invalid = true end end)
    return invalid
end

-- Construct a separate session: failed saves and cancel confirmation must never
-- consume the open window's draft. Reset goes through the session's reset API.
function M.draft_session(session, values, skip_invalid, document, art_import)
    local draft = Wizard.new(session.baseline, session.original)
    draft.draft = Model.copy(document or session.draft)
    draft.identity, draft.project_name = session.identity, values.project_name or session.project_name
    if art_import ~= false then draft.art_import = art_import or session.art_import end
    if document then
        assert(skip_invalid or not M.has_errors(values), "Correct the field errors before saving.")
        return draft
    end
    local before, defaults = session:values(), Model.controls({}, session.baseline)
    each_field(function(key)
        local issue = problem(key, values[key])
        if not (skip_invalid and issue) and not same(values[key], before[key]) then
            assert(not issue, M.label(key) .. ": " .. tostring(issue))
            if same(values[key], defaults[key]) then draft:reset(key)
            else draft:set(key, values[key]) end
        end
    end)
    return draft
end

function M.apply_preset(session, values, key, document)
    local draft = M.draft_session(session, values, true, document)
    if key == "current" then draft:restore_saved()
    else draft:preset(assert(Presets.player[key], "Unknown preset: " .. tostring(key))) end
    local out = initial_values(draft)
    out.project_name = key == "current" and (session.identity and session.identity.title or values.project_name) or values.project_name
    -- A preset must not silently discard an invalid edit on an unrelated tab.
    if key ~= "current" then
        each_field(function(field)
            if problem(field, values[field]) and Presets.player[key][field] == nil then out[field] = values[field] end
        end)
    end
    return out, draft.draft
end

local function dependency(spec, values)
    for _, condition in ipairs(spec.applies_when or {}) do
        local key, expected = condition:match("^([^=]+)=(.+)$")
        key = key or condition
        local enabled = expected and tostring(values[key]) == expected or (not expected and values[key] == true)
        if not enabled then
            local title = Model.fields[key] and Model.fields[key].title or pretty(key)
            return false, expected and ("Available when " .. title .. " is " .. pretty(expected) .. ".")
                or ("Available when " .. title .. " is on.")
        end
    end
    return true
end

-- Completion validation remains the shared authoring validator. This map only
-- routes its diagnostics to controls; it does not restate validation rules.
local ending_issue_fields = {
    invalid_completion_id = "ending_id", unknown_completion_id = "ending_id",
    missing_ending_region = "ending_condition", unpublished_ending_region = "ending_condition",
    missing_ending_flag = "ending_flag", unknown_ending_boss = "ending_boss_id",
    invalid_ending_condition = "ending_condition", invalid_continue_policy = "ending_continue_policy",
    invalid_ending_return = "ending_return_room", ending_disabled = "ending_enabled",
}
function M.field_issues(ui, session, values, context)
    local issues = {}
    each_field(function(key) issues[key] = M.range_issue(ui, key, values[key]) end)
    local identity = session.identity
    if identity then
        local name_error = Identity.name_issue(values.project_name)
        if name_error then issues.project_name = {severity=ui.ISSUE_SEVERITY.ERROR, message=name_error}
        elseif Identity.is_shared_title(values.project_name, {shared_titles=identity.shared_titles}) then
            issues.project_name = {severity=ui.ISSUE_SEVERITY.WARNING,
                message="Rename your game so its saves and exported build aren't confused with other toolkit games"}
        end
    end
    local source_error = Context.source_issue(values.art_source, values.art_mode, context)
    if source_error then issues.art_source = {severity=ui.ISSUE_SEVERITY.ERROR, message=source_error} end
    if context and context.ending and not M.has_errors(values) then
        local cfg = {}
        each_field(function(key)
            local field = Model.fields[key].path:match("^game_completion%.(.+)$")
            if field then cfg[field] = values[key] end
        end)
        local c = context.ending
        for _, d in ipairs(require("developer.tools.completion_authoring").validate(cfg, c.index, c.bosses, c.layout)) do
            local key = ending_issue_fields[d.code]
            if key and (not issues[key] or d.severity == "error") then
                issues[key] = {severity=d.severity == "error" and ui.ISSUE_SEVERITY.ERROR or ui.ISSUE_SEVERITY.WARNING,
                    message=d.message}
            end
        end
    end
    return issues
end
local function invalid_issues(ui, issues)
    for _, issue in pairs(issues) do
        if issue and issue.severity == ui.ISSUE_SEVERITY.ERROR then return true end
    end
    return false
end

function M.line_summary(value)
    local first = value:match("^[^\n]*") or ""
    local _, count = value:gsub("\n", "")
    return first .. (count > 0 and (" +" .. count .. " more " .. (count == 1 and "line" or "lines")) or "")
end

local function row(ui, key, values, defaults, set, issues, result, session)
    local spec = specification(key)
    local value, default = values[key], defaults[key]
    local enabled, reason = dependency(spec, values)
    local help = (spec.help or "") .. (reason and (" " .. reason) or "")
    local changed = not same(value, default)
    local props = { value = value, tooltip = help, enabled = enabled, issue = issues[key] or false,
        on_value_changed = function(new_value) if new_value ~= nil then set(key, new_value) end end }
    local input
    if spec.read_only then
        local id = session.identity and session.identity.game_id or ""
        input = ui.label({text=id ~= "" and id or "Assigned on first Save", tooltip=help})
        changed = false
    elseif spec.multiline then
        input = ui.horizontal({grow=true, spacing=ui.SPACING.SMALL, children={
            ui.label({text=M.line_summary(value), tooltip=help, grow=true}),
            ui.dialog_button({text="Edit lines…", enabled=enabled, result=result("lines", key)}),
        }})
    elseif spec.choices then
        props.options, props.to_string = spec.choices, pretty
        input = ui.select_box(props)
    elseif spec.type == "boolean" then input = ui.check_box(props)
    elseif spec.type == "string" then
        props.grow = true
        input = ui.string_field(props)
        if key == "art_source" and values.art_mode == "sheet" and ui.show_resource_dialog then
            input = ui.horizontal({grow=true, spacing=ui.SPACING.SMALL, children={input,
                ui.dialog_button({text="Browse…", enabled=enabled, result=result("browse")})}})
        end
    else
        props.grow = true
        input = ((spec.editor_integer or spec.integer) and ui.integer_field or ui.number_field)(props)
    end
    return {
        ui.label({ text = M.label(key), tooltip = help, alignment = ui.ALIGNMENT.LEFT,
            color = changed and ui.COLOR.OVERRIDE or ui.COLOR.TEXT }),
        input,
        ui.button({ icon = ui.ICON.CLEAR, enabled = enabled and changed and not spec.read_only,
            on_pressed = function() set(key, default, true) end }),
    }
end

local function section_view(ui, section, values, defaults, set, note, issues, result, session)
    local rows = {}
    for _, key in ipairs(section.fields) do rows[#rows + 1] = row(ui, key, values, defaults, set, issues, result, session) end
    return ui.vertical({ spacing = ui.SPACING.SMALL, children = {
        ui.heading({ text = section.title, style = ui.HEADING_STYLE.H4 }),
        note and ui.paragraph({ text = note, color = ui.COLOR.HINT }) or false,
        ui.grid({ columns = { {}, { grow = true }, {} }, children = rows }),
    } })
end

function M.summary(changed, edits)
    return (changed == 1 and "1 setting differs" or (tostring(changed) .. " settings differ"))
        .. " from the toolkit defaults (names in blue). "
        .. (edits == 1 and "1 unsaved change." or (tostring(edits) .. " unsaved changes."))
end

function M.component(ui)
    return ui.component(function(props)
        local values, set_values = ui.use_state(starting_values, props.session, props.values)
        local document, set_document = ui.use_state(Model.copy, props.document or props.session.draft)
        local preset, set_preset = ui.use_state("current")
        local pending, set_pending = ui.use_state(props.art_import or props.session.art_import or false)
        local art_notice, set_art_notice = ui.use_state(false)
        local function draft_copy()
            local draft = Wizard.new(props.session.baseline, props.session.original)
            draft.draft = Model.copy(document)
            draft.identity = props.session.identity
            draft.project_name = values.project_name
            return draft
        end
        local function publish_draft(draft, raw)
            local effective = initial_values(draft)
            effective.project_name = raw.project_name
            each_field(function(key) if problem(key, raw[key]) then effective[key] = raw[key] end end)
            set_document(draft.draft)
            set_values(effective)
        end
        local function set(key, value, reset)
            if key == "project_name" then set_values(with_value(values, key, value)); return end
            if pending and value ~= values[key] and (key:match("^art_") or key == "player_scale") then
                set_pending(false)
                set_art_notice("Art settings changed. Import and preview again to use the new art.")
            end
            local raw = with_value(values, key, value)
            if problem(key, value) then set_values(raw); return end
            local draft = draft_copy()
            if reset then draft:reset(key) else draft:set(key, value) end
            -- Store the session document as well as visible values: disabling a
            -- parent masks its children, but must not erase their saved choices.
            publish_draft(draft, raw)
        end
        local defaults = Model.controls({}, props.session.baseline)
        defaults.project_name = props.session.identity and props.session.identity.title or values.project_name
        local edits = M.unsaved_count(props.session, values, document, pending)
        local issues = M.field_issues(ui, props.session, values, props.context)
        local can_save = edits > 0 and not invalid_issues(ui, issues)
        local function result(action, key)
            return { action=action, key=key, values=values, document=document, art_import=pending }
        end
        local tabs = {}
        for index, tab in ipairs(Layout.tabs) do
            local sections = {}
            if index == 1 then
                sections[#sections + 1] = ui.horizontal({ spacing = ui.SPACING.SMALL, children = {
                    ui.label({ text = "Preset", alignment = ui.ALIGNMENT.LEFT }),
                    ui.select_box({ value = preset, options = Presets.order, to_string = pretty,
                        on_value_changed = set_preset }),
                    ui.button({ text = "Apply preset", on_pressed = function()
                        local next_values, next_document = M.apply_preset(props.session, values, preset, document)
                        set_document(next_document)
                        set_values(next_values)
                        if pending then set_pending(false); set_art_notice("Preset applied. Import and preview again to use the new art.") end
                    end }),
                } })
            end
            for section_index, section in ipairs(tab.sections) do
                local note = tab.title == "Abilities" and section_index == 1
                    and "Checked: unlocked when a new game starts. Unchecked: the player finds it as a pickup." or nil
                sections[#sections + 1] = section_view(ui, section, values, defaults, set, note, issues, result, props.session)
            end
            if tab.title == "Player art" then
                sections[#sections + 1] = ui.dialog_button({text="Import and preview…",
                    enabled=not M.has_errors(values), result=result("import")})
                sections[#sections + 1] = ui.paragraph({text=art_notice or (pending
                    and "Art is ready to save with the settings." or "Import and preview before using new player art."), color=ui.COLOR.HINT})
            elseif tab.title == "Movement test" or tab.title == "Camera" then
                local supported = props.platform == "x86_64-win32"
                local course = tab.title == "Movement test"
                sections[#sections + 1] = ui.dialog_button({
                    text=supported and (course and "Launch test course" or "Launch room preview") or "Previews need Windows for now",
                    enabled=supported and not M.has_errors(values),
                    result=result(course and "preview_course" or "preview_rooms")})
            elseif tab.title == "Ending" then
                sections[#sections + 1] = ui.dialog_button({text="Preview ending…", result=result("ending_preview")})
            end
            tabs[#tabs + 1] = ui.tab({ text = tab.title, content = ui.scroll({ content = ui.vertical({
                padding = ui.PADDING.MEDIUM, spacing = ui.SPACING.LARGE, children = sections }) }) })
        end
        return ui.dialog({
            title = M.TITLE, width = 760, height = 680, resizable = true,
            header = ui.vertical({ spacing = ui.SPACING.SMALL, children = {
                ui.heading({ text = "Game Settings", style = ui.HEADING_STYLE.DIALOG }),
                ui.paragraph({ text = "Hover over a name or field for help. Save changes to the project, then Build to play." }),
                ui.label({ text = M.summary(count(values, defaults), edits), color = ui.COLOR.HINT }),
                props.status and ui.paragraph({ text = props.status,
                    color = props.error and ui.COLOR.ERROR or ui.COLOR.HINT }) or false,
                props.preview_job and ui.dialog_button({text="Refresh status", result=result("refresh")}) or false,
            } }),
            -- The documented native tabs API has no selection property or event.
            content = ui.tabs({ tabs = tabs, grow = true }),
            buttons = {
                ui.dialog_button({ text = "Save", enabled = can_save, result = result("save") }),
                ui.dialog_button({ text = "Save and Prepare & Check", enabled = can_save,
                    result = result("save_prepare") }),
                -- No default button: Enter confirms a typed value in a field and
                -- must never close a window full of fields.
                ui.dialog_button({ text = "Close", cancel = true,
                    result = result("close") }),
            },
        })
    end)
end

-- Called only by M.run after the native dialog has returned.
function M.save(deps, session)
    local root = root_path(deps)
    local current = Identity.inspect(root, { read = deps.read })
    local proposal = Identity.propose(session.identity or current)
    local options = Model.copy(deps.save_options or {})
    options.base, options.project_root = root .. "/developer", root
    return session:save({ project_name = session.project_name or current.title, identity_proposal = proposal,
        identity_choice = current.game_id == "" and "fresh" or nil, save_options = options })
end

function M.lines_component(ui)
    return ui.component(function(props)
        local lines, set_lines = ui.use_state(function()
            local out = {}
            for line in (props.value .. "\n"):gmatch("(.-)\n") do out[#out+1] = line end
            return out
        end)
        local rows = {}
        for i, line in ipairs(lines) do
            local index = i
            rows[#rows+1] = ui.horizontal({spacing=ui.SPACING.SMALL, children={
                ui.string_field({value=line, grow=true, on_value_changed=function(value)
                    local next_lines=Model.copy(lines); next_lines[index]=value or ""; set_lines(next_lines)
                end}),
                ui.button({text="Remove line", enabled=#lines > 1, on_pressed=function()
                    local next_lines=Model.copy(lines); table.remove(next_lines,index); set_lines(next_lines)
                end}),
            }})
        end
        rows[#rows+1] = ui.button({text="Add line", on_pressed=function()
            local next_lines=Model.copy(lines); next_lines[#next_lines+1]=""; set_lines(next_lines)
        end})
        return ui.dialog({title=props.title, width=620, height=420, resizable=true,
            content=ui.scroll({content=ui.vertical({padding=ui.PADDING.MEDIUM, spacing=ui.SPACING.SMALL, children=rows})}),
            buttons={ui.dialog_button({text="Use lines", result={value=table.concat(lines,"\n")}}),
                ui.dialog_button({text="Cancel", cancel=true, result=false})}})
    end)
end

function M.preview_component(ui)
    return ui.component(function(props)
        local preview=props.preview
        local animation,set_animation=ui.use_state(preview.names[1])
        local frame=assert(preview.images[animation])
        return ui.dialog({title="Player art preview", width=640, height=560, resizable=true,
            content=ui.scroll({content=ui.vertical({padding=ui.PADDING.MEDIUM, spacing=ui.SPACING.SMALL, children={
                ui.select_box({value=animation, options=preview.names, on_value_changed=set_animation}),
                -- Already rasterized at an integer zoom. No fitting dimensions:
                -- letting the native image keep its size avoids a second resample.
                ui.image({image=frame.url}),
                ui.label({text=animation .. ": " .. frame.frame_count .. " frames (first frame shown)"}),
                ui.paragraph({text="Explicit fallback states: " .. (#preview.fallbacks > 0 and table.concat(preview.fallbacks,", ") or "None")}),
                preview.is_stretched and ui.paragraph({text="This model will be stretched. Export frames at in-game size for 1:1 art.", color=ui.COLOR.HINT}) or false,
            }})}),
            buttons={ui.dialog_button({text="Use this art", result="use"}),
                ui.dialog_button({text="Cancel", cancel=true, result="cancel"})}})
    end)
end

-- The pages and artwork are resolved before rendering. Navigation changes only
-- the page number; no file reads, builds or saved-state changes occur here.
function M.ending_component(ui)
    return ui.component(function(props)
        local preview = props.preview
        local page, set_page = ui.use_state(1)
        local current = assert(preview.pages[page])
        local children = {
            ui.heading({text=current.title, style=ui.HEADING_STYLE.H4}),
            ui.paragraph({text=current.body}),
        }
        if page == 1 then
            local art = preview.artwork or {}
            children[#children+1] = art.image and ui.image({image=art.image, width=220, height=180})
                or ui.paragraph({text=(art.animation and art.animation ~= "" and (art.animation .. " — ") or "") .. "Artwork not found",
                    color=ui.COLOR.HINT})
        end
        for _, issue in ipairs(preview.issues or {}) do
            children[#children+1] = ui.paragraph({text=issue.message,
                color=issue.severity == ui.ISSUE_SEVERITY.ERROR and ui.COLOR.ERROR or ui.COLOR.HINT})
        end
        children[#children+1] = ui.paragraph({text="Playtime and items held use sample values. Music plays only in the game.", color=ui.COLOR.HINT})
        children[#children+1] = ui.horizontal({spacing=ui.SPACING.SMALL, children={
            ui.button({text="Previous", enabled=page > 1, on_pressed=function() set_page(math.max(1,page-1)) end}),
            ui.label({text="Page " .. page .. " of " .. #preview.pages}),
            ui.button({text="Next", enabled=page < #preview.pages, on_pressed=function() set_page(math.min(#preview.pages,page+1)) end}),
        }})
        return ui.dialog({title="Ending preview", width=680, height=560, resizable=true,
            content=ui.scroll({content=ui.vertical({padding=ui.PADDING.MEDIUM, spacing=ui.SPACING.SMALL, children=children})}),
            buttons={ui.dialog_button({text="Close", cancel=true, result=true})}})
    end)
end

-- All three adapters are called by M.run only after show_dialog returns.
function M.launch_preview(deps, session, mode)
    return require("developer.tools.designer_preview").launch_editor(session, mode,
        {editor=deps.editor, root=root_path(deps), read=deps.read})
end
function M.refresh_preview(deps, session)
    return require("developer.tools.designer_preview").refresh(session,
        {editor=deps.editor, root=root_path(deps), read=deps.read})
end
function M.ending_preview(deps, session)
    local cfg = Model.merge(Model.copy(session.baseline.game_completion), session.draft.overrides.game_completion or {})
    local host, root = deps.editor, root_path(deps)
    return require("mvtk.editor.game_settings_ending_preview").prepare({
        read=function(path) return deps.read(root .. "/" .. path) end,
        exists=host and host.resource_attributes and function(path) return host.resource_attributes("/" .. path).is_file end or nil,
    }, cfg)
end

-- This adapter runs after the main dialog returns. The importer still receives
-- its usual RGBA decoder; the in-game image.load adapter remains untouched.
function M.import_art(deps, session)
    local Art = require "developer.tools.player_art_import"
    local Preview = require "mvtk.editor.game_settings_art_preview"
    local Decoder = require "mvtk.editor.png_decoder"
    local Scale = require "mvtk.player.player_scale"
    local root, host = root_path(deps), deps.editor
    if not root:match("^%a:/") and root:sub(1,1) ~= "/" then
        root = host.external_file_attributes(root).path:gsub("\\", "/"):gsub("/$", "")
    end
    local preview_opts = {root=root, editor=host, read=deps.read, write=deps.write, remove=deps.remove}
    Preview.cleanup(preview_opts)
    local cfg = Model.copy(session.baseline)
    cfg.player_art = Scale.convert_units(cfg.player_art,"player_art",cfg.player)
    Model.merge(cfg, session.draft.overrides)
    assert(Context.source_path(cfg.player_art.source), "Choose a source PNG or sequence folder inside this project.")
    local last_path
    local plan = Art.prepare(cfg.player_art, {player=cfg.player,
        read=function(path)
            last_path=path
            return deps.read(root .. "/" .. assert(Context.source_path(path), "Invalid project source: " .. path))
        end,
        decode=function(bytes) return Decoder.decode(bytes,{name=last_path, inflate=deps.inflate}) end,
        list=function(path)
            if deps.list then return deps.list(root .. "/" .. path) end
            local resource="/" .. assert(Context.source_path(path))
            assert(host.can_get(resource,"children"), "Missing source folder: " .. path)
            local files={}
            for _, child in ipairs(host.get(resource,"children")) do
                if host.resource_attributes(child).is_file then files[#files+1]=child:match("([^/]+)$") end
            end
            table.sort(files)
            return {},files
        end,
    })
    -- Source fingerprints are transient import data. Absolute project paths
    -- let the existing save adapter recheck both resource-style and relative
    -- source spellings without depending on the host's working directory.
    local sources={}
    for path,signature in pairs(plan.sources) do sources[root .. "/" .. assert(Context.source_path(path))]=signature end
    plan.sources=sources
    preview_opts.cleaned=true
    return plan, Preview.build(plan,cfg.player,preview_opts)
end

function M.run(deps)
    local editor = deps.editor
    local ui = editor and editor.ui
    assert(not deps.headless and ui and ui.show_dialog and ui.tabs and ui.component,
        "Game Settings runs from the Defold editor's Project menu.")
    -- Flush editor buffers before taking the original/saved snapshot.
    if editor.save then editor.save() end
    local load_session, save = deps.load or M.load, deps.save or M.save
    local load_context = deps.load_context or Context.load
    local session = load_session(deps)
    local context = load_context(deps)
    session.identity = context.identity
    local values, document, pending, status, failed, preview_job
    local component = M.component(ui)
    while true do
        local result = ui.show_dialog(component({ session=session, values=values, document=document,
            art_import=pending, context=context, status=status, error=failed,
            platform=editor.platform, preview_job=preview_job }))
        if not result then return true end
        values, document, pending = result.values, result.document, result.art_import
        if result.action == "close" then
            if M.unsaved_count(session, values, document, pending) == 0 then return true end
            local choice = ui.show_dialog(ui.dialog({ title = "Discard unsaved changes?", buttons = {
                ui.dialog_button({ text = "Keep editing", cancel = true, result = "edit" }),
                ui.dialog_button({ text = "Discard", result = "discard" }),
            } }))
            if choice == "discard" then return true end
        elseif result.action == "lines" then
            local lines=ui.show_dialog(M.lines_component(ui)({title=M.label(result.key), value=values[result.key]}))
            if lines then
                local draft=M.draft_session(session,values,true,document,pending)
                draft:set(result.key,lines.value)
                document=draft.draft; values=with_value(values,result.key,lines.value)
            end
        elseif result.action == "browse" then
            local selected=ui.show_resource_dialog({extensions={"png"},selection="single",title="Choose player sheet"})
            if selected then
                local path=assert(Context.source_path(selected),"Choose a PNG inside this project.")
                local draft=M.draft_session(session,values,true,document,pending)
                draft:set("art_source",path)
                document=draft.draft; values=with_value(values,"art_source",path); pending=false
                context=load_context(deps)
            end
        elseif result.action == "import" then
            local ok, plan, preview=pcall(function()
                return (deps.import_art or M.import_art)(deps,M.draft_session(session,values,false,document,pending))
            end)
            if ok then
                local choice=ui.show_dialog(M.preview_component(ui)({preview=preview}))
                if choice=="use" then
                    pending=plan; failed=false; status="Player art is ready. Save to use it in the project."
                else
                    failed=false; status="Art preview cancelled. The project and settings draft are unchanged."
                end
            else
                ui.show_dialog(ui.dialog({title="Player art import failed",
                    content=ui.paragraph({text=tostring(plan),color=ui.COLOR.ERROR}),
                    buttons={ui.dialog_button({text="Close",cancel=true,result=true})}}))
                failed=true; status="Player art was not imported: " .. tostring(plan)
            end
        elseif result.action == "preview_course" or result.action == "preview_rooms" then
            if editor.platform ~= "x86_64-win32" then
                failed, status = false, "Previews need Windows for now"
            else
                local draft
                local ok, message = pcall(function()
                    draft = M.draft_session(session,values,false,document,pending)
                    draft.preview_job = preview_job
                    return (deps.launch_preview or M.launch_preview)(deps,draft,result.action == "preview_course" and "course" or "rooms")
                end)
                if draft then preview_job = draft.preview_job end
                failed, status = not ok, ok and message or ("Preview could not start: " .. tostring(message))
            end
        elseif result.action == "refresh" then
            local ok, message = pcall(deps.refresh_preview or M.refresh_preview, deps, {preview_job=preview_job})
            failed, status = not ok, ok and message or ("Could not refresh preview status: " .. tostring(message))
        elseif result.action == "ending_preview" then
            local ok, preview = pcall(function()
                local draft = M.draft_session(session,values,true,document,pending)
                local prepared = (deps.ending_preview or M.ending_preview)(deps,draft)
                prepared.issues = {}
                local issues = M.field_issues(ui,session,values,context)
                each_field(function(key)
                    if key:match("^ending_") and issues[key] then prepared.issues[#prepared.issues+1] = issues[key] end
                end)
                return prepared
            end)
            if ok then
                ui.show_dialog(M.ending_component(ui)({preview=preview}))
                failed, status = false, "Ending preview closed."
            else
                ui.show_dialog(ui.dialog({title="Ending preview unavailable",
                    content=ui.paragraph({text=tostring(preview),color=ui.COLOR.ERROR}),
                    buttons={ui.dialog_button({text="Close",cancel=true,result=true})}}))
                failed, status = true, "Could not preview the ending: " .. tostring(preview)
            end
        elseif result.action == "save" or result.action == "save_prepare" then
            local saved_session
            local ok, saved = pcall(function()
                saved_session = M.draft_session(session,values,false,document,pending)
                assert(not invalid_issues(ui,M.field_issues(ui,session,values,context)),"Correct the field errors before saving.")
                return save(deps,saved_session)
            end)
            if not ok or not saved or not saved.ok then
                failed = true
                status = "Settings were not saved: " .. tostring(ok and (saved and saved.error or "Save failed") or saved)
            else
                -- Re-read disk instead of the session result or package.loaded.
                local reloaded, fresh, fresh_context = pcall(function() return load_session(deps),load_context(deps) end)
                if not reloaded then
                    session=saved_session; session.original=Model.copy(session.draft); session.art_import=nil
                    session.identity=Model.copy(session.identity)
                    session.identity.title=values.project_name
                    values, document, pending=nil,nil,false
                    failed, status = true, "Settings saved, but could not reload: " .. tostring(fresh)
                else
                    fresh.identity=fresh_context.identity
                    session, context, values, document, pending = fresh, fresh_context, nil, nil, false
                    failed, status = false, "Settings saved. Build to play with these values."
                    if saved.out and saved.out.cleanup_warning then
                        status = status .. " " .. tostring(saved.out.cleanup_warning)
                    end
                    if result.action == "save_prepare" then
                        local prepared, preparation, detail = pcall(function()
                            assert(deps.prepare, "Prepare & Check is unavailable")
                            return deps.prepare()
                        end)
                        if not prepared or preparation == false or (preparation == nil and detail ~= nil) then
                            failed = true
                            status = "Settings saved. Prepare & Check failed: " .. tostring(prepared and detail or preparation)
                        else status = "Settings saved. Review the Prepare & Check result before building." end
                    end
                end
            end
        end
    end
end

return M
