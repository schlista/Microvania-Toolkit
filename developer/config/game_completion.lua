-- A single, explicit ending for a compact game. Disabled in the empty toolkit.
-- Use Project > Game Settings... > Ending for conditions, credits, lines and art.
return {
    enabled = false, -- No ending checks or screen while false.
    id = "ending", -- Stable save identity; end_game regions reference this ID.
    condition = "region", -- region, flag, or boss (boss preset/persistent identity).
    flag = "", -- Required existing flag when condition="flag".
    boss_id = "", -- boss_defeated_<boss_id> flag, after defeat cleanup finishes.
    continue_policy = "completed", -- completed shows ending again; explore resumes.
    return_room = "", -- Explore return point: published room ID, world coordinates.
    return_x = 0, -- Blank room uses the last valid saved checkpoint instead.
    return_y = 0, -- Validate placement against the published room before saving.
    title = "Journey complete", -- Completion heading.
    body = "Thank you for playing.", -- Completion body text; newlines supported.
    credits = "Created by you", -- Newline-separated credit entries, paged by the UI.
    music = "", -- Existing music track ID; blank keeps current music.
    artwork = "", -- Animation in completion.gui's creator-owned artwork atlas.
    reward_flag = "", -- Optional permanent flag committed in the completion save.
    font = "default", -- Font ID declared in the completion GUI resource.
    text_scale = 0.8, -- Text scale for completion and credits screens.
    credits_per_page = 8, -- Controller/keyboard navigable credit lines per page.
}
