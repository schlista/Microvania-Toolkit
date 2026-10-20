-- Disposable, static player-art previews for Game Settings. The window calls
-- cleanup/build only after show_dialog returns. Project art is published later
-- through the existing wizard transaction, never through this helper.
local Art = require "developer.tools.player_art_import"
local PNG = require "mvtk.editor.layout_editor.png_writer"
local M = {}
local DIRECTORY = "build/mvtk_art_preview"
local MANIFEST = "previews.txt"
local HEADER = "MVTK art previews 1"
local last_generation = {}

local function normalize(path)
    return tostring(path):gsub("\\", "/"):gsub("/+$", "")
end

local function absolute(path)
    return path:match("^%a:/") or path:sub(1, 1) == "/"
end

local function context(opts)
    opts = opts or {}
    local editor_api = opts.editor
    local root = opts.root
    if not root or not absolute(normalize(root)) then
        assert(editor_api and editor_api.external_file_attributes, "Art preview needs the absolute project folder")
        root = editor_api.external_file_attributes(".").path
    end
    root = normalize(root)
    assert(absolute(root), "Art preview needs the absolute project folder")
    for part in root:gmatch("[^/]+") do assert(part ~= "." and part ~= "..", "Invalid art preview project folder") end
    local function read(path)
        if opts.read then return opts.read(path) end
        local f, err, code = io.open(path, "rb")
        if not f then
            if code == 2 or (editor_api and editor_api.external_file_attributes(path).exists == false) then return nil end
            error("Cannot read " .. path .. ": " .. tostring(err))
        end
        local bytes, read_error = f:read("*a")
        local closed, close_error = f:close()
        assert(bytes and closed, read_error or close_error or ("Cannot read " .. path))
        return bytes
    end
    local function write(path, bytes)
        if opts.write then return opts.write(path, bytes) end
        local f = assert(io.open(path, "wb"))
        local written, write_error = f:write(bytes)
        local closed, close_error = f:close()
        assert(written and closed, write_error or close_error or ("Cannot write " .. path))
    end
    return { root = root, directory = root .. "/" .. DIRECTORY, editor = editor_api,
        read = read, write = write, remove = opts.remove or os.remove }
end

local function manifest(ctx)
    local text = ctx.read(ctx.directory .. "/" .. MANIFEST)
    if not text then return 0, {} end
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    assert(lines[1] == HEADER, "Unrecognized art preview manifest")
    local generation = tonumber(lines[2])
    assert(generation and generation >= 0 and generation < 2147483646 and generation == math.floor(generation),
        "Invalid art preview generation")
    local files, seen = {}, {}
    for index = 3, #lines do
        local name = lines[index]
        -- The manifest is data, not Lua. Confine deletion to this helper's
        -- generated basenames, even if an on-disk manifest was edited.
        assert(name:match("^preview%-%d+%-%d+%.png$") and not seen[name], "Invalid art preview filename")
        seen[name] = true; files[#files + 1] = name
    end
    return generation, files
end

-- Call before importing, including when source validation later fails. Keep the
-- manifest's generation counter so filenames never repeat after editor reload.
function M.cleanup(opts)
    local ctx = context(opts)
    local generation, files = manifest(ctx)
    for _, name in ipairs(files) do
        local path = ctx.directory .. "/" .. name
        if ctx.read(path) ~= nil then
            ctx.remove(path)
            assert(ctx.read(path) == nil, "Cannot delete old art preview: " .. path)
        end
    end
    return generation
end

-- editor.ui.image accepts URLs. Defold's editor passes a URI with a scheme to
-- JavaFX Image directly; file URLs bypass the ignored build resource tree.
function M.file_url(path)
    path = normalize(path)
    assert(absolute(path), "Art preview image needs an absolute path")
    local hex = "0123456789ABCDEF"
    local encoded = path:gsub("[^%w%-%._~/:]", function(char)
        local byte = char:byte()
        return "%" .. hex:sub(math.floor(byte / 16) + 1, math.floor(byte / 16) + 1)
            .. hex:sub(byte % 16 + 1, byte % 16 + 1)
    end)
    if path:sub(1, 2) == "//" then return "file:" .. encoded end
    return (path:match("^%a:/") and "file:///" or "file://") .. encoded
end

local function pixel(buf, width, height, x, y, color, blend)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if x < 0 or y < 0 or x >= width or y >= height then return end
    local at = (y * width + x) * 4
    if blend then
        local alpha = color[4] / 255
        local old_alpha = (buf[at + 4] or 0) / 255
        local combined = alpha + old_alpha * (1 - alpha)
        for channel = 1, 3 do
            buf[at + channel] = math.floor((color[channel] * alpha
                + (buf[at + channel] or 0) * old_alpha * (1 - alpha)) / combined + 0.5)
        end
        buf[at + 4] = math.floor(combined * 255 + 0.5)
    else
        for channel = 1, 4 do buf[at + channel] = color[channel] end
    end
end

-- Input/output pixels are straight RGBA, top row first. Geometry uses the same
-- displayed sprite dimensions, offsets and already-scaled body as the game.
function M.raster(plan, name, player, body)
    local cfg = plan.config
    local width, height = Art.dimensions(cfg)
    local scale = player.player_scale or 1
    width, height = width * scale, height * scale
    -- World size is not raster resolution: a small Player Size must not throw
    -- source pixels away before enlargement, and large sprites must not create
    -- enormous images. Normalize the longest displayed side to its source
    -- pixel count; use that same projection for art, body and origin.
    local density = math.max(cfg.frame_width, cfg.frame_height) / math.max(width, height)
    width, height = width * density, height * density
    local left = (cfg.offset_x or 0) * scale * density - width / 2
    local top = (cfg.offset_y or 0) * scale * density + height / 2
    body = {x=body.x*density,y=body.y*density,width=body.width*density,height=body.height*density}
    local min_x = math.floor(math.min(left, body.x - body.width / 2, 0)) - 2
    local max_x = math.ceil(math.max(left + width, body.x + body.width / 2, 0)) + 2
    local min_y = math.floor(math.min(top - height, body.y - body.height / 2, 0)) - 2
    local max_y = math.ceil(math.max(top, body.y + body.height / 2, 0)) + 2
    local zoom = math.max(1, math.floor(256 / math.max(max_x - min_x, max_y - min_y)))
    local out_width, out_height = (max_x - min_x) * zoom, (max_y - min_y) * zoom
    assert(out_width * out_height <= 16777216,
        "Art preview exceeds 16 million pixels; reduce the art offset or body dimensions.")
    local frames = assert(plan.animations[name], "Unknown preview animation")
    local source = assert(plan.frames[frames[1]], "Animation has no preview frame")
    assert(#source == cfg.frame_width * cfg.frame_height * 4, "Invalid player preview pixels")
    local pixels = {}
    for y = 0, out_height - 1 do
        local world_y = max_y - (y + 0.5) / zoom
        local source_y = math.floor((top - world_y) * cfg.frame_height / height)
        for x = 0, out_width - 1 do
            local world_x = min_x + (x + 0.5) / zoom
            local source_x = math.floor((world_x - left) * cfg.frame_width / width)
            local r, g, b, a = 0, 0, 0, 0
            if source_x >= 0 and source_x < cfg.frame_width and source_y >= 0 and source_y < cfg.frame_height then
                local at = (source_y * cfg.frame_width + source_x) * 4 + 1
                r, g, b, a = source:byte(at, at + 3)
            end
            local at = (y * out_width + x) * 4
            pixels[at + 1], pixels[at + 2], pixels[at + 3], pixels[at + 4] = r, g, b, a
        end
    end
    local function px(x) return (x - min_x) * zoom end
    local function py(y) return (max_y - y) * zoom end
    local origin_x, origin_y = px(0), py(0)
    local white = {255, 255, 255, 77}
    for x = 0, out_width - 1 do pixel(pixels, out_width, out_height, x, origin_y, white, true) end
    for y = 0, out_height - 1 do pixel(pixels, out_width, out_height, origin_x, y, white, true) end
    local x0, x1 = px(body.x - body.width / 2), px(body.x + body.width / 2)
    local y0, y1 = py(body.y + body.height / 2), py(body.y - body.height / 2)
    local green = {0, 255, 0, 255}
    for _, line in ipairs({{x0, y0, x1, y0}, {x1, y0, x1, y1}, {x1, y1, x0, y1}, {x0, y1, x0, y0}}) do
        PNG.draw_line(pixels, out_width, out_height, line[1], line[2], line[3], line[4], green, 1)
    end
    return { width = out_width, height = out_height, buffer = PNG.buffer_to_bytes(pixels),
        zoom = zoom, density = density, origin_x = origin_x, origin_y = origin_y,
        sprite = { left = px(left), top = py(top), width = width * zoom, height = height * zoom },
        body = { left = x0, top = y0, right = x1, bottom = y1 } }
end

local function png_bytes(raster)
    local rows, stride = {}, raster.width * 4
    -- png_writer's established input is bottom-up; decoded art is top-down.
    for row = raster.height - 1, 0, -1 do rows[#rows + 1] = raster.buffer:sub(row * stride + 1, (row + 1) * stride) end
    return PNG.encode_png(raster.width, raster.height, table.concat(rows))
end

function M.build(plan, player, opts)
    opts = opts or {}
    local ctx = context(opts)
    if not opts.cleaned then M.cleanup(opts) end
    -- Project Clean can remove build/ while the editor still caches images.
    -- Keep a per-process counter as well as the on-disk counter for reloads.
    local generation = math.max(manifest(ctx), last_generation[ctx.root] or 0) + 1
    last_generation[ctx.root] = generation
    if ctx.editor and ctx.editor.create_directory then ctx.editor.create_directory("/" .. DIRECTORY)
    else assert(opts.write, "Art preview files must be created from the Defold editor") end
    local body = Art.body(player, function(path) return ctx.read(ctx.root .. "/" .. path) end)
    local names, lines = {}, {HEADER, tostring(generation)}
    for index, name in ipairs(plan.names) do
        names[index] = string.format("preview-%d-%d.png", generation, index)
        lines[#lines + 1] = names[index]
    end
    -- Journal every intended file before writing any image: an interrupted
    -- import can leave a partial set, and the next cleanup knows every path.
    ctx.write(ctx.directory .. "/" .. MANIFEST, table.concat(lines, "\n") .. "\n")
    local result = { names = plan.names, images = {}, fallbacks = plan.fallbacks or {},
        is_stretched = Art.is_stretched(plan.config), generation = generation }
    for index, name in ipairs(plan.names) do
        local raster = M.raster(plan, name, player, body)
        local path = ctx.directory .. "/" .. names[index]
        ctx.write(path, png_bytes(raster))
        result.images[name] = { url = M.file_url(path), path = path, width = raster.width, height = raster.height,
            frame_count = #plan.animations[name], geometry = raster }
        -- Dialogs only need image geometry, not another retained RGBA copy.
        raster.buffer = nil
    end
    return result
end

return M
