-- Project > Spine Add-on…: the editor adapter for the shared text transforms.
-- Command discovery never loads this module or reads/writes project files.
local Addon = require "mvtk.editor.spine_addon"
local Transaction = require "mvtk.editor.project_transaction"
local M = {}

M.LICENSE_NOTICE = "The Spine add-on puts Esoteric Software's Spine runtime in your game. Spine's license requires everyone who builds with it to own a Spine Editor license (Essential or higher); the free Trial does not cover the runtime. Turn it on?"

function M.off_message(path)
    return "This project uses Spine (" .. tostring(path) .. "), but the Spine add-on is off. "
        .. "Turn it on with Project ▸ Spine Add-on… (needs your own Spine Editor license), or remove the Spine content."
end

function M.mixed_message(details)
    local lines = { "The Spine add-on state is mixed. Run Project ▸ Spine Add-on… again and choose Turn On or Turn Off." }
    for _, detail in ipairs(details or {}) do
        lines[#lines + 1] = detail.path .. ": " .. detail.message
    end
    return table.concat(lines, "\n")
end

local function controls(deps)
    local files = {}
    local root = tostring(deps.root or "."):gsub("\\", "/"):gsub("/$", "")
    for _, path in ipairs(Addon.CONTROL_PATHS) do
        local text, err = deps.read(root .. "/" .. path)
        assert(text ~= nil or err == nil, "Cannot read " .. path .. ": " .. tostring(err))
        files[path] = text
    end
    return files
end

-- Called by the baker only when a boss explicitly or implicitly selects Spine.
-- Read current control bytes rather than caching the state in package.loaded.
function M.require_on(deps, path)
    local state, details = Addon.state(controls(deps))
    assert(state ~= "mixed", M.mixed_message(details))
    assert(state == "on", M.off_message(path))
    return true
end

-- Share one checked disk inventory across all recursive reads. The ordinary
-- editor resource list may omit new files and cannot prove an empty directory.
function M.collect(deps)
    local root = tostring(deps.root or "."):gsub("\\", "/"):gsub("/$", "")
    local options = {spine_scan_root=root}
    local list = assert(deps.list, "Spine scan needs a directory reader")
    return Addon.collect({root=root, read=deps.read,
        list=function(path) return list(path, options) end})
end

local function reload_resources(editor)
    -- execute reloads resources from disk by default (official editor API).
    if editor.platform:find("win32", 1, true) then editor.execute("cmd", "/c", "exit", "0")
    else editor.execute("true") end
end

function M.run(deps)
    local editor = deps.editor
    local ui = editor and editor.ui
    assert(not deps.headless and ui and ui.dialog_button,
        "Spine Add-on runs from the Defold editor's Project menu.")
    local root = tostring(deps.root or "."):gsub("\\", "/"):gsub("/$", "")
    -- Restore any interrupted prior edit before taking the transform snapshot.
    if Transaction.recover(root, deps.transaction) then
        -- Recovery can restore control files even when the next dialog is
        -- cancelled. Refresh before that early return becomes possible.
        reload_resources(editor)
    end
    local files = controls(deps)
    local state, details = Addon.state(files)
    local lines = { "Current Spine add-on state: " .. state .. "." }
    if state == "mixed" then lines[#lines + 1] = M.mixed_message(details) end
    local choice = deps.dialog("Spine Add-on", lines, {
        cancel_text = "Cancel", cancel_result = "cancel",
        extra_buttons = {
            ui.dialog_button({ text = "Turn On", result = "on" }),
            ui.dialog_button({ text = "Turn Off", result = "off" }),
        },
    })
    if choice ~= "on" and choice ~= "off" then return true end
    if choice == "on" then
        local accepted = deps.dialog("Turn On Spine Add-on", { M.LICENSE_NOTICE }, {
            cancel_text = "Cancel", cancel_result = "cancel",
            extra_buttons = { ui.dialog_button({ text = "Turn On", result = "on" }) },
        })
        if accepted ~= "on" then return true end
        files = controls(deps)
    else
        files = M.collect({ root = root, read = deps.read, list = deps.list })
        local reasons = Addon.refusal_reasons(files)
        if #reasons > 0 then
            local problems = { "Spine is still in use. Change these files before turning the add-on off:" }
            for _, reason in ipairs(reasons) do
                problems[#problems + 1] = reason.path .. ": " .. reason.message
            end
            return false, table.concat(problems, "\n")
        end
    end
    local changes = Addon.plan(files, choice)
    local written, cleanup_warning = Transaction.commit(root, changes, deps.transaction)
    local info = deps.info or function() end
    info("Spine Add-on: " .. choice .. "; updated " .. tostring(#written) .. " file(s).")
    if cleanup_warning then info("Spine Add-on transaction cleanup: " .. cleanup_warning) end
    -- execute's documented resource reload makes the new game.project and
    -- factory prototypes visible before Fetch Libraries resolves dependencies.
    reload_resources(editor)
    local fetch = type(editor.fetch_libraries) == "function"
    deps.dialog("Spine Add-on " .. (choice == "on" and "On" or "Off"), {
        fetch and "Libraries will refresh when you close this message." or "Next, run Project ▸ Fetch Libraries.",
        "If Defold does not pick up the .defignore change, close and reopen the editor.",
        "Then run Prepare & Check before building or Export Game.",
    })
    -- The API reloads library editor scripts. This must be the last editor
    -- operation; editor_commands deliberately skips its usual trailing reload.
    if fetch then editor.fetch_libraries() end
    return true
end

return M
