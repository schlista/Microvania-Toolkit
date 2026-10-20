-- Pure ending presentation shared by the game and editor previews.
-- Page one includes session statistics; subsequent pages contain credit lines.
local M = {}

function M.build(cfg, data)
    data = data or {}
    local per_page = math.max(1, math.floor(cfg.credits_per_page or 8))
    local credits = {}
    for line in (cfg.credits or ""):gmatch("[^\n]+") do credits[#credits + 1] = line end
    local count = 0
    for _, amount in pairs((data.stats or {}).items or {}) do count = count + amount end
    local stats = string.format("Playtime: %d minutes", math.floor((data.playtime_s or 0) / 60))
        .. string.format("  |  Items held: %d", count)
    local pages = {{title = cfg.title, text = cfg.body, stats = stats,
        body = cfg.body .. "\n\n" .. stats, artwork = cfg.artwork}}
    for first = 1, #credits, per_page do
        local rows = {}
        for i = first, math.min(#credits, first + per_page - 1) do rows[#rows + 1] = credits[i] end
        local body = table.concat(rows, "\n")
        pages[#pages + 1] = {title = "Credits", text = body, body = body}
    end
    return pages, {credits = credits, per_page = per_page}
end

return M
