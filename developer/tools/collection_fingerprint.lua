-- Editor-stable fingerprints for Defold .collection files.
--
-- Toolkit bakers write room collections as protobuf text. The Defold editor
-- marks those files unsaved as soon as it loads them, because its own
-- serialization differs: component properties follow each script's
-- go.property order, numbers are re-printed as Java floats/doubles, and
-- default fields are dropped. Any editor save (Ctrl+S, or the save every
-- toolkit command performs before it runs) therefore rewrites every baked
-- collection without changing a single value. Freshness checks fingerprint
-- the protobuf meaning so that rewrite cannot stale a published world.
--
-- Anything this parser does not understand falls back to the byte
-- fingerprint, which can only over-report a change, never hide one.
local Adler = require "mvtk.core.adler32"

local M = {version = 1}

local ESCAPES = {n="\n", r="\r", t="\t", a="\a", b="\b", f="\f", v="\v",
    ["\\"]="\\", ["'"]="'", ['"']='"', ["?"]="?"}

-- Message fields whose omitted value is the proto default (collection.md).
local DEFAULTS = {
    position = {x=0, y=0, z=0},
    rotation = {x=0, y=0, z=0, w=1},
    scale3 = {x=1, y=1, z=1},
    scale = {x=1, y=1, z=1},
}
-- Scalar defaults, applied only on collection-level messages.
local SCALAR_DEFAULTS = {scale=1, scale_along_z=0}
local COLLECTION_LEVEL = {[""]=true, instances=true, embedded_instances=true, collection_instances=true}
-- Repeated fields keyed by id, where the editor chooses its own order.
local UNORDERED = {
    instances = {component_properties=true},
    embedded_instances = {component_properties=true},
    component_properties = {properties=true},
    components = {properties=true},
}
-- Script property values the editor parses with Double/parseDouble and
-- prints back with Java's double formatting ("1" becomes "1.0").
local NUMERIC_PROPERTY = {PROPERTY_TYPE_NUMBER=1, PROPERTY_TYPE_VECTOR3=3,
    PROPERTY_TYPE_VECTOR4=4, PROPERTY_TYPE_QUAT=4}

local function read_string(text, start, quote)
    local parts, pos = {}, start + 1
    local stop = "[\\" .. quote .. "\n]"
    while true do
        local s = text:find(stop, pos)
        if not s then return nil end
        local c = text:sub(s, s)
        if c == "\n" then return nil end
        parts[#parts + 1] = text:sub(pos, s - 1)
        if c == quote then return table.concat(parts), s + 1 end
        local e = text:sub(s + 1, s + 1)
        if ESCAPES[e] then
            parts[#parts + 1] = ESCAPES[e]; pos = s + 2
        elseif e:match("^[0-7]$") then
            local digits = text:match("^[0-7][0-7]?[0-7]?", s + 1)
            local byte = tonumber(digits, 8)
            if byte > 255 then return nil end
            parts[#parts + 1] = string.char(byte); pos = s + 1 + #digits
        elseif e == "x" or e == "X" then
            local digits = text:match("^%x%x?", s + 2)
            if not digits then return nil end
            parts[#parts + 1] = string.char(tonumber(digits, 16)); pos = s + 2 + #digits
        else
            return nil
        end
    end
end

local function tokenize(text)
    local kinds, values, n, pos, len = {}, {}, 0, 1, #text
    while pos <= len do
        local _, e = text:find("^[ \t\r\n]+", pos)
        if e then
            pos = e + 1
        else
            local c = text:sub(pos, pos)
            if c == "#" then
                local nl = text:find("\n", pos, true)
                pos = nl and nl + 1 or len + 1
            elseif c == "{" or c == "}" or c == ":" then
                n = n + 1; kinds[n] = c; pos = pos + 1
            elseif c == '"' or c == "'" then
                local value, next_pos = read_string(text, pos, c)
                if not value then return nil end
                n = n + 1; kinds[n] = "s"; values[n] = value; pos = next_pos
            else
                local word = text:match("^[%w_%.%+%-]+", pos)
                if not word then return nil end
                n = n + 1; kinds[n] = "w"; values[n] = word; pos = pos + #word
            end
        end
    end
    return kinds, values
end

-- Fields are {name, kind, value}: kind "m" holds a field list, "s" a decoded
-- string (adjacent literals joined), "w" a bare scalar token.
local function parse(text)
    local kinds, values = tokenize(text)
    if not kinds then return nil end
    local i = 1
    local function message(closed)
        local fields = {}
        while true do
            local kind = kinds[i]
            if kind == nil then
                if closed then error("unterminated message", 0) end
                return fields
            elseif kind == "}" then
                if not closed then error("unexpected }", 0) end
                i = i + 1
                return fields
            elseif kind ~= "w" then
                error("expected a field name", 0)
            end
            local name = values[i]; i = i + 1
            local colon = kinds[i] == ":"
            if colon then i = i + 1 end
            if kinds[i] == "{" then
                i = i + 1
                fields[#fields + 1] = {name, "m", message(true)}
            elseif colon and kinds[i] == "s" then
                local parts = {}
                while kinds[i] == "s" do parts[#parts + 1] = values[i]; i = i + 1 end
                fields[#fields + 1] = {name, "s", table.concat(parts)}
            elseif colon and kinds[i] == "w" then
                fields[#fields + 1] = {name, "w", values[i]}; i = i + 1
            else
                error("expected a value", 0)
            end
        end
    end
    local ok, fields = pcall(message, false)
    return ok and fields or nil
end

-- Exact, runtime-independent key for a number rounded to `bits` significant
-- bits: 24 matches the editor's float32 fields, 53 keeps full doubles. Uses
-- only power-of-two arithmetic and %d, which behave alike in desktop Lua and
-- the editor's LuaJ (whose string.format ignores %.Ng precision).
local function number_key(value, bits)
    if value ~= value then return "nan" end
    if value == 0 then return "0" end
    local sign = ""
    if value < 0 then sign = "-"; value = -value end
    if value == math.huge then return sign .. "inf" end
    local low, high, exponent = 2 ^ (bits - 1), 2 ^ bits, 0
    while value >= high do value = value / 2; exponent = exponent + 1 end
    while value < low do value = value * 2; exponent = exponent - 1 end
    local whole = math.floor(value)
    local rest = value - whole
    if rest > 0.5 or (rest == 0.5 and whole % 2 == 1) then whole = whole + 1 end
    while whole % 2 == 0 do whole = whole / 2; exponent = exponent + 1 end
    local hi = math.floor(whole / 67108864)
    return string.format("%s%d.%dp%d", sign, hi, whole - hi * 67108864, exponent)
end

local function scalar_number(word)
    if not word:match("^[%+%-]?%.?%d") then return nil end
    return tonumber(word)
end

local function scalar_key(word, number)
    -- Integer literals beyond float32 precision stay exact so int fields can
    -- never collapse; such values never appear in float fields.
    if math.abs(number) >= 16777216 and not word:find("[%.eE]") then return number_key(number, 53) end
    return number_key(number, 24)
end

local function numeric_property(text, count)
    local keys = {}
    for part in (text .. ","):gmatch("([^,]*),") do
        local trimmed = part:match("^%s*(.-)%s*$")
        local number = scalar_number(trimmed)
        if not number then return nil end
        keys[#keys + 1] = number_key(number, 53)
    end
    if #keys ~= count then return nil end
    return table.concat(keys, ",")
end

local canonical_message
canonical_message = function(fields, context)
    local defaults = DEFAULTS[context]
    local scalar_defaults = COLLECTION_LEVEL[context] and SCALAR_DEFAULTS
    local property_type
    if context == "properties" then
        for _, f in ipairs(fields) do
            if f[1] == "type" and f[2] == "w" then property_type = f[3] end
        end
    end
    local by_name, names = {}, {}
    for _, f in ipairs(fields) do
        local name, kind, value = f[1], f[2], f[3]
        local item
        if kind == "m" then
            local body = canonical_message(value, name)
            if not (body == "" and DEFAULTS[name]) then item = name .. "{" .. body .. "}" end
        elseif kind == "s" then
            local count = context == "properties" and name == "value" and NUMERIC_PROPERTY[property_type]
            local numbers = count and numeric_property(value, count)
            if numbers then
                item = name .. "=n" .. numbers
            elseif name == "data" then
                -- Embedded game objects/components are protobuf text too.
                local nested = parse(value)
                if nested then item = name .. "=m{" .. canonical_message(nested, "data") .. "}" end
            end
            item = item or (name .. "=s" .. #value .. ":" .. value)
        else
            local number = scalar_number(value)
            if number then
                local default = (defaults and defaults[name]) or (scalar_defaults and scalar_defaults[name])
                if number ~= default then item = name .. "=n" .. scalar_key(value, number) end
            else
                item = name .. "=w" .. value
            end
        end
        if item then
            local list = by_name[name]
            if not list then list = {}; by_name[name] = list; names[#names + 1] = name end
            list[#list + 1] = item
        end
    end
    table.sort(names)
    local out, unordered = {}, UNORDERED[context]
    for _, name in ipairs(names) do
        local list = by_name[name]
        if unordered and unordered[name] then table.sort(list) end
        for _, item in ipairs(list) do out[#out + 1] = item end
    end
    return table.concat(out, ";")
end

-- Canonical text for a collection, or nil when it is not parseable.
function M.canonical(text)
    local fields = parse(text)
    return fields and canonical_message(fields, "") or nil
end

-- A prepare run takes several snapshots of unchanged files. Remember results
-- by byte fingerprint, which freshness checks already treat as identity.
local cache, cached = {}, 0
function M.fingerprint(text)
    local raw = Adler.fingerprint(text)
    local hit = cache[raw]
    if hit then return hit end
    local ok, canonical = pcall(M.canonical, text)
    local result = (ok and canonical) and ("pb" .. M.version .. ":" .. Adler.fingerprint(canonical)) or raw
    if cached >= 4096 then cache, cached = {}, 0 end
    cache[raw] = result; cached = cached + 1
    return result
end

return M
