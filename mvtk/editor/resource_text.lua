-- Small protobuf-text editor. Retain source spans so resource edits preserve
-- unrelated fields, comments, custom references and animation properties.
local M = {}

local string_escapes = {
    a=string.char(7), b=string.char(8), f=string.char(12), n="\n", r="\r", t="\t", v=string.char(11),
    ["?"]="?", ["\\"]="\\", ['"']='"', ["'"]="'",
}

local function utf8_codepoint(value)
    assert(value <= 0x10ffff and not (value >= 0xd800 and value <= 0xdfff),
        "Invalid Unicode code point in resource string")
    if value <= 0x7f then return string.char(value) end
    if value <= 0x7ff then return string.char(0xc0 + math.floor(value/64), 0x80 + value%64) end
    if value <= 0xffff then
        return string.char(0xe0 + math.floor(value/4096), 0x80 + math.floor(value/64)%64, 0x80 + value%64)
    end
    return string.char(0xf0 + math.floor(value/262144), 0x80 + math.floor(value/4096)%64,
        0x80 + math.floor(value/64)%64, 0x80 + value%64)
end

-- Protobuf strings use octal bytes, whereas Lua numeric escapes are decimal.
-- Decode the text-format grammar directly, without compiling resource content.
-- https://protobuf.dev/reference/protobuf/textformat-spec/#string-literals
local function decode_string(raw, source_first)
    local parts, pos = {}, 2
    while pos < #raw do
        local escaped = raw:find("[\\\r\n]", pos)
        if not escaped or escaped >= #raw then
            parts[#parts+1] = raw:sub(pos, #raw-1)
            break
        end
        if escaped > pos then parts[#parts+1] = raw:sub(pos,escaped-1); pos = escaped end
        assert(raw:sub(pos,pos) == "\\", "Unescaped newline in resource string at " .. (source_first+pos-1))
        local code = raw:sub(pos+1,pos+1)
        if string_escapes[code] then
            parts[#parts+1] = string_escapes[code]
            pos = pos + 2
        elseif code:match("[0-7]") then
            local digits = raw:sub(pos+1,pos+3):match("^[0-7][0-7]?[0-7]?")
            local byte = tonumber(digits,8)
            assert(byte <= 255, "Octal resource string escape exceeds one byte at " .. (source_first+pos-1))
            parts[#parts+1] = string.char(byte)
            pos = pos + 1 + #digits
        elseif code == "x" then
            local digits = raw:sub(pos+2,pos+3):match("^[%da-fA-F][%da-fA-F]?")
            assert(digits, "Invalid hexadecimal resource string escape at " .. (source_first+pos-1))
            parts[#parts+1] = string.char(tonumber(digits,16))
            pos = pos + 2 + #digits
        elseif code == "u" or code == "U" then
            local count = code == "u" and 4 or 8
            local digits = raw:sub(pos+2,pos+1+count)
            assert(#digits == count and digits:match("^[%da-fA-F]+$"),
                "Invalid Unicode resource string escape at " .. (source_first+pos-1))
            parts[#parts+1] = utf8_codepoint(tonumber(digits,16))
            pos = pos + 2 + count
        else
            error("Invalid resource string escape at " .. (source_first+pos-1) .. ": \\" .. code)
        end
    end
    return table.concat(parts)
end

function M.parse(source)
    local tokens, pos = {}, 1
    while pos <= #source do
        local c = source:sub(pos,pos)
        if c:match("%s") then pos = pos + 1
        elseif c == "#" or source:sub(pos,pos+1) == "//" then
            pos = source:find("\n", pos, true) or (#source + 1)
        elseif c == '"' or c == "'" then
            local first, quote = pos, c
            pos = pos + 1
            while pos <= #source and source:sub(pos,pos) ~= quote do
                if source:sub(pos,pos) == "\\" then pos = pos + 1 end
                pos = pos + 1
            end
            assert(pos <= #source, "Unclosed resource string")
            local raw = source:sub(first,pos)
            local value = decode_string(raw,first)
            tokens[#tokens+1] = { kind = "string", value = value, first = first, last = pos }
            pos = pos + 1
        elseif c == ":" or c == "{" or c == "}" then
            tokens[#tokens+1] = { kind = c, value = c, first = pos, last = pos }
            pos = pos + 1
        else
            local first, last = source:find("^[^%s:{}]+", pos)
            assert(first, "Unsupported resource token at " .. pos)
            local value = source:sub(first,last)
            tokens[#tokens+1] = { kind = "scalar", value = tonumber(value) or value, first = first, last = last }
            pos = last + 1
        end
    end
    local index = 1
    local function parse_node(nested)
        local node = { entries = {}, close = #source + 1 }
        while tokens[index] and tokens[index].kind ~= "}" do
            local key = tokens[index]; index = index + 1
            assert(key.kind == "scalar" and type(key.value) == "string", "Expected resource field name")
            local token = assert(tokens[index], "Missing resource value")
            index = index + 1
            local field = { name = key.value, start = key.first }
            if token.kind == "{" then field.node = parse_node(true)
            else
                assert(token.kind == ":", "Expected ':' or '{' after " .. key.value)
                token = assert(tokens[index], "Missing resource scalar"); index = index + 1
                assert(token.kind == "scalar" or token.kind == "string", "Invalid resource scalar")
                field.value, field.first, field.last = token.value, token.first, token.last
                if token.kind == "string" then
                    while tokens[index] and tokens[index].kind == "string" do
                        field.value = field.value .. tokens[index].value
                        field.last = tokens[index].last; index = index + 1
                    end
                end
            end
            field.finish = tokens[index-1].last
            node.entries[#node.entries+1] = field
        end
        if nested then
            assert(tokens[index] and tokens[index].kind == "}", "Unclosed resource block")
            node.close = tokens[index].first; index = index + 1
        end
        return node
    end
    local root = parse_node(false)
    assert(index > #tokens, "Unexpected closing resource block")
    return { root = root, source = source, edits = {}, inserts = {} }
end

function M.all(node, name)
    local entries = {}
    for _, entry in ipairs(node.entries) do if entry.name == name then entries[#entries+1] = entry end end
    return entries
end

function M.one(node, name)
    local entries = M.all(node, name)
    assert(#entries <= 1, "Ambiguous resource field: " .. name)
    return entries[1]
end

function M.value(node, name)
    local entry = M.one(node, name)
    return entry and entry.value
end

function M.format_number(value)
    assert(value == value and math.abs(value) < math.huge, "Invalid resource dimension")
    -- LuaJ ignores floating-point precision. Round before formatting integer
    -- parts, so editor and desktop Lua write the same resource dimensions.
    local rounded = math.floor(math.abs(value) * 1000000000 + 0.5)
    local whole = math.floor(rounded / 1000000000)
    local fraction = rounded - whole * 1000000000
    local tail = string.format("%09d", fraction):gsub("0+$", "")
    return (value < 0 and rounded ~= 0 and "-" or "") .. string.format("%d", whole)
        .. "." .. (tail ~= "" and tail or "0")
end

function M.replace(doc, entry, value)
    assert(entry.first and entry.last, "Cannot replace a resource block as a scalar")
    local text
    if type(value) == "number" then
        assert(value == value and math.abs(value) < math.huge, "Invalid resource dimension")
        if value == entry.value then doc.edits[entry.first] = nil; return end
        text = M.format_number(value)
    else
        local function quote(part)
            return '"' .. part:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
        end
        local parts, consumed = {}, 0
        for line in value:gmatch("[^\n]*\n") do parts[#parts+1] = quote(line); consumed = consumed + #line end
        if consumed < #value or #parts == 0 then parts[#parts+1] = quote(value:sub(consumed+1)) end
        local line = doc.source:sub(1,entry.first-1):match("[^\n]*$")
        text = table.concat(parts, "\n" .. (line:match("^%s*") or ""))
    end
    doc.edits[entry.first] = { last = entry.last, text = text }
end

function M.insert(doc, node, text)
    doc.inserts[node.close] = (doc.inserts[node.close] or "") .. "\n" .. text .. "\n"
end

function M.remove(doc, entry)
    doc.edits[entry.start] = { last = entry.finish, text = "" }
end

function M.vector(doc, node, name, multiplier, axes, default)
    local field = M.one(node, name)
    if not field then
        if default == nil then return end
        local rows = {}
        for _, axis in ipairs(axes) do rows[#rows+1] = axis .. ": " .. M.format_number(default * multiplier) end
        if name == "scale3" or name == "scale" then rows[#rows+1] = "z: 1" end
        M.insert(doc, node, name .. " { " .. table.concat(rows, " ") .. " }")
        return
    end
    assert(field.node, "Expected vector block")
    for _, axis in ipairs(axes) do
        local value = M.one(field.node, axis)
        if value then M.replace(doc, value, assert(tonumber(value.value)) * multiplier)
        elseif default and default ~= 0 then M.insert(doc, field.node, axis .. ": " .. M.format_number(default * multiplier)) end
    end
end

function M.render(doc)
    local edits = {}
    for first, entry in pairs(doc.edits) do edits[#edits+1] = { first=first, last=entry.last, text=entry.text } end
    for first, text in pairs(doc.inserts) do edits[#edits+1] = { first=first, last=first-1, text=text } end
    table.sort(edits, function(a,b) return a.first > b.first end)
    local text, next_position = doc.source, #doc.source+1
    for _, edit in ipairs(edits) do
        assert(edit.last < next_position, "Overlapping resource edits")
        text = text:sub(1,edit.first-1) .. edit.text .. text:sub(edit.last+1)
        next_position = edit.first
    end
    return text
end

-- Resource strings contain escaped newlines; normalize only inter-field whitespace.
function M.tidy(text)
    text=text:gsub("\n[ \t]*\n%s*\n", "\n\n")
    return (text:gsub("%s*$", "")) .. "\n"
end
return M
