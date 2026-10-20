-- Portable Adler-32 for editor preparation and PNG writers. No engine APIs,
-- native modules, bit operators, filesystem access, or persistent caches.
local M = {}
local byte = string.byte

function M.sums(data)
    local a, b = 1, 0
    local length = #data
    for first = 1, length, 5552 do
        -- Reducing once per block is equivalent to reducing after every byte.
        -- Even with all bytes = 255 and both initial sums = 65520, a block of
        -- 5552 keeps b below 2^32 (and thus exact in Lua's double arithmetic).
        local last = math.min(first + 5551, length)
        local i = first
        while i + 15 <= last do
            -- One string-library call per sixteen bytes. Accumulate the
            -- prefix sums algebraically; use the OLD a when updating b.
            local x1,x2,x3,x4,x5,x6,x7,x8,x9,x10,x11,x12,x13,x14,x15,x16 = byte(data,i,i+15)
            b = b + 16*a + 16*x1 + 15*x2 + 14*x3 + 13*x4 + 12*x5 + 11*x6 + 10*x7 + 9*x8
                + 8*x9 + 7*x10 + 6*x11 + 5*x12 + 4*x13 + 3*x14 + 2*x15 + x16
            a = a+x1+x2+x3+x4+x5+x6+x7+x8+x9+x10+x11+x12+x13+x14+x15+x16
            i = i + 16
        end
        for j = i, last do
            a = a + byte(data, j)
            b = b + a
        end
        a, b = a % 65521, b % 65521
    end
    return a, b
end

function M.checksum(data)
    local a, b = M.sums(data)
    return b * 65536 + a
end

function M.fingerprint(data)
    local a, b = M.sums(data)
    return string.format("%d:%d:%d", #data, a, b)
end

return M
