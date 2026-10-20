-- Static script-property type checks shared by headless tools and Validate All.
-- No script is executed: release-bundle hash values cannot be reverse looked up.
local ResourceText = require "mvtk.editor.resource_text"

local M = {}

local ESCAPES = {
    a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
    ["\\"] = "\\", ['"'] = '"', ["'"] = "'",
}

local function long_string_end(source, pos)
    local first, last, equals = source:find("^%[(=*)%[", pos)
    if not first then return nil end
    local closing = "]" .. equals .. "]"
    local finish = source:find(closing, last + 1, true)
    return finish and finish + #closing or #source + 1
end

local function quoted_string(source, pos)
    local quote, parts = source:sub(pos, pos), {}
    pos = pos + 1
    while pos <= #source do
        local ch = source:sub(pos, pos)
        if ch == quote then return table.concat(parts), pos + 1 end
        if ch == "\\" then
            local next_ch = source:sub(pos + 1, pos + 1)
            local digits = source:match("^%d%d?%d?", pos + 1)
            if digits then
                local value = tonumber(digits)
                parts[#parts + 1] = value <= 255 and string.char(value) or ""
                pos = pos + 1 + #digits
            elseif next_ch == "\r" and source:sub(pos + 2, pos + 2) == "\n" then
                parts[#parts + 1] = "\n"
                pos = pos + 3
            else
                parts[#parts + 1] = ESCAPES[next_ch] or next_ch
                pos = pos + 2
            end
        else
            parts[#parts + 1] = ch
            pos = pos + 1
        end
    end
    error("Unclosed quoted string in script-property declarations")
end

-- Lua tokenization only needs strings, identifiers and punctuation. Comments
-- and long strings are consumed whole, so examples cannot invent declarations.
local function script_tokens(source)
    local tokens, pos = {}, 1
    while pos <= #source do
        local ch = source:sub(pos, pos)
        if ch:match("%s") then
            pos = pos + 1
        elseif source:sub(pos, pos + 1) == "--" then
            pos = long_string_end(source, pos + 2)
                or source:find("\n", pos + 2, true) or #source + 1
        elseif ch == '"' or ch == "'" then
            local value
            value, pos = quoted_string(source, pos)
            tokens[#tokens + 1] = { kind = "string", value = value }
        elseif ch == "[" and long_string_end(source, pos) then
            pos = long_string_end(source, pos)
            tokens[#tokens + 1] = { kind = "long_string" }
        else
            local first, last = source:find("^[_%a][_%w]*", pos)
            if first then
                tokens[#tokens + 1] = { kind = "word", value = source:sub(first, last) }
                pos = last + 1
            else
                -- Keep numeric literals whole; signs are separate punctuation.
                local number = source:match("^0[xX]%x+", pos)
                    or source:match("^%d+%.?%d*[eE][%+%-]?%d+", pos)
                    or source:match("^%.%d+[eE][%+%-]?%d+", pos)
                    or source:match("^%d+%.?%d*", pos)
                    or source:match("^%.%d+", pos)
                if number then
                    tokens[#tokens + 1] = { kind = "number", value = number }
                    pos = pos + #number
                else
                    tokens[#tokens + 1] = { kind = ch, value = ch }
                    pos = pos + 1
                end
            end
        end
    end
    return tokens
end

local function token_is(tokens, index, value)
    local token = tokens[index]
    return token and token.kind ~= "string" and token.value == value
end

local function default_type(tokens, index)
    local token = tokens[index]
    if not token then return nil end
    if token.kind == "string" or token.kind == "long_string" then return "PROPERTY_TYPE_TEXT" end
    if token.kind == "number" then return "PROPERTY_TYPE_NUMBER" end
    if (token.value == "-" or token.value == "+") and tokens[index + 1]
        and tokens[index + 1].kind == "number" then return "PROPERTY_TYPE_NUMBER" end
    if token.value == "true" or token.value == "false" then return "PROPERTY_TYPE_BOOLEAN" end
    if token.value == "hash" and token_is(tokens, index + 1, "(") then return "PROPERTY_TYPE_HASH" end
    if token.value == "resource" and token_is(tokens, index + 1, ".") then return nil, true end
    if not token_is(tokens, index + 1, ".") or not token_is(tokens, index + 3, "(") then return nil end
    local constructor = tokens[index + 2] and tokens[index + 2].value
    if token.value == "msg" and constructor == "url" then return "PROPERTY_TYPE_URL" end
    if token.value == "vmath" then
        local types = { vector3 = "PROPERTY_TYPE_VECTOR3", vector4 = "PROPERTY_TYPE_VECTOR4", quat = "PROPERTY_TYPE_QUAT" }
        return types[constructor]
    end
    return nil
end

-- Resource properties are deliberately excluded from the returned type map.
-- The second result distinguishes them from undeclared property names.
function M.declared_types(script_text)
    local declared, ignored = {}, {}
    local tokens = script_tokens(script_text or "")
    for index = 1, #tokens - 5 do
        local previous = tokens[index - 1]
        if token_is(tokens, index, "go") and token_is(tokens, index + 1, ".")
            and token_is(tokens, index + 2, "property") and token_is(tokens, index + 3, "(")
            and tokens[index + 4].kind == "string" and token_is(tokens, index + 5, ",")
            and not (previous and (previous.value == "." or previous.value == ":"))
        then
            local name = tokens[index + 4].value
            local kind, resource = default_type(tokens, index + 6)
            declared[name], ignored[name] = kind, resource or nil
        end
    end
    return declared, ignored
end

local function script_declarations(context, path)
    if not path or not path:match("%.script$") then return nil end
    if not context.scripts[path] then
        local text = context.read(path)
        local declared, ignored = M.declared_types(text)
        context.scripts[path] = { script = path, declared = declared, ignored = ignored }
    end
    return context.scripts[path]
end

local function check_properties(node, record, instance, component, mismatches)
    -- These checks concern script overrides, not engine component properties.
    if record and not record.script then return end
    for _, property in ipairs(ResourceText.all(node, "properties")) do
        local name = ResourceText.value(property.node, "id")
        local stored = ResourceText.value(property.node, "type")
        local declared = record and record.declared[name]
        if not (record and record.ignored[name]) and (declared == nil or stored ~= declared) then
            mismatches[#mismatches + 1] = {
                instance = instance, component = component, property = name,
                declared = declared, stored = stored, script = record and record.script,
            }
        end
    end
end

local function check_prototype(text, context, instance, mismatches)
    local components = {}
    local prototype = ResourceText.parse(text or "").root
    for _, component in ipairs(ResourceText.all(prototype, "components")) do
        local id = ResourceText.value(component.node, "id")
        local path = ResourceText.value(component.node, "component")
        local record = script_declarations(context, path) or {}
        components[id] = record
        check_properties(component.node, record, instance, id, mismatches)
    end
    return components
end

function M.check_go(go_text, read)
    local mismatches = {}
    check_prototype(go_text, { read = assert(read, "Property checks require a resource reader"), scripts = {} },
        "", mismatches)
    return mismatches
end

function M.check_collection(collection_text, read)
    local context = { read = assert(read, "Property checks require a resource reader"), scripts = {} }
    local mismatches = {}
    local collection = ResourceText.parse(collection_text).root
    for _, entry in ipairs(collection.entries) do
        if entry.node and (entry.name == "instances" or entry.name == "embedded_instances") then
            local instance = ResourceText.value(entry.node, "id") or ""
            local text, prototype
            if entry.name == "embedded_instances" then
                text = ResourceText.value(entry.node, "data")
            else
                prototype = ResourceText.value(entry.node, "prototype")
                text = prototype and read(prototype)
            end
            local first_prototype_mismatch = #mismatches + 1
            local components = check_prototype(text, context, instance, mismatches)
            -- Overrides stored in a referenced prototype live in that file, not in
            -- this collection; record it so diagnostics name the file to rebuild.
            for index = first_prototype_mismatch, #mismatches do
                mismatches[index].source = prototype
            end
            for _, component in ipairs(ResourceText.all(entry.node, "component_properties")) do
                local id = ResourceText.value(component.node, "id")
                check_properties(component.node, components[id], instance, id, mismatches)
            end
        end
    end
    return mismatches
end

return M
