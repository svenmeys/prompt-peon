-- Print the frames the addon's own encoder makes, as hex, for the bridge test to decode.
-- Usage: luajit tests/encode_frames.lua <seq> <thread id> <hex of text>
package.path = "tests/?.lua;" .. package.path
local stub = require("wow_stub")
stub.install()
local ns = {}
for _, name in ipairs({ "Core.lua", "CoreEncode.lua" }) do
  assert(loadfile("addon/PromptPeon/" .. name))("PromptPeon", ns)
end
local seq, thread, hex = tonumber(arg[1]), arg[2], arg[3]
local text = hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)
for _, frame in ipairs(ns.Frames(ns.EncodeMessage(seq, thread, text))) do
  print((frame:gsub(".", function(char) return string.format("%02x", char:byte()) end)))
end
