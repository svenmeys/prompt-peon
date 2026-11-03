-- Encode: turns a reply into the frames the send addons carry. The bridge decodes the same format,
-- and tests/encode_frames.lua checks the two agree.

local _, ns = ...

local band, bxor, lshift, rshift = bit.band, bit.bxor, bit.lshift, bit.rshift

--- CRC-8 starting from 0xA5, so an all-clear (all zero) frame can never look valid.
function ns.Crc8(data)
  local crc = 0xA5
  for index = 1, #data do
    crc = bxor(crc, data:byte(index))
    for _ = 1, 8 do
      if band(crc, 0x80) ~= 0 then
        crc = band(bxor(lshift(crc, 1), 0x07), 0xFF)
      else
        crc = band(lshift(crc, 1), 0xFF)
      end
    end
  end
  return crc
end

local crcTable

--- The standard CRC-32, so the bridge can check it with zlib.
function ns.Crc32(data)
  if not crcTable then
    crcTable = {}
    for index = 0, 255 do
      local value = index
      for _ = 1, 8 do
        if band(value, 1) ~= 0 then
          value = bxor(rshift(value, 1), 0xEDB88320)
        else
          value = rshift(value, 1)
        end
      end
      crcTable[index] = value
    end
  end
  local crc = -1
  for index = 1, #data do
    crc = bxor(rshift(crc, 8), crcTable[band(bxor(crc, data:byte(index)), 0xFF)])
  end
  return bxor(crc, -1)
end

local function bytes(value, count)
  local out = {}
  for index = count, 1, -1 do
    out[#out + 1] = string.char(band(rshift(value, (index - 1) * 8), 0xFF))
  end
  return table.concat(out)
end

--- version, seq, thread id, text, CRC-32 of all of it.
function ns.EncodeMessage(seq, threadId, text)
  local body = string.char(1) .. bytes(seq, 3) .. string.char(#threadId) .. threadId .. bytes(#text, 2) .. text
  return body .. bytes(ns.Crc32(body), 4)
end

--- Split a message into frames: [crc8][first flag + index][10 bytes of message].
function ns.Frames(message)
  local frames, index = {}, 0
  local size = ns.OUT_COUNT / 8 - 2
  for start = 1, #message, size do
    local chunk = message:sub(start, start + size - 1)
    chunk = chunk .. string.rep("\0", size - #chunk)
    local head = band(index, 0x7F)
    if start == 1 then head = head + 0x80 end
    local data = string.char(head) .. chunk
    frames[#frames + 1] = string.char(ns.Crc8(data)) .. data
    index = index + 1
  end
  return frames
end
