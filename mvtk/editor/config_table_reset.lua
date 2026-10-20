-- mvtk/editor/config_table_reset.lua
--
-- Empties a config file of the form `return { ... }` while keeping its
-- documentation. Every live entry of the returned table is removed, together
-- with the comment lines directly above it and a trailing comment on its
-- closing line; the file header, section banners, commented examples and
-- free-standing notes stay.
--
-- One definition of "empty" for Project > Reset Project to Empty (secret rooms,
-- via reset_baseline) and the release package staging (secret rooms,
-- cutscenes and videos, via tools/reset_config_tables.lua). Plain Lua 5.1 that
-- also runs in the editor's LuaJ sandbox: no frontier patterns, no pattern
-- back-references.

local M = {}

-- Index just past a long bracket ("[[...]]", "[==[...]==]") opening at i, or
-- nil, false when "[" at i does not open one, or nil, true when unterminated.
local function skip_long_bracket(text, i)
    local j = i + 1
    while text:sub(j, j) == "=" do j = j + 1 end
    if text:sub(j, j) ~= "[" then return nil, false end
    local close = "]" .. string.rep("=", j - i - 1) .. "]"
    local _, finish = text:find(close, j + 1, true)
    if not finish then return nil, true end
    return finish + 1
end

-- Index just past a comment starting at i ("--"), or nil when unterminated.
local function skip_comment(text, i)
    if text:sub(i + 2, i + 2) == "[" then
        local after, opened = skip_long_bracket(text, i + 2)
        if after then return after, true end
        if opened then return nil end
    end
    local newline = text:find("\n", i + 2, true)
    return newline or (#text + 1), false
end

-- Index just past a quoted string starting at i, or nil when unterminated.
local function skip_quoted(text, i)
    local quote, j = text:sub(i, i), i + 1
    while j <= #text do
        local ch = text:sub(j, j)
        if ch == "\\" then
            j = j + 2
        elseif ch == quote then
            return j + 1
        elseif ch == "\n" then
            return nil
        else
            j = j + 1
        end
    end
    return nil
end

-- Index just past one table field starting at i (including its "," or ";"),
-- or the index of the table's closing "}" when the field has no separator.
local function skip_field(text, i)
    local depth, j = 0, i
    while j <= #text do
        local ch = text:sub(j, j)
        if text:sub(j, j + 1) == "--" then
            local after = skip_comment(text, j)
            if not after then return nil, "unterminated comment" end
            j = after
        elseif ch == '"' or ch == "'" then
            j = skip_quoted(text, j)
            if not j then return nil, "unterminated string" end
        elseif ch == "[" then
            local after, opened = skip_long_bracket(text, j)
            if after then
                j = after
            elseif opened then
                return nil, "unterminated long string"
            else
                depth, j = depth + 1, j + 1
            end
        elseif ch == "{" or ch == "(" then
            depth, j = depth + 1, j + 1
        elseif ch == "}" or ch == ")" or ch == "]" then
            if depth == 0 then
                if ch == "}" then return j end
                return nil, "unbalanced '" .. ch .. "'"
            end
            depth, j = depth - 1, j + 1
        elseif (ch == "," or ch == ";") and depth == 0 then
            return j + 1
        else
            j = j + 1
        end
    end
    return nil, "the returned table is not closed"
end

-- Split the returned table body into whitespace, comment, field and close tokens.
local function tokenize(text, i)
    local tokens = {}
    while i <= #text do
        local ch = text:sub(i, i)
        local ws = text:match("^%s+", i)
        if ws then
            tokens[#tokens + 1] = { kind = "ws", text = ws }
            i = i + #ws
        elseif text:sub(i, i + 1) == "--" then
            local after, long = skip_comment(text, i)
            if not after then return nil, "unterminated comment" end
            tokens[#tokens + 1] = { kind = long and "long" or "line", text = text:sub(i, after - 1) }
            i = after
        elseif ch == "}" then
            tokens[#tokens + 1] = { kind = "close", text = text:sub(i) }
            return tokens
        else
            local after, err = skip_field(text, i)
            if not after then return nil, err end
            -- A last field without a separator ends at the table's "}"; leave
            -- the whitespace before that brace to the following gap.
            local last = after - 1
            while last > i and text:sub(last, last):match("%s") do last = last - 1 end
            tokens[#tokens + 1] = { kind = "field", text = text:sub(i, last) }
            i = last + 1
        end
    end
    return nil, "the returned table is not closed"
end

local function has_newline(token)
    return token.kind == "ws" and token.text:find("\n", 1, true) ~= nil
end

local function blank_line(token)
    return token.kind == "ws" and token.text:find("\n[ \t\r]*\n") ~= nil
end

-- Returns the emptied file text, or nil and a reason.
function M.empty(text)
    if type(text) ~= "string" then return nil, "expected the file text" end
    local _, open = text:find("^return%s*{")
    if not open then _, open = text:find("\nreturn%s*{") end
    if not open then return nil, "no top-level 'return {' table" end
    local tokens, err = tokenize(text, open + 1)
    if not tokens then return nil, err end

    local drop = {}
    for index, token in ipairs(tokens) do
        if token.kind == "field" then
            drop[index] = true
            -- Comment lines directly above the field (no blank line between).
            local back = index - 1
            while back >= 1 and tokens[back].kind == "ws" and not blank_line(tokens[back])
                and back > 1 and tokens[back - 1].kind == "line" do
                drop[back - 1] = true
                back = back - 2
            end
            -- A trailing comment on the field's own closing line.
            local nxt = tokens[index + 1]
            if nxt and nxt.kind == "ws" and not has_newline(nxt)
                and tokens[index + 2] and tokens[index + 2].kind == "line" then
                drop[index + 1], drop[index + 2] = true, true
            end
        end
    end

    -- Rebuild, merging whitespace left between kept tokens into one break that
    -- keeps a blank line where one existed and the next token's indentation.
    local nl = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local out, gap, first = { text:sub(1, open) }, nil, true
    for index, token in ipairs(tokens) do
        if token.kind == "ws" then
            gap = (gap or "") .. token.text
        elseif not drop[index] then
            if gap then
                local indent = gap:match("([ \t]*)$")
                local breaks = select(2, gap:gsub("\n", "\n"))
                if breaks == 0 then
                    out[#out + 1] = gap
                else
                    out[#out + 1] = ((breaks >= 2 and not first) and nl .. nl or nl) .. indent
                end
            end
            out[#out + 1] = token.text
            gap, first = nil, false
        end
    end
    local result = table.concat(out)

    local compile = loadstring or load
    local ok, compile_err = compile(result, "=emptied config")
    if not ok then return nil, "emptied file does not compile: " .. tostring(compile_err) end
    return result
end

return M
