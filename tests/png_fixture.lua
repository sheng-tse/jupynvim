-- Build a real PNG in pure Lua, so image specs need no fixture files and no
-- Python. RGB, 8 bits, deflate "stored" blocks. The pixels depend on `seed`,
-- so two seeds give two distinct images of the same size.
local bit = require("bit")

local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1)) else c = bit.rshift(c, 1) end
  end
  crc_table[i] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
  end
  return bit.bxor(c, 0xFFFFFFFF)
end

local function be32(n)
  return string.char(bit.band(bit.rshift(n, 24), 0xFF), bit.band(bit.rshift(n, 16), 0xFF),
                     bit.band(bit.rshift(n, 8), 0xFF), bit.band(n, 0xFF))
end

local function chunk(kind, data)
  return be32(#data) .. kind .. data .. be32(crc32(kind .. data))
end

local function zlib_stored(raw)
  local out, a, b = { "\120\1" }, 1, 0
  for i = 1, #raw do a = (a + raw:byte(i)) % 65521; b = (b + a) % 65521 end
  local pos = 1
  repeat
    local block = raw:sub(pos, pos + 65534)
    pos = pos + #block
    local final = pos > #raw and 1 or 0
    local n = #block
    out[#out + 1] = string.char(final, n % 256, math.floor(n / 256),
                                (255 - n % 256), 255 - math.floor(n / 256)) .. block
  until pos > #raw
  out[#out + 1] = be32(b * 65536 + a)
  return table.concat(out)
end

return function(w, h, seed)
  seed = seed or 0
  local rows = {}
  for y = 0, h - 1 do
    local r = { "\0" }
    for x = 0, w - 1 do
      r[#r + 1] = string.char((x * 7 + seed) % 256, (y * 5 + seed * 3) % 256, (x + y + seed * 11) % 256)
    end
    rows[#rows + 1] = table.concat(r)
  end
  local ihdr = be32(w) .. be32(h) .. "\8\2\0\0\0"
  return "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr) .. chunk("IDAT", zlib_stored(table.concat(rows)))
         .. chunk("IEND", "")
end
