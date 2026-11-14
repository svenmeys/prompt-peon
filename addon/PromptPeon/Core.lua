-- Core: the numbers and shared state everything else reads, and small text helpers.
--
-- A WoW addon cannot open a socket or read a file, so it talks to the bridge in
-- two moves, and neither one needs a reload:
--   In:  LoadAddOn on an unused refresh slot re-reads the bridge's Snapshot.lua.
--        A slot only loads once per UI session, so slots are a budget. See CoreRefresh.lua.
--   Out: C_AddOns.SaveAddOns() writes AddOns.txt to disk immediately, in about
--        half a millisecond. So 96 "send" addons act as 96 bits: each save is one
--        frame the bridge reads. Nothing leaves this machine, and nothing shows. See CoreSend.lua.

local _, ns = ...

ns.loaded = {} -- Thread id -> the diff and agent reports opened this session.
ns.SLOT_COUNT = 1000 -- Keep equal to SLOT_COUNT in bridge/promptpeon_bridge.py.
ns.OUT_COUNT = 96 -- Keep equal to OUT_COUNT in bridge/promptpeon_bridge.py.
-- T3's approval modes, in its order and with its names. Keep equal to RUNTIME_MODES in the bridge.
-- `free` ones can act without asking, so they take the installer's yes. The bridge is what enforces that.
ns.RUNTIME_MODES = {
  { id = "approval-required", label = "Supervised", note = "It asks before commands and file changes, and you answer in T3." },
  { id = "auto-accept-edits", label = "Auto-accept edits", note = "It makes edits by itself. It asks before anything else, and you answer in T3." },
  { id = "auto", label = "Auto", free = true, note = "Some providers approve routine actions by themselves. The rest still ask, and you answer in T3." },
  { id = "full-access", label = "Full access", free = true, note = "It runs commands and changes files without asking." },
}
ns.REFRESH_OPEN = 20 -- Seconds between refreshes with the log open. 1000 of these last over 5 hours.
ns.REFRESH_WATCHING = 30 -- Log closed, agents working: the tracker and party frames stay fresh.
ns.REFRESH_CLOSED = 90 -- Log closed, nothing happening.
ns.QUIET_RUSH_SLOTS = 12 -- Updates to spend at 5 seconds apart, waiting for the first real data after login.
ns.BRIDGE_QUIET_AFTER = 45 -- A snapshot this old when loaded means the bridge has stopped.
ns.MAX_REPLY_BYTES = 4000
ns.STARTING_SHOWS_FOR = 30 -- Seconds. Long enough for T3 to answer, and it goes if T3 never does.
ns.starting = {} -- New threads you've just started, until T3's own row arrives.
ns.sentShowing = {} -- Messages the companion app has confirmed, until T3's own copy arrives.
ns.CHUNK_BYTES = 1500 -- One text block in the log.
ns.FRAME_SECONDS = 0.04
ns.FIRST_FRAME_SECONDS = 0.12 -- Held longer, so a bridge that was idling wakes up in time.
ns.MAX_TRIES = 3

ns.nextSlot = 1
ns.lastRefresh = 0
ns.liveProblem = nil -- Why live refresh stopped, in words. Nil while it works.
ns.loadFailures = 0
ns.lastStatus = nil -- thread id -> status, to notice a thread changing state.
ns.snapshotAge = 0
ns.carrier = {}

-- --- Text ------------------------------------------------------------------

--- Make untrusted text safe to draw. In a FontString a single | starts an escape
--- (colours, textures, clickable links), so every pipe from a thread is doubled.
function ns.Plain(text)
  return (tostring(text or ""):gsub("|", "||"))
end

--- What the player typed, as they typed it. An EditBox doubles pipes in GetText.
function ns.Typed(text)
  return (tostring(text or ""):gsub("||", "|"))
end

--- Split long text into pieces a FontString or chat line can hold, losing nothing but the
--- whitespace it splits on. Prefers a line break, then a space, and never splits a character.
function ns.Chunks(text, size)
  size = size or ns.CHUNK_BYTES
  local chunks, start, length = {}, 1, #text
  while start <= length do
    if length - start + 1 <= size then
      chunks[#chunks + 1] = text:sub(start)
      break
    end
    local stop, floor, cut = start + size - 1, start + math.floor(size / 2), nil
    for index = stop, floor, -1 do
      if text:byte(index) == 10 then cut = index; break end
    end
    if not cut then
      for index = stop, floor, -1 do
        if text:byte(index) == 32 then cut = index; break end
      end
    end
    if not cut then
      cut = stop
      -- The next byte continues a UTF-8 character, so step back to keep it whole.
      while cut > start and bit.band(text:byte(cut + 1), 0xC0) == 0x80 do cut = cut - 1 end
    end
    chunks[#chunks + 1] = (text:sub(start, cut):gsub("%s+$", ""))
    start = cut + 1
  end
  return chunks
end

function ns.ToHex(text)
  return (text:gsub(".", function(char) return string.format("%02x", string.byte(char)) end))
end

--- A running time: 45s, 3m 12s, 1h 04m.
function ns.Clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60) end
  return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

function ns.Ago(seconds)
  if seconds < 90 then return "just now" end
  if seconds < 5400 then return math.floor(seconds / 60 + 0.5) .. " min ago" end
  if seconds < 129600 then return math.floor(seconds / 3600 + 0.5) .. " h ago" end
  return math.floor(seconds / 86400 + 0.5) .. " d ago"
end
