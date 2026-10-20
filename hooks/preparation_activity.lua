-- Keep editor work visible while its existing stage dialogs come and go.
-- Work starts in a button callback, never during component rendering.
local M={}
local function initial_state(session)
    return session.state
end
local function refresh_action(session,set_state)
    return function()
        if not session.closed then set_state(session.state) end
    end
end
local function start_action(session,set_state,run,opts)
    return function()
        if session.started then return end
        session.started=true
        local function update(message,running)
            -- Keep the latest result independently of the rendered component.
            -- Resource refreshes and deferred UI renders must not lose it.
            session.state={started=true,running=running,message=message}
            if not running then session.completed=true end
            -- Closing the window must not abort the writer or release its lock.
            if not session.closed then
                set_state(session.state)
            end
        end
        update(opts.first_running_message,true)
        local ok,result,err,outcome=pcall(run,function(message,running)
            -- Show the saved result before profiling returns, and keep that
            -- result instead of replacing it with the generic fallback below.
            update(message,running~=false)
        end)
        if not ok or result==false then
            -- A late error must stay visible even after an earlier final report.
            update(opts.failure_prefix..tostring(not ok and result or err)..opts.failure_suffix,false)
        elseif not session.completed then
            update(outcome=="cancelled" and opts.cancelled_text or opts.finished_text,false)
        end
        -- Defold editor bug (ui_components.clj): any localization change, e.g.
        -- progress text during a resource sync, re-renders the dialog root with
        -- this component's cached view and clears its pending re-render, so a
        -- set_state just before it is never drawn. Re-post the final state after
        -- quiet suspensions (no resource reload) so it renders without Refresh.
        if opts.settle then
            for _=1,2 do
                if session.closed then break end
                pcall(opts.settle)
                if not session.closed then set_state(session.state) end
            end
        end
    end
end
function M.show(ui,run,opts)
    local defaults={
        title="Prepare & Check — Progress",
        idle_message="Ready to check exports and prepare the project.",
        first_running_message="Checking editor scripts and project changes...",
        start_text="Continue",
        running_note="Preparation is running. Closing this window does not cancel it. Continue/Cancel menus appear between stages.",
        stopped_note="Preparation has stopped. You can close this window.",
        idle_note="The step-by-step preparation menus remain available.",
        failure_prefix="Preparation failed: ",failure_suffix="",
        cancelled_text="Preparation cancelled.",
        finished_text="Preparation finished. Review the preparation result before building.",
        refresh_text="Refresh status",close_text="Close",
    }
    for key,value in pairs(opts or {}) do defaults[key]=value end
    opts=defaults
    local session={started=false,closed=false,
        state={started=false,running=false,message=opts.idle_message}}
    local component=ui.component(function()
        local state,set_state=ui.use_state(initial_state,session)
        local start=ui.use_memo(start_action,session,set_state,run,opts)
        local refresh=ui.use_memo(refresh_action,session,set_state)
        local lines={}
        for line in state.message:gmatch("[^\r\n]+") do
            lines[#lines+1]=ui.paragraph({text=line})
        end
        return ui.vertical({padding=12,spacing=8,children={
                ui.scroll({grow=true,content=ui.vertical({spacing=8,children=lines})}),
                ui.paragraph({text=state.running
                    and opts.running_note
                    or state.started and opts.stopped_note
                    or opts.idle_note}),
                ui.button({text=opts.start_text,enabled=not state.started,on_pressed=start}),
                ui.button({text=opts.refresh_text,on_pressed=refresh}),
            }})
    end)
    -- Keep the modal shell and its exit outside the reactive content. A missed
    -- progress render must never strand the editor behind a disabled Close.
    local ok,err=pcall(ui.show_dialog,ui.dialog({title=opts.title,
        width=640,height=440,resizable=true,content=component({}),
        buttons={ui.dialog_button({text=opts.close_text,cancel=true})}}))
    session.closed=true
    if not ok then error(err,0) end
    return true
end
return M
