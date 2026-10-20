-- Decimal output for authoring files on both desktop Lua and the editor's LuaJ.
-- LuaJ ignores printf precision. Build exact decimal digits from the binary
-- significand there; keep the native formatter on hosts that honor precision so
-- existing desktop/in-game files (including platform exponent spelling) match.
local M = {}
local BASE = 10000000

local function precise_printf()
    return string.format("%.17g", 0.1) == "0.10000000000000001"
        and string.format("%.2f", 1) == "1.00"
end

local function exact(value)
    assert(type(value) == "number" and value == value and math.abs(value) < math.huge,
        "Settings numbers must be finite")
    local negative = value < 0 or (value == 0 and 1 / value < 0)
    value = math.abs(value)
    if value == 0 then return "0", 0, negative end
    local mantissa, exponent = math.frexp(value)
    local integer = mantissa * 9007199254740992 -- all 53 binary significand bits
    exponent = exponent - 53
    local limbs = {}
    repeat
        limbs[#limbs + 1] = integer % BASE
        integer = math.floor(integer / BASE)
    until integer == 0
    local multiplier = exponent < 0 and 5 or 2
    for _ = 1, math.abs(exponent) do
        local carry = 0
        for i = 1, #limbs do
            local n = limbs[i] * multiplier + carry
            limbs[i], carry = n % BASE, math.floor(n / BASE)
        end
        if carry > 0 then limbs[#limbs + 1] = carry end
    end
    local parts = { string.format("%d", limbs[#limbs]) }
    for i = #limbs - 1, 1, -1 do parts[#parts + 1] = string.format("%07d", limbs[i]) end
    local digits = table.concat(parts)
    return digits, #digits + math.min(exponent, 0) - 1, negative
end

local function increment(digits)
    local i = #digits
    while i > 0 and digits:sub(i, i) == "9" do i = i - 1 end
    if i == 0 then return "1" .. string.rep("0", #digits) end
    return digits:sub(1, i - 1) .. tostring(tonumber(digits:sub(i, i)) + 1)
        .. string.rep("0", #digits - i)
end

-- Round decimal integer digits, never a floating-point printf conversion.
local function rounded(digits, count)
    if count < 0 then return "0" end
    local kept = digits:sub(1, count)
    if #kept < count then kept = kept .. string.rep("0", count - #kept) end
    if (tonumber(digits:sub(count + 1, count + 1)) or 0) >= 5 then
        kept = increment(kept)
    end
    return kept == "" and "0" or kept
end

function M.fixed(value, places)
    places = places or 2
    assert(places >= 0 and places == math.floor(places), "Invalid decimal precision")
    if precise_printf() then return string.format("%." .. places .. "f", value) end
    local digits, exponent, negative = exact(value)
    digits = rounded(digits, exponent + 1 + places)
    if #digits <= places then digits = string.rep("0", places + 1 - #digits) .. digits end
    local point = #digits - places
    local text = places == 0 and digits or digits:sub(1, point) .. "." .. digits:sub(point + 1)
    return (negative and "-" or "") .. text
end

function M.general(value, places)
    places = places or 17
    assert(places >= 1 and places <= 17 and places == math.floor(places), "Invalid significant precision")
    if precise_printf() then return string.format("%." .. places .. "g", value) end
    local digits, exponent, negative = exact(value)
    digits = rounded(digits, places)
    if #digits > places then exponent = exponent + 1; digits = digits:sub(1, places) end
    digits = digits:gsub("0+$", "")
    if digits == "" then return negative and "-0" or "0" end
    local text
    if exponent < -4 or exponent >= places then
        text = digits:sub(1, 1) .. (#digits > 1 and "." .. digits:sub(2) or "")
            .. "e" .. (exponent < 0 and "-" or "+") .. string.format("%02d", math.abs(exponent))
    elseif exponent >= #digits - 1 then
        text = digits .. string.rep("0", exponent + 1 - #digits)
    elseif exponent < 0 then
        text = "0." .. string.rep("0", -exponent - 1) .. digits
    else
        text = digits:sub(1, exponent + 1) .. "." .. digits:sub(exponent + 2)
    end
    return (negative and "-" or "") .. text
end

return M
