-- mvtk/editor/layout_editor/png_writer.lua
--
-- Self-contained PNG encoding + line rasterization used by the layout editor's
-- minimap export. Extracted verbatim from controller.lua to keep the controller
-- focused on coordination rather than image-format internals.
--
-- Public API:
--   M.encode_png(width, height, pixel_bytes)  - returns PNG byte string
--   M.draw_line(buf, w, h, x0, y0, x1, y1, color, thickness)  - writes RGBA pixels
--   M.buffer_to_bytes(buf)  - flatten {0..255} byte array into a string
--   M.poly_reduce_colinear(poly, dot_epsilon)  - simplify near-colinear polygon
--
-- Private internals: bitops shim, CRC32, Adler32, zlib stored-block packer.
-- Caller supplies RGBA with bottom-to-top rows; encode_png flips those rows
-- to the PNG format's top-to-bottom convention.

local Logger = require "mvtk.core.logger"
local adler32 = require("mvtk.core.adler32").checksum
local log = Logger.get_logger("layout_editor.png_writer")

local M = {}

-- Bitop shim: prefer LuaJIT's `bit`, then Lua 5.2 `bit32`, fall back to pure-Lua.
local function make_bitops()
    local bit = rawget(_G, "bit")
    if bit then
        return bit.bxor, bit.band, bit.bor, bit.rshift, bit.lshift, true
    end
    local bit32 = rawget(_G, "bit32")
    if not bit32 then
        local ok, library = pcall(require, "bit32")
        if ok then bit32 = library end
    end
    if bit32 then
        return bit32.bxor, bit32.band, bit32.bor, bit32.rshift, bit32.lshift, true
    end
    local function bxor(a, b)
        local res = 0
        local bit_val = 1
        while a > 0 or b > 0 do
            local aa = a % 2
            local bb = b % 2
            if aa ~= bb then
                res = res + bit_val
            end
            a = (a - aa) / 2
            b = (b - bb) / 2
            bit_val = bit_val * 2
        end
        return res
    end
    local function band(a, b)
        local res = 0
        local bit_val = 1
        while a > 0 and b > 0 do
            local aa = a % 2
            local bb = b % 2
            if aa == 1 and bb == 1 then
                res = res + bit_val
            end
            a = (a - aa) / 2
            b = (b - bb) / 2
            bit_val = bit_val * 2
        end
        return res
    end
    local function bor(a, b)
        local res = 0
        local bit_val = 1
        while a > 0 or b > 0 do
            local aa = a % 2
            local bb = b % 2
            if aa == 1 or bb == 1 then
                res = res + bit_val
            end
            a = (a - aa) / 2
            b = (b - bb) / 2
            bit_val = bit_val * 2
        end
        return res
    end
    local function rshift(a, n)
        if n <= 0 then return a end
        return math.floor(a / (2 ^ n))
    end
    local function lshift(a, n)
        if n <= 0 then return a end
        return (a * (2 ^ n)) % 4294967296
    end
    return bxor, band, bor, rshift, lshift
end

local BXOR, BAND, BOR, RSHIFT, LSHIFT, NATIVE_BITOPS = make_bitops()
-- BOR/LSHIFT retained for parity with the controller's original locals; not yet
-- needed in this module but kept available if future helpers are added here.
local _ = BOR; local __ = LSHIFT

local CRC32_TABLE = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if BAND(crc, 1) ~= 0 then
            crc = BXOR(RSHIFT(crc, 1), 0xEDB88320)
        else
            crc = RSHIFT(crc, 1)
        end
    end
    CRC32_TABLE[i + 1] = crc
end

local crc32
if NATIVE_BITOPS then
    crc32 = function(str)
        local crc = 0xFFFFFFFF
        for i = 1, #str do
            local byte = str:byte(i)
            local idx = BAND(BXOR(crc, byte), 0xFF)
            crc = BXOR(RSHIFT(crc, 8), CRC32_TABLE[idx + 1])
        end
        return BXOR(crc, 0xFFFFFFFF)
    end
else
    -- The CRC recurrence needs only byte XOR. Keep its state as four bytes
    -- and precompute byte XOR once, avoiding two 32-bit arithmetic loops per
    -- input byte on hosts without a bit library. The polynomial and resulting
    -- PNG bytes are identical to the native path.
    local xor, low, second, third, high = {}, {}, {}, {}, {}
    for a = 0, 255 do
        for b = 0, 255 do xor[a * 256 + b] = BXOR(a, b) end
        local crc = CRC32_TABLE[a + 1]
        low[a] = crc % 256
        second[a] = math.floor(crc / 256) % 256
        third[a] = math.floor(crc / 65536) % 256
        high[a] = math.floor(crc / 16777216)
    end
    local byte = string.byte
    crc32 = function(str)
        local a, b, c, d = 255, 255, 255, 255
        for i = 1, #str do
            local index = xor[a * 256 + byte(str, i)]
            a, b, c, d = xor[b * 256 + low[index]], xor[c * 256 + second[index]],
                xor[d * 256 + third[index]], high[index]
        end
        return (255 - a) + (255 - b) * 256 + (255 - c) * 65536 + (255 - d) * 16777216
    end
end

local function u32be(n)
    n = n % 4294967296
    local b1 = math.floor(n / 16777216) % 256
    local b2 = math.floor(n / 65536) % 256
    local b3 = math.floor(n / 256) % 256
    local b4 = n % 256
    return string.char(b1, b2, b3, b4)
end

local function u16le(n)
    n = n % 65536
    local b1 = n % 256
    local b2 = math.floor(n / 256) % 256
    return string.char(b1, b2)
end

local function zlib_stored(data)
    local chunks = {}
    local total = #data
    local pos = 1
    while pos <= total do
        local size = math.min(65535, total - pos + 1)
        local last = (pos + size - 1 == total) and 1 or 0
        local block = {}
        block[#block + 1] = string.char(last)
        block[#block + 1] = u16le(size)
        block[#block + 1] = u16le(0xFFFF - size)
        block[#block + 1] = data:sub(pos, pos + size - 1)
        chunks[#chunks + 1] = table.concat(block)
        pos = pos + size
    end
    local body = table.concat(chunks)
    return string.char(0x78, 0x01) .. body .. u32be(adler32(data))
end

function M.buffer_to_bytes(buf)
    local parts = {}
    local chunk = {}
    for i = 1, #buf do
        chunk[#chunk + 1] = string.char(buf[i] or 0)
        if #chunk >= 4096 then
            parts[#parts + 1] = table.concat(chunk)
            chunk = {}
        end
    end
    if #chunk > 0 then
        parts[#parts + 1] = table.concat(chunk)
    end
    return table.concat(parts)
end

function M.encode_png(width, height, pixel_bytes)
    local signature = "\137PNG\r\n\026\n"
    local chunks = { signature }
    local function append_chunk(ctype, data)
        chunks[#chunks + 1] = u32be(#data) .. ctype .. data .. u32be(crc32(ctype .. data))
    end
    local ihdr = u32be(width) .. u32be(height) .. string.char(8, 6, 0, 0, 0)
    append_chunk("IHDR", ihdr)
    local scanlines = {}
    local row_stride = width * 4
    -- PNG stores rows top-to-bottom; the caller's buffer is bottom-up, so flip.
    for y = 0, height - 1 do
        local src_row = height - 1 - y
        local start = src_row * row_stride + 1
        local stop = start + row_stride - 1
        scanlines[#scanlines + 1] = string.char(0) .. pixel_bytes:sub(start, stop)
    end
    local raw = table.concat(scanlines)
    append_chunk("IDAT", zlib_stored(raw))
    append_chunk("IEND", "")
    return table.concat(chunks)
end

function M.draw_line(buf, w, h, x0, y0, x1, y1, color, thickness)
    thickness = math.max(1, math.floor(thickness or 1))
    x0 = math.floor(x0 + 0.5)
    y0 = math.floor(y0 + 0.5)
    x1 = math.floor(x1 + 0.5)
    y1 = math.floor(y1 + 0.5)
    local dx = math.abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math.abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    local offset_start = -math.floor(thickness / 2)
    local offset_end = math.ceil(thickness / 2) - 1
    local dominant_axis
    if dx == 0 and dy == 0 then
        dominant_axis = nil
    elseif math.abs(dx) >= math.abs(dy) then
        dominant_axis = "horizontal"
    else
        dominant_axis = "vertical"
    end

    local function plot(px, py)
        if px >= 0 and px < w and py >= 0 and py < h then
            local idx = (py * w + px) * 4
            buf[idx + 1] = color[1]
            buf[idx + 2] = color[2]
            buf[idx + 3] = color[3]
            buf[idx + 4] = color[4]
        end
    end

    while true do
        if not dominant_axis then
            for oy = offset_start, offset_end do
                for ox = offset_start, offset_end do
                    plot(x0 + ox, y0 + oy)
                end
            end
        elseif dominant_axis == "horizontal" then
            for oy = offset_start, offset_end do
                plot(x0, y0 + oy)
            end
        else
            for ox = offset_start, offset_end do
                plot(x0 + ox, y0)
            end
        end
        if x0 == x1 and y0 == y1 then break end
        local e2 = err * 2
        if e2 >= dy then
            err = err + dy
            x0 = x0 + sx
        end
        if e2 <= dx then
            err = err + dx
            y0 = y0 + sy
        end
    end
end

function M.poly_reduce_colinear(poly, dot_epsilon)
    local n = #poly
    if n <= 2 then return poly end
    local th = dot_epsilon or 0.9995
    local out = { poly[1] }
    for i = 2, n - 1 do
        local a, b, c = out[#out], poly[i], poly[i + 1]
        local abx, aby = (b.x - a.x), (b.y - a.y)
        local bcx, bcy = (c.x - b.x), (c.y - b.y)
        local abl = math.sqrt(abx * abx + aby * aby)
        local bcl = math.sqrt(bcx * bcx + bcy * bcy)
        if abl > 0 and bcl > 0 then
            local d = (abx * bcx + aby * bcy) / (abl * bcl)
            if d < th then
                out[#out + 1] = b
            end
        end
    end
    out[#out + 1] = poly[n]
    if #out ~= n then
        log.debug("outline reduced: %d -> %d points", n, #out)
    end
    return out
end

return M
