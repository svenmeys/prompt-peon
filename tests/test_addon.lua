-- Run from the repo root with: luajit tests/test_addon.lua [hostile_snapshot.lua]
package.path = "tests/?.lua;" .. package.path
local stub = require("wow_stub")
local failures, checks = 0, 0
local function check(name, condition, detail)
  checks = checks + 1
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

stub.install()
local ns = {}
local function load_file(path)
  local chunk = assert(loadfile("addon/PromptPeon/" .. path))
  chunk("PromptPeon", ns)
end

local THREAD = "1f7743e2-3c60-4348-88a5-7b9f3d6c00b0"
local OTHER = "aaaaaaaa-0000-4000-8000-000000000000"
local function snapshot(extra)
  local base = {
    v = 1, at = time(), ack = 0, res = {}, err = "", errAt = 0,
    threads = {
      { id = THREAD, p = "Shop", t = "WoW addon", s = "running", u = time() - 60, m = { { "u", "hello" }, { "a", "hi | there" } } },
      { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 },
    },
  }
  for key, value in pairs(extra or {}) do base[key] = value end
  return base
end

--- Let one reply finish going out, then run the check timers.
local function drainSend()
  for _ = 1, 2000 do
    if not ns.tx then break end
    stub.now = stub.now + 0.2
    ns.sender.scripts.OnUpdate()
  end
end

PROMPTPEON_SNAPSHOT = snapshot()
PromptPeonDB = { firstTracked = true }
-- Load what the game loads, in the game's order, so a file left out of the .toc fails here too.
for line in io.lines("addon/PromptPeon/PromptPeon.toc") do
  local name = line:match("^([%w_]+%.lua)%s*$")
  if name and name ~= "Snapshot.lua" then load_file(name) end
end
stub.fire("ADDON_LOADED", "PromptPeon")
stub.fire("PLAYER_LOGIN")
stub.runTimers()

check("snapshot read at login", ns.snapshot and #ns.snapshot.threads == 2)
check("global cleared after reading", PROMPTPEON_SNAPSHOT == nil)
check("outbox starts empty", PromptPeonOutbox == "")
check("tracker reads working count", PromptPeonTracker.text.text:find("1 working", 1, true), PromptPeonTracker.text.text)
-- What the log's buttons do, for tests about what happens next rather than the button.
local press = {}
function press.startThread(project, prompt)
  local mode = ns:NewThreadMode()
  if ns:QueueCommand("new-thread", "new", mode.id .. "\n" .. project .. "\n" .. prompt) then
    ns:ShowStarting(project, prompt)
    ns.Chat:ReportReload("Starting a new thread in " .. ns.Plain(project) .. ". " .. mode.note)
    ns.UI:Render()
  end
end
function press.party()
  PromptPeonDB.partyOn = not PromptPeonDB.partyOn
  ns.UI:Render()
end
function press.send(id, words)
  local ok = ns:QueueReply(id, words)
  ns:Deliver()
  return ok
end
function press.spell(id)
  for _, entry in ipairs(ns.Game.SPELLS) do
    if entry.id == id then return entry end
  end
end
check("carriers cleared at login", #stub.saves[#stub.saves] == 0)

-- Opening the log.
SlashCmdList.PROMPTPEON("")
check("/peon opens the log", ns.UI:IsOpen())
check("first thread selected", PromptPeonDB.selected == THREAD)
check("hint names the thread", ns.UI.hint.text:find("WoW addon", 1, true), ns.UI.hint.text)
SlashCmdList.PROMPTPEON("")
check("/peon closes the log", not ns.UI:IsOpen())
SlashCmdList.PROMPTPEON("")

check("pipes doubled for display", ns.Plain("a|Hitem:1|h") == "a||Hitem:1||h")
check("typed pipes restored", ns.Typed("a||b") == "a|b")

-- A reply from the window: no reload, ever.
local reloadsBefore = stub.reloads
ns.UI.input.EditBox:SetText("  hello from Azeroth  ")
ns.UI:Send()
check("reply queued", #PromptPeonDB.pending == 1)
check("whitespace trimmed", PromptPeonDB.pending[1].text == "hello from Azeroth")
check("box cleared", ns.UI.input.EditBox:GetText() == "")
check("shows sending", ns.UI.notice.text == "Sending...", ns.UI.notice.text)
check("shown in the thread straight away", (function()
  for _, line in ipairs(ns.UI.lines) do if line.text == "hello from Azeroth" then return true end end
end)())
check("transmit started", ns.tx ~= nil)
local savesBefore = #stub.saves
drainSend()
check("every frame saved to disk", #stub.saves - savesBefore >= 3, #stub.saves - savesBefore)
check("carriers clear when done", #stub.saves[#stub.saves] == 0)
ns:StartNextSend()
check("no resend while waiting for the answer", ns.tx == nil and PromptPeonDB.pending[1].tries == 1)
check("Send does not reload", stub.reloads == reloadsBefore)
check("fallback outbox still written", PromptPeonOutbox:find("1:" .. ns.ToHex(THREAD) .. ":", 1, true) == 1, PromptPeonOutbox)

-- The bridge answers.
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 1, res = { ["1"] = "sent" } })
stub.runTimers()
check("ack clears pending", #PromptPeonDB.pending == 0)
check("ack clears the outbox", PromptPeonOutbox == "")
check("shows sent", ns.UI.notice.text:find("Sent", 1, true), ns.UI.notice.text)

-- Refused replies keep the text.
ns.UI.input.EditBox:SetText("   ")
ns.UI:Send()
check("empty reply refused", ns.UI.notice.text:find("Nothing", 1, true), ns.UI.notice.text)
check("no thread refused", ns:QueueReply(nil, "x") == nil)
local refused, why = ns:QueueReply("has|pipe", "x")
check("a thread we can't reach is refused and explained", refused == nil and why:find("Open it in T3", 1, true), why)
check("oversized reply refused", ns:QueueReply(THREAD, string.rep("x", 4001)) == nil)

-- Nobody answers: resend, then stop and say so. Nothing is lost.
stub.timers = {}
ns:QueueReply(THREAD, "into the void")
ns:Deliver()
local stuckEntry = PromptPeonDB.pending[1]
for _ = 1, 3 do
  drainSend()
  stub.slotData = nil
  stub.now = stub.now + 100
  stub.runTimers() -- First check.
  stub.now = stub.now + 100
  stub.runTimers() -- Second check, then resend or give up.
end
check("tried three times", stuckEntry.tries == 3, stuckEntry.tries)
check("stuck is flagged", stuckEntry.stuck == true)
check("stuck offers a reload", ns:NeedsReload() and ns.UI.reload.shown)
check("stuck says what to do", ns.UI.notice.text:find("Reload UI", 1, true), ns.UI.notice.text)
check("stuck stays in the fallback outbox", PromptPeonOutbox:find(ns.ToHex("into the void"), 1, true))
check("chat is told", stub.chat[#stub.chat]:find("not answering", 1, true), stub.chat[#stub.chat])
ns:QueueReply(OTHER, "behind the stuck one")
ns:Deliver()
check("a later reply never overtakes a stuck one", ns.tx == nil)
check("the later reply is told why", (function()
  PromptPeonDB.selected = OTHER
  ns.UI:Render()
  local text = ns.UI.notice.text
  PromptPeonDB.selected = THREAD
  return text:find("not answering", 1, true)
end)())
PromptPeonDB.pending[2] = nil
PromptPeonDB.nextSeq = 3
ns:WriteOutbox()
ns.UI:Render()
stub.slotData = snapshot({ ack = 2, res = { ["2"] = "sent" } })
stub.now = stub.now + 100
ns:RefreshAndRender()
check("a late answer clears it", #PromptPeonDB.pending == 0 and not ns:NeedsReload())
stub.timers = {}

-- A failure from the bridge reaches the player.
ns:QueueReply(THREAD, "bad one")
ns:Deliver()
drainSend()
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 3, res = { ["3"] = "failed: too many replies in one minute" } })
stub.runTimers()
check("failure shown in the log", ns.UI.notice.text:find("too many", 1, true), ns.UI.notice.text)
check("failure shown in chat", stub.chat[#stub.chat]:find("too many", 1, true), stub.chat[#stub.chat])
stub.timers = {}

-- Combat: replies wait, nothing reloads, the log gets out of the way and comes back.
check("log open before the fight", ns.UI:IsOpen())
stub.fire("PLAYER_REGEN_DISABLED")
stub.inCombat = true
check("log hides in combat", not ns.UI:IsOpen())
press.send(PromptPeonDB.selected, "mid fight message")
check("reply accepted in combat", #PromptPeonDB.pending == 1)
check("no frames sent in combat", ns.tx == nil)
stub.now = stub.now + 100
local slotBefore = ns.nextSlot
stub.tick()
check("no slot spent in combat", ns.nextSlot == slotBefore)
stub.inCombat = false
stub.fire("PLAYER_REGEN_ENABLED")
check("log returns after combat", ns.UI:IsOpen())
check("held reply goes out after combat", ns.tx ~= nil)
drainSend()
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 4, res = { ["4"] = "sent" } })
stub.runTimers()
check("held reply delivered", #PromptPeonDB.pending == 0)
stub.timers = {}

-- A reply to another thread.
press.send(OTHER, "hello other thread")
check("a reply goes to the thread it names", PromptPeonDB.pending[1].thread == OTHER)
check("and your words stay out of chat, which is what other addons and logs keep", not table.concat(stub.chat, "\n"):find("hello other thread", 1, true))
PromptPeonDB.selected = OTHER
drainSend()
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 5, res = { ["5"] = "sent" } })
stub.runTimers()
stub.timers = {}
press.send(PromptPeonDB.selected, "and again")
check("/peon text uses the current thread", PromptPeonDB.pending[1].thread == OTHER and PromptPeonDB.pending[1].text == "and again")
drainSend()
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 6, res = { ["6"] = "sent" } })
stub.runTimers()
stub.timers = {}
local chatBefore = #stub.chat
ns.UI:OpenThread(THREAD)
check("opening a thread selects it", PromptPeonDB.selected == THREAD and ns.UI:IsOpen())
check("a new install's window is solid", PromptPeonDB.opacity == 1, PromptPeonDB.opacity)
check("/peon is the command, and /t3 still works", SLASH_PROMPTPEON1 == "/peon" and SLASH_PROMPTPEON2 == "/t3")
check("the reply box knows both", ns.Chat.OwnCommand("/peon") and ns.Chat.OwnCommand(" /T3 "))
check("and leaves anything else alone", not ns.Chat.OwnCommand("/peon away") and not ns.Chat.OwnCommand("/peonies are nice") and not ns.Chat.OwnCommand("/compact"))
do
  local holder = ns.UI.party
  PromptPeonDB.partyPosition = nil
  ns.UI:RenderParty()
  check("Classic's party hangs under your own frame", holder == nil or holder.lastPoint[2] == PlayerFrame)
  _G.ObjectiveTrackerFrame = CreateFrame("Frame")
  ns.UI:RenderParty()
  check("on retail and Forever it has its own spot, wherever your frame went", holder == nil or holder.lastPoint[2] == UIParent)
  _G.ObjectiveTrackerFrame = nil
  local shownTracker = ns.UI.tracker
  local savedSpot = PromptPeonDB.tracker
  PromptPeonDB.tracker = nil
  _G.ObjectiveTrackerFrame = CreateFrame("Frame")
  ns.UI:BuildTracker()
  check("the tracker sits beside the game's own objectives", ns.UI.tracker.lastPoint[2] == ObjectiveTrackerFrame and ns.UI.tracker.lastPoint[3] == "TOPLEFT")
  _G.ObjectiveTrackerFrame = nil
  -- Classic hides its quest list when nothing is tracked, and a hidden list has no place on screen.
  -- Anchored to it, our tracker vanished on any character with no tracked quests.
  _G.QuestWatchFrame = CreateFrame("Frame")
  QuestWatchFrame:Hide()
  ns.UI:BuildTracker()
  check("with no quests tracked it sits under the minimap, and stays visible", ns.UI.tracker.lastPoint[2] == Minimap)
  QuestWatchFrame:Show()
  QuestWatchFrame.scripts.OnShow(QuestWatchFrame)
  check("track a quest and it moves beside the list", ns.UI.tracker.lastPoint[2] == QuestWatchFrame and ns.UI.tracker.lastPoint[3] == "TOPLEFT")
  QuestWatchFrame:Hide()
  QuestWatchFrame.scripts.OnHide(QuestWatchFrame)
  check("and back when the list goes away", ns.UI.tracker.lastPoint[2] == Minimap)
  PromptPeonDB.tracker = { "TOPLEFT", "TOPLEFT", 40, -40 }
  QuestWatchFrame:Show()
  QuestWatchFrame.scripts.OnShow(QuestWatchFrame)
  check("a spot you dragged it to always wins", ns.UI.tracker.lastPoint[2] == UIParent)
  PromptPeonDB.tracker = nil
  _G.QuestWatchFrame = nil
  ns.UI:BuildTracker()
  check("with no list at all, it sits under the minimap", ns.UI.tracker.lastPoint[2] == Minimap)
  ns.UI.tracker, _G.PromptPeonTracker, PromptPeonDB.tracker = shownTracker, shownTracker, savedSpot
end
ns.UI:SetOpacity(0.4)
check("/peon opacity sets the stacked background", math.abs(PromptPeonDB.opacity - 0.4) < 0.001
  and math.abs(1 - (1 - PromptPeonFrame.Bg.alpha) * (1 - PromptPeonFrame.InsetBg.alpha) - 0.4) < 0.001)
check("text stays opaque", PromptPeonFrame.alpha > 0.5)
ns.UI:SetOpacity(5)
check("opacity is clamped", PromptPeonDB.opacity == 1)
ns.UI:SetOpacity(0.8)

-- Clickable thread names.
stub.linkHandler(nil, "addon:peon:" .. OTHER, "x", "LeftButton")
check("clicking a thread name opens it in the log", PromptPeonDB.selected == OTHER and ns.UI:IsOpen())
stub.linkHandler(nil, "addon:peon:" .. THREAD, "x", "RightButton")
check("so does a right click", PromptPeonDB.selected == THREAD)
stub.linkHandler(nil, "item:123", "x", "LeftButton")
check("other links are left alone", PromptPeonDB.selected == THREAD)

-- Idle fade.
stub.mouseOver = false
ns.UI.input.EditBox:ClearFocus()
for _ = 1, 60 do PromptPeonFrame.scripts.OnUpdate(PromptPeonFrame) end
check("fades when idle", PromptPeonFrame.alpha < 0.9, PromptPeonFrame.alpha)
stub.mouseOver = true
for _ = 1, 60 do PromptPeonFrame.scripts.OnUpdate(PromptPeonFrame) end
check("full when the mouse is on it", PromptPeonFrame.alpha > 0.98, PromptPeonFrame.alpha)

-- Without the send addons (game not restarted yet): fall back to a reload, and say nothing is lost.
stub.carriersExist = false
reloadsBefore = stub.reloads
press.send(PromptPeonDB.selected, "old way")
check("falls back to a reload", stub.reloads == reloadsBefore + 1)
stub.carriersExist = true
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, res = { ["7"] = "sent" } })
ns:RefreshAndRender()
stub.timers = {}

-- Live refresh.
stub.now = stub.now + 100
slotBefore = ns.nextSlot
stub.slotData = snapshot({ ack = 7, at = time() + 1 })
stub.tick()
check("tick spends one slot", ns.nextSlot == slotBefore + 1)

-- Open/close spam does not burn slots.
stub.now = stub.now + 100
ns:RefreshAndRender()
local spent = ns.nextSlot
ns:RefreshAndRender()
ns:RefreshAndRender()
check("quick re-renders spend no slots", ns.nextSlot == spent)

-- Agent finishes: chat says so, with the start of its answer.
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = time() + 2, threads = {
  { id = THREAD, p = "Shop", t = "WoW addon", s = "done", u = time(), m = { { "a", "All finished, it works |cffff0000really" } } },
  { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 },
} })
ns:RefreshAndRender()
local last = stub.chat[#stub.chat]
check("finished thread is announced", last:find("finished", 1, true) and last:find("All finished", 1, true), last)
check("announced text cannot inject colours", last:find("||cffff0000", 1, true), last)
check("thread name is a clickable link", last:find("|Haddon:peon:" .. THREAD, 1, true), last)

-- Needs you: sound, banner and chat line, once.
stub.now = stub.now + 100
local before = stub.sounds
stub.slotData = snapshot({ ack = 7, at = time() + 3, threads = { { id = THREAD, p = "Shop", t = "Blocked", s = "needs", u = time() } } })
ns:RefreshAndRender()
check("needs-you alerts, with the bell and the peon", stub.sounds == before + 2 and stub.errors[#stub.errors]:find("Blocked", 1, true))
check("needs-you reaches chat", stub.chat[#stub.chat]:find("needs you", 1, true), stub.chat[#stub.chat])
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = time() + 4, threads = { { id = THREAD, p = "Shop", t = "Blocked", s = "needs", u = time() } } })
ns:RefreshAndRender()
check("needs-you alerts only once", stub.sounds == before + 2)
check("tracker shows needs you", PromptPeonTracker.text.text:find("1 need you", 1, true), PromptPeonTracker.text.text)

-- Mac gone: keep the threads and say so.
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = time() + 5, threads = {}, err = "Can't reach T3 at http://x.", errAt = time() - 300 })
ns:RefreshAndRender()
check("outage keeps the last threads", #ns.snapshot.threads == 1)
check("outage is named", (ns:Problem() or ""):find("Can't reach", 1, true), ns:Problem())
check("tracker says offline", PromptPeonTracker.text.text:find("T3 offline", 1, true), PromptPeonTracker.text.text)

-- Bridge dead: what we load is old the moment we load it.
stub.now = stub.now + 100
stub.clock = os.time() + 4000
stub.slotData = snapshot({ ack = 7, at = os.time() + 3000 })
ns:RefreshAndRender()
check("quiet bridge is named", (ns:Problem() or ""):find("quiet", 1, true), ns:Problem())
stub.clock = nil

-- Garbage in a slot leaves the last good data alone.
stub.now = stub.now + 100
local good = ns.snapshot
stub.slotData = { v = 99 }
ns:RefreshAndRender()
check("wrong version ignored", ns.snapshot == good)
stub.now = stub.now + 100
stub.slotData = "not a table"
ns:RefreshAndRender()
check("non-table ignored", ns.snapshot == good)
stub.now = stub.now + 100
good.sid, good.rv = "run1", 5
stub.slotData = snapshot({ at = time() + 9000, sid = "run1", rv = 4 })
ns:RefreshAndRender()
check("an older revision from the same run is ignored, whatever its clock says", ns.snapshot == good)
stub.now = stub.now + 100
stub.slotData = snapshot({ at = 1, sid = "run1", rv = 6, threads = good.threads })
ns:RefreshAndRender()
check("a newer one counts, even if the clock went backwards", ns.snapshot ~= good and ns.snapshot.rv == 6)
good = ns.snapshot
stub.now = stub.now + 100
stub.slotData = snapshot({ at = 1, sid = "run2", rv = 1, threads = good.threads })
ns:RefreshAndRender()
check("a restarted bridge starts counting again", ns.snapshot.sid == "run2")
good = ns.snapshot
good.sid, good.rv = nil, nil

-- Slots run out: say so, offer the reload, and a reload resets them.
ns.nextSlot = ns.SLOT_COUNT + 1
stub.now = stub.now + 100
ns:RefreshAndRender()
check("running out of slots is named", (ns:Problem() or ""):find("Reload UI", 1, true), ns:Problem())
check("reload button appears", ns.UI.reload.shown)
ns.liveProblem = nil
ns.nextSlot = 200

-- The client refuses LoadAddOn: stop trying and explain.
stub.refuseLoads = true
for _ = 1, 3 do
  stub.now = stub.now + 100
  ns:RefreshAndRender()
end
check("refused loads stop and explain", (ns.liveProblem or ""):find("DISABLED", 1, true), ns.liveProblem)
local stopped = ns.nextSlot
stub.now = stub.now + 30
stub.tick()
check("no rush after a refusal", ns.nextSlot == stopped)
stub.now = stub.now + 100
stub.tick()
check("but it tries again after a minute, because another addon can use up a few helpers", ns.nextSlot == stopped + 1, ns.nextSlot)
stub.refuseLoads = false
ns.liveProblem = nil

-- Long messages are never cut, in the log or in chat.
local function stripped(text) return (text:gsub("%s+", "")) end
local paragraph = "Une phrase avec des accents: été, déjà, naïve. And a |pipe too. "
local long = {}
for index = 1, 400 do long[index] = paragraph .. index .. (index % 7 == 0 and "\n\n" or "") end
long = table.concat(long)
local solid = string.rep("é", 2000) .. string.rep("x", 3000)
for name, text in pairs({ long = long, solid = solid }) do
  local chunks = ns.Chunks(text)
  check(name .. " text is split up", #chunks > 1, #chunks)
  local whole = true
  for _, chunk in ipairs(chunks) do
    if #chunk > ns.CHUNK_BYTES then whole = false end
    if chunk:sub(-1):byte() >= 0xC0 or (chunk:byte(1) >= 0x80 and chunk:byte(1) < 0xC0) then whole = false end
  end
  check(name .. " chunks fit and no character is split", whole)
  check(name .. " loses nothing when split", stripped(table.concat(chunks)) == stripped(text))
end
check("short text stays one piece", #ns.Chunks("hello") == 1 and ns.Chunks("hello")[1] == "hello")
check("empty text is no pieces", #ns.Chunks("") == 0)
check("a single long word still splits", #ns.Chunks(string.rep("x", 3100)) == 3)

stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = os.time() + 5000, threads = {
  { id = THREAD, p = "Shop", t = "Long one", s = "running", u = time(), m = { { "a", long } } },
  { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 },
} })
PromptPeonDB.selected = THREAD
ns:RefreshAndRender()
local drawn = {}
for _, line in ipairs(ns.UI.lines) do
  if line.shown and line.text ~= "Agent" then drawn[#drawn + 1] = line.text end
end
check("the log shows the whole message", stripped(table.concat(drawn)):gsub("||", "|") == stripped(long), #drawn)
check("the log uses several text blocks", #drawn > 1, #drawn)

local chatStart = #stub.chat
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = os.time() + 5001, threads = {
  { id = THREAD, p = "Shop", t = "Long one", s = "done", u = time(), m = { { "a", long } } },
  { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 },
} })
ns:RefreshAndRender()
local said = {}
for index = chatStart + 1, #stub.chat do said[#said + 1] = stub.chat[index] end
local chatText = table.concat(said):gsub("^.-finished: ", "")
check("chat only shows the start of a long message", #said == 4 and said[4]:find("the rest is in the log", 1, true), #said)
check("chat lines stay a sensible length", (function()
  for _, line in ipairs(said) do if #line > 900 then return false end end
  return true
end)())

-- /peon status.
ns.Chat:Status()
check("/peon status reports live updates left", table.concat(stub.chat, "\n", math.max(#stub.chat - 1, 1)):find("live updates left", 1, true), stub.chat[#stub.chat])

-- Text size.
check("default text is a bit smaller", PromptPeonBody.size == 11 and PromptPeonSmall.size == 10 and PromptPeonTitle.size == 13, PromptPeonBody.size)
ns.UI:SetFontSize(14)
check("/peon font sets all the sizes", PromptPeonBody.size == 14 and PromptPeonSmall.size == 13 and PromptPeonTitle.size == 16 and PromptPeonDB.fontSize == 14)
ns.UI:SetFontSize(99)
check("/peon font is clamped", PromptPeonDB.fontSize == 20)
ns.UI:SetFontSize(11)

-- What T3 shows inside a thread: thinking, steps, questions, what it is doing now.
local function shownLines()
  local out = {}
  for _, line in ipairs(ns.UI.lines) do
    if line.shown then out[#out + 1] = line.text end
  end
  return table.concat(out, "\n")
end
local function working(extra)
  local row = {
    id = THREAD, p = "Shop", t = "Busy", s = "running", u = time(), a = "Thinking", as = time() - 75,
    m = {
      { "u", "please fix it", "d", 1 },
      { "t", "Early thought about the bug", "d", 2 },
      { "s", "Ran git status", "d", 3 },
      { "s", "Ran make test", "f", 4 },
      { "a", "Found it, fixing now", "d", 5 },
      { "t", "Now weighing the second fix", "r", 6 },
      { "s", "Ran git diff", "r", 7 },
    },
  }
  for key, value in pairs(extra or {}) do row[key] = value end
  return row
end
local stamp = os.time() + 6000
local function show(row)
  stamp = stamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = 7, at = stamp, threads = { row, { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 } } })
  PromptPeonDB.selected = THREAD
  ns:RefreshAndRender()
end
show(working())
local shown = shownLines()
check("messages always show", shown:find("please fix it", 1, true) and shown:find("Found it", 1, true))
check("older work starts collapsed", not shown:find("Early thought", 1, true), shown)
check("the steps of work still going on show", shown:find("Ran git diff", 1, true), shown)
check("its thinking stays folded", not shown:find("Now weighing the second fix", 1, true), shown)
check("a running step is marked", shown:find("... Ran git diff", 1, true), shown)
local workHead = ns.UI.heads[2]
workHead.scripts.OnClick(workHead)
check("thinking is labelled once you open it", shownLines():find("Thinking: Now weighing", 1, true), shownLines())
ns.UI.groups = {}
ns.UI:Render()
check("the collapsed group says what is inside", ns.UI.heads[1].text.text:find("1 thought, 2 steps", 1, true), ns.UI.heads[1].text.text)
check("failed steps stand out when collapsed", ns.UI.heads[1].text.text:find("1 failed", 1, true), ns.UI.heads[1].text.text)
ns.UI.heads[1].scripts.OnClick(ns.UI.heads[1])
shown = shownLines()
check("clicking opens the group", shown:find("Early thought", 1, true) and shown:find("Ran make test", 1, true), shown)
check("a failed step is marked", shown:find("x Ran make test", 1, true), shown)
ns.UI.heads[1].scripts.OnClick(ns.UI.heads[1])
check("clicking again closes it", not shownLines():find("Early thought", 1, true))
ns.UI.heads[1].scripts.OnClick(ns.UI.heads[1])
show(working())
check("your choice survives a refresh", shownLines():find("Early thought", 1, true))
ns.UI.groups = {}

check("activity says what it is doing", ns.UI.activity.text:find("Thinking", 1, true), ns.UI.activity.text)
check("activity has a running clock", ns.UI.activity.text:find("1m 15s", 1, true) or ns.UI.activity.text:find("1m 16s", 1, true), ns.UI.activity.text)
local before = ns.UI.activity.text
stub.clock = os.time() + 60
stub.now = stub.now + 5
PromptPeonFrame.scripts.OnUpdate(PromptPeonFrame)
check("the clock ticks without a refresh", ns.UI.activity.text ~= before, ns.UI.activity.text)
stub.clock = nil
check("clock format", ns.Clock(45) == "45s" and ns.Clock(192) == "3m 12s" and ns.Clock(3840) == "1h 04m")

local spentBefore = ns.nextSlot
stub.now = stub.now + 21
stub.slotData = nil
stub.tick()
check("with the log open it refreshes every 20 seconds", ns.nextSlot == spentBefore + 1)
spentBefore = ns.nextSlot
stub.now = stub.now + 3
stub.tick()
check("but not faster", ns.nextSlot == spentBefore)
PromptPeonDB.selected = OTHER
spentBefore = ns.nextSlot
stub.now = stub.now + 11
stub.tick()
check("whichever thread is open", ns.nextSlot == spentBefore)
PromptPeonDB.selected = THREAD

show(working({ s = "done", a = false, as = false, m = { { "s", "Ran git status", "d", 3 }, { "a", "All done", "d", 5 } } }))
check("finished work collapses", not shownLines():find("Ran git status", 1, true))
check("no activity when finished", ns.UI.activity.text == "", ns.UI.activity.text)

show(working({ s = "done", a = false, as = false, qc = 1, m = { { "a", "All done", "d", 5 }, { "u", "do one more thing", "q", 0 } } }))
shown = shownLines()
check("a queued message says so", shown:find("You (queued, goes next)", 1, true) and shown:find("do one more thing", 1, true), shown)
check("activity counts the queue", ns.UI.activity.text:find("1 message queued", 1, true), ns.UI.activity.text)

show(working({ s = "needs", a = "Waiting for your answer", nb = true, m = { { "q", "Which one?\n- Red\n- Blue", "r", 9 } } }))
shown = shownLines()
check("an open question is shown in full", shown:find("Which one?", 1, true) and shown:find("- Blue", 1, true), shown)
check("it says a reply answers it", shown:find("Your reply here answers it", 1, true), shown)
check("activity says it is waiting", ns.UI.activity.text:find("Waiting for your answer", 1, true), ns.UI.activity.text)
show(working({ s = "needs", a = "Waiting for your approval", m = { { "a", "May I?", "d", 9 } } }))
check("an approval says to use T3", shownLines():find("Answer it in T3", 1, true))

show(working({ m = { { "d", "[x] First\n[>] Second", "r", 8 } } }))
check("a todo list shows in open work", shownLines():find("[>] Second", 1, true), shownLines())
show(working({ m = { { "n", "Context compacted", "d", 8 } }, s = "running" }))
check("notices show", shownLines():find("Context compacted", 1, true))
check("work without thoughts or steps still has a heading", ns.UI.heads[1].text.text:find("Notes", 1, true))
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = stamp + 1, threads = { { id = THREAD, p = "Shop", t = "Old shape", s = "done", u = time(), m = { { "u", "two field row" }, { "a", "still fine" } } } } })
stamp = stamp + 1
ns:RefreshAndRender()
check("rows without a state still draw", shownLines():find("still fine", 1, true))
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = 7, at = stamp + 1 })
stamp = stamp + 1
ns:RefreshAndRender()

-- Quest feel.
local feelStamp = os.time() + 9000
local function feel(status, extra)
  feelStamp = feelStamp + 1
  stub.now = stub.now + 100
  local row = { id = THREAD, p = "Shop", t = "Feel", s = status, u = time(), m = { { "a", "Words", "d", 1 } } }
  for key, value in pairs(extra or {}) do row[key] = value end
  stub.slotData = snapshot({ ack = 7, at = feelStamp, threads = { row, { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 } } })
  ns:RefreshAndRender()
end
feel("running", { a = "Thinking", cu = 40, pv = "claudeAgent" })
stub.played, stub.banners = {}, {}
PromptPeonDB.questSound = true
feel("done")
PromptPeonDB.questSound = nil
check("finishing plays quest complete if you've asked for it", stub.played[1] == SOUNDKIT.IG_QUEST_LIST_COMPLETE)
check("finishing shows a banner", stub.banners[1] and stub.banners[1]:find("Quest complete: Feel", 1, true), stub.banners[1])
feel("running", { a = "Thinking" })
stub.played, stub.banners = {}, {}
feel("error")
check("failing plays the failure sound", stub.played[#stub.played] == SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST)
check("failing says so", stub.banners[1] and stub.banners[1]:find("Quest failed", 1, true), stub.banners[1])
feel("running", { a = "Thinking" })
stub.played, stub.banners = {}, {}
feel("stopped")
check("stopping is silent", #stub.played == 0 and #stub.banners == 0)
stub.played, stub.banners = {}, {}
feel("done")
check("no fanfare without a run finishing", #stub.banners == 0)

-- Tracking threads like quests.
feel("running", { a = "Thinking", cu = 40, pv = "claudeAgent", m = { { "d", "[x] First\n[>] Second\n[ ] Third", "r", 1 }, { "a", "Latest words from the agent", "d", 2 } } })
PromptPeonDB.tracked = {}
PromptPeonDB.expanded = {}
ns.UI:Render()
local working = ns:ThreadById(THREAD)
local quiet = ns:ThreadById(OTHER)
check("a working agent tracks itself", ns:IsTracked(working))
check("a finished thread does not", not ns:IsTracked(quiet))
local trackRow = ns.UI.trackRows[1]
check("it is on the tracker", trackRow.shown and trackRow.title.text:find("Feel", 1, true), trackRow.title.text)
check("it starts collapsed, with WoW's plus", trackRow.fold.texture:find("UI-PlusButton-Up", 1, true) and not trackRow.body.shown)
stub.shift = false
trackRow.scripts.OnClick(trackRow, "LeftButton")
check("clicking expands it, with WoW's minus", trackRow.fold.texture:find("UI-MinusButton-Up", 1, true) and trackRow.body.shown)
check("expanded shows activity", trackRow.body.text:find("Thinking", 1, true), trackRow.body.text)
check("expanded shows todo progress and the step", trackRow.body.text:find("1/3  Second", 1, true), trackRow.body.text)
check("expanded shows the latest words", trackRow.body.text:find("Latest words", 1, true), trackRow.body.text)
trackRow.scripts.OnClick(trackRow, "LeftButton")
check("clicking again collapses it", not trackRow.body.shown)
ns:ToggleTracked(quiet)
check("/peon track pins any thread", ns:IsTracked(quiet))
check("pinned threads reach the tracker", ns.UI.trackRows[2].shown)
stub.shift = true
ns.UI.trackRows[2].scripts.OnClick(ns.UI.trackRows[2], "LeftButton")
stub.shift = false
check("shift-click untracks", not ns:IsTracked(quiet))
stub.shift = true
local listRow
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == OTHER then listRow = row end
end
listRow.scripts.OnClick(listRow, "LeftButton")
stub.shift = false
check("shift-click in the log tracks", ns:IsTracked(quiet))
PromptPeonDB.tracked[THREAD] = false
ns.UI:Render()
check("a working agent can be untracked", not ns:IsTracked(working))
PromptPeonDB.tracked = {}
ns.UI:Render()

-- Party frames are on until you turn them off.
check("party frames start on", PromptPeonDB.partyOn == true and ns.UI.party.shown)
press.party()
check("/peon party turns them off", PromptPeonDB.partyOn == false and not ns.UI.party.shown)
press.party()
check("/peon party turns them on", PromptPeonDB.partyOn == true and ns.UI.party.shown)
local member = ns.UI.partyRows[1]
check("a working agent is in the party", ns.UI.party.shown and member.shown and member.name.text == "Feel", member.name.text)
check("the activity is a still icon", ns.UI.ActivityIcon(ns:ThreadById(THREAD)):find("MindVision", 1, true) and member.debuff.value == 0)
check("each activity has its own icon", ns.UI.ActivityIcon({ s = "running", a = "Running a command" }):find("Engineering", 1, true)
  and ns.UI.ActivityIcon({ s = "running", a = "Editing b.py" }):find("Feather", 1, true)
  and ns.UI.ActivityIcon({ s = "running", a = "Searching files" }):find("Spyglass", 1, true)
  and ns.UI.ActivityIcon({ s = "running", a = "Waiting for your answer" }):find("QuestionMark", 1, true)
  and ns.UI.ActivityIcon({ s = "running", a = "Something new" }):find("Gear", 1, true))
check("nothing on the party frames animates", ns.UI.party.scripts.OnUpdate == nil and ns.UI.AnimateParty == nil and member.cast == nil)
check("mana is context left", math.abs(member.mana.value - 0.6) < 0.001, member.mana.value)
check("health is how the turn is going", member.health.value == 1, member.health.value)
local partyOpened
local realOpen = ns.UI.OpenThread
ns.UI.OpenThread = function(_, id) partyOpened = id end
member.scripts.OnClick(member, "LeftButton")
check("clicking a party member opens the thread", partyOpened == THREAD)
ns.UI.OpenThread = realOpen
press.party()
check("/peon party turns them off", not ns.UI.party.shown and not PromptPeonDB.partyOn)
press.party()
check("and on again", ns.UI.party.shown)
feel("done")
check("one you took off the list stays out of the party", not ns.UI.party.shown)
stub.now = stub.now + 100

-- Real faces.
feel("running", { a = "Thinking" })
local faceRow = ns.UI.partyRows[1]
local firstFace = faceRow.face.portrait
check("everyone starts as a peon", faceRow.face.portrait == 10038, faceRow.face.portrait)
check("a second agent is a peon too", ns.UI.FaceFor({ id = "second-agent-id" }) == 10038)
check("being a peon is not written down", PromptPeonDB.faces[THREAD] == nil)
ns.UI.NextFace({ id = THREAD, t = "Feel" })
ns:RefreshAndRender()
stub.timers = {}
check("Change face promotes this one", faceRow.face.portrait ~= 10038 and faceRow.face.portrait > 0, faceRow.face.portrait)
check("and it stays promoted", PromptPeonDB.faces[THREAD] == faceRow.face.portrait)
PromptPeonDB.faces = {}
ns.UI:Render()

-- Right-click and hiding.
feel("running", { a = "Thinking" })
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
end
listRow.scripts.OnClick(listRow, "RightButton")
check("right-click opens a menu", ns.UI.menuCatcher.shown)
local function menuItem(words)
  for _, button in ipairs(ns.UI.menuButtons or {}) do
    -- A tick or an icon can come first, so match the end of what it says.
    if button.shown and tostring(button.text.text):sub(-#words) == words then return button end
  end
end
check("the menu offers the actions", menuItem("Open") and menuItem("Stop tracking") and menuItem("Hide...") and menuItem("Snooze..."), "menu")
check("and only those", not menuItem("Reply in chat") and not menuItem("New thread in this project") and not menuItem("Change face"))
menuItem("Open").scripts.OnClick(menuItem("Open"))
check("choosing closes the menu", not ns.UI.menuCatcher.shown)
listRow.scripts.OnClick(listRow, "RightButton")
ns.UI.menuCatcher.scripts.OnClick(ns.UI.menuCatcher)
check("clicking away closes the menu", not ns.UI.menuCatcher.shown)
stub.played, stub.banners = {}, {}
listRow.scripts.OnClick(listRow, "RightButton")
menuItem("Hide...").scripts.OnClick(menuItem("Hide..."))
menuItem("This thread").scripts.OnClick(menuItem("This thread"))
check("a hidden thread leaves the list", (function()
  for _, row in ipairs(ns.UI.rows) do
    if row.shown and row.thread and row.thread.id == THREAD then return false end
  end
  return true
end)())
check("a Hidden section appears", (function()
  for _, row in ipairs(ns.UI.rows) do
    if row.shown and row.isHiddenHeader then return row.text.text:find("Hidden (1)", 1, true) end
  end
end)())
check("the open thread moves off a hidden one", ns.UI.title.text ~= "Feel", ns.UI.title.text)
check("hidden threads leave the tracker", not (ns.UI.trackRows[1].shown and ns.UI.trackRows[1].thread.id == THREAD))
check("hidden threads leave the party", not ns.UI.party.shown)
check("hidden threads leave the counts", ns:Counts().running == 0 and PromptPeonTracker.text.text:find("working", 1, true) == nil, PromptPeonTracker.text.text)
feel("done", { })
check("hidden threads make no noise", #stub.played == 0 and #stub.banners == 0)
local hiddenHeader
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.isHiddenHeader then hiddenHeader = row end
end
hiddenHeader.scripts.OnClick(hiddenHeader, "LeftButton")
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
end
check("the Hidden section opens", listRow and listRow.thread.id == THREAD and listRow.shown)
listRow.scripts.OnClick(listRow, "RightButton")
check("a hidden thread can be shown again", menuItem("Show"))
menuItem("Show").scripts.OnClick(menuItem("Show"))
check("it comes back", not ns:IsHidden(ns:ThreadById(THREAD)))
PromptPeonDB.hiddenOpen = nil
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.project == "other" then listRow = row end
end
listRow.scripts.OnClick(listRow, "RightButton")
menuItem("Hide this project").scripts.OnClick(menuItem("Hide this project"))
check("hiding a project hides its threads", ns:IsHidden(ns:ThreadById(OTHER)))
PromptPeonDB.hiddenProjects = {}
PromptPeonDB.hiddenThreads = {}
ns.UI:Render()

-- The hover list on the tracker keeps hidden threads out too.
PromptPeonDB.hiddenThreads[THREAD] = true
local tipLines = {}
local realTipAdd = GameTooltip.AddLine
GameTooltip.AddLine = function(_, text) tipLines[#tipLines + 1] = tostring(text) end
ns.UI:ShowTrackerTip(PromptPeonTracker)
GameTooltip.AddLine = realTipAdd
check("the tracker tooltip leaves out hidden threads", not table.concat(tipLines, "\n"):find(ns:ThreadById(THREAD).t, 1, true), table.concat(tipLines, " | "))
check("the tracker tooltip still lists the others", table.concat(tipLines, "\n"):find("Quiet one", 1, true), table.concat(tipLines, " | "))
PromptPeonDB.hiddenThreads = {}

-- A reply whose outcome the bridge no longer has must not read as sent.
stub.timers = {}
ns:QueueReply(THREAD, "outcome lost")
local lostSeq = PromptPeonDB.pending[#PromptPeonDB.pending].seq
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = lostSeq, at = os.time() + 20000, res = {} })
ns.tx = nil
ns:RefreshAndRender()
check("a missing outcome is not called sent", PromptPeonDB.results[THREAD].text ~= "sent", PromptPeonDB.results[THREAD].text)
check("a missing outcome says to check", PromptPeonDB.results[THREAD].text:find("Check the thread", 1, true), PromptPeonDB.results[THREAD].text)
stub.timers = {}
stub.slotData = snapshot({ ack = lostSeq, at = os.time() + 20001 })

-- Options are a page, with real controls.
PromptPeonDB.partyOn = nil
ns.UI.options.scripts.OnClick(ns.UI.options)
stub.timers = {}
check("the cogwheel opens the options page", ns.UI.showOptions == true and ns.UI.title.text == "Options" and ns.UI.optionsPage.shown, ns.UI.title.text)
local optionsPage = ns.UI.optionsPage
local partyBox = optionsPage.checks.party.box
check("a checkbox shows how things stand", partyBox.checked == false)
partyBox.checked = true
partyBox.scripts.OnClick(partyBox)
check("ticking party frames turns them on", PromptPeonDB.partyOn == true)
partyBox.checked = false
partyBox.scripts.OnClick(partyBox)
check("unticking turns them off", not PromptPeonDB.partyOn)
local sizeBefore = PromptPeonDB.fontSize
local fontSlider = optionsPage.sliders.Font
fontSlider.bar.scripts.OnValueChanged(fontSlider.bar, sizeBefore + 1)
check("the text size slider works", PromptPeonDB.fontSize == sizeBefore + 1 and fontSlider.text.text:find(tostring(sizeBefore + 1), 1, true), fontSlider.text.text)
fontSlider.bar.scripts.OnValueChanged(fontSlider.bar, sizeBefore)
check("and goes back", PromptPeonDB.fontSize == sizeBefore)
local opacitySlider = optionsPage.sliders.Opacity
local opacityBefore = PromptPeonDB.opacity
opacitySlider.bar.scripts.OnValueChanged(opacitySlider.bar, 0.5)
check("the background slider works and says the percentage", PromptPeonDB.opacity == 0.5 and opacitySlider.text.text:find("50%%"), opacitySlider.text.text)
PromptPeonDB.opacity = opacityBefore
ns.UI:Render()
check("the page gets its room in the scroll area", ns.UI.detailContent.height >= optionsPage.height, ns.UI.detailContent.height)
ns.UI.back.scripts.OnClick(ns.UI.back)
stub.timers = {}
check("back leaves the page", ns.UI.showOptions == nil and not optionsPage.shown and ns.UI.title.text ~= "Options", ns.UI.title.text)

-- Markdown blocks.
local MD = ns.Markdown
local blocks = MD.Blocks("# Title\n\nSome words\nmore words\n\n- one\n- two\n  carried on\n  - nested\n\n1. first\n2) second\n\n> quoted\n> twice\n\n---\n\n| A | B |\n| --- | :-: |\n| 1 | 2 |\n| x |\n\n```lua\nlocal a = 1\n\n  indented\n```\nafter")
local kinds = {}
for _, block in ipairs(blocks) do kinds[#kinds + 1] = block.kind end
check("every block kind is recognised", table.concat(kinds, " ") == "h p li li li li li quote rule table code p", table.concat(kinds, " "))
check("heading level and text", blocks[1].level == 1 and blocks[1].text == "Title")
check("single line breaks stay in a paragraph", blocks[2].text == "Some words\nmore words", blocks[2].text)
check("an item takes its indented next line", blocks[4].text == "two carried on", blocks[4].text)
check("nesting is kept", blocks[5].depth == 1 and blocks[5].text == "nested")
check("numbers are kept", blocks[6].mark == "1." and blocks[7].mark == "2.")
check("quotes join up", blocks[8].text == "quoted\ntwice", blocks[8].text)
check("table cells are split", blocks[10].rows[1][2] == "B" and blocks[10].rows[2][1] == "1")
check("a short table row is still a row", blocks[10].rows[3][1] == "x" and #blocks[10].rows == 3)
check("code keeps its spacing", blocks[11].text == "local a = 1\n\n  indented", blocks[11].text)
check("an unclosed code block runs to the end", MD.Blocks("```\nstill code")[1].text == "still code")
check("empty text is no blocks", #MD.Blocks("") == 0 and #MD.Blocks(nil) == 0)
check("a pipe in a sentence is not a table", MD.Blocks("a | b\nc")[1].kind == "p")
check("a dash line under text is not a table", MD.Blocks("Title\n---\nmore")[2].kind == "rule")

-- Inline formatting is colour, and text from a thread can never become a WoW code.
check("bold", MD.Inline("**big**") == "|cffffffffbig|r", MD.Inline("**big**"))
check("inline code", MD.Inline("`x`") == "|cff9fd3c7x|r", MD.Inline("`x`"))
check("code is not reformatted", MD.Inline("`**x**`") == "|cff9fd3c7**x**|r", MD.Inline("`**x**`"))
check("a link shows its text", MD.Inline("[site](http://a.b/c)") == "|cff70b7ffsite|r", MD.Inline("[site](http://a.b/c)"))
check("a lone star stays a star", MD.Inline("2 * 3 * 4") == "2 * 3 * 4", MD.Inline("2 * 3 * 4"))
check("thread pipes stay harmless", MD.Inline("|cffff0000red|r |Hitem:1|h") == "||cffff0000red||r ||Hitem:1||h", MD.Inline("|cffff0000red|r |Hitem:1|h"))
check("pipes in code stay harmless", MD.Inline("`|Hitem:1|h`"):find("||Hitem:1||h", 1, true), MD.Inline("`|Hitem:1|h`"))
check("plain strips the marks for chat", MD.Plain("# T\n**b** `c` [d](e)\n\n| a | b |\n|---|---|\n| 1 | 2 |") == "T\nb c d\na - b\n1 - 2", MD.Plain("# T\n**b** `c` [d](e)\n\n| a | b |\n|---|---|\n| 1 | 2 |"))

-- Drawing it.
local mdStamp = os.time() + 30000
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = mdStamp, threads = { { id = THREAD, p = "Shop", t = "Formatted", s = "done", u = time(), m = { { "a",
  "## Heading\n\nA **bold** word\n\n- item one\n\n```\ncode line\n```\n\n> a quote\n\n---\n\n| Col A | Col B |\n| --- | --- |\n| cell 1 | cell 2 |", "d", 1 } } } } })
PromptPeonDB.selected = THREAD
ns:RefreshAndRender()
local function lineWith(words)
  for _, line in ipairs(ns.UI.lines) do
    if line.shown and tostring(line.text):find(words, 1, true) then return line end
  end
end
check("a heading is drawn", lineWith("Heading") and not lineWith("## Heading"))
check("bold is drawn without its stars", lineWith("|cffffffffbold|r") and not lineWith("**"))
check("a bullet is drawn", lineWith("\226\128\162") and lineWith("item one"))
check("code is drawn", lineWith("code line") and not lineWith("```"))
check("a quote is drawn without its mark", lineWith("a quote") and not lineWith("> a quote"))
check("table cells are separate blocks", lineWith("Col B") and lineWith("cell 2") and not lineWith("| Col A"))
local visibleBars = 0
for _, texture in ipairs(ns.UI.bars or {}) do
  if texture.shown then visibleBars = visibleBars + 1 end
end
check("code, quote, rule and table draw their shapes", visibleBars >= 4, visibleBars)
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = mdStamp + 1, threads = { { id = THREAD, p = "Shop", t = "Plain", s = "done", u = time(), m = { { "a", "just words", "d", 1 } } } } })
ns:RefreshAndRender()
visibleBars = 0
for _, texture in ipairs(ns.UI.bars or {}) do
  if texture.shown then visibleBars = visibleBars + 1 end
end
check("old shapes do not linger", visibleBars == 0, visibleBars)
check("code uses its own font", PromptPeonCode.path:find("IBMPlexMono", 1, true), PromptPeonCode.path)
local longTable = "| a | b |\n|---|---|\n| " .. string.rep("wide ", 200) .. " | " .. string.rep("wider ", 200) .. " |"
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = mdStamp + 2, threads = { { id = THREAD, p = "Shop", t = "Wide", s = "done", u = time(), m = { { "a", longTable, "d", 1 } } } } })
ns:RefreshAndRender()
check("a table wider than the window still fits", (function()
  for _, line in ipairs(ns.UI.lines) do
    if line.shown and line.width > ns.UI.detailScroll:GetWidth() then return false end
  end
  return true
end)())
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = mdStamp + 3 })
ns:RefreshAndRender()

-- Pictures in a thread.
local picStamp = os.time() + 40000
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = picStamp, threads = { { id = THREAD, p = "Shop", t = "Pics", s = "done", u = time(), m = {
  { "s", "Read", "d", 1 },
  { "i", "shot.png", "d", 1, 7, 768, 432, "" },
  { "i", "photo.jpg", "d", 2, 0, 0, 0, "Only PNG pictures can be previewed for now." },
  { "i", "later.png", "d", 3, 0, 0, 0, "Loading preview..." },
  { "a", "Here it is", "d", 4 },
} } } })
PromptPeonDB.selected = THREAD
ns:RefreshAndRender()
local firstPic = ns.UI.pictures and ns.UI.pictures[1]
check("a picture is drawn", firstPic and firstPic.shown and firstPic.path:find("previews\\p07", 1, true), firstPic and firstPic.path)
check("it fits the pane and keeps its shape", firstPic.width <= 420 and math.abs(firstPic.width / firstPic.height - 768 / 432) < 0.01, firstPic.width)
check("a picture shows even with steps collapsed", not lineWith("Read") and firstPic.shown)
check("its name shows under it", lineWith("shot.png"))
check("a picture that can't show says why", lineWith("photo.jpg") and lineWith("Only PNG"))
check("one still loading says so", lineWith("Loading preview"))
firstPic.scripts.OnClick(firstPic)
check("clicking opens it large", PromptPeonPicture and PromptPeonPicture.shown and PromptPeonPicture.tex.width > firstPic.width, PromptPeonPicture and PromptPeonPicture.tex.width)
check("the large one fits the screen", PromptPeonPicture.tex.width <= 1920 * 0.8 + 1 and PromptPeonPicture.tex.height <= 1080 * 0.8 + 1)
PromptPeonPicture.scripts.OnClick(PromptPeonPicture)
check("clicking closes it", not PromptPeonPicture.shown)
check("escape closes it too", (function()
  for _, name in ipairs(UISpecialFrames) do if name == "PromptPeonPicture" then return true end end
end)())
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = picStamp + 1 })
ns:RefreshAndRender()
check("old pictures do not linger", not firstPic.shown)

-- The tracker has room for a hint, not a read.
local UI = ns.UI
check("gist takes the first sentence", UI.Gist("Fixed the bug. Then I ran the tests and it all passed.") == "Fixed the bug.", UI.Gist("Fixed the bug. Then I ran the tests and it all passed."))
check("gist ignores markdown", UI.Gist("## **Done** with `this`\n\nmore") == "Done with this", UI.Gist("## **Done** with `this`\n\nmore"))
check("gist skips a bullet mark", UI.Gist("- first point\n- second") == "first point", UI.Gist("- first point\n- second"))
check("gist cuts at a word", UI.Gist(string.rep("word ", 60)):match("word%.%.%.$") and #UI.Gist(string.rep("word ", 60)) <= 93, UI.Gist(string.rep("word ", 60)))
check("gist never splits a character", UI.Gist(string.rep("é", 200)):match("^[\195\169]+%.%.%.$") and (#UI.Gist(string.rep("é", 200)) - 3) % 2 == 0, UI.Gist(string.rep("é", 200)))
check("gist of nothing is nothing", UI.Gist("") == "" and UI.Gist(nil) == "")
check("todo says how far and what now", UI.TodoSummary("[x] One\n[>] Second step\n[ ] Third") == "1/3  Second step", UI.TodoSummary("[x] One\n[>] Second step\n[ ] Third"))
check("todo with nothing running names the next", UI.TodoSummary("[x] One\n[ ] Two") == "1/2  Two", UI.TodoSummary("[x] One\n[ ] Two"))
check("a finished todo says so", UI.TodoSummary("[x] One") == "1/1  All done", UI.TodoSummary("[x] One"))
check("no todo, no line", UI.TodoSummary("") == nil)
local trackStamp = os.time() + 50000
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = trackStamp, threads = {
  { id = THREAD, p = "Shop", t = "Busy", s = "running", u = time(), a = "Running a command", m = {
    { "d", "[x] One\n[>] Build it\n[ ] Three", "r", 1 }, { "a", "I found the cause. It takes a long explanation that no tracker should try to show in full.", "d", 2 } } },
  { id = OTHER, p = "other", t = "Quiet", s = "done", u = time() - 600, m = { { "a", "All merged and deployed.\n\n" .. string.rep("Lots of detail. ", 50), "d", 2 } } },
} })
PromptPeonDB.tracked = { [OTHER] = true }
PromptPeonDB.expanded = { [THREAD] = true, [OTHER] = true }
ns:RefreshAndRender()
local busyBody, quietBody
for _, row in ipairs(ns.UI.trackRows) do
  if row.shown and row.thread.id == THREAD then busyBody = row.body.text end
  if row.shown and row.thread.id == OTHER then quietBody = row.body.text end
end
check("working shows the activity", busyBody:find("Running a command", 1, true), busyBody)
check("working shows progress and the step", busyBody:find("1/3  Build it", 1, true), busyBody)
check("working shows the point, not the essay", busyBody:find("I found the cause.", 1, true) and not busyBody:find("long explanation", 1, true), busyBody)
check("finished says when", quietBody:find("Done, 10 min ago", 1, true), quietBody)
check("finished gives the point", quietBody:find("All merged and deployed.", 1, true) and not quietBody:find("Lots of detail", 1, true), quietBody)
PromptPeonDB.tracked, PromptPeonDB.expanded = {}, {}

-- The thread list can be put away.
local leftBefore = ns.UI.listScroll.shown
check("the list starts visible", leftBefore)
ns.UI.listButton.scripts.OnClick(ns.UI.listButton)
check("the button hides the list", not ns.UI.listScroll.shown and PromptPeonDB.listHidden == true)
check("the button shows which way it goes", ns.UI.listButton.text == ">", ns.UI.listButton.text)
ns.UI:ToggleOptions()
stub.timers = {}
check("Options shows it as off", ns.UI.optionsPage.checks.list.box.checked == false)
ns.UI.optionsPage.checks.list.box.checked = true
ns.UI.optionsPage.checks.list.box.scripts.OnClick(ns.UI.optionsPage.checks.list.box)
check("and brings it back", ns.UI.listScroll.shown and not PromptPeonDB.listHidden)
ns.UI:ToggleOptions()
stub.timers = {}
ns.UI:ToggleList()
check("/peon sidebar works", not ns.UI.listScroll.shown)
ns.UI:ToggleList()
stub.timers = {}
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = trackStamp + 1 })
ns:RefreshAndRender()

-- Thread controls: the right-click menu sends commands the bridge understands.
local ctlStamp = os.time() + 60000
local function ctlShow(status)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = THREAD, p = "Shop", t = "Controls", s = status, u = time(), a = status == "running" and "Thinking" or nil, m = { { "a", "words", "d", 1 } } } } })
  PromptPeonDB.selected = THREAD
  ns:RefreshAndRender()
  stub.timers = {}
  for _, row in ipairs(ns.UI.rows) do
    if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
  end
end
ctlShow("running")
listRow.scripts.OnClick(listRow, "RightButton")
check("a running thread offers Abandon, not Turn in", menuItem("Stop") and not menuItem("Turn in"))
menuItem("Stop").scripts.OnClick(menuItem("Stop"))
check("abandoning asks first", stub.popups[#stub.popups].name == "PROMPTPEON_ABANDON" and #PromptPeonDB.pending == 0)
StaticPopupDialogs.PROMPTPEON_ABANDON.OnAccept(nil, THREAD)
local sentCommand = PromptPeonDB.pending[1]
check("confirming sends stop", sentCommand and sentCommand.text == "\1stop" and sentCommand.command == "stop", sentCommand and sentCommand.text)
check("a command does not show as your message", not lineWith("stop"))
drainSend()
stub.now = stub.now + 100
ctlStamp = ctlStamp + 1
stub.slotData = snapshot({ ack = sentCommand.seq, at = ctlStamp, res = { [tostring(sentCommand.seq)] = "sent" }, threads = { { id = THREAD, p = "Shop", t = "Controls", s = "stopped", u = time() } } })
stub.runTimers()
stub.timers = {}
check("a command that worked stays quiet", not PromptPeonDB.results[THREAD] or PromptPeonDB.results[THREAD].text ~= "sent")
ctlShow("done")
listRow.scripts.OnClick(listRow, "RightButton")
check("a finished thread offers Turn in", menuItem("Turn in"))
menuItem("Turn in").scripts.OnClick(menuItem("Turn in"))
check("Turn in asks first and sends nothing yet", stub.popups[#stub.popups].name == "PROMPTPEON_TURN_IN" and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
StaticPopupDialogs.PROMPTPEON_TURN_IN.OnAccept(nil, stub.popups[#stub.popups].data)
sentCommand = PromptPeonDB.pending[1]
check("saying yes sends settle", sentCommand.text == "\1settle", sentCommand.text)
drainSend()
stub.now = stub.now + 100
ctlStamp = ctlStamp + 1
stub.slotData = snapshot({ ack = sentCommand.seq, at = ctlStamp, res = { [tostring(sentCommand.seq)] = "failed: that thread is not on this T3 server" }, threads = { { id = THREAD, p = "Shop", t = "Controls", s = "done", u = time() } } })
stub.runTimers()
stub.timers = {}
check("a failed command reaches the player", PromptPeonDB.results[THREAD].text:find("not on this T3", 1, true) and stub.chat[#stub.chat]:find("not on this T3", 1, true))
PromptPeonDB.results = {}

-- New threads.
ctlShow("done")
press.startThread("Shop", "fix the login page")
sentCommand = PromptPeonDB.pending[1]
check("/peon new names project and prompt", sentCommand.thread == "new-thread" and sentCommand.text == "\1new\napproval-required\nShop\nfix the login page", sentCommand.text)
check("it tells you it will ask first", stub.chat[#stub.chat]:find("It asks before commands", 1, true), stub.chat[#stub.chat])
drainSend()
stub.now = stub.now + 100
ctlStamp = ctlStamp + 1
stub.slotData = snapshot({ ack = sentCommand.seq, at = ctlStamp, res = { [tostring(sentCommand.seq)] = "sent" }, threads = { { id = THREAD, p = "Shop", t = "Controls", s = "done", u = time() } } })
stub.runTimers()
stub.timers = {}
if ns.UI.newThread then ns.UI:StopNewThread() end

-- Agents in the timeline.
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = THREAD, p = "Shop", t = "Agents", s = "running", u = time(), a = "Agent: Scout", m = {
  { "sa", "Scout the code", "r", 3, "" },
  { "sa", "Review it", "d", 4, "## Findings\n\nThree **real** problems." },
} } } })
PromptPeonDB.selected = THREAD
ns:RefreshAndRender()
stub.timers = {}
local agentHead = ns.UI.heads[1]
check("a working subagent shows its state", agentHead.text.text:find("Agent: Scout the code (working)", 1, true), agentHead.text.text)
local doneHead = ns.UI.heads[2]
check("one with nothing to open has no button", not agentHead.fold.shown)
check("a finished one says done and can open", doneHead.text.text:find("Agent: Review it (done)", 1, true) and doneHead.fold.shown and doneHead.fold.texture:find("UI-PlusButton-Up", 1, true), doneHead.text.text)
check("its result starts closed", not lineWith("Findings"))
doneHead.scripts.OnClick(doneHead)
check("clicking shows the result, formatted", lineWith("Findings") and lineWith("|cffffffffreal|r"))
ns.UI.groups = {}

-- The Agents view: every subagent T3 knows about.
local function agentsThread(extra)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  local row = { id = THREAD, p = "Shop", t = "Sent agents", s = "done", u = time(), m = { { "a", "main thread words", "d", 1 } }, agn = 32, ag = {
    { "k1", "Review the bridge", "d", "gpt-6-astra", time() - 120 },
    { "k2", "Scout the code", "r", "codex", time() - 60 },
    { "k3", "Test the login", "f", "", 0 },
  } }
  for key, value in pairs(extra or {}) do row[key] = value end
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { row } })
  stub.runTimers()
  stub.timers = {}
  PromptPeonDB.selected = THREAD
  ns:RefreshAndRender()
  stub.timers = {}
end
agentsThread()
check("the button counts every agent", ns.UI.agents.shown and ns.UI.agents.label == "Agents (32)", ns.UI.agents.label)
check("a thread without changes has no Changes button", not ns.UI.changes.shown)
check("the thread shows until you ask", lineWith("main thread words"))
ns.UI.agents.scripts.OnClick(ns.UI.agents)
sentCommand = PromptPeonDB.pending[1]
check("opening asks the bridge for their words", sentCommand and sentCommand.text == "\1agents", sentCommand and sentCommand.text)
check("the button goes back", ns.UI.agents.label == "Back to thread")
check("the thread's words step aside", not lineWith("main thread words"))
check("each agent shows name and model on the left", ns.UI.heads[1].text.text:find("Review the bridge", 1, true) and ns.UI.heads[1].text.text:find("gpt-6-astra", 1, true), ns.UI.heads[1].text.text)
check("and its state in the right column", ns.UI.heads[1].right.text:find("done", 1, true), ns.UI.heads[1].right.text)
check("a working one says so", ns.UI.heads[2].right.text:find("working", 1, true), ns.UI.heads[2].right.text)
check("a failed one says so", ns.UI.heads[3].right.text:find("failed", 1, true), ns.UI.heads[3].right.text)
check("older ones point to T3", lineWith("29 older agents in T3."))
ns.UI.heads[1].scripts.OnClick(ns.UI.heads[1])
check("opening one before its words arrive says so", lineWith("Asking T3..."))
check("we refresh sooner while we wait", ns.UI:IsLoading(ns:ThreadById(THREAD)))
drainSend()
agentsThread({ ax = { k1 = { "Look **hard**.", "## Found\n\nTwo bugs." }, k2 = { "Scout it.", "" } } })
check("the words stay after they stop being sent", ns.loaded[THREAD].ax.k1 ~= nil)
agentsThread()
check("what it was asked shows", lineWith("What it was asked") and lineWith("|cffffffffhard|r"))
check("what it came back with shows", lineWith("What it came back with") and lineWith("Two bugs."))
ns.UI.heads[2].scripts.OnClick(ns.UI.heads[2])
check("one still working says so", lineWith("Still working."))
ns.UI.heads[3].scripts.OnClick(ns.UI.heads[3])
check("one left out for size points to T3", lineWith("Too long to show here."))
check("we stop hurrying once it came", not ns.UI:IsLoading(ns:ThreadById(THREAD)))
ns.UI.agents.scripts.OnClick(ns.UI.agents)
check("back shows the thread again", lineWith("main thread words"))
ns.UI.groups = {}

-- The Changes view.
local PATCH = "@@ -1,2 +1,2 @@\n keep\n-old |cffff0000line\n+new line"
local function changedThread(extra)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  local row = { id = THREAD, p = "Shop", t = "Changed", s = "done", u = time(), ch = { { "x.lua", "modified", 1, 1 } }, m = { { "a", "words from the changed thread", "d", 2 } } }
  for key, value in pairs(extra or {}) do row[key] = value end
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { row } })
  stub.runTimers()
  stub.timers = {}
  PromptPeonDB.selected = THREAD
  ns:RefreshAndRender()
  stub.timers = {}
end
ns.loaded = {}
changedThread()
check("the Changes button shows", ns.UI.changes.shown and ns.UI.changes.label == "Changes", ns.UI.changes.label)
ns.UI.changes.scripts.OnClick(ns.UI.changes)
sentCommand = PromptPeonDB.pending[1]
check("opening asks the bridge for the diff", sentCommand and sentCommand.text == "\1diff", sentCommand and sentCommand.text)
check("it lists what it knows straight away", ns.UI.heads[1].text.text:find("x.lua", 1, true) and lineWith("Asking T3..."))
check("those can't be opened yet", not ns.UI.heads[1].fold.shown)
check("the button goes back", ns.UI.changes.label == "Back to thread")
drainSend()
changedThread({ dn = "", df = {
  { "src/ui/x.lua", 1, 1, PATCH, true },
  { "huge.json", 9000, 2, "", false },
  { "logo.png", 0, 0, "", true },
} })
local summaryHead, fileHead, hugeHead, logoHead = ns.UI.heads[1], ns.UI.heads[2], ns.UI.heads[3], ns.UI.heads[4]
check("a summary leads, with totals in the same column", summaryHead.text.text:find("3 files changed", 1, true) and summaryHead.right.text:find("+9001", 1, true) and summaryHead.right.text:find("-3", 1, true), summaryHead.text.text)
check("the summary has nothing to open", not summaryHead.fold.shown)
check("files arrive closed", fileHead.fold.texture:find("UI-PlusButton-Up", 1, true) and not lineWith("new line"))
check("the name comes before the folder", fileHead.text.text:find("x.lua", 1, true) < fileHead.text.text:find("src/ui", 1, true), fileHead.text.text)
check("counts sit in the right column, not after the name", hugeHead.right.text:find("+9000", 1, true) and hugeHead.right.text:find("-2", 1, true) and not hugeHead.text.text:find("9000", 1, true), hugeHead.right.text)
fileHead.scripts.OnClick(fileHead)
check("an open file shows WoW's minus", ns.UI.heads[2].fold.texture:find("UI-MinusButton-Up", 1, true))
check("the code uses the code font", (function()
  for _, line in ipairs(ns.UI.lines) do
    if line.shown and line.text:find("new line", 1, true) then return line.fontObject == "PromptPeonCode" end
  end
end)())
check("added lines show as text", lineWith("+new line") and lineWith("+new line").text == "+new line", lineWith("+new line") and lineWith("+new line").text)
check("removed lines too, and text in them stays harmless", lineWith("-old ||cffff0000line"))
check("line numbers are their own column", not lineWith("    2 ") and lineWith("    1"))
check("hunks stay as they are", lineWith("@@ -1,2 +1,2 @@"))
hugeHead.scripts.OnClick(hugeHead)
sentCommand = PromptPeonDB.pending[1]
check("opening a big file asks for its first page", sentCommand and sentCommand.text == "\1file\nhuge.json\n1", sentCommand and sentCommand.text)
check("and says so meanwhile", lineWith("Asking T3..."))
check("we refresh sooner while we wait for it", ns.UI:IsLoading(ns:ThreadById(THREAD)))
drainSend()
local function bigFileThread(fp)
  changedThread({ dn = "", fp = fp, df = {
    { "src/ui/x.lua", 1, 1, PATCH, true },
    { "huge.json", 9000, 2, "", false },
    { "logo.png", 0, 0, "", true },
  } })
end
bigFileThread({ "huge.json", 1, 3, 10, 20, " first page line" })
check("the page is drawn", lineWith("first page line"))
check("with the right line number", lineWith("   20"))
check("it says which page", lineWith("Page 1 of 3"))
check("we stop hurrying once it came", not ns.UI:IsLoading(ns:ThreadById(THREAD)))
local function pagerHead(words)
  for _, head in ipairs(ns.UI.heads) do
    if head.shown and head.text.text:find(words, 1, true) then return head end
  end
end
check("the first page has no way back", pagerHead("Next page") and not pagerHead("Previous page"))
pagerHead("Next page").scripts.OnClick(pagerHead("Next page"))
sentCommand = PromptPeonDB.pending[1]
check("next asks for the next page", sentCommand and sentCommand.text == "\1file\nhuge.json\n2", sentCommand and sentCommand.text)
drainSend()
bigFileThread({ "huge.json", 2, 3, 500, 600, "+second page line" })
check("the next page replaces it", lineWith("second page line") and not lineWith("first page line"))
check("the middle page goes both ways", pagerHead("Next page") and pagerHead("Previous page"))
pagerHead("Previous page").scripts.OnClick(pagerHead("Previous page"))
check("a page we already have needs no asking", #PromptPeonDB.pending == 0 and lineWith("first page line"))
stub.runTimers()
stub.timers = {}
check("a big file never says too big", not lineWith("Too big"))
for _, head in ipairs(ns.UI.heads) do
  if head.shown and head.text.text:find("logo.png", 1, true) then head.scripts.OnClick(head) break end
end
check("a file with nothing to draw says so", lineWith("Nothing to show for this file"))
local kinds = {}
for _, block in ipairs(ns.UI.PatchBlocks("@@ -10,3 +20,3 @@ name\n same\n-gone\n-gone too\n+came\n same\n\\ No newline at end of file")) do kinds[#kinds + 1] = block.kind end
check("each run of a kind is its own block", table.concat(kinds) == "@ -+ ", table.concat(kinds))
local numbered = ns.UI.PatchBlocks("@@ -10,2 +20,2 @@\n same\n-gone\n+came")
check("numbers follow the hunk header", numbered[2].numbers == "   20" and numbered[3].numbers == "   11" and numbered[4].numbers == "   21", numbered[3].numbers)
local function rowsOf(text)
  local rows = {}
  for row in (text .. "\n"):gmatch("(.-)\n") do rows[#rows + 1] = row end
  return rows
end
local wrapped = ns.UI.PatchBlocks("+" .. string.rep("word ", 30), 1, 1, 40)[1]
local textRows, numberRows = rowsOf(wrapped.text), rowsOf(wrapped.numbers)
check("a long line wraps by itself", #textRows > 2, #textRows)
check("the columns have the same rows, so they stay lined up", #textRows == #numberRows, #numberRows)
check("only the first row gets a number", numberRows[1] == "    1" and numberRows[2] == " ", numberRows[2])
check("no row is too long", #textRows[1] <= 40 and #textRows[2] <= 40, #textRows[2])
check("later rows hang past the sign", textRows[2]:sub(1, 2) == "  " and textRows[2]:sub(3, 3) ~= " ", textRows[2])
local urlRows = rowsOf(ns.UI.PatchBlocks("+https://example.com/" .. string.rep("x", 100), 1, 1, 40)[1].text)
check("a long URL with no spaces still wraps", #urlRows >= 3 and #urlRows[1] == 40, #urlRows[1])
local accents = rowsOf(ns.UI.PatchBlocks("+" .. string.rep("é", 60), 1, 1, 20)[1].text)
check("wrapping counts characters and never cuts one in half", #accents >= 3 and accents[1] == "+" .. string.rep("é", 19), accents[1])
check("a blank line still takes a row", rowsOf(ns.UI.PatchBlocks(" a\n\n b", 1, 1, 40)[1].text)[2] == " ")
check("a page starts counting where the last one stopped", ns.UI.PatchBlocks(" same\n+new", 50, 60)[1].numbers == "   60" and ns.UI.PatchBlocks(" same\n+new", 50, 60)[2].numbers == "   61")
check("the no-newline note gets no number", select(2, ns.UI.PatchBlocks(" same\n\\ No newline at end of file")[1].numbers:gsub("%d+", "")) == 1)
check("long patches are split", #ns.UI.PatchBlocks(string.rep("+added line of code\n", 400)) > 2)
ns.UI.changes.scripts.OnClick(ns.UI.changes)
check("after that the button counts files", ns.UI.changes.label == "Changes (3)", ns.UI.changes.label)
check("back shows the thread again", lineWith("words from the changed thread"))
ns.UI.changes.scripts.OnClick(ns.UI.changes)
check("opening again asks again, for the latest", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text == "\1diff")
drainSend()
stub.now = stub.now + 40
check("we stop waiting after a while", not ns.UI:IsLoading(ns:ThreadById(THREAD)))
ns.UI:Render()
check("and say T3 did not send it", lineWith("T3 did not send this."))
ns.UI.views = {}
ns.UI.groups = {}
ns.loaded = {}
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- The peon talks.
local WORK, COMPLETE, NEEDS, MORE = 6197, 6199, 6196, 6288
local function plays(kit)
  local count = 0
  for _, sound in ipairs(stub.played) do if sound == kit then count = count + 1 end end
  return count
end
local function peonSnapshot(status, queued, extra)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.played = {}
  local row = { id = THREAD, p = "Shop", t = "Peon", s = status, u = time(), qc = queued }
  for key, value in pairs(extra or {}) do row[key] = value end
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { row } })
  ns:RefreshAndRender()
  stub.timers = {}
end
peonSnapshot("done")
peonSnapshot("running")
check("an agent starting says work, work", plays(WORK) == 1, plays(WORK))
peonSnapshot("running")
check("and only when it starts", plays(WORK) == 0)
peonSnapshot("done")
check("finishing says work complete", plays(COMPLETE) == 1 and plays(WORK) == 0, plays(COMPLETE))
peonSnapshot("needs")
check("needing you asks if something needs doing", plays(NEEDS) == 1, plays(NEEDS))
peonSnapshot("running", 2)
check("working with messages waiting is plain work", plays(WORK) == 1 and plays(MORE) == 0)
peonSnapshot("running", 1)
check("taking the next one says more work", plays(MORE) == 1 and plays(WORK) == 0, plays(MORE))
peonSnapshot("running", 1)
check("once", plays(MORE) == 0)
peonSnapshot("done", 1)
check("a pause before the next one still says complete", plays(COMPLETE) == 1)
peonSnapshot("running", 0)
check("then picking it up says more work, not work", plays(MORE) == 1 and plays(WORK) == 0, plays(WORK))
peonSnapshot("error")
check("failing never says work complete", plays(COMPLETE) == 0)
peonSnapshot("running")
peonSnapshot("stopped")
check("stopping never says work complete", plays(COMPLETE) == 0)
peonSnapshot("done")
stub.played = {}
ns.voiceAt = nil
ns:QueueReply(THREAD, "do the thing")
check("sending a message plays it right away", plays(WORK) == 1, plays(WORK))
ns:PeonSays("work")
check("not twice in a row", plays(WORK) == 1, plays(WORK))
drainSend()
stub.now = stub.now + 100
stub.played = {}
ns:QueueCommand(THREAD, "settle")
check("a command is not work", plays(WORK) == 0, plays(WORK))
drainSend()
stub.now = stub.now + 100
ns:QueueCommand("new-thread", "new", "Shop\nwork")
check("a new thread is", plays(WORK) == 1, plays(WORK))
drainSend()
peonSnapshot("done")
PromptPeonDB.hiddenThreads[THREAD] = true
peonSnapshot("running")
peonSnapshot("done")
check("hidden threads stay quiet", plays(COMPLETE) == 0 and plays(WORK) == 0)
PromptPeonDB.hiddenThreads[THREAD] = nil
PromptPeonDB.peonQuiet = true
peonSnapshot("running")
peonSnapshot("done")
check("Options can quiet the peon", plays(WORK) == 0 and plays(COMPLETE) == 0)
PromptPeonDB.peonQuiet = nil
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- Code uses a real monospace font, and survives without it.
check("code is monospace", PromptPeonCode.path:find("IBMPlexMono-Regular.ttf", 1, true), PromptPeonCode.path)
stub.missingFonts = { ["Interface\\AddOns\\PromptPeon\\IBMPlexMono-Regular.ttf"] = true }
ns.UI:ApplyFonts()
check("a missing font falls back, so text never vanishes", PromptPeonCode.path == "Fonts\\ARIALN.TTF", PromptPeonCode.path)
stub.missingFonts = nil
ns.UI:ApplyFonts()

-- Tracked things stay, like quests, and stay in the party when it is on.
local STAY = "aaaaaaaa-0000-0000-0000-000000000001"
local function stayRow(status, extra)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  local threads = { { id = STAY, p = "Shop", t = "Stays", s = status, u = time() } }
  for _, row in ipairs(extra or {}) do threads[#threads + 1] = row end
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads })
  ns:RefreshAndRender()
  stub.timers = {}
end
local partyWasOn = PromptPeonDB.partyOn
PromptPeonDB.partyOn = true
PromptPeonDB.tracked = {}
stayRow("done")
check("a thread nobody tracked stays out of the party", not ns.UI.party.shown)
stayRow("running")
check("working puts it in the party", ns.UI.party.shown and ns.UI.partyRows[1].name.text == "Stays")
check("at full light", ns.UI.partyRows[1].debuff.texture:find("Interface\\Icons", 1, true), ns.UI.partyRows[1].debuff.texture)
stayRow("done")
check("finishing keeps it in the party", ns.UI.party.shown and ns.UI.partyRows[1].name.text == "Stays")
check("with a ready check instead of a task icon", ns.UI.partyRows[1].debuff.texture:find("ReadyCheck-Ready", 1, true), ns.UI.partyRows[1].debuff.texture)
stayRow("error")
check("a failed one gets the red cross", ns.UI.partyRows[1].debuff.texture:find("UI-GroupLoot-Pass-Up", 1, true))
stayRow("done", { { id = "bbbbbbbb-0000-0000-0000-000000000002", p = "Shop", t = "Busy", s = "running", u = time(), a = "Thinking" } })
check("a busy agent goes first, ahead of a finished one", ns.UI.partyRows[1].name.text == "Busy" and ns.UI.partyRows[2].name.text == "Stays", ns.UI.partyRows[1].name.text)
ns:ToggleTracked(ns:ThreadById(STAY))
stayRow("done")
check("taking it off the list takes it out of the party", not ns.UI.party.shown or ns.UI.partyRows[1].name.text ~= "Stays")
stayRow("running")
check("and it stays off when it works again", PromptPeonDB.tracked[STAY] == false)
PromptPeonDB.partyOn = partyWasOn
PromptPeonDB.tracked = {}
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- Nobody gets surprised by a reload.
check("time for a sentence", ns.AboutTime(30) == "under a minute" and ns.AboutTime(60) == "about 1 minute" and ns.AboutTime(610) == "about 11 minutes" and ns.AboutTime(3600) == "about 1 hour" and ns.AboutTime(9000) == "about 3 hours", ns.AboutTime(610))
check("time for a small space", ns.ShortTime(30) == "<1m" and ns.ShortTime(610) == "~11m" and ns.ShortTime(7200) == "~2h", ns.ShortTime(610))
local savedSlot, savedPace = ns.nextSlot, ns.refreshPace
local function reloadState(left, pace)
  ns.nextSlot = ns.SLOT_COUNT - left + 1
  ns.refreshPace = pace
  ns.UI:Render()
end
reloadState(300, 20)
check("plenty left shows a quiet estimate", ns.UI.reloadHint.text.text == "Reload in ~2h", ns.UI.reloadHint.text.text)
check("no button yet", not ns.UI.reload.shown)
reloadState(60, 20)
check("twenty minutes left offers the button", ns.UI.reload.shown and ns.UI.reloadHint.text.text == "Reload in ~20m", ns.UI.reloadHint.text.text)
check("without a warning strip, since nothing is wrong yet", not (ns:Problem() or ""):find("Reload", 1, true), ns:Problem())
ns.warnedSoon, ns.warnedStopped = nil, nil
local chatBefore = #stub.chat
reloadState(60, 20)
ns:WarnAboutReload()
check("that far out chat stays quiet", #stub.chat == chatBefore)
reloadState(25, 20)
ns:WarnAboutReload()
check("close to the end chat says it plainly", #stub.chat == chatBefore + 1 and stub.chat[#stub.chat]:find("about 9 minutes of live updates left", 1, true) and stub.chat[#stub.chat]:find("Press Reload UI", 1, true), stub.chat[#stub.chat])
ns:WarnAboutReload()
check("once", #stub.chat == chatBefore + 1)
reloadState(0, 20)
ns:WarnAboutReload()
check("running out says so once more", #stub.chat == chatBefore + 2 and stub.chat[#stub.chat]:find("stopped", 1, true), stub.chat[#stub.chat])
check("and the footer says reload now", ns.UI.reloadHint.text.text == "Reload now", ns.UI.reloadHint.text.text)
ns.Chat:Status()
local statusWords = table.concat(stub.chat, "\n", math.max(#stub.chat - 1, 1))
check("/peon status uses plain words", statusWords:find("0 live updates left before you need a reload", 1, true), statusWords)
check("and shows how long sending takes", statusWords:find("Sending: the last step took", 1, true), statusWords)
ns.nextSlot, ns.refreshPace = savedSlot, savedPace
ns.warnedSoon, ns.warnedStopped = nil, nil
local paceBefore = ns.refreshPace
ns.refreshPace = nil
stub.now = stub.now + 100
ns.lastRefresh = stub.now - 40
ns:Refresh()
check("the estimate follows how fast updates really go", ns.refreshPace == 40, ns.refreshPace)
stub.now = stub.now + 20
ns:Refresh()
check("and changes smoothly", ns.refreshPace == 38, ns.refreshPace)
ns.refreshPace = paceBefore
ns.UI:Render()

local reloadTipLines = {}
local addLineWas = GameTooltip.AddLine
GameTooltip.AddLine = function(_, text) reloadTipLines[#reloadTipLines + 1] = tostring(text) end
ns.UI.reloadHint.scripts.OnEnter(ns.UI.reloadHint)
GameTooltip.AddLine = addLineWas
local reloadTip = table.concat(reloadTipLines, " ")
check("hovering the reload hint explains it in plain words", reloadTip:find("whole UI", 1, true) and reloadTip:find("never happens by itself", 1, true), reloadTip)

-- Scrolling back through older messages.
local OLD = "cccccccc-0000-0000-0000-000000000003"
local function oldThread(extra)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  local row = { id = OLD, p = "Shop", t = "Long story", s = "done", u = time(), hm = true, m = { { "a", "the newest words", "d", 500 } } }
  for key, value in pairs(extra or {}) do row[key] = value end
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { row } })
  PromptPeonDB.selected = OLD
  stub.runTimers()
  stub.timers = {}
  ns:RefreshAndRender()
  stub.timers = {}
end
local function olderHead()
  for _, head in ipairs(ns.UI.heads) do
    if head.shown and head.text.text:find("Show older messages", 1, true) then return head end
  end
end
oldThread()
check("a long thread offers older messages", olderHead() ~= nil)
olderHead().scripts.OnClick(olderHead())
sentCommand = PromptPeonDB.pending[1]
check("clicking asks for what comes before the oldest row", sentCommand and sentCommand.text == "\1older\n500", sentCommand and sentCommand.text)
check("it says so meanwhile", olderHead().right.text:find("Asking T3...", 1, true), olderHead().right.text)
olderHead().scripts.OnClick(olderHead())
check("a second click asks nothing twice", #PromptPeonDB.pending == 1)
drainSend()
oldThread({ ob = { { "a", "words from before", "d", 400 } }, om = true, oc = 500 })
check("older messages appear", lineWith("words from before") and lineWith("the newest words"))
check("and the row stays for more", olderHead() ~= nil)
oldThread({ ob = { { "a", "words from before", "d", 400 } }, om = true, oc = 500 })
check("the same answer arriving again adds nothing", #ns.loaded[OLD].older == 1, #ns.loaded[OLD].older)
oldThread()
check("they stay after they stop being sent", lineWith("words from before"))
olderHead().scripts.OnClick(olderHead())
check("the next ask starts from the oldest we have", PromptPeonDB.pending[1].text == "\1older\n400", PromptPeonDB.pending[1].text)
drainSend()
oldThread({ ob = { { "u", "the very first ask", "d", 100 } }, om = false, oc = 400 })
check("oldest first", ns.loaded[OLD].older[1][2] == "the very first ask" and ns.loaded[OLD].older[2][2] == "words from before")
check("at the start the row goes away and says so", not olderHead() and lineWith("This is the start of the thread."))
oldThread({ hm = false })
ns.loaded[OLD] = nil
oldThread({ hm = false })
check("a short thread has no such row", not olderHead() and not lineWith("start of the thread"))
ns.loaded = {}
PromptPeonDB.selected = THREAD
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- These tests refresh more often than one UI session is allowed to.
ns.SLOT_COUNT = 100000
ns.liveProblem = nil

-- The peon, annoyed.
local Game = ns.Game
stub.played = {}
Game.pokes, Game.lastPoke, Game.nextLine = nil, nil, nil
Game:Poke()
check("a click gets a normal answer", stub.played[1] == 6193, stub.played[1])
Game:Poke()
Game:Poke()
check("a few clicks still do", stub.played[2] == 6194 and stub.played[3] == 6195, stub.played[3])
Game:Poke()
check("then it gets annoyed", stub.played[4] == 6189 or stub.played[4] == 6190 or stub.played[4] == 6191 or stub.played[4] == 6291, stub.played[4])
stub.now = stub.now + 60
stub.played = {}
Game:Poke()
check("and calms down again", stub.played[1] == 6193 or stub.played[1] == 6194 or stub.played[1] == 6195, stub.played[1])
PromptPeonDB.peonQuiet = true
stub.played = {}
Game:Poke()
check("quiet means quiet", #stub.played == 0)
PromptPeonDB.peonQuiet = nil

-- Levels mean turns finished, on a rising curve.
check("a new thread is level 1", Game.LevelOf({ tn = 0 }) == 1 and Game.LevelOf({}) == 1)
check("level comes from turns", Game.LevelOf({ tn = 4 }) == 2 and Game.LevelOf({ tn = 8 }) == 2 and Game.LevelOf({ tn = 9 }) == 3 and Game.LevelOf({ tn = 100 }) == 10)
check("the tooltip says what level means", Game.LevelWords({ tn = 10 }) == "Level 3 (10/16 turns)", Game.LevelWords({ tn = 10 }))
check("from the very start", Game.LevelWords({}) == "Level 1 (0/4 turns)", Game.LevelWords({}))
local DINGER = "dddddddd-0000-0000-0000-000000000004"
local function dingThread(turns)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.played = {}
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = DINGER, p = "Shop", t = "Dinger", s = "done", u = time(), tn = turns } } })
  ns:RefreshAndRender()
  stub.timers = {}
end
local function dinged()
  for _, sound in ipairs(stub.played) do if sound == 888 then return true end end
  return false
end
dingThread(10)
check("seeing a thread for the first time is no ding", not dinged() and PromptPeonDB.levels[DINGER] == 3)
dingThread(15)
check("a turn inside the level is no ding", not dinged())
dingThread(16)
check("reaching the next level dings", dinged())
check("and says so", stub.chat[#stub.chat]:find("Dinger reached level 4!", 1, true), stub.chat[#stub.chat])
dingThread(16)
check("once", not dinged())

-- Health and death.
check("nothing failed is full health", Game.Health({ s = "running", m = { { "u", "go", "d", 1 }, { "s", "ran", "d", 2 } } }) == 1)
check("each failed step this turn hurts", math.abs(Game.Health({ s = "running", m = { { "u", "go", "d", 1 }, { "s", "a", "f", 2 }, { "s", "b", "f", 3 } } }) - 0.7) < 0.001)
check("last turn's failures are forgiven", Game.Health({ s = "running", m = { { "s", "a", "f", 1 }, { "u", "again", "d", 2 }, { "s", "b", "d", 3 } } }) == 1)
check("a queued message doesn't count as a new turn", math.abs(Game.Health({ s = "running", m = { { "u", "go", "d", 1 }, { "s", "a", "f", 2 }, { "u", "later", "q", 0 } } }) - 0.85) < 0.001)
check("many failures leave it barely alive", Game.Health({ s = "running", m = { { "s", "a", "f", 1 }, { "s", "a", "f", 2 }, { "s", "a", "f", 3 }, { "s", "a", "f", 4 }, { "s", "a", "f", 5 }, { "s", "a", "f", 6 }, { "s", "a", "f", 7 } } }) == 0.1)
check("a failed run is dead", Game.Health({ s = "error" }) == 0)
check("it says so", Game.HealthWords({ s = "error" }) == "Dead" and Game.HealthWords({ s = "done", m = { { "s", "a", "f", 1 } } }) == "Health: 1 failed step" and Game.HealthWords({ s = "done", m = { { "s", "a", "f", 1 }, { "s", "b", "f", 2 }, { "s", "c", "f", 3 } } }) == "Your gear is damaged: 3 failed steps" and Game.HealthWords({ s = "done" }) == "Health full")
local DEAD = "eeeeeeee-0000-0000-0000-000000000005"
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = DEAD, p = "Shop", t = "Dead one", s = "error", u = time(), m = { { "a", "it broke", "d", 5 } } } } })
PromptPeonDB.selected = DEAD
ns:RefreshAndRender()
stub.timers = {}
local function headWith(words)
  for _, head in ipairs(ns.UI.heads) do
    if head.shown and head.text.text:find(words, 1, true) then return head end
  end
end
check("a dead thread says so", lineWith("This agent died."))
check("and offers both ways out", headWith("Resurrect") and headWith("Release Spirit"))
headWith("Resurrect").scripts.OnClick(headWith("Resurrect"))
check("Resurrect shows you the words first", stub.popups[#stub.popups].name == "PROMPTPEON_RESURRECT" and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
StaticPopupDialogs.PROMPTPEON_RESURRECT.OnAccept(nil, stub.popups[#stub.popups].data)
sentCommand = PromptPeonDB.pending[1]
check("resurrecting tells it to try again", sentCommand and sentCommand.text:find("try again a different way", 1, true) and not sentCommand.command, sentCommand and sentCommand.text)
drainSend()
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = DEAD, p = "Shop", t = "Dead one", s = "error", u = time(), m = { { "a", "it broke", "d", 5 } } } } })
ns:RefreshAndRender()
stub.timers = {}
headWith("Release Spirit").scripts.OnClick(headWith("Release Spirit"))
check("Release Spirit asks first too", stub.popups[#stub.popups].name == "PROMPTPEON_RELEASE" and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
StaticPopupDialogs.PROMPTPEON_RELEASE.OnAccept(nil, stub.popups[#stub.popups].data)
check("releasing turns it in", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text == "\1settle", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text)
drainSend()
PromptPeonDB.selected = THREAD
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- What happened while you were in that dungeon.
local AWAY1, AWAY2, AWAY3, AWAY4 = "11111111-0000-0000-0000-000000000001", "22222222-0000-0000-0000-000000000002", "33333333-0000-0000-0000-000000000003", "44444444-0000-0000-0000-000000000004"
local function awayShow(threads)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 30
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads })
  ns:RefreshAndRender()
  stub.timers = {}
end
PromptPeonDB.away, Game.report, Game.reportWhenFresh, ns.UI.showReport = nil, nil, nil, nil
local before = {
  { id = AWAY1, p = "Shop", t = "Finisher", s = "running", u = time(), tn = 3, m = { { "a", "old words", "d", 10 } } },
  { id = AWAY2, p = "Shop", t = "Quiet", s = "done", u = time(), tn = 2, m = { { "a", "nothing new", "d", 20 } } },
  { id = AWAY3, p = "Shop", t = "Blocked", s = "running", u = time(), m = { { "a", "working", "d", 30 } } },
}
awayShow(before)
PromptPeonDB.seen = {}
Game.seeded = nil
awayShow(before)
stub.instance = "The Deadmines"
stub.fire("PLAYER_ENTERING_WORLD")
check("going into a dungeon notes where things stand", PromptPeonDB.away and PromptPeonDB.away.kind == "dungeon" and PromptPeonDB.away.place == "The Deadmines" and PromptPeonDB.away.base[AWAY1].o == 10)
PromptPeonDB.away.since = time() - 2300
local chatBeforeAway = #stub.chat
stub.instance = nil
local after = {
  { id = AWAY1, p = "Shop", t = "Finisher", s = "done", u = time(), tn = 5, lc = { 3, 40, 2, 15 }, m = { { "a", "old words", "d", 10 }, { "a", "It works now, and the tests pass.", "d", 15 } } },
  { id = AWAY2, p = "Shop", t = "Quiet", s = "done", u = time(), tn = 2, m = { { "a", "nothing new", "d", 20 } } },
  { id = AWAY3, p = "Shop", t = "Blocked", s = "needs", u = time(), m = { { "a", "working", "d", 30 } } },
  { id = AWAY4, p = "Shop", t = "Brand new", s = "running", u = time(), m = {} },
}
stub.fire("PLAYER_ENTERING_WORLD")
stub.timers = {}
check("coming out waits for news from after you came back", PromptPeonDB.away == nil or Game.reportWhenFresh ~= nil)
awayShow(after)
local report = Game.report
check("then there is a report", report ~= nil and report.title == "While you were in The Deadmines", report and report.title)
check("what needs you comes first", report.entries[1].id == AWAY3 and report.entries[2].id == AWAY1, report.entries[1].title)
check("a thread where nothing moved is left out", #report.entries == 3, #report.entries)
check("it adds up", report.counts.done == 1 and report.counts.needs == 1 and report.counts.running == 1 and report.messages == 1 and report.turns == 2 and report.files == 3 and report.added == 40, report.turns)
check("it knows how long you were gone", report.minutes >= 38 and report.minutes <= 40, report.minutes)
check("it reads like a person wrote it", Game.ReportHeadline(report) == "1 finished, 1 needs you, 1 still working.", Game.ReportHeadline(report))
local reportLine
for index = chatBeforeAway + 1, #stub.chat do
  if stub.chat[index]:find("While you were in The Deadmines: 1 finished", 1, true) then reportLine = stub.chat[index] end
end
check("chat links to it", reportLine and reportLine:find("|Haddon:peon:report|h", 1, true), reportLine)
ns.Chat:OnLink("addon:peon:report", "LeftButton")
stub.timers = {}
check("the link opens it", ns.UI.showReport == true and ns.UI.title.text == "While you were in The Deadmines", ns.UI.title.text)
check("with the headline", lineWith("1 finished, 1 needs you, 1 still working."))
check("and what each one said", lineWith("It works now, and the tests pass."))
check("and what it changed", lineWith("3 files changed"))
check("the view buttons step aside", not ns.UI.changes.shown)
Game:OpenReport()
stub.timers = {}
check("/peon away opens it too", ns.UI.showReport == true)
local reportHead
for _, head in ipairs(ns.UI.heads) do
  if head.shown and head.text.text:find("Finisher", 1, true) then reportHead = head end
end
check("a thread in the report says how much it said", reportHead.right.text:find("1 message", 1, true), reportHead.right.text)
reportHead.scripts.OnClick(reportHead)
check("clicking a thread opens it", ns.UI.showReport == nil and PromptPeonDB.selected == AWAY1 and ns.UI.title.text == "Finisher", ns.UI.title.text)

-- Short absences are nobody's business.
awayShow(after)
Game.report = nil
stub.instance = "Ragefire Chasm"
stub.fire("PLAYER_ENTERING_WORLD")
stub.instance = nil
stub.fire("PLAYER_ENTERING_WORLD")
stub.timers = {}
awayShow(after)
check("a quick dungeon gets no report", Game.report == nil and PromptPeonDB.away == nil)

-- A closed log counts when it has been a while.
PromptPeonDB.away = nil
ns.UI.frame:Hide()
check("closing the log notes where things stand", PromptPeonDB.away and PromptPeonDB.away.kind == "closed")
PromptPeonDB.away.since = time() - 1800
PromptPeonDB.away.base[AWAY2] = { s = "running", o = 1, t = 0, c = 0 }
ns.UI.frame:Show()
stub.timers = {}
check("opening it after a while shows what happened", ns.UI.showReport == true and Game.report and Game.report.title == "While you were out questing", Game.report and Game.report.title)
ns.UI.showReport = nil
ns.UI:Render()

-- Quest marks in the list.
PromptPeonDB.selected = AWAY2
PromptPeonDB.seen = { [AWAY1] = 10, [AWAY2] = 20, [AWAY3] = 30, [AWAY4] = 0 }
ns.UI:Render()
local function listText(id)
  for _, row in ipairs(ns.UI.rows) do
    if row.shown and row.thread and row.thread.id == id then return row.text.text end
  end
end
do
local function listMark(id)
  for _, row in ipairs(ns.UI.rows) do
    if row.shown and row.thread and row.thread.id == id then return row.statusIcon end
  end
end
check("a thread that wants you gets the yellow ?", listMark(AWAY3).texture == "Interface\\GossipFrame\\ActiveQuestIcon", listMark(AWAY3).texture)
check("one with news to hand in has a bright check", listMark(AWAY1).texture == "Interface\\Buttons\\UI-CheckBox-Check" and listMark(AWAY1).alpha == 1, listMark(AWAY1).alpha)
check("one you have read fades", listMark(AWAY2).alpha == 0.5, listMark(AWAY2).alpha)
end
PromptPeonDB.selected = AWAY1
ns.UI:Render()
ns.UI:Render()
check("reading it clears the mark", not listText(AWAY1):find("|cffffd100?|r", 1, true), listText(AWAY1))
PromptPeonDB.away, Game.report, ns.UI.showReport = nil, nil, nil
PromptPeonDB.selected = THREAD
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- Loot.
local function lootTier(added, removed) return Game.LootFor({ 1, added, removed, 1 }) end
check("a small fix is junk", lootTier(3, 2).name == "Tattered Patch of Refactoring" and lootTier(3, 2).tier == 1, lootTier(3, 2).name)
check("size sets the quality", lootTier(30, 5).tier == 2 and lootTier(150, 5).tier == 3 and lootTier(900, 5).tier == 4 and lootTier(4000, 5).tier == 5 and lootTier(9000, 5).tier == 6)
check("mostly new code is creation", lootTier(100, 1).name == "Sturdy Patch of Creation", lootTier(100, 1).name)
check("mostly removed code is deletion", lootTier(1, 100).name == "Sturdy Patch of Deletion", lootTier(1, 100).name)
check("the biggest ones are legendary", lootTier(9000, 8000).name == "Legendary Patch of Refactoring", lootTier(9000, 8000).name)
local LOOTER = "55555555-0000-0000-0000-000000000005"
local function lootThread(status, change)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.played = {}
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = LOOTER, p = "Shop", t = "Looter", s = status, u = time(), lc = change } } })
  ns:RefreshAndRender()
  stub.timers = {}
end
local function chatHas(words, from)
  for index = from or 1, #stub.chat do
    if stub.chat[index]:find(words, 1, true) then return stub.chat[index] end
  end
end
PromptPeonDB.looted = {}
Game.seeded = nil
lootThread("done", { 2, 10, 2, 100 })
local lootChat = #stub.chat
check("old work is not new loot", not chatHas("found loot", lootChat) and PromptPeonDB.looted[LOOTER] == 100)
lootThread("running", { 3, 900, 3, 200 })
check("nothing drops while it is working", not chatHas("found loot", lootChat + 1))
lootThread("done", { 3, 900, 3, 200 })
local lootLine = chatHas("found loot", lootChat + 1)
check("finishing drops loot, named and colored", lootLine and lootLine:find("|cff0070dd|Haddon:peon:changes:" .. LOOTER .. "|h[Fine Patch of Creation]|h|r", 1, true), lootLine)
check("and says what it was", lootLine and lootLine:find("+900 -3 in 3 files", 1, true), lootLine)
local afterLoot = #stub.chat
lootThread("done", { 3, 900, 3, 200 })
check("once", PromptPeonDB.looted[LOOTER] == 200 and not chatHas("found loot", afterLoot + 1))
stub.played = {}
lootThread("done", { 9, 8000, 500, 300 })
check("epic and better get the big sound", stub.played[1] == SOUNDKIT.UI_EPICLOOT_TOAST or stub.played[2] == SOUNDKIT.UI_EPICLOOT_TOAST, stub.played[1])
check("the first legendary is an achievement", PromptPeonDB.achievements.legendary ~= nil)
PromptPeonDB.selected = LOOTER
ns.UI.views = {}
ns.Chat:OnLink("addon:peon:changes:" .. LOOTER, "LeftButton")
stub.timers = {}
check("clicking loot only opens the thread", PromptPeonDB.selected == LOOTER and ns.UI.views[LOOTER] == nil and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
drainSend()
ns.UI.views = {}

-- Achievements.
PromptPeonDB.achievements, PromptPeonDB.stats = {}, {}
local achieveChat = #stub.chat
Game:Earn("zugzug")
check("earning one says so in chat", chatHas("[Zug Zug]", achieveChat + 1) and chatHas("Achievement earned", achieveChat + 1))
local afterEarn = #stub.chat
Game:Earn("zugzug")
check("only once", #stub.chat == afterEarn)
for _ = 1, 4 do Game:Count("resurrected", 5, "necromancer") end
check("counting toward one earns nothing yet", not PromptPeonDB.achievements.necromancer)
Game:Count("resurrected", 5, "necromancer")
check("reaching the goal does", PromptPeonDB.achievements.necromancer ~= nil)
local all = {}
for _, entry in ipairs(Game.ACHIEVEMENTS) do all[entry.id] = true end
check("every achievement earned in code exists", all.zugzug and all.questhub and all.raid and all.legendary and all.hogger and all.necromancer and all.leeroy and all.reload and all.night and all.peon and all.spell)
PromptPeonDB.achievements = {}
Game:OnStarted({ rm = "full-access", b = "main" })
check("full access on main is Leeroy", PromptPeonDB.achievements.leeroy ~= nil)
PromptPeonDB.achievements = {}
Game:OnStarted({ rm = "approval-required", b = "main" })
Game:OnStarted({ rm = "full-access", b = "feature" })
check("anything else isn't", not PromptPeonDB.achievements.leeroy)
PromptPeonDB.stats = {}
for _ = 1, 4 do Game:OnFinished({ s = "error" }) end
Game:OnFinished({ s = "done" })
check("a success resets the failure streak", PromptPeonDB.stats.failStreak == 0)
for _ = 1, 5 do Game:OnFinished({ s = "error" }) end
check("5 in a row is Hogger", PromptPeonDB.achievements.hogger ~= nil)

-- Spells.
local CASTER = "66666666-0000-0000-0000-000000000006"
local function casterThread(status, pr)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = CASTER, p = "Shop", t = "Caster", s = status, u = time(), prs = pr and { pr } or nil, m = { { "a", "words", "d", 5 } } } } })
  PromptPeonDB.selected = CASTER
  ns:RefreshAndRender()
  stub.timers = {}
end
casterThread("done")
local spellBar = Game.spellBar
check("the spell bar is there", spellBar ~= nil and #spellBar.buttons == #Game.SPELLS)
local function spellButton(id)
  for _, button in ipairs(spellBar.buttons) do
    if button.spell.id == id then return button end
  end
end
check("Sunder hides while nothing is failing", not spellButton("sunder").shown and spellButton("light").shown)
stub.errors = {}
Game.casts, Game.lastCast = nil, nil
-- A spell is a real order to a real agent, so it shows you the words first.
do
spellButton("light").scripts.OnClick(spellButton("light"))
local castPopup = stub.popups[#stub.popups]
check("a spell asks first and sends nothing yet", castPopup.name == "PROMPTPEON_CAST" and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
check("it names the spell and the thread", castPopup.a:find("Holy Light", 1, true) and castPopup.a:find("Caster", 1, true), castPopup.a)
check("and shows the exact words", castPopup.b:find("Prove it works", 1, true), castPopup.b)
StaticPopupDialogs.PROMPTPEON_CAST.OnAccept(nil, castPopup.data)
sentCommand = PromptPeonDB.pending[1]
check("saying yes casts it", sentCommand and sentCommand.text:find("Prove it works", 1, true))
end
drainSend()
casterThread("done")
Game.casts, Game.lastCast = nil, nil
PromptPeonDB.spellsNoAsk = true -- Options can turn the question off. The rest of these go without it.
spellButton("light").scripts.OnClick(spellButton("light"))
sentCommand = PromptPeonDB.pending[1]
check("casting sends its prompt to the open thread", sentCommand and sentCommand.thread == CASTER and sentCommand.text:find("Prove it works", 1, true), sentCommand and sentCommand.text)
check("your first spell is an achievement", PromptPeonDB.achievements.spell ~= nil)
check("the icon greys out while it cools down", spellButton("light").icon.desaturated == true and spellButton("sight").icon.desaturated == false, spellButton("light").icon.desaturated)
spellButton("sight").scripts.OnClick(spellButton("sight"))
check("the global cooldown stops a double click", #PromptPeonDB.pending == 1 and stub.errors[#stub.errors] == "Spell is not ready yet.", stub.errors[#stub.errors])
stub.now = stub.now + 2
spellButton("light").scripts.OnClick(spellButton("light"))
check("each spell has its own cooldown", #PromptPeonDB.pending == 1)
drainSend()
casterThread("done")
spellButton("light").scripts.OnClick(spellButton("light"))
check("it comes back", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text:find("Prove it works", 1, true))
drainSend()
casterThread("error")
stub.errors = {}
spellButton("sight").scripts.OnClick(spellButton("sight"))
check("you can't cast at the dead", stub.errors[#stub.errors] == "Your target is dead." and #PromptPeonDB.pending == 0, stub.errors[#stub.errors])
Game:Cast(Game.SPELLS[1], nil)
check("or at nobody", stub.errors[#stub.errors] == "You have no target.")
casterThread("done")
Game.casts, Game.lastCast = nil, nil
Game:Cast(press.spell("dispel"), ns:ThreadById(PromptPeonDB.selected))
check("a spell sends its words", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text:find("going in circles", 1, true), PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text)
drainSend()
casterThread("done")
check("no spell promises anything risky", (function()
  for _, spell in ipairs(Game.SPELLS) do
    if spell.id == "execute" and not spell.prompt:find("Don't push", 1, true) then return false end
    if spell.id == "sunder" and (not spell.prompt:find("don't skip or disable", 1, true) or not spell.prompt:find("Don't push", 1, true)) then return false end
    if #spell.prompt > 400 then return false end
  end
  return true
end)())

-- The spell for a failing build.
casterThread("done", { n = 42, st = "open", ck = "passing", ti = "Fix it" })
check("a green build has no use for Sunder", not spellButton("sunder").shown)
casterThread("done", { n = 42, st = "merged", ck = "failing", ti = "Fix it" })
check("nor does a merged one", not spellButton("sunder").shown)
casterThread("done", { n = 42, st = "open", ck = "failing", ti = "Fix it" })
check("a red one offers it", spellButton("sunder").shown)
Game.casts, Game.lastCast = nil, nil
spellButton("sunder").scripts.OnClick(spellButton("sunder"))
check("casting it tells the agent to fix CI", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text:find("CI is", 1, true))
drainSend()
PromptPeonDB.selected = THREAD
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

do
-- What the reviews broke, kept broken-proof.
local RED_A, RED_B = "aaaaaaaa-1111-0000-0000-000000000001", "bbbbbbbb-2222-0000-0000-000000000002"
local function redShow(threads)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads, pj = { "Shop", "Other Project" } })
  ns:RefreshAndRender()
  stub.timers = {}
end
local threadA = { id = RED_A, p = "Shop", t = "A", s = "done", u = time() }
local threadB = { id = RED_B, p = "Shop", t = "B", s = "done", u = time() }
PromptPeonDB.drafts = {}
redShow({ threadA, threadB })
PromptPeonDB.selected = RED_A
ns.UI:Render()
local box = ns.UI.input.EditBox
box:SetText("for A only")
PromptPeonDB.selected = RED_B -- What a chat link or a menu does, with no render yet.
ns.UI:Send()
check("text typed for A goes to A, whatever got selected since", PromptPeonDB.pending[1].thread == RED_A, PromptPeonDB.pending[1].thread)
drainSend()
PromptPeonDB.selected = RED_A
redShow({ threadA, threadB })
ns.UI:Render()
box:SetText("an important draft")
PromptPeonDB.selected = RED_A
redShow({ threadB })
check("a thread that vanishes keeps its draft", PromptPeonDB.drafts[RED_A] == "an important draft", PromptPeonDB.drafts[RED_A])
check("and the box moves on", box:GetText() ~= "an important draft", box:GetText())
redShow({ threadA, threadB })
PromptPeonDB.selected = RED_A
ns.UI:Render()
check("the draft is there when it comes back", box:GetText() == "an important draft", box:GetText())
box:SetText("")
PromptPeonDB.drafts = {}
press.startThread("Elsewhere", "fix login")
check("a named project is never swapped for the open one", PromptPeonDB.pending[1].text == "\1new\napproval-required\nElsewhere\nfix login", PromptPeonDB.pending[1].text)
drainSend()
redShow({ threadA, threadB })
press.startThread("Other Project", "fix login")
check("a real project with a space in its name works", PromptPeonDB.pending[1].text == "\1new\napproval-required\nOther Project\nfix login", PromptPeonDB.pending[1].text)
drainSend()
redShow({ threadA, threadB })
local notSent, notWhy = ns:QueueReply(RED_A, "\1stop")
check("a pasted control byte can't turn a reply into a command", notSent == nil and notWhy:find("can't be sent", 1, true) and #PromptPeonDB.pending == 0)
check("thread IDs with colons can be replied to", ns:QueueReply("import:codex:abcdefgh", "hi") == true)
check("and fit the fallback", PromptPeonOutbox:find(ns.ToHex("import:codex:abcdefgh"), 1, true) ~= nil)
PromptPeonDB.pending = {}
ns:WriteOutbox()
ns.Chat:OnLink("addon:peon:report", "LeftButton")
ns.UI.showReport = nil
PromptPeonDB.selected = RED_A
ns.UI:Render()
ns:QueueReply(RED_A, "words I typed")
local failedSeq = PromptPeonDB.pending[1].seq
box:SetText("")
PromptPeonDB.drafts = {}
drainSend()
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = failedSeq, at = ctlStamp, res = { [tostring(failedSeq)] = "failed: T3 said no" }, threads = { threadA, threadB } })
ns:RefreshAndRender()
stub.timers = {}
check("a reply that failed comes back to the box", box:GetText() == "words I typed", box:GetText())
box:SetText("")
PromptPeonDB.drafts = {}
PromptPeonDB.results = {}

-- A hostile table costs almost nothing to write. It must not cost much to draw.
local bigHeader = "|" .. string.rep(" h |", 201)
local bigRows = {}
for _ = 1, 200 do bigRows[#bigRows + 1] = "| a | b |" end
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = RED_A, p = "Shop", t = "Table", s = "done", u = time(), m = { { "a", bigHeader .. "\n|" .. string.rep("-|", 201) .. "\n" .. table.concat(bigRows, "\n"), "d", 1 } } } } })
ns:RefreshAndRender()
stub.timers = {}
local linesUsed = 0
for _, line in ipairs(ns.UI.lines) do if line.shown then linesUsed = linesUsed + 1 end end
check("a huge table stays cheap to draw", linesUsed <= 400, linesUsed)
check("and says there is more", lineWith("more rows in T3."))
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = RED_A, p = "Shop", t = "Deep", s = "done", u = time(), m = { { "a", string.rep(" ", 10000) .. "- deep", "d", 1 } } } } })
ns:RefreshAndRender()
stub.timers = {}
local deepest = 0
for _, line in ipairs(ns.UI.lines) do
  if line.shown and tostring(line.text):find("deep", 1, true) then deepest = line.width or 0 end
end
check("a hostile indent can't make text negative width", deepest > 0, deepest)

-- A secrets file stays out, and says why.
ns.loaded = {}
ns.UI.views = {}
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = RED_A, p = "Shop", t = "Sec", s = "done", u = time(), ch = { { ".env", "modified", 1, 0 } }, df = { { ".env", 1, 0, "", true, true } }, dn = "", m = {} } } })
ns:RefreshAndRender()
stub.timers = {}
ns.UI.views[RED_A] = "changes"
PromptPeonDB.selected = RED_A
ns.UI:Render()
for _, head in ipairs(ns.UI.heads) do
  if head.shown and head.text.text:find(".env", 1, true) then head.scripts.OnClick(head) break end
end
check("a secrets file is kept out and says why", lineWith("looks like a secrets file"))
check("without asking the bridge for it", #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
ns.UI.views, ns.UI.groups, ns.loaded = {}, {}, {}

-- Just logged in, before the bridge has spoken.
local chatQuiet, playedQuiet = #stub.chat, nil
stub.played = {}
PromptPeonDB.seen, PromptPeonDB.looted = {}, {}
ns.lastStatus, Game.seeded = nil, nil
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {}, quiet = true })
ns:RefreshAndRender()
stub.timers = {}
check("a cleared snapshot says nothing about any thread", ns.lastStatus == nil and Game.seeded == nil)
check("we ask again soon", (function()
  local before = ns.nextSlot
  stub.now = stub.now + 6
  stub.tick()
  stub.timers = {}
  return ns.nextSlot == before + 1
end)())
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = RED_A, p = "Shop", t = "Old work", s = "running", u = time(), lc = { 1, 500, 0, 9 }, m = { { "a", "old", "d", 9 } } } } })
ns:RefreshAndRender()
stub.timers = {}
check("the first real one isn't all news", not chatHas("found loot", chatQuiet + 1) and not Game.IsUnread(ns:ThreadById(RED_A)))
PromptPeonDB.selected = THREAD
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

end

do
-- Resizing is our own drag now, with no help from the game that could send it flying.
local grip, window2 = ns.UI.grip, ns.UI.frame
window2:SetSize(820, 520)
stub.cursorX, stub.cursorY, stub.mouseDown = 800, 300, true
grip.scripts.OnMouseDown(grip)
stub.cursorX, stub.cursorY = 700, 350
grip.scripts.OnUpdate(grip)
check("dragging the corner up and left shrinks it by exactly that much", window2.width == 720 and window2.height == 470, window2.width)
stub.cursorX, stub.cursorY = -5000, 5000
grip.scripts.OnUpdate(grip)
check("it stops at the smallest size", window2.width == ns.UI.minWidth and window2.height == 240, window2.width)
stub.cursorX, stub.cursorY = 900000, -900000
grip.scripts.OnUpdate(grip)
check("it can't get bigger than the screen", window2.width == UIParent:GetWidth() - window2:GetLeft() and window2.height == window2:GetTop(), window2.width)
stub.cursorX, stub.cursorY = 700, 350
grip.scripts.OnUpdate(grip)
check("and it comes back down", window2.width == 720, window2.width)
grip.scripts.OnMouseUp(grip)
check("letting go remembers it", PromptPeonDB.width == 720 and PromptPeonDB.height == 470, PromptPeonDB.width)
check("and where it is", PromptPeonDB.position and PromptPeonDB.position[1] == "TOPLEFT")
stub.cursorX = 100
grip.scripts.OnUpdate(grip)
check("after that it stops following the mouse", window2.width == 720, window2.width)
stub.cursorX, stub.cursorY = 800, 300
grip.scripts.OnMouseDown(grip)
stub.mouseDown = false
stub.cursorX = 100
grip.scripts.OnUpdate(grip)
check("letting go somewhere else counts too", grip.start == nil and window2.width == 720, window2.width)
stub.mouseDown = true
ns.UI:ResetWindow()
check("Reset window size is the way back", window2.width == 820 and window2.height == 520 and PromptPeonDB.width == nil)
stub.timers = {}

-- Spells sit along the bottom, as many as fit.
local function spellsShown()
  local count = 0
  for _, button in ipairs(Game.spellBar.buttons) do if button.shown then count = count + 1 end end
  return count
end
PromptPeonDB.selected = THREAD
ns.UI:Render()
check("a normal window shows all of them", spellsShown() == 9, spellsShown())
window2:SetSize(300, 300)
window2.scripts.OnSizeChanged(window2)
ns.UI:Render()
check("the smallest window still fits most", spellsShown() >= 7, spellsShown())
ns:ReloadIn()
window2:SetSize(820, 520)
window2.scripts.OnSizeChanged(window2)
ns.UI:Render()

-- The achievements panel.
PromptPeonDB.achievements = { zugzug = 1700000000 }
PromptPeonDB.stats = { turnedIn = 3 }
PromptPeonDB.selected = THREAD
ns.Game:OpenAchievements()
stub.timers = {}
check("/peon achievements opens the panel", ns.UI.showAchievements == true and ns.UI.title.text == "Achievements", ns.UI.title.text)
check("it says how many", ns.UI.meta.text:find("1 of 12 earned", 1, true), ns.UI.meta.text)
local function achievementHead(words)
  for _, head in ipairs(ns.UI.heads) do
    if head.shown and head.text.text:find(words, 1, true) then return head end
  end
end
check("earned ones are gold, with an icon and the date", achievementHead("Zug Zug").text.text:find("|cffffd100Zug Zug", 1, true) and achievementHead("Zug Zug").text.text:find("|TInterface\\Icons\\INV_Misc_Head_Orc_01:14|t", 1, true) and achievementHead("Zug Zug").right.text:find("2023", 1, true), achievementHead("Zug Zug").right.text)
check("the rest are grey", achievementHead("Hogger").text.text:find("|cff808080Hogger", 1, true), achievementHead("Hogger").text.text)
check("counted ones show how far along you are", achievementHead("Quest Hub").right.text:find("3 of 10", 1, true), achievementHead("Quest Hub").right.text)
check("earned come first", ns.UI.heads[1].text.text:find("Zug Zug", 1, true), ns.UI.heads[1].text.text)
check("the view buttons step aside", not ns.UI.changes.shown and not ns.UI.agents.shown)
ns.UI.back.scripts.OnClick(ns.UI.back)
check("back goes back", ns.UI.showAchievements == nil and ns.UI.title.text ~= "Achievements", ns.UI.title.text)
PromptPeonDB.achievements = {}
local earnChat = #stub.chat
Game:Earn("hogger")
check("earning one links to the panel", stub.chat[#stub.chat]:find("|Haddon:peon:achievements|h[Hogger]|h", 1, true), stub.chat[#stub.chat])
ns.Chat:OnLink("addon:peon:achievements", "LeftButton")
stub.timers = {}
check("and the link opens it", ns.UI.showAchievements == true)
ns.UI.showAchievements = nil
PromptPeonDB.achievements, PromptPeonDB.stats = {}, {}
ns.UI:Render()

-- Queued messages can be cancelled or edited, Turn in can be undone, the list says when it is
-- cut short, and what you hide reaches the bridge.
local function qShow(threads, extra)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  local snap = { ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads }
  for key, value in pairs(extra or {}) do snap[key] = value end
  stub.slotData = snapshot(snap)
  ns:RefreshAndRender()
  stub.timers = {}
end
local function qThread(rows, extra)
  local row = { id = THREAD, p = "Shop", t = "Queue", s = "running", u = time(), qc = 1, m = rows }
  for key, value in pairs(extra or {}) do row[key] = value end
  return row
end
local function lastPending() return PromptPeonDB.pending[#PromptPeonDB.pending] end
local projectRow
local function qHead(words)
  for _, button in ipairs(ns.UI.queueButtons or {}) do
    if button.shown and button.label == words then return button end
  end
  for _, head in ipairs(ns.UI.heads) do
    if head.shown and head.text.text:find(words, 1, true) then return head end
  end
end
local function click(head) head.scripts.OnClick(head) end

-- Queue control.
PromptPeonDB.selected = THREAD
PromptPeonDB.drafts = {}
qShow({ qThread({ { "a", "working", "d", 1 }, { "u", "do one more thing", "q", 0, "run-1" } }) })
check("a queued message with a run offers Cancel and Edit", qHead("Cancel") and qHead("Edit"))
check("they are small icon buttons", qHead("Cancel").action and qHead("Edit").action and qHead("Cancel").icon.texture ~= nil)
qShow({ qThread({ { "a", "working", "d", 1 }, { "u", "old queued", "q", 0 } }) })
check("an old queued row with no run offers nothing", not qHead("Cancel") and not qHead("Edit") and lineWith("old queued"))
qShow({ qThread({ { "u", "two", "q", 0, "run-1" }, { "u", "three", "q", 0, "run-2" } }) })
check("each queued message gets its own pair", #(function()
  local found = {}
  for _, button in ipairs(ns.UI.queueButtons or {}) do
    if button.shown and button.label == "Cancel" then found[#found + 1] = button end
  end
  return found
end)() == 2)

qShow({ qThread({ { "u", "do one more thing", "q", 0, "run-1" } }) })
stub.played = {}
PromptPeonDB.achievements = {}
click(qHead("Cancel"))
check("Cancel sends cancelq with the run", lastPending().text == "\1cancelq\nrun-1" and lastPending().command == "cancelq", lastPending().text)
drainSend()

qShow({ qThread({ { "u", "do one more thing", "q", 0, "run-1" } }) })
ns.UI.input.EditBox:SetText("half typed")
ns.UI:SaveDraft()
click(qHead("Edit"))
check("Edit puts the text in the box", ns.UI.input.EditBox:GetText() == "do one more thing", ns.UI.input.EditBox:GetText())
check("and remembers which message", ns.UI.editingQueued and ns.UI.editingQueued.thread == THREAD and ns.UI.editingQueued.run == "run-1")
check("and says so", ns.UI.notice.text:find("Editing", 1, true) and ns.UI.hint.text:find("editing", 1, true), ns.UI.notice.text .. " / " .. ns.UI.hint.text)
check("what you had typed is kept for later", PromptPeonDB.drafts[THREAD] == "half typed", PromptPeonDB.drafts[THREAD])
local pendingBefore = #PromptPeonDB.pending
ns.UI.input.EditBox:SetText("do two things")
stub.played, PromptPeonDB.achievements = {}, {}
ns.UI:Send()
check("sending while editing sends editq", lastPending().text == "\1editq\nrun-1\ndo two things" and lastPending().command == "editq", lastPending().text)
check("it is not a reply", #PromptPeonDB.pending == pendingBefore + 1 and #stub.played == 0 and not PromptPeonDB.achievements.zugzug)
check("edit mode ends", ns.UI.editingQueued == nil)
check("your own draft comes back", ns.UI.input.EditBox:GetText() == "half typed", ns.UI.input.EditBox:GetText())
drainSend()
PromptPeonDB.drafts = {}
ns.UI.input.EditBox:SetText("")

-- The way out: empty the box and send.
qShow({ qThread({ { "u", "keep me", "q", 0, "run-1" } }) })
click(qHead("Edit"))
ns.UI.input.EditBox:SetText("")
pendingBefore = #PromptPeonDB.pending
ns.UI:Send()
check("an empty box says nothing to send", ns.UI.notice.text == "Nothing to send yet.", ns.UI.notice.text)
check("and sends nothing, and leaves edit mode", #PromptPeonDB.pending == pendingBefore and ns.UI.editingQueued == nil)

-- Switching thread leaves edit mode, and no queued text leaks into a draft.
qShow({ qThread({ { "u", "keep me", "q", 0, "run-1" } }), { id = OTHER, p = "other", t = "Quiet one", s = "done", u = time() - 600 } })
click(qHead("Edit"))
PromptPeonDB.selected = OTHER
ns.UI:Render()
check("switching thread leaves edit mode", ns.UI.editingQueued == nil)
check("the queued text did not become a draft", PromptPeonDB.drafts[THREAD] == nil, PromptPeonDB.drafts[THREAD])
check("the other thread's box is its own", ns.UI.input.EditBox:GetText() == "")
PromptPeonDB.selected = THREAD
ns.UI:Render()

-- The message went out while you were editing: your words stay as a normal draft.
click(qHead("Edit"))
qShow({ qThread({ { "a", "took it", "d", 2 } }, { qc = 0 }) })
check("a vanished queued message ends edit mode", ns.UI.editingQueued == nil)
check("and your text stays in the box", ns.UI.input.EditBox:GetText() == "keep me", ns.UI.input.EditBox:GetText())
ns.UI.input.EditBox:SetText("")
ns.UI:SaveDraft()

-- Undo Turn in.
qShow({ { id = THREAD, p = "Shop", t = "Fin|ished", s = "done", u = time(), m = { { "a", "done", "d", 1 } } } })
local chatFrom = #stub.chat
ns:Settle(ns:ThreadById(THREAD))
check("settling sends settle", lastPending().text == "\1settle", lastPending().text)
check("and remembers it", PromptPeonDB.lastSettled and PromptPeonDB.lastSettled.id == THREAD and PromptPeonDB.lastSettled.title == "Fin|ished")
local settled = chatHas("Turned in", chatFrom + 1)
check("chat says so, with an Undo link", settled and settled:find("Fin||ished", 1, true) and settled:find("|cffffd100|Haddon:peon:unsettle:" .. THREAD .. "|h[Undo]|h|r", 1, true), settled)
drainSend()
ns.Chat:OnLink("addon:peon:unsettle:" .. THREAD, "LeftButton")
check("clicking Undo sends unsettle", lastPending().text == "\1unsettle" and lastPending().command == "unsettle", lastPending().text)
drainSend()
local COLONED = "ns:with:colons"
PromptPeonDB.lastSettled = { id = COLONED, title = "Colons" }
ns.Chat:OnLink("addon:peon:unsettle:" .. COLONED, "LeftButton")
check("ids with colons work", lastPending().thread == COLONED, lastPending().thread)
drainSend()
-- Any addon can print a link that looks like ours, so Undo only ever means the last one you turned in.
do
  PromptPeonDB.lastSettled = { id = THREAD, title = "Mine" }
  local before = #PromptPeonDB.pending
  ns.Chat:OnLink("addon:peon:unsettle:" .. COLONED, "LeftButton")
  check("an Undo link for some other thread does nothing", #PromptPeonDB.pending == before, #PromptPeonDB.pending)
  PromptPeonDB.lastSettled = nil
end
drainSend()
PromptPeonDB.lastSettled = nil
ns:Settle(ns:ThreadById(THREAD))
drainSend()
pendingBefore = #PromptPeonDB.pending
ns.Chat:Undo(THREAD)
check("/peon undo brings the last one back", #PromptPeonDB.pending == pendingBefore + 1 and lastPending().thread == THREAD and lastPending().text == "\1unsettle", lastPending().text)
drainSend()

-- The menu and Release Spirit go through the same function.
qShow({ { id = THREAD, p = "Shop", t = "Menu one", s = "done", u = time(), m = { { "a", "done", "d", 1 } } } })
PromptPeonDB.lastSettled = nil
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
end
listRow.scripts.OnClick(listRow, "RightButton")
menuItem("Turn in").scripts.OnClick(menuItem("Turn in"))
check("nothing is remembered until you say yes", PromptPeonDB.lastSettled == nil)
StaticPopupDialogs.PROMPTPEON_TURN_IN.OnAccept(nil, stub.popups[#stub.popups].data)
check("the thread menu remembers it", PromptPeonDB.lastSettled and PromptPeonDB.lastSettled.title == "Menu one")
drainSend()
qShow({ { id = THREAD, p = "Shop", t = "Dead two", s = "error", u = time(), m = { { "a", "broke", "d", 5 } } } })
PromptPeonDB.lastSettled = nil
click(qHead("Release Spirit"))
StaticPopupDialogs.PROMPTPEON_RELEASE.OnAccept(nil, stub.popups[#stub.popups].data)
check("Release Spirit remembers it", PromptPeonDB.lastSettled and PromptPeonDB.lastSettled.title == "Dead two")
drainSend()

-- Thread count.
local manyThreads = {}
for number = 1, 3 do manyThreads[number] = { id = "t" .. number, p = "Shop", t = "Thread " .. number, s = "done", u = time() } end
qShow(manyThreads, { tc = 46 })
local countRow
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.text.text and row.text.text:find("of 46 threads", 1, true) then countRow = row end
end
check("a cut list says how many are left out", countRow and countRow.text.text:find("Showing 3 of 46 threads. The rest are in T3.", 1, true), countRow and countRow.text.text)
check("it is not a thread or a project", countRow and countRow.thread == nil and countRow.project == nil and not countRow.isHiddenHeader)
local selectedBefore = PromptPeonDB.selected
countRow.scripts.OnClick(countRow, "LeftButton")
countRow.scripts.OnClick(countRow, "RightButton")
countRow.scripts.OnEnter(countRow)
check("clicking it does nothing", PromptPeonDB.selected == selectedBefore and not countRow.selected.shown)
qShow(manyThreads, { tc = 3 })
local anyCount = false
for _, row in ipairs(ns.UI.rows) do if row.shown and row.text.text and row.text.text:find("Showing", 1, true) then anyCount = true end end
check("a whole list says nothing", not anyCount)
qShow(manyThreads)
anyCount = false
for _, row in ipairs(ns.UI.rows) do if row.shown and row.text.text and row.text.text:find("Showing", 1, true) then anyCount = true end end
check("an old snapshot with no count says nothing", not anyCount)

-- Hidden threads reach the bridge.
qShow({ { id = THREAD, p = "Shop", t = "Hide me", s = "done", u = time(), m = { { "a", "done", "d", 1 } } } })
PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenProjects, PromptPeonDB.hiddenSent = {}, {}, nil
pendingBefore = #PromptPeonDB.pending
check("nothing hidden and nothing sent before: nothing to say", ns:SendHidden() == nil and #PromptPeonDB.pending == pendingBefore)
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
end
listRow.scripts.OnClick(listRow, "RightButton")
menuItem("Hide...").scripts.OnClick(menuItem("Hide..."))
menuItem("This thread").scripts.OnClick(menuItem("This thread"))
check("hiding a thread sends the list", lastPending().text == "\1hidden\nt:" .. THREAD and lastPending().command == "hidden" and lastPending().thread == "settings", lastPending().text)
check("and remembers what it sent", PromptPeonDB.hiddenSent == "t:" .. THREAD)
drainSend()
pendingBefore = #PromptPeonDB.pending
ns:SendHidden()
check("the same list is not sent twice", #PromptPeonDB.pending == pendingBefore)
PromptPeonDB.hiddenProjects.zeta, PromptPeonDB.hiddenProjects.alpha = true, true
PromptPeonDB.hiddenThreads.b, PromptPeonDB.hiddenThreads.a = true, true
ns:SendHidden()
check("lines are sorted so the text is stable", lastPending().text == "\1hidden\np:alpha\np:zeta\nt:" .. THREAD .. "\nt:a\nt:b", lastPending().text)
drainSend()
PromptPeonDB.hiddenProjects, PromptPeonDB.hiddenThreads = {}, {}
qShow({ { id = THREAD, p = "Shop", t = "Hide me", s = "done", u = time(), m = { { "a", "done", "d", 1 } } } })
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.project == "Shop" then projectRow = row end
end
projectRow.scripts.OnClick(projectRow, "RightButton")
menuItem("Hide this project").scripts.OnClick(menuItem("Hide this project"))
check("the project menu sends it too", lastPending().text:find("\1hidden\np:Shop", 1, true), lastPending().text)
drainSend()
listRow = nil
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
end
check("the hidden thread is in the Hidden section", listRow == nil)
PromptPeonDB.hiddenOpen = true
ns.UI:Render()
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread and row.thread.id == THREAD then listRow = row end
end
listRow.scripts.OnClick(listRow, "RightButton")
menuItem("Show Shop").scripts.OnClick(menuItem("Show Shop"))
check("showing a project sends the shorter list", lastPending().text == "\1hidden", lastPending().text)
check("and the empty list is remembered", PromptPeonDB.hiddenSent == "")
drainSend()
PromptPeonDB.hiddenOpen = nil

-- Too many to fit: send what does, and say so.
PromptPeonDB.hiddenThreads = {}
for number = 1, 400 do PromptPeonDB.hiddenThreads[string.format("%08d-0000-4000-8000-000000000000", number)] = true end
chatFrom = #stub.chat
ns:SendHidden()
check("an oversize list still goes, trimmed", lastPending().command == "hidden" and #lastPending().text <= ns.MAX_REPLY_BYTES, #lastPending().text)
check("and chat says some were left out", chatHas("Too many hidden", chatFrom + 1), stub.chat[#stub.chat])
drainSend()
PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenProjects, PromptPeonDB.hiddenSent = {}, {}, nil

-- Login: the bridge's copy is what counts, so it is sent again once.
PromptPeonDB.hiddenThreads.zz = true
PromptPeonDB.hiddenSent = "t:zz"
pendingBefore = #PromptPeonDB.pending
ns:SendHidden(true)
check("login sends the list even if it was sent before", #PromptPeonDB.pending == pendingBefore + 1 and lastPending().text == "\1hidden\nt:zz", lastPending().text)
drainSend()
PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenSent = {}, nil

-- A hidden thread arrives with no text at all.
qShow({ { id = THREAD, p = "Shop", s = "running", u = time(), hd = true, qc = 0 }, { id = OTHER, p = "other", s = "done", u = time(), hd = true } })
PromptPeonDB.selected = THREAD
PromptPeonDB.hiddenOpen = true
PromptPeonDB.hiddenThreads[THREAD] = true
ns.UI:Render()
check("an open hidden thread explains itself", lineWith("This thread is hidden, so its text stays out of the game. Show it to read it here."))
check("and doesn't say there were no messages", not lineWith("No messages in this update"))
ns.UI:RenderTracker()
Game:OnSnapshot(ns.snapshot)
Game:OpenReport()
ns.UI:ShowThreadTip(ns.UI.rows[1], ns:ThreadById(THREAD))
check("nothing falls over on a row with no text", true)
ns.UI.showReport = nil
PromptPeonDB.hiddenOpen, PromptPeonDB.hiddenThreads = nil, {}
PromptPeonDB.selected = THREAD
qShow({ { id = THREAD, p = "Shop", t = "In the list", s = "done", u = time() } })

end

do
-- The open thread has real buttons, and the right-click menu is a shortcut.
local MENU_THREAD = "77777777-0000-0000-0000-000000000007"
local CATALOG = {
  { i = "claudeAgent", n = "Claude", m = {
    { "claude-opus-5-5", "Opus 5.5", "effort", { "low", "high", "xhigh" }, { "Low", "High", "Extra High" }, "high" },
    { "claude-haiku-5-5", "Haiku 5.5", "", {}, {}, "" },
  } },
  { i = "codex", n = "Codex", m = {
    { "gpt-6-astra", "GPT-6 Astra", "reasoningEffort", { "low", "high", "ultra" }, { "Low", "High", "Ultra" }, "low" },
  } },
}
local function menuThread(status)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, md = CATALOG, pj = { "Shop", "Other" }, threads = {
    { id = MENU_THREAD, p = "Shop", t = "Menu", s = status, u = time(), mi = "claudeAgent", mo = "claude-opus-5-5", ef = "xhigh", m = { { "a", "words", "d", 1 } } },
  } })
  PromptPeonDB.selected = MENU_THREAD
  ns:RefreshAndRender()
  stub.timers = {}
end
menuThread("done")
local UI2 = ns.UI
check("a finished thread offers Turn in, Track and Hide", UI2.primary.shown and UI2.primary.label == "Turn in" and UI2.secondary.label == "Track" and UI2.hideButton.label == "Hide", UI2.primary.label)
check("as icons", UI2.primary.icon.texture:find("ActiveQuestIcon", 1, true) and UI2.hideButton.icon.texture:find("Ability_Stealth", 1, true) and UI2.primary.width == 24, UI2.primary.icon.texture)
check("untracked looks switched off", UI2.secondary.icon.desaturated == true)
UI2.secondary.scripts.OnClick(UI2.secondary)
check("the track button tracks", PromptPeonDB.tracked[MENU_THREAD] == true and UI2.secondary.label == "Tracked", UI2.secondary.label)
check("and lights up", UI2.secondary.icon.desaturated == false)
local tipTitle, tipBody
local addLineBefore = GameTooltip.AddLine
GameTooltip.AddLine = function(_, text) if tipTitle then tipBody = tipBody or text else tipTitle = text end end
UI2.primary.scripts.OnEnter(UI2.primary)
GameTooltip.AddLine = addLineBefore
check("hovering says what it does", tipTitle == "Turn in" and tipBody and tipBody:find("handing in a quest", 1, true), tipTitle)
UI2.primary.scripts.OnClick(UI2.primary)
check("the Turn in icon asks first", stub.popups[#stub.popups].name == "PROMPTPEON_TURN_IN" and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
check("and it names the thread", stub.popups[#stub.popups].a == "Menu", stub.popups[#stub.popups].a)
StaticPopupDialogs.PROMPTPEON_TURN_IN.OnAccept(nil, stub.popups[#stub.popups].data)
check("the main button turns it in", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text == "\1settle", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text)
drainSend()
menuThread("running")
check("a working one offers Stop", UI2.primary.label == "Stop", UI2.primary.label)
local popupsBefore = #stub.popups
UI2.primary.scripts.OnClick(UI2.primary)
check("which asks first", #stub.popups == popupsBefore + 1 and #PromptPeonDB.pending == 0)
menuThread("error")
check("a dead one offers Resurrect and Release", UI2.primary.label == "Resurrect" and UI2.secondary.label == "Release Spirit", UI2.primary.label)
UI2.secondary.scripts.OnClick(UI2.secondary)
check("the Release icon asks first", stub.popups[#stub.popups].name == "PROMPTPEON_RELEASE" and #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
StaticPopupDialogs.PROMPTPEON_RELEASE.OnAccept(nil, stub.popups[#stub.popups].data)
check("releasing settles it", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text == "\1settle")
drainSend()
menuThread("done")
UI2.hideButton.scripts.OnClick(UI2.hideButton)
check("the hide button hides it", PromptPeonDB.hiddenThreads[MENU_THREAD] == true)
PromptPeonDB.hiddenThreads[MENU_THREAD] = nil
drainSend()
PromptPeonDB.pending = {}
ns:WriteOutbox()
menuThread("done")
UI2.frame:SetSize(300, 300)
UI2.frame.scripts.OnSizeChanged(UI2.frame)
UI2:Render()
check("a small window has room for all three", UI2.primary.shown and UI2.secondary.shown and UI2.hideButton.shown)
UI2.frame:SetSize(820, 520)
UI2.frame.scripts.OnSizeChanged(UI2.frame)
UI2:Render()
UI2:ToggleOptions()
stub.timers = {}
check("pages put them away", not UI2.primary.shown and not UI2.modelChip.shown)
UI2:ToggleOptions()
stub.timers = {}

-- The right-click menu stays short.
UI2:ThreadMenu(UI2.frame, ns:ThreadById(MENU_THREAD))
check("it has the quick things", menuItem("Open") and menuItem("Turn in") and menuItem("Hide...") and menuItem("Snooze..."), "menu")
UI2:CloseMenu()
UI2:ThreadMenu(UI2.frame, ns:ThreadById(MENU_THREAD), true)
check("a party frame adds Change face", menuItem("Change face"))
check("and no longer holds model, effort or spells", not menuItem("Cast a spell >"))
UI2:CloseMenu()
UI2:ProjectMenu(UI2.frame, "Shop")
check("a project offers new thread, collapse and hide", menuItem("New thread here") and menuItem("Collapse") and menuItem("Hide this project"))
UI2:CloseMenu()

-- Model and effort sit by the reply box.
check("the box shows the model and effort by name", UI2.modelChip.shown and UI2.modelChip.text == "Opus 5.5" and UI2.effortChip.text == "Extra High", UI2.modelChip.text)
UI2.modelChip.scripts.OnClick(UI2.modelChip)
check("it opens on the provider you use", menuItem("Haiku 5.5") and menuItem("Opus 5.5") and menuItem("Other providers >"))
check("with yours ticked", menuItem("Opus 5.5").text.text:find("UI-CheckBox-Check", 1, true))
menuItem("Other providers >").scripts.OnClick(menuItem("Other providers >"))
check("other providers are one click away", menuItem("Claude >") and menuItem("Codex >"))
menuItem("Claude >").scripts.OnClick(menuItem("Claude >"))
menuItem("Haiku 5.5").scripts.OnClick(menuItem("Haiku 5.5"))
sentCommand = PromptPeonDB.pending[1]
check("choosing one tells the bridge", sentCommand and sentCommand.text == "\1setmodel\nclaudeAgent\nclaude-haiku-5-5", sentCommand and sentCommand.text)
check("and shows right away", UI2.modelChip.text == "Haiku 5.5" and UI2.meta.text:find("Haiku 5.5", 1, true), UI2.modelChip.text)
check("a model with no effort levels has no effort button", not UI2.effortChip.shown)
drainSend()
menuThread("done")
UI2.effortChip.scripts.OnClick(UI2.effortChip)
check("the effort list is that model's, with yours ticked", menuItem("Low") and menuItem("High") and menuItem("Extra High").text.text:find("UI-CheckBox-Check", 1, true) and not menuItem("Ultra"))
menuItem("High").scripts.OnClick(menuItem("High"))
sentCommand = PromptPeonDB.pending[1]
check("choosing one sends it with its model", sentCommand and sentCommand.text == "\1setmodel\nclaudeAgent\nclaude-opus-5-5\nhigh", sentCommand and sentCommand.text)
drainSend()
menuThread("done")
check("the header shows model and effort by name", UI2.meta.text:find("Opus 5.5 Extra High", 1, true), UI2.meta.text)
UI2:ProviderMenu(UI2.frame, CATALOG[2], { instance = "claudeAgent", model = "claude-opus-5-5", effort = "high" }, function(i, m, e) stub.chosen = { i, m, e } end)
menuItem("GPT-6 Astra").scripts.OnClick(menuItem("GPT-6 Astra"))
check("a shared effort level carries over", stub.chosen[3] == "high", stub.chosen[3])
UI2:ProviderMenu(UI2.frame, CATALOG[2], { instance = "claudeAgent", model = "claude-opus-5-5", effort = "xhigh" }, function(i, m, e) stub.chosen = { i, m, e } end)
menuItem("GPT-6 Astra").scripts.OnClick(menuItem("GPT-6 Astra"))
check("one the new model lacks becomes its default", stub.chosen[3] == "", stub.chosen[3])
UI2:CloseMenu()
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), mi = "x", mo = "y", m = {} } } })
ns:RefreshAndRender()
stub.timers = {}
check("without a list from T3, no pickers", not UI2.modelChip.shown and not UI2.effortChip.shown)
menuThread("done")
UI2.newButton.scripts.OnClick(UI2.newButton)
check("the plus button starts a new thread", UI2.newThread ~= nil and UI2.title.text == "New thread")
UI2:StopNewThread()
UI2.newThreadWords = nil
UI2:Render()

-- Queued messages have their buttons on one line.
do
  local function queuedThread(status)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {
      { id = MENU_THREAD, p = "Shop", t = "Queue", s = status, u = time(), qc = 1, m = { { "a", "words", "d", 1 }, { "u", "do this next", "q", 0, "run-7" } } },
    } })
    PromptPeonDB.selected = MENU_THREAD
    ns:RefreshAndRender()
    stub.timers = {}
  end
  local function icon(label)
    for _, button in ipairs(UI2.queueButtons or {}) do
      if button.shown and button.label == label then return button end
    end
  end
  queuedThread("running")
  check("a queued message has its text", lineWith("do this next"))
  check("and steer, edit and cancel as icons", icon("Steer") and icon("Edit") and icon("Cancel"))
  check("on the same line, side by side", icon("Steer").lastPoint[5] == icon("Cancel").lastPoint[5] and icon("Steer").lastPoint[4] < icon("Edit").lastPoint[4] and icon("Edit").lastPoint[4] < icon("Cancel").lastPoint[4], icon("Steer").lastPoint[4])
  icon("Steer").scripts.OnClick(icon("Steer"))
  check("steer sends it now", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text == "\1steer\nrun-7", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text)
  drainSend()
  queuedThread("running")
  icon("Cancel").scripts.OnClick(icon("Cancel"))
  check("cancel cancels it", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text == "\1cancelq\nrun-7", PromptPeonDB.pending[1] and PromptPeonDB.pending[1].text)
  drainSend()
  queuedThread("done")
  check("nothing to steer when it isn't working", not icon("Steer") and icon("Edit") and icon("Cancel"))
  UI2.input.EditBox:SetText("")
  icon("Edit").scripts.OnClick(icon("Edit"))
  check("edit moves it into the box", UI2.input.EditBox:GetText() == "do this next" and UI2.editingQueued ~= nil, UI2.input.EditBox:GetText())
  UI2:StopEditing()
  UI2:Render()
end
PromptPeonDB.drafts = {}

-- The New thread page.
menuThread("done")
do local function parkedAndMarks()
  -- Snoozed and settled threads live at the bottom of the list and nowhere else.
  local UI3 = ns.UI
  local function parkedShow(pk, thread)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, md = CATALOG, threads = {
      { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), mi = "x", mo = "y", m = { { "a", "words", "d", 1 } } },
    }, pk = pk })
    if thread then PromptPeonDB.selected = thread end
    ns:RefreshAndRender()
    stub.timers = {}
  end
  local function groupRow(words)
    for _, row in ipairs(UI3.rows) do
      if row.shown and row.foldKey and row.text.text:find(words, 1, true) then return row end
    end
  end
  local function listed(id)
    for _, row in ipairs(UI3.rows) do
      if row.shown and row.thread and row.thread.id == id then return row end
    end
  end
  local SLEEPY, DONE_ONE = "88888888-0000-0000-0000-000000000008", "99999999-0000-0000-0000-000000000009"
  local wake = time() + 3600
  local PARKED = {
    { id = SLEEPY, p = "Shop", t = "Sleepy", s = "running", u = time(), pk = "z", zu = wake },
    { id = DONE_ONE, p = "Shop", t = "Old job", s = "done", u = time(), pk = "s", cd = true },
  }
  parkedShow(PARKED, MENU_THREAD)
  PromptPeonDB.snoozedOpen, PromptPeonDB.settledOpen = nil, nil
  UI3:Render()
  check("snoozed shows its count", groupRow("Snoozed (1)"))
  check("settled shows no count, since only the newest few reach the game", groupRow("Settled") and not groupRow("Settled ("))
  check("closed by default", not listed(SLEEPY) and not listed(DONE_ONE))
  check("a parked thread never counts as working", ns:Counts().running == 0, ns:Counts().running)
  local foldRow = groupRow("Settled")
  foldRow.scripts.OnClick(foldRow, "LeftButton")
  foldRow = groupRow("Snoozed (1)")
  foldRow.scripts.OnClick(foldRow, "LeftButton")
  check("a click opens them", listed(SLEEPY) and listed(DONE_ONE))
  check("a snoozed row says when it wakes, on the right", listed(SLEEPY).when.shown and listed(SLEEPY).when.text:find(ns.UI.WakeWords(wake, true), 1, true), listed(SLEEPY).when.text)
  check("with the game's sleep icon", listed(SLEEPY).statusIcon.texture == "Interface\\Icons\\Spell_Nature_Sleep", listed(SLEEPY).statusIcon.texture)
  check("the row's words are only its title", not listed(SLEEPY).text.text:find("[", 1, true) and listed(SLEEPY).text.text:find("Sleepy", 1, true), listed(SLEEPY).text.text)
  check("a settled row has a greyed check mark", listed(DONE_ONE).statusIcon.texture == "Interface\\Buttons\\UI-CheckBox-Check" and listed(DONE_ONE).statusIcon.desaturated == true, listed(DONE_ONE).statusIcon.texture)
  local order = {}
  for _, row in ipairs(UI3.rows) do
    if row.shown and (row.project or row.foldKey) then order[#order + 1] = row.project or row.foldKey end
  end
  check("projects first, then snoozed, then settled", table.concat(order, ",") == "Shop,snoozedOpen,settledOpen", table.concat(order, ","))
  -- Which project a settled thread came from has to be readable at a glance.
  local OTHER_ONE = "aaaaaaaa-0000-0000-0000-00000000000a"
  local mixed = {
    { id = DONE_ONE, p = "Shop", t = "Old job", s = "done", u = time(), pk = "s" },
    { id = OTHER_ONE, p = "Other", t = "Other job", s = "done", u = time(), pk = "s" },
    { id = "bbbbbbbb-0000-0000-0000-00000000000b", p = "Shop", t = "Older job", s = "done", u = time(), pk = "s" },
  }
  parkedShow(mixed)
  local seen = {}
  for _, row in ipairs(UI3.rows) do
    if row.shown then
      if row.thread and row.thread.pk then
        seen[#seen + 1] = row.thread.t
      elseif not row.thread and not row.project and not row.foldKey then
        seen[#seen + 1] = "<" .. row.text.text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. ">"
      end
    end
  end
  check("settled threads sit under their project, newest project first", table.concat(seen, ",") == "<Shop>,Old job,Older job,<Other>,Other job", table.concat(seen, ","))
  parkedShow(PARKED)
  -- A long list makes room for its scroll bar, so the bar covers neither the marks nor the thread's name.
  local manyRows = {}
  for index = 1, 60 do
    manyRows[index] = { id = string.format("cccccccc-0000-0000-0000-%012d", index), p = "Shop", t = "Job " .. index, s = "done", u = time(), pk = "s" }
  end
  UI3.listScroll.GetHeight = function() return 300 end
  parkedShow(manyRows)
  check("a long list narrows its rows for the scroll bar", listed(manyRows[1].id).width == UI3.ListWidth() - 20, listed(manyRows[1].id).width)
  parkedShow(PARKED)
  check("a short one keeps its full width", listed(DONE_ONE).width == UI3.ListWidth(), listed(DONE_ONE).width)
  UI3.listScroll.GetHeight = nil

  local sent = #PromptPeonDB.pending
  listed(DONE_ONE).scripts.OnClick(listed(DONE_ONE), "LeftButton")
  check("you can open a settled thread", UI3.title.text == "Old job", UI3.title.text)
  check("it asks T3 for the words, once", #PromptPeonDB.pending == sent + 1 and PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1view", #PromptPeonDB.pending)
  check("and says so while it waits", lineWith("Asking T3") ~= nil)
  check("loading refreshes sooner", UI3:IsLoading(ns:ThreadById(DONE_ONE)))
  UI3:Render()
  check("rendering again doesn't ask again", #PromptPeonDB.pending == sent + 1, #PromptPeonDB.pending)
  check("the main icon is Reopen", UI3.primary.label == "Reopen" and UI3.primary.shown, UI3.primary.label)
  check("no Track or Snooze on it", not UI3.secondary.shown and not UI3.snoozeButton.shown)
  check("it can show its changes", UI3.changes.shown)
  check("the line says it's settled", UI3.meta.text:find("Settled", 1, true), UI3.meta.text)
  drainSend()
  local withWords = {}
  for index, row in ipairs(PARKED) do withWords[index] = row end
  withWords[2] = { id = DONE_ONE, p = "Shop", t = "Old job", s = "done", u = time(), pk = "s", cd = true, vm = { { "a", "what it said", "d", 1 } } }
  parkedShow(withWords)
  check("the words arrive", lineWith("what it said") ~= nil)
  parkedShow(PARKED)
  check("and stay after they stop riding along", lineWith("what it said") ~= nil)
  UI3.primary.scripts.OnClick(UI3.primary)
  check("Reopen unsettles without asking", PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1unsettle", PromptPeonDB.pending[#PromptPeonDB.pending].text)
  drainSend()

  listed(SLEEPY).scripts.OnClick(listed(SLEEPY), "LeftButton")
  check("a snoozed thread opens too", UI3.title.text == "Sleepy" and UI3.meta.text:find("Snoozed until", 1, true), UI3.meta.text)
  check("the main icon wakes it", UI3.primary.label == "Wake it up", UI3.primary.label)
  UI3.primary.scripts.OnClick(UI3.primary)
  check("waking sends unsnooze", PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1unsnooze", PromptPeonDB.pending[#PromptPeonDB.pending].text)
  drainSend()

  -- Turning one in keeps what it said, with no new ask.
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {
    { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), m = { { "a", "its last words", "d", 1 } } },
  }, pk = {} })
  PromptPeonDB.selected = MENU_THREAD
  ns:RefreshAndRender()
  stub.timers = {}
  local sent3 = #PromptPeonDB.pending
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {}, pk = {
    { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), pk = "s" },
  } })
  ns:RefreshAndRender()
  stub.timers = {}
  check("a thread you just turned in stays open with its words", UI3.title.text == "Menu" and lineWith("its last words") ~= nil, UI3.title.text)
  check("with no new ask", #PromptPeonDB.pending == sent3, #PromptPeonDB.pending)
  PromptPeonDB.snoozedOpen, PromptPeonDB.settledOpen = nil, nil

  -- The marks on the right of each row are the game's own.
  local function markOf(status, extra)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    local row = { id = MENU_THREAD, p = "Shop", t = "Menu", s = status, u = time(), mi = "x", mo = "y", m = { { "a", "words", "d", 1 } } }
    for key, value in pairs(extra or {}) do row[key] = value end
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, md = CATALOG, threads = { row }, pk = {} })
    PromptPeonDB.selected = nil
    ns:RefreshAndRender()
    stub.timers = {}
    return listed(MENU_THREAD)
  end
  PromptPeonDB.tracked[MENU_THREAD] = nil
  check("question or permission is the yellow ?", markOf("needs").statusIcon.texture == "Interface\\GossipFrame\\ActiveQuestIcon", markOf("needs").statusIcon.texture)
  check("failed is the red x", markOf("error").statusIcon.texture == "Interface\\RaidFrame\\ReadyCheck-NotReady", markOf("error").statusIcon.texture)
  check("working shows what it's doing, like its peon", markOf("running", { a = "Thinking" }).statusIcon.texture == "Interface\\Icons\\Spell_Holy_MindVision", markOf("running", { a = "Thinking" }).statusIcon.texture)
  check("done is the check mark", markOf("done").statusIcon.texture == "Interface\\Buttons\\UI-CheckBox-Check", markOf("done").statusIcon.texture)
  check("idle has no mark", not markOf("idle").statusIcon.shown)
  PromptPeonDB.tracked[MENU_THREAD] = false
  check("untracked shows no spyglass", not markOf("done").trackIcon.shown)
  PromptPeonDB.tracked[MENU_THREAD] = true
  check("tracked shows the spyglass", markOf("done").trackIcon.shown)
  PromptPeonDB.tracked[MENU_THREAD] = nil
  local titleOnly = markOf("needs").text.text
  check("no marks left in the words", not titleOnly:find("!", 1, true) and not titleOnly:find("?", 1, true) and not titleOnly:find("*", 1, true), titleOnly)
  check("a project row has no mark", (function()
    for _, row in ipairs(UI3.rows) do
      if row.shown and row.project and row.statusIcon.shown then return false end
    end
    return true
  end)())

  -- The hover text says each thing once, and short.
  do
    local lines = {}
    local realAdd, realOwner = GameTooltip.AddLine, GameTooltip.SetOwner
    GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    UI3:ShowThreadTip(UI3.frame, { id = "x", t = "Tip", p = "Shop", s = "running", a = "Working", cu = 34, tn = 16 })
    local all = table.concat(lines, "|")
    local _, working = all:gsub("Working", "")
    check("working shows once", working == 1, all)
    check("context is short", all:find("Context 34%", 1, true) and not all:find("used", 1, true), all)
    check("level shows a/b turns", all:find("Level 4 (16/25 turns)", 1, true), all)
    check("health is short", all:find("Health full", 1, true), all)
    lines = {}
    UI3:ShowThreadTip(UI3.frame, { id = "x", t = "Tip", p = "Shop", s = "running", a = "Thinking" })
    check("what it's actually doing still shows", table.concat(lines, "|"):find("Thinking", 1, true), table.concat(lines, "|"))
    GameTooltip.AddLine, GameTooltip.SetOwner = realAdd, realOwner
  end

  -- What happened and Achievements sit by the cogwheel.
  do
    local Quiet = ns.Game
    local savedReport, savedLast, savedFresh = Quiet.report, PromptPeonDB.lastReport, Quiet.reportFresh
    Quiet.report, PromptPeonDB.lastReport, Quiet.reportFresh = nil, nil, nil
    UI3:Render()
    check("both icons show", UI3.reportIcon.shown and UI3.achievementsIcon.shown)
    check("they're quiet by default", UI3.reportIcon.icon.desaturated == true and UI3.achievementsIcon.icon.desaturated == true)
    local chatBefore = #stub.chat
    UI3.reportIcon.scripts.OnClick(UI3.reportIcon)
    check("with no report it says when one comes", stub.chat[#stub.chat]:find("10 minutes", 1, true) and #stub.chat > chatBefore, stub.chat[#stub.chat])
    check("and opens nothing", not UI3.showReport)
    UI3.achievementsIcon.scripts.OnClick(UI3.achievementsIcon)
    check("the trophy opens achievements", UI3.showAchievements == true and UI3.title.text == "Achievements", UI3.title.text)
    check("and lights up", UI3.achievementsIcon.icon.desaturated == false)
    UI3.achievementsIcon.scripts.OnClick(UI3.achievementsIcon)
    check("pressing it again goes back", UI3.showAchievements == nil and UI3.title.text ~= "Achievements", UI3.title.text)
    Quiet.report = { title = "While you were out questing", minutes = 12, entries = { { id = "r1", p = "Shop", title = "Job", s = "done", fresh = 1, turns = 1 } }, loot = {}, counts = { done = 1, needs = 0, error = 0, running = 0 }, messages = 1, turns = 1, added = 0, removed = 0, files = 0 }
    Quiet.reportFresh = true
    UI3:Render()
    check("a new report lights its icon", UI3.reportIcon.icon.desaturated == false)
    UI3.reportIcon.scripts.OnClick(UI3.reportIcon)
    check("the letter opens the report", UI3.showReport == true and Quiet.reportFresh == nil)
    UI3.reportIcon.scripts.OnClick(UI3.reportIcon)
    check("and closes it", UI3.showReport == nil)
    check("the icon goes quiet once read", UI3.reportIcon.icon.desaturated == true)
    PromptPeonDB.hiddenThreads.r1 = true
    check("a thread you hid since leaves the report", #Quiet:CurrentReport().entries == 0)
    PromptPeonDB.hiddenThreads.r1 = nil
    -- What gets saved for after a reload leaves the agents' words out.
    do
      local realThreads = ns.snapshot.threads
      ns.snapshot.threads = { { id = "r2", p = "Shop", t = "Job", s = "done", tn = 1, m = { { "a", "private words here", "d", 5 } } } }
      PromptPeonDB.away = { kind = "closed", since = time() - 700, base = {}, loot = {} }
      Quiet:FinishAway()
      check("the report you're looking at has the agent's words", Quiet.report.entries[1].gist and Quiet.report.entries[1].gist:find("private", 1, true), Quiet.report.entries[1].gist)
      check("the saved one doesn't", PromptPeonDB.lastReport.entries[1].gist == nil and PromptPeonDB.lastReport.entries[1].title == "Job")
      check("a new report wants reading", Quiet.reportFresh == true)
      ns.snapshot.threads = realThreads
      UI3.showReport = nil
    end
    -- A reload forgets everything but what was saved.
    Quiet.report = nil
    PromptPeonDB.lastReport = { title = "Saved", minutes = 12, entries = {}, loot = {}, counts = { done = 0, needs = 0, error = 0, running = 0 }, messages = 0, turns = 0, added = 0, removed = 0, files = 0 }
    UI3.reportIcon.scripts.OnClick(UI3.reportIcon)
    check("the last report is still there after a reload", UI3.showReport == true and UI3.title.text == "Saved", UI3.title.text)
    UI3.showReport = nil
    Quiet.report, PromptPeonDB.lastReport, Quiet.reportFresh = savedReport, savedLast, savedFresh
    UI3:Render()
  end

  -- A thread's linked pull requests.
  do
    local PR_THREAD = "15151515-0000-0000-0000-000000000015"
    local PRS = {
      { n = 7, ti = "Fix the login", st = "open", ck = "failing", cp = 3, ct = 5, rv = "changes-requested", mg = "conflicting", a = 40, d = 5, f = 3, hb = "fix", bb = "main", au = "someone", r = "me/repo", u = "https://github.com/me/repo/pull/7", at = 2 },
      { n = 6, ti = "Older work", st = "merged", ck = "passing", rv = "approved", a = 10, d = 1, f = 1, hb = "old", bb = "main", au = "someone", r = "me/repo", at = 1 },
    }
    local function show(extra)
      ctlStamp = ctlStamp + 1
      stub.now = stub.now + 100
      local row = { id = PR_THREAD, p = "Shop", t = "With PRs", s = "done", u = time(), m = { { "a", "words", "d", 1 } }, prs = PRS }
      for key, value in pairs(extra or {}) do row[key] = value or nil end
      stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { row }, pk = {} })
      PromptPeonDB.selected = PR_THREAD
      ns:RefreshAndRender()
      stub.timers = {}
    end
    show()
    check("a thread with pull requests has the icon", UI3.pullRequests.shown and UI3.pullRequests.label == "Pull requests (2)", UI3.pullRequests.label)
    check("the tooltip sums them up", UI3.pullRequests.detail == "2 pull requests: 1 open, 1 merged.", UI3.pullRequests.detail)
    check("the summary line says where one stands", UI3.PullRequestLine(PRS[1]):find("CI failing", 1, true) and UI3.PullRequestLine(PRS[1]):find("(3/5)", 1, true) and UI3.PullRequestLine(PRS[1]):find("changes requested", 1, true) and UI3.PullRequestLine(PRS[1]):find("has conflicts", 1, true), UI3.PullRequestLine(PRS[1]))
    check("a merged one skips the noise", not UI3.PullRequestLine(PRS[2]):find("CI", 1, true) and not UI3.PullRequestLine(PRS[2]):find("approved", 1, true), UI3.PullRequestLine(PRS[2]))
    local sent = #PromptPeonDB.pending
    UI3.pullRequests.scripts.OnClick(UI3.pullRequests)
    check("opening the list asks T3 for nothing, it came with the thread", #PromptPeonDB.pending == sent, #PromptPeonDB.pending)
    check("and doesn't count as loading", not UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    check("the list shows them", lineWith("2 pull requests: 1 open, 1 merged.") ~= nil)
    local function head(words)
      for _, row in ipairs(UI3.heads) do
        if row.shown and tostring(row.text.text):find(words, 1, true) then return row end
      end
    end
    check("each has its number and title", head("#7") and head("Fix the login") and head("#6"))
    check("and its counts on the right", head("#7").right.text:find("40", 1, true), head("#7").right.text)
    head("#7").scripts.OnClick(head("#7"))
    check("clicking one opens its page and asks T3", PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1pr\n7", PromptPeonDB.pending[#PromptPeonDB.pending].text)
    check("once", #PromptPeonDB.pending == sent + 1, #PromptPeonDB.pending)
    check("loading refreshes sooner", UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    check("it says where it stands straight away", lineWith("fix into main") ~= nil and lineWith("CI failing") ~= nil)
    check("the list is gone", head("#6") == nil)
    check("there's a way back", head("All pull requests") ~= nil)
    drainSend()
    local now = time()
    local function page(extra)
      local fresh = {
        b = "## Why\n\nBecause it broke.", oa = now - 7200, cs = { { "unit tests", "failure" } }, ct = { { "failure", 1 }, { "success", 41 }, { "skipped", 30 } }, cm = 0,
        lb = { "urgent" }, bh = 3, rv = { { "ann", "approved" }, { "bob", "changes-requested" } }, dn = 5,
        ds = {
          { w = "ann", bt = false, at = now - 5000, b = "Looks **good** to me", g = "Looks good to me" },
          { w = "ci-bot", bt = true, at = now - 4000, b = "A long bot report", g = "A long bot report" },
          { w = "cat", bt = false, at = now - 3000, b = "Why this?", g = "Why this?", pa = "src/deep/a.lua", ln = 12, re = { { "dan", false, now - 2000, "Because of the bug." } }, mr = 2 },
          { w = "eve", bt = false, at = now - 1000, b = "Fixed now", g = "Fixed now", rs = true, pa = "src/b.lua" },
          { w = "fay", bt = false, at = now - 900, b = "", g = "", st = "approved" },
          { w = "gus", bt = false, at = now - 800, b = string.rep("A long comment. ", 80), g = "A long comment." },
        },
        tl = { { "merged", now - 100 }, { "note", now - 5000, 1 }, { "commit", now - 6000, "abcdef1", "Do the thing", 4, 1 }, { "opened", now - 7200, "ann" } },
      }
      for key, value in pairs(extra or {}) do fresh[key] = value end
      return fresh
    end
    show({ pd = { 7, page() } })
    check("loading is over", not UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    check("the summary is open and drawn as markdown", head("Summary") and head("Summary").open and lineWith("Because it broke.") ~= nil and lineWith("## Why") == nil)
    check("it knows how far behind it is", lineWith("3 behind") ~= nil)
    check("and when it opened", lineWith("opened ") ~= nil)
    check("who stands where", lineWith("ann") ~= nil and lineWith("asked for changes") ~= nil)
    check("its labels", lineWith("Labels: urgent") ~= nil)
    check("checks are counted", head("Checks").right.text:find("41 passed", 1, true) and lineWith("30 skipped") ~= nil, head("Checks").right.text)
    check("something broken opens them and gets named", head("Checks").open and lineWith("unit tests") ~= nil and lineWith("Failed") ~= nil)
    check("nobody needs forty green rows", lineWith("Passed  ") == nil)
    check("the discussion is open with its count", head("Discussion (5)") and head("Discussion (5)").open)
    check("people's comments read straight away", lineWith("Looks") ~= nil and lineWith("Why this?") ~= nil)
    check("a reply comes with them", lineWith("Because of the bug.") ~= nil and lineWith("2 more in T3.") ~= nil)
    check("a thread says where it is", head("on a.lua:12") ~= nil and lineWith("src/deep/a.lua:12") ~= nil)
    check("a verdict with no words still shows", head("fay") ~= nil and head("fay").text.text:find("approved", 1, true))
    check("a long one waits for a click", head("gus") and not head("gus").open and lineWith("A long comment.") ~= nil)
    head("gus").scripts.OnClick(head("gus"))
    check("and opens", head("gus").open)
    head("gus").scripts.OnClick(head("gus"))
    check("bots wait behind a button", head("ci-bot") == nil and lineWith("A long bot report") == nil)
    check("so does what's resolved", head("eve") == nil and lineWith("Fixed now") == nil)
    check("the button says how many", head("Show 2 from bots and resolved threads") ~= nil)
    head("Show 2 from bots").scripts.OnClick(head("Show 2 from bots"))
    check("they can be shown, folded", head("ci-bot") and not head("ci-bot").open and lineWith("A long bot report") ~= nil and head("eve") ~= nil)
    check("marked as a bot", head("ci-bot").text.text:find("bot", 1, true))
    check("resolved says so", head("eve").text.text:find("resolved", 1, true))
    head("Hide 2").scripts.OnClick(head("Hide 2"))
    check("and hidden again", head("ci-bot") == nil)
    check("the timeline starts closed", head("Timeline (4)") and not head("Timeline (4)").open and head("abcdef1") == nil)
    head("Timeline (4)").scripts.OnClick(head("Timeline (4)"))
    check("then has the commits", head("abcdef1") and head("Do the thing") and head("abcdef1").right.text:find("4", 1, true))
    check("and when it merged and opened", head("Merged") ~= nil and head("opened this") ~= nil)
    head("Summary").scripts.OnClick(head("Summary"))
    check("the summary folds away", lineWith("Because it broke.") == nil)
    head("Summary").scripts.OnClick(head("Summary"))
    head("Timeline (4)").scripts.OnClick(head("Timeline (4)"))
    sent = #PromptPeonDB.pending
    UI3:Render()
    check("a fresh answer isn't asked for again", #PromptPeonDB.pending == sent, #PromptPeonDB.pending)
    show()
    check("the page stays after it stops riding along", lineWith("Because it broke.") ~= nil)
    check("an open one asks again while you read", #PromptPeonDB.pending == sent + 1 and PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1pr\n7", #PromptPeonDB.pending)
    check("that isn't loading, the old answer stays up", not UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    UI3:Render()
    check("and once is enough", #PromptPeonDB.pending == sent + 1, #PromptPeonDB.pending)
    drainSend()
    show({ pd = { 7, page({ ct = {}, cs = {}, b = "" }) } })
    check("no description says so", lineWith("No description.") ~= nil)
    check("no checks says so", head("Checks").right.text == "None", head("Checks").right.text)
    show({ pd = { 7, page({ cs = { { "bad one", "failure" } }, ct = { { "failure", 44 } }, cm = 3 }) } })
    check("too many checks says how many it left out", lineWith("3 more in T3.") ~= nil)
    show({ pd = { 7, { b = "Just this", ct = {}, er = "the host said no" } } })
    check("half an answer says what's missing", lineWith("the host said no") ~= nil and lineWith("Just this") ~= nil)
    check("and leaves out what it doesn't have", head("Discussion") == nil and head("Timeline") == nil)
    show({ pd = { 7, page({ ds = {}, tl = {} }) } })
    check("no comments says so", lineWith("No comments yet.") ~= nil)
    show({ pd = { 7, page({ ds = { { w = "ci-bot", bt = true, at = now, b = "x", g = "x" } }, tl = {} }) } })
    check("only bots says so", lineWith("Nothing from people yet.") ~= nil)
    show({ pd = { 7, page({ tr = true }) } })
    check("T3 cutting the list off says so", lineWith("T3 only has the newest ones.") ~= nil)
    do
      local many, rows = {}, {}
      for number = 1, 35 do many[number] = { w = "p" .. number .. "x", bt = false, at = now - 1000 + number, b = "Note " .. number, g = "Note " .. number } end
      for number = 1, 100 do rows[number] = { "commit", now - number, "c" .. number .. "x", "Change " .. number, 1, 1 } end
      show({ pd = { 7, page({ ds = many, tl = rows }) } })
      check("a long discussion starts at the newest ten", head("p35x") ~= nil and head("p26x") ~= nil and head("p25x") == nil)
      head("Show 20 older").scripts.OnClick(head("Show 20 older"))
      check("and shows more when asked", head("p6x") ~= nil and head("p5x") == nil)
      head("Show 5 older").scripts.OnClick(head("Show 5 older"))
      check("up to all of them", head("p1x") ~= nil and head(" older") == nil)
      head("Timeline (100)").scripts.OnClick(head("Timeline (100)"))
      check("a long timeline starts at the newest forty", head("c1x") ~= nil and head("c40x") ~= nil and head("c41x") == nil)
      head("Show 40 older").scripts.OnClick(head("Show 40 older"))
      check("and goes on", head("c80x") ~= nil and head("c81x") == nil)
      head("Timeline (100)").scripts.OnClick(head("Timeline (100)"))
    end
    show({ pd = { 7, page({ b = "|Hitem:1|h[Fake]|h |TInterface\\Icons\\x:0|t", ds = { { w = "|cffff0000ann", bt = false, at = now, b = "|Hitem:2|h[Worse]|h", g = "|Hitem:2|h[Worse]|h" } }, tl = {} }) } })
    check("nobody can put links or pictures in the game with a comment", lineWith("Fake") and not tostring(lineWith("Fake").text):gsub("||", ""):find("|Hitem", 1, true) and lineWith("Worse") and not tostring(lineWith("Worse").text):gsub("||", ""):find("|Hitem", 1, true) and not head("ann").text.text:gsub("||", ""):find("|cffff0000", 1, true))
    show({ pd = { 7, page() } })
    head("Copy the link").scripts.OnClick(head("Copy the link"))
    check("the link can be copied", stub.popups[#stub.popups].name == "PROMPTPEON_COPY" and stub.popups[#stub.popups].data == PRS[1].u, stub.popups[#stub.popups].name)
    -- Going in, you see this pull request's own files, not everything the thread changed.
    check("the page offers its own files, folded", head("Files changed (3)") and not head("Files changed (3)").open, head("Files changed (3)"))
    local askedBefore = #PromptPeonDB.pending
    check("it asks T3 for nothing until you open them", #PromptPeonDB.pending == askedBefore)
    head("Files changed (3)").scripts.OnClick(head("Files changed (3)"))
    check("opening them asks for this one", PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1prdiff\n7", PromptPeonDB.pending[#PromptPeonDB.pending].text)
    check("and that counts as loading", UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    UI3:Render()
    check("only once", #PromptPeonDB.pending == askedBefore + 1, #PromptPeonDB.pending)
    drainSend()
    local PR_PATCH = "@@ -1 +1 @@\n-old login\n+new login"
    show({ pd = { 7, page() }, dn = "", dp = 7, df = { { "src/login.py", 1, 1, PR_PATCH, true }, { "big.py", 900, 0, "", false } } })
    check("loading is over once it's here", not UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    check("its files are listed", head("login.py") ~= nil and head("big.py") ~= nil)
    head("login.py").scripts.OnClick(head("login.py"))
    check("and a file opens to its diff", lineWith("new login") ~= nil)
    head("big.py").scripts.OnClick(head("big.py"))
    check("a big file asks for its page from this pull request", PromptPeonDB.pending[#PromptPeonDB.pending].text == "\1file\nbig.py\n1\n7", PromptPeonDB.pending[#PromptPeonDB.pending].text)
    check("and that counts as loading too", UI3:IsLoading(ns:ThreadById(PR_THREAD)))
    drainSend()
    show({ pd = { 7, page() }, dn = "", dp = 0, df = { { "elsewhere.py", 1, 1, PR_PATCH, true } } })
    check("the thread's own changes never pass for this pull request's", head("elsewhere.py") == nil, head("elsewhere.py"))
    drainSend()
    show({ pd = { 7, page() }, dn = "", dp = 7, df = { { "src/login.py", 1, 1, PR_PATCH, true } } })
    head("Files changed (3)").scripts.OnClick(head("Files changed (3)"))
    head("All pull requests").scripts.OnClick(head("All pull requests"))
    check("back goes to the list", head("#6") ~= nil and head("#7") ~= nil and lineWith("2 pull requests: 1 open, 1 merged.") ~= nil)
    head("#6").scripts.OnClick(head("#6"))
    sent = #PromptPeonDB.pending
    check("the other one asks about itself", PromptPeonDB.pending[sent].text == "\1pr\n6", PromptPeonDB.pending[sent].text)
    UI3:Render()
    UI3:Render()
    check("rendering again doesn't ask again", #PromptPeonDB.pending == sent, #PromptPeonDB.pending)
    drainSend()
    show({ pd = { 6, page() } })
    sent = #PromptPeonDB.pending
    show()
    check("a merged one isn't asked again so soon", #PromptPeonDB.pending == sent, #PromptPeonDB.pending)
    stub.now = stub.now + 700
    show()
    check("but in a while, because comments can still come", #PromptPeonDB.pending == sent + 1, #PromptPeonDB.pending)
    drainSend()
    UI3.pullRequests.scripts.OnClick(UI3.pullRequests)
    check("the icon goes back to the thread", UI3.views[PR_THREAD] == nil)
    UI3.pullRequests.scripts.OnClick(UI3.pullRequests)
    check("and comes back to the list", head("#7") ~= nil and head("#6") ~= nil)
    drainSend()
    show({ prs = { PRS[1] } })
    check("with only one, the list would be a pointless click", lineWith("fix into main") ~= nil and head("All pull requests") == nil)
    show({ prs = false })
    UI3.pullRequests.scripts.OnClick(UI3.pullRequests)
    show({ prs = false })
    check("a thread with none has no icon once you've left", not UI3.pullRequests.shown)
    show()
    UI3.pullRequests.scripts.OnClick(UI3.pullRequests)
    PromptPeonDB.hiddenThreads[PR_THREAD] = true
    UI3.views[PR_THREAD] = nil
    show()
    check("hiding throws away what you opened", ns.loaded[PR_THREAD] == nil and ns:ThreadById(PR_THREAD).prs == nil)
    PromptPeonDB.hiddenThreads[PR_THREAD] = nil
    drainSend()
    PromptPeonDB.selected = MENU_THREAD
  end

  -- News in chat: its own tab, your main chat, or nowhere.
  do
    local tabs, tabLines, selected = {}, {}, "general"
    local thread = { id = "news", n = 3, t = "Job", s = "done", m = { { "a", "All done", "d", 1 } } }
    local saved = { FCF_OpenNewWindow, FCF_GetChatWindowInfo, FCF_GetChatFrameByID, FCFDock_GetSelectedWindow, FCF_SelectDockFrame, GENERAL_CHAT_DOCK }
    FCF_GetChatWindowInfo = function(index)
      local tab = tabs[index]
      if tab then return tab, nil, nil, nil, nil, nil, true end
    end
    FCF_GetChatFrameByID = function() return { AddMessage = function(_, text) tabLines[#tabLines + 1] = text end } end
    FCF_OpenNewWindow = function(name, noDefaults)
      if #tabs >= 2 then return nil end
      tabs[#tabs + 1] = name
      check("the tab only gets what we put in it", noDefaults == true)
      selected = name
      return FCF_GetChatFrameByID()
    end
    GENERAL_CHAT_DOCK = {}
    FCFDock_GetSelectedWindow = function() return selected end
    FCF_SelectDockFrame = function(frame) selected = frame end
    local Chat = ns.Chat
    local inMain = #stub.chat
    Chat:ReportFinished(thread)
    check("a finished thread goes to its own tab", #tabs == 1 and tabs[1] == "Peon" and tabLines[1]:find("finished", 1, true), tabLines[1])
    check("not your general chat", #stub.chat == inMain)
    check("and doesn't take you away from your general chat", selected == "general", selected)
    Chat:News("Job reached level 3!")
    check("the next one finds the same tab", #tabs == 1 and tabLines[#tabLines]:find("level 3", 1, true))
    Chat:ReportNeeds(thread)
    check("needs you goes there too", tabLines[#tabLines]:find("needs you", 1, true))
    Chat:ReportFailure({ thread = "news" }, "too long")
    check("something going wrong stays where you'll see it", #stub.chat == inMain + 1 and stub.chat[#stub.chat]:find("did not go through", 1, true))
    ns.db.chatNewsInMain = true
    inMain = #stub.chat
    Chat:News("In main")
    check("it can go in your main chat instead", #stub.chat == inMain + 1 and stub.chat[#stub.chat]:find("In main", 1, true))
    ns.db.chatNewsInMain = nil
    ns.db.chatNewsOff = true
    local lines = #tabLines
    inMain = #stub.chat
    Chat:ReportFinished(thread)
    Chat:News("Nobody hears this")
    check("or nowhere", #tabLines == lines and #stub.chat == inMain)
    Chat:ReportFailure({ thread = "news" }, "too long")
    check("but off never hides a failure", #stub.chat == inMain + 1)
    ns.db.chatNewsOff = nil
    tabs = { "One", "Two" }
    inMain = #stub.chat
    Chat:News("No room for a tab")
    check("with every tab taken it falls back on your main chat", #stub.chat == inMain + 1)
    FCF_OpenNewWindow, FCF_GetChatWindowInfo, FCF_GetChatFrameByID, FCFDock_GetSelectedWindow, FCF_SelectDockFrame, GENERAL_CHAT_DOCK = unpack(saved, 1, 6)
    check("options has both switches", ns.UI.optionsPage == nil or (ns.UI.optionsPage.checks.chatNews and ns.UI.optionsPage.checks.chatTab))
  end

  -- No threads at all, which is what a new install on an empty T3 looks like.
  do
    local UI5 = ns.UI
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {}, pk = {} })
    ns:RefreshAndRender()
    stub.timers = {}
    check("with no threads it says so", UI5.empty.shown and UI5.empty.text:find("No open threads", 1, true), UI5.empty.text)
    UI5.options.scripts.OnClick(UI5.options)
    check("Options still opens", UI5.showOptions and UI5.optionsPage and UI5.optionsPage.shown and UI5.title.text == "Options", UI5.title.text)
    check("in place of the empty words", not UI5.empty.shown)
    UI5.back.scripts.OnClick(UI5.back)
    check("and closes again", not UI5.optionsPage.shown and UI5.empty.shown)
    ns.Game:OpenAchievements()
    check("Achievements opens too", UI5.title.text == "Achievements", UI5.title.text)
    UI5.showAchievements = nil
    UI5:Render()
    check("and closes", UI5.empty.shown)
  end

  -- The reply box and the keyboard.
  do
    local UI4 = ns.UI
    local box, other = UI4.input.EditBox, { cleared = 0 }
    function other:ClearFocus() self.cleared = self.cleared + 1 end
    local savedFocus, savedFoci = GetCurrentKeyBoardFocus, GetMouseFoci
    GetCurrentKeyBoardFocus = function() return other end
    GetMouseFoci = function() return { { GetName = function() return "SomeOverlay" end } } end
    PromptPeonDB.keyboardTrail = nil
    box:ClearFocus()
    UI4.holder.scripts.OnMouseDown()
    check("clicking the box takes the keyboard from whatever had it", other.cleared == 1 and box:HasFocus())
    GetCurrentKeyBoardFocus = function() return box end
    box.scripts.OnMouseDown()
    check("clicking right on the words works too", box:HasFocus() and other.cleared == 1)
    check("and it doesn't take it from itself", other.cleared == 1)
    box:ClearFocus()
    if box.scripts.OnEditFocusLost then box.scripts.OnEditFocusLost() end
    local trail = PromptPeonDB.keyboardTrail
    check("losing the keyboard leaves a trail", trail and trail[#trail].what == "lost it" and trail[#trail].under == "SomeOverlay", trail and trail[#trail].what)
    local written = {}
    for _, entry in ipairs(trail) do for key in pairs(entry) do written[key] = true end end
    check("the trail never holds your words", not written.text and not written.words)
    for _ = 1, 40 do UI4:NoteKeyboard("lost it") end
    check("and stays short", #PromptPeonDB.keyboardTrail == 12, #PromptPeonDB.keyboardTrail)
    PromptPeonDB.keyboardTrail = nil
    GetCurrentKeyBoardFocus, GetMouseFoci = savedFocus, savedFoci
  end

  -- Bringing back what you hid.
  do
    local HIDE_A, HIDE_B = "12121212-0000-0000-0000-000000000012", "13131313-0000-0000-0000-000000000013"
    local function rows()
      ctlStamp = ctlStamp + 1
      stub.now = stub.now + 100
      stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {
        { id = HIDE_A, p = "Shop", t = "Plain one", s = "done", u = time(), m = {} },
        { id = HIDE_B, p = "Secret", t = "In a hidden project", s = "done", u = time(), m = {} },
      }, pk = { { id = "14141414-0000-0000-0000-000000000014", p = "Secret", t = "Settled in it", s = "done", u = time(), pk = "s" } } })
      ns:RefreshAndRender()
      stub.timers = {}
    end
    local function eyeOn(words)
      for _, row in ipairs(UI3.rows) do
        if row.shown and row.showButton.shown and row.text.text:find(words, 1, true) then return row end
      end
    end
    PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenProjects = { [HIDE_A] = true }, { Secret = true, Ghost = true }
    PromptPeonDB.hiddenOpen = true
    rows()
    check("a hidden project has an eye", eyeOn("Secret") and eyeOn("Secret").showButton.words == "Show this project")
    check("so does a project with nothing in it, or you could never show it", eyeOn("Ghost"), "no row")
    check("and a thread you hid by itself", eyeOn("Plain one") and eyeOn("Plain one").showButton.words == "Show this thread")
    check("but not one hidden with its project", not eyeOn("In a hidden project"))
    local ghost = eyeOn("Ghost")
    ghost.scripts.OnClick(ghost, "RightButton")
    check("right-clicking a hidden project offers showing it", menuItem("Show this project") and not menuItem("New thread here"))
    UI3:CloseMenu()
    ghost = eyeOn("Ghost")
    ghost.showButton.scripts.OnClick(ghost.showButton)
    check("the eye brings it back", PromptPeonDB.hiddenProjects.Ghost == nil)
    local plain = eyeOn("Plain one")
    plain.showButton.scripts.OnClick(plain.showButton)
    check("for a thread too", PromptPeonDB.hiddenThreads[HIDE_A] == nil)
    drainSend()
    -- The icon on an open thread: this is what used to do nothing.
    PromptPeonDB.selected = HIDE_B
    UI3:Render()
    check("a thread hidden with its project offers showing the project", UI3.hideButton.label == "Show Secret", UI3.hideButton.label)
    UI3.hideButton.scripts.OnClick(UI3.hideButton)
    check("and that works", PromptPeonDB.hiddenProjects.Secret == nil and not ns:IsHidden(ns:ThreadById(HIDE_B)))
    drainSend()
    PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenProjects, PromptPeonDB.hiddenOpen = {}, {}, nil
    PromptPeonDB.selected = MENU_THREAD
  end

  -- The empty box says how it works, and model and effort sit beside Send.
  do
    local box = UI3.input.EditBox
    box:SetText("")
    UI3.updateHint()
    check("the empty box names who it's for", UI3.hint.shown)
    check("and how it works", UI3.hintKeys.shown and UI3.hintKeys.text:find("Enter to send", 1, true), UI3.hintKeys.text)
    box:SetText("x")
    UI3.updateHint()
    check("typing clears both", not UI3.hint.shown and not UI3.hintKeys.shown)
    box:SetText("")
    UI3.updateHint()
    check("the footer no longer says it", not tostring(UI3.notice.text or ""):find("Enter to send", 1, true), UI3.notice.text)
  end

  local Spells = ns.Game
  check("no spell tells an agent to push", (function()
    for _, spell in ipairs(Spells.SPELLS) do
      if spell.prompt:lower():find("push to", 1, true) then return false end
    end
    return true
  end)())
  do
    UI3:ToggleOptions()
    local box = UI3.optionsPage.checks.askSpells
    local before = PromptPeonDB.spellsNoAsk
    PromptPeonDB.spellsNoAsk = nil
    check("Options has the question, on by default", box and box.get() == true)
    PromptPeonDB.spellsNoAsk = true
    check("and shows when it's off", box.get() == false)
    PromptPeonDB.spellsNoAsk = before
    UI3:ToggleOptions()
  end

  -- Hiding takes the words out of the game at once, along with anything you opened.
  local SECRET = "dddddddd-0000-0000-0000-00000000000d"
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {
    { id = SECRET, p = "Shop", t = "Secret", s = "done", u = time(), m = { { "a", "the words", "d", 1 } }, df = { { "a.txt", 1, 0, "+private", true } } },
  }, pk = {} })
  PromptPeonDB.selected = SECRET
  ns:RefreshAndRender()
  stub.timers = {}
  UI3.views[SECRET] = "changes"
  check("a diff you opened is kept", ns.loaded[SECRET] and ns.loaded[SECRET].df)
  UI3:ToggleHidden(ns:ThreadById(SECRET))
  check("hiding throws it away", ns.loaded[SECRET] == nil and UI3.views[SECRET] == nil)
  check("and the words", ns:ThreadById(SECRET).m == nil)
  PromptPeonDB.hiddenThreads[SECRET] = nil
  drainSend()
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = {
    { id = SECRET, p = "Shop", t = "Secret", s = "done", u = time(), hd = true, df = { { "a.txt", 1, 0, "+private", true } } },
  }, pk = {} })
  ns:RefreshAndRender()
  stub.timers = {}
  check("a row the companion app hid is scrubbed too", ns.loaded[SECRET] == nil)

  -- An agent that keeps starting and stopping can't flood you.
  local FIRST_NEW, SECOND_NEW = "eeeeeeee-0000-0000-0000-00000000000e", "ffffffff-0000-0000-0000-00000000000f"
  local chatBefore = #stub.chat
  local function flap(status)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 5
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = SECOND_NEW, p = "Shop", t = "Flappy", s = status, u = time(), a = "Thinking", m = { { "a", "words", "d", 1 } } } }, pk = {} })
    ns.lastRefresh = 0
    ns:RefreshAndRender()
    stub.timers = {}
  end
  for _ = 1, 5 do flap("running"); flap("done") end
  local reports = 0
  for index = chatBefore + 1, #stub.chat do
    if stub.chat[index]:find("finished", 1, true) then reports = reports + 1 end
  end
  check("five quick finishes make one report", reports == 1, reports)
  PromptPeonDB.tracked[SECOND_NEW] = nil

  -- A long list in a message doesn't freeze the log.
  local manyLines = { "- item" }
  for index = 2, 32000 do manyLines[index] = "  more" end
  local started = os.clock()
  ns.Markdown.Blocks(table.concat(manyLines, "\n"))
  check("32,000 indented lines parse quickly", os.clock() - started < 1, os.clock() - started)

  -- WoW Forever's docs say UnitName can be secret, and addon code can't pass a secret on.
  do
    local realName, realSecret = UnitName, _G.issecretvalue
    ns.playerName = nil
    UnitName = function() return "Hero" end
    _G.issecretvalue = function(value) return value == "SECRET" end
    check("the name is kept at login", ns:PlayerName() == "Hero", ns:PlayerName())
    UnitName = function() return "SECRET" end
    check("a secret name never gets used", ns:PlayerName() == "Hero", ns:PlayerName())
    ns.playerName = nil
    check("with none kept, there's no name", ns:PlayerName() == nil)
    local saves = 0
    local realSave = C_AddOns.SaveAddOns
    C_AddOns.SaveAddOns = function() saves = saves + 1 end
    ns:WriteFrame(nil)
    check("and nothing gets written", saves == 0, saves)
    C_AddOns.SaveAddOns = realSave
    UnitName, _G.issecretvalue = realName, realSecret
    ns.playerName = nil
  end

  -- A second WoW account on this install can land on a number the first one used.
  drainSend()
  local nextBefore = PromptPeonDB.nextSeq
  PromptPeonDB.pending = { { seq = nextBefore, thread = MENU_THREAD, text = "from the second account", at = time(), tries = 0 } }
  PromptPeonDB.nextSeq = nextBefore + 1
  PromptPeonDB.results = {}
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = nextBefore, at = ctlStamp, res = { [tostring(nextBefore)] = "sent" }, rc = { [tostring(nextBefore)] = ns.Crc32(MENU_THREAD .. "\0from the first account") % 4294967296 }, threads = {}, pk = {} })
  ns:RefreshAndRender()
  stub.timers = {}
  check("another account's result doesn't consume your message", #PromptPeonDB.pending == 1 and PromptPeonDB.pending[1].text == "from the second account", #PromptPeonDB.pending)
  check("it goes again under a new number", PromptPeonDB.pending[1].seq > nextBefore, PromptPeonDB.pending[1].seq)
  check("and nothing says it was sent", PromptPeonDB.results[MENU_THREAD] == nil)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  local newSeq = PromptPeonDB.pending[1].seq
  stub.slotData = snapshot({ ack = newSeq, at = ctlStamp, res = { [tostring(newSeq)] = "sent" }, rc = { [tostring(newSeq)] = ns.Crc32(MENU_THREAD .. "\0from the second account") % 4294967296 }, threads = {}, pk = {} })
  ns:RefreshAndRender()
  stub.timers = {}
  check("its own result clears it", #PromptPeonDB.pending == 0, #PromptPeonDB.pending)
  -- The same words to a different thread are a different message. Turn in sends the same word every time.
  PromptPeonDB.pending = { { seq = PromptPeonDB.nextSeq, thread = SECOND_NEW, text = "continue", at = time(), tries = 0 } }
  local sameWords = PromptPeonDB.nextSeq
  PromptPeonDB.nextSeq = sameWords + 1
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = sameWords, at = ctlStamp, res = { [tostring(sameWords)] = "sent" }, rc = { [tostring(sameWords)] = ns.Crc32(FIRST_NEW .. "\0continue") % 4294967296 }, threads = {}, pk = {} })
  ns:RefreshAndRender()
  stub.timers = {}
  check("the same words to another thread aren't mistaken for yours", #PromptPeonDB.pending == 1 and PromptPeonDB.pending[1].seq > sameWords, #PromptPeonDB.pending)
  PromptPeonDB.pending = {}

  -- Snoozing from the game.
  menuThread("done")
  check("an open thread can be snoozed", UI3.snoozeButton.shown and UI3.snoozeButton.label == "Snooze")
  UI3.snoozeButton.scripts.OnClick(UI3.snoozeButton)
  check("it offers times", menuItem("For 1 hour") and menuItem("Until tomorrow morning") and menuItem("Until Monday morning"))
  local before = time()
  menuItem("For 1 hour").scripts.OnClick(menuItem("For 1 hour"))
  local snoozeSent = PromptPeonDB.pending[#PromptPeonDB.pending].text
  local until1 = tonumber(snoozeSent:match("^\1snooze\n(%d+)$"))
  check("it sends the time", until1 and until1 >= before + 3599 and until1 <= time() + 3601, snoozeSent)
  drainSend()
  menuThread("needs")
  check("not while it's waiting on you, T3 refuses that", not UI3.snoozeButton.shown)
  menuThread("done")
  local monday = UI3.SnoozeChoices(os.time({ year = 2026, month = 11, day = 2, hour = 12 }))[4][2] -- A Monday.
  check("Monday morning from a Monday is next week", os.date("%Y-%m-%d %H", monday) == "2026-11-09 08", os.date("%Y-%m-%d %H", monday))
  local tomorrow = UI3.SnoozeChoices(os.time({ year = 2026, month = 12, day = 31, hour = 12 }))[3][2]
  check("tomorrow crosses the year", os.date("%Y-%m-%d %H", tomorrow) == "2027-01-01 08", os.date("%Y-%m-%d %H", tomorrow))

  -- Refresh speed, from Options.
  check("20 seconds until you pick", ns:RefreshSeconds() == 20 and PromptPeonDB.refreshSeconds == nil, ns:RefreshSeconds())
  UI3:ToggleOptions()
  local refreshSlider = UI3.optionsPage.sliders.Refresh
  refreshSlider.bar.scripts.OnValueChanged(refreshSlider.bar, 10)
  check("the slider sets it", PromptPeonDB.refreshSeconds == 10 and ns:RefreshSeconds() == 10, PromptPeonDB.refreshSeconds)
  check("and says what a reload costs", refreshSlider.text.text:find("10 s", 1, true) and refreshSlider.text.text:find("apart", 1, true), refreshSlider.text.text)
  PromptPeonDB.refreshSeconds = 1
  check("never faster than 10 seconds, because Blizzard's rules name loading from disk", ns:RefreshSeconds() == 10, ns:RefreshSeconds())
  PromptPeonDB.refreshSeconds = 10
  local slotBefore, lastBefore = ns.nextSlot, ns.lastRefresh
  ns.lastRefresh = GetTime() - 9
  ns:Tick()
  check("9 seconds in, nothing loads", ns.nextSlot == slotBefore, ns.nextSlot)
  ns.lastRefresh = GetTime() - 11
  ns:Tick()
  stub.timers = {}
  check("11 seconds in, it does", ns.nextSlot > slotBefore, ns.nextSlot)
  PromptPeonDB.refreshSeconds = nil
  UI3:ToggleOptions()
  ns.lastRefresh = lastBefore
end parkedAndMarks() end

local box2 = ns.UI.input.EditBox
box2:SetText("my draft for this thread")
ns.UI:ProjectMenu(ns.UI.frame, "Other")
menuItem("New thread here").scripts.OnClick(menuItem("New thread here"))
local function pageHead(text)
  for _, head in ipairs(ns.UI.heads) do
    if head.shown and head.text.text:find(text, 1, true) then return head end
  end
end
check("it opens as a page in the log", ns.UI.title.text == "New thread" and box2:GetText() == "", ns.UI.title.text)
check("for the project you asked from", pageHead("Project").text.text:find("Other", 1, true), pageHead("Project") and pageHead("Project").text.text)
check("the model starts as the open thread's", ns.UI.modelChip.shown and ns.UI.modelChip.text == "Opus 5.5" and ns.UI.effortChip.text == "Extra High", ns.UI.modelChip.text)
check("the hint says what the box is for", ns.UI.hint.text:find("new thread do", 1, true), ns.UI.hint.text)
check("it starts out asking first, and says so", pageHead("Approvals") and pageHead("Approvals").text.text:find("Supervised", 1, true) and lineWith("It asks before commands"))
check("your draft is safe", PromptPeonDB.drafts[MENU_THREAD] == "my draft for this thread", PromptPeonDB.drafts[MENU_THREAD])
pageHead("Project").scripts.OnClick(pageHead("Project"))
check("the project can be changed", menuItem("Shop") and menuItem("Other").text.text:find("UI-CheckBox-Check", 1, true))
menuItem("Shop").scripts.OnClick(menuItem("Shop"))
check("and it shows", pageHead("Project").text.text:find("Shop", 1, true))
ns.UI.modelChip.scripts.OnClick(ns.UI.modelChip)
menuItem("Other providers >").scripts.OnClick(menuItem("Other providers >"))
menuItem("Codex >").scripts.OnClick(menuItem("Codex >"))
menuItem("GPT-6 Astra").scripts.OnClick(menuItem("GPT-6 Astra"))
check("so can the model, by the box", ns.UI.modelChip.text == "GPT-6 Astra" and ns.UI.effortChip.text == "Low", ns.UI.effortChip.text)
ns.UI.effortChip.scripts.OnClick(ns.UI.effortChip)
menuItem("Ultra").scripts.OnClick(menuItem("Ultra"))
check("and the effort", ns.UI.effortChip.text == "Ultra", ns.UI.effortChip.text)
ns.UI:Send()
check("sending nothing asks for words, and sends nothing", #PromptPeonDB.pending == 0 and ns.UI.title.text == "New thread")
box2:SetText("fix the login page")
ns.UI:Send()
sentCommand = PromptPeonDB.pending[1]
check("sending starts it with what you picked", sentCommand and sentCommand.thread == "new-thread" and sentCommand.text == "\1newm\napproval-required\nShop\ncodex\ngpt-6-astra\nultra\nfix the login page", sentCommand and sentCommand.text)
check("your draft comes back", box2:GetText() == "my draft for this thread" and ns.UI.title.text == "Menu", box2:GetText())
local failedNew = sentCommand.seq
drainSend()
box2:SetText("")
PromptPeonDB.drafts = {}
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = failedNew, at = ctlStamp, md = CATALOG, res = { [tostring(failedNew)] = "failed: T3 doesn't offer that" }, threads = { { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), mi = "claudeAgent", mo = "claude-opus-5-5", m = {} } } })
ns:RefreshAndRender()
stub.timers = {}
check("a thread that didn't start gives your words back", box2:GetText() == "fix the login page", box2:GetText())
box2:SetText("")
PromptPeonDB.drafts, PromptPeonDB.results = {}, {}
menuThread("done")
ns.UI:StartNewThread()
box2:SetText("half written")
ns.UI.back.scripts.OnClick(ns.UI.back)
check("Back leaves the page", ns.UI.title.text == "Menu" and ns.UI.newThread == nil, ns.UI.title.text)
ns.UI:StartNewThread()
check("what you had written is still there next time", box2:GetText() == "half written", box2:GetText())
PromptPeonDB.selected = THREAD
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, md = CATALOG })
ns:RefreshAndRender()
stub.timers = {}
check("opening another thread leaves the page too", ns.UI.newThread == nil and ns.UI.title.text ~= "New thread", ns.UI.title.text)
ns.UI.newThreadWords = nil
box2:SetText("")
do
  -- Approvals on the New thread page, the way a player gets there.
  local MODES = {
    CATALOG[1],
    { i = "pi", n = "Pi", rm = { "approval-required", "full-access" }, m = { { "pi-1", "Pi One", "", {}, {}, "" } } },
  }
  local function served(fullAccess)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, md = MODES, fa = fullAccess, pj = { "Shop", "Other" }, threads = {
      { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), mi = "claudeAgent", mo = "claude-opus-5-5", ef = "xhigh", m = { { "a", "words", "d", 1 } } },
    } })
    PromptPeonDB.selected = MENU_THREAD
    ns:RefreshAndRender()
    stub.timers = {}
  end
  local function openApprovals()
    local head = pageHead("Approvals")
    head.scripts.OnClick(head)
  end
  local function pick(words) menuItem(words).scripts.OnClick(menuItem(words)) end
  local function lastSent() return PromptPeonDB.pending[#PromptPeonDB.pending].text end

  PromptPeonDB.newMode = nil
  served(nil)
  ns.UI:StartNewThread()
  check("with nothing picked it shows the mode that asks", pageHead("Approvals").text.text:find("Supervised", 1, true) and lineWith("It asks before commands"))
  openApprovals()
  check("the modes that ask can be picked", menuItem("Supervised") and menuItem("Auto-accept edits"))
  check("a no at install shows the others as off", menuItem("Auto (off)|r") and menuItem("Full access (off)|r"))
  pick("Full access (off)|r")
  check("clicking one says how to turn it on, and picks nothing", ns.UI.notice.text:find("installer", 1, true) and PromptPeonDB.newMode == nil and pageHead("Approvals").text.text:find("Supervised", 1, true), ns.UI.notice.text)
  openApprovals()
  pick("Auto-accept edits")
  check("a mode that asks about the rest can be picked with a no", pageHead("Approvals").text.text:find("Auto-accept edits", 1, true) and lineWith("makes edits by itself"))

  served(true)
  openApprovals()
  check("a yes at install offers every mode, with your pick ticked", menuItem("Auto") and menuItem("Full access") and menuItem("Auto-accept edits").text.text:find("UI-CheckBox-Check", 1, true))
  pick("Full access")
  check("picking one shows it and says what it means", pageHead("Approvals").text.text:find("Full access", 1, true) and lineWith("without asking"))
  box2:SetText("fix the login page")
  ns.UI:Send()
  check("sending carries it, with the model", lastSent() == "\1newm\nfull-access\nShop\nclaudeAgent\nclaude-opus-5-5\nxhigh\nfix the login page", lastSent())
  check("chat says what it will do", stub.chat[#stub.chat]:find("without asking", 1, true), stub.chat[#stub.chat])
  drainSend()

  served(true)
  press.startThread("Shop", "tidy up")
  check("your pick is remembered, for /peon new too", lastSent() == "\1new\nfull-access\nShop\ntidy up", lastSent())
  check("and it says so", stub.chat[#stub.chat]:find("without asking", 1, true), stub.chat[#stub.chat])
  drainSend()

  PromptPeonDB.newMode = "auto"
  served(true)
  ns.UI:StartNewThread()
  check("your pick holds while the provider has it", pageHead("Approvals").text.text:find("Auto", 1, true))
  ns.UI.modelChip.scripts.OnClick(ns.UI.modelChip)
  pick("Other providers >")
  pick("Pi >")
  pick("Pi One")
  check("a provider without your pick shows what will really happen", pageHead("Approvals").text.text:find("Supervised", 1, true), pageHead("Approvals").text.text)
  openApprovals()
  check("and only lists what it has", menuItem("Full access") and menuItem("Supervised") and not menuItem("Auto") and not menuItem("Auto-accept edits"))
  ns.UI:CloseMenu()
  box2:SetText("fix it")
  ns.UI:Send()
  check("so what goes out is the mode that asks", lastSent() == "\1newm\napproval-required\nShop\npi\npi-1\n\nfix it", lastSent())
  drainSend()

  PromptPeonDB.newMode = "full-access"
  served(nil)
  press.startThread("Shop", "tidy up")
  check("a pick the installer has since turned off goes back to asking, and says so", lastSent() == "\1new\napproval-required\nShop\ntidy up" and stub.chat[#stub.chat]:find("It asks before commands", 1, true), lastSent())
  check("your pick stays for when it's back on", PromptPeonDB.newMode == "full-access")
  drainSend()

  PromptPeonDB.newMode = nil
  PromptPeonDB.drafts, PromptPeonDB.results = {}, {}
  ns.UI.newThreadWords = nil
  box2:SetText("")
end
do
  -- The command typed into the box stays ours. It once started a real agent run.
  menuThread("done")
  ns.UI:StartNewThread()
  local before = #PromptPeonDB.pending
  box2:SetText("  /T3 ")
  ns.UI:Send()
  check("the command on the New thread page starts nothing", #PromptPeonDB.pending == before, #PromptPeonDB.pending)
  check("and it leaves that page", ns.UI.newThread == nil and ns.UI.newThreadWords == nil)
  check("and the command is gone from the box", box2:GetText() == "", box2:GetText())
  if not ns.UI:IsOpen() then ns.UI:Toggle() end
  box2:SetText("/peon")
  ns.UI:Send()
  check("the command in the reply box isn't sent to the agent", #PromptPeonDB.pending == before, #PromptPeonDB.pending)
  check("it closes the log instead", not ns.UI:IsOpen())
  ns.UI:Toggle()
  box2:SetText("/peon is broken, please look")
  ns.UI:Send()
  check("a sentence that starts with /peon is still a message", #PromptPeonDB.pending == before + 1 and PromptPeonDB.pending[#PromptPeonDB.pending].text == "/peon is broken, please look")
  drainSend()
  local count = #PromptPeonDB.pending
  box2:SetText("/peon away\nand here is why")
  ns.UI:Send()
  check("so is more than one line", #PromptPeonDB.pending == count + 1, #PromptPeonDB.pending)
  drainSend()
  box2:SetText("/review this please")
  ns.UI:Send()
  check("other slash words still reach the agent", PromptPeonDB.pending[#PromptPeonDB.pending].text == "/review this please", #PromptPeonDB.pending)
  drainSend()
  box2:SetText("")
  ns.UI.newButton.scripts.OnClick(ns.UI.newButton)
  check("the plus button opens the New thread page", ns.UI.newThread ~= nil and ns.UI.title.text == "New thread", ns.UI.title.text)
  ns.UI.newButton.scripts.OnClick(ns.UI.newButton)
  check("and pressing it again closes it", ns.UI.newThread == nil and ns.UI.title.text ~= "New thread", ns.UI.title.text)
  ns.UI.newThreadWords = nil
  box2:SetText("")

  -- T3 can diff a thread whose recent window shows no changed files.
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, md = CATALOG, threads = { { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), cd = true, mi = "x", mo = "y", m = {} } } })
  ns:RefreshAndRender()
  stub.timers = {}
  PromptPeonDB.selected = MENU_THREAD
  ns.UI:Render()
  check("a thread T3 can diff keeps its Changes button", ns.UI.changes.shown and ns.UI.changes.label == "Changes", ns.UI.changes.label)
end
PromptPeonDB.drafts = {}
ns.UI:StartNewThread()
stub.timers = {}
check("the New thread button opens the page", ns.UI.newThread ~= nil)
ns.UI:StopNewThread()
ns.UI.newThreadWords = nil
ns.UI:Render()

end

-- WoW's own collapse buttons in the thread list.
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = { { id = THREAD, p = "Shop", t = "In the list", s = "done", u = time() } } })
ns:RefreshAndRender()
stub.timers = {}
local projectRow, threadInList
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.project == "Shop" then projectRow = row end
  if row.shown and row.thread and row.thread.id == THREAD then threadInList = row end
end
check("an open project shows WoW's minus", projectRow.fold.shown and projectRow.fold.texture:find("UI-MinusButton-Up", 1, true))
check("no typed mark is left", not projectRow.text.text:find("^[-+] "), projectRow.text.text)
check("a thread row has no button", not threadInList.fold.shown)
PromptPeonDB.collapsed.Shop = true
ns.UI:Render()
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.project == "Shop" then projectRow = row end
end
check("a closed project shows WoW's plus", projectRow.fold.texture:find("UI-PlusButton-Up", 1, true))
PromptPeonDB.collapsed.Shop = nil
ctlStamp = ctlStamp + 1
stub.now = stub.now + 100
stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp })
ns:RefreshAndRender()
stub.timers = {}

-- The thread list can be dragged wider or thinner.
check("the list starts thin", ns.UI.ListWidth() == 200, ns.UI.ListWidth())
local edge = ns.UI.listEdge
edge.scripts.OnMouseDown(edge)
stub.cursorX = 330
edge.scripts.OnUpdate(edge)
check("dragging resizes it", ns.UI.listScroll.width and math.abs(ns.UI.listScroll.width - ns.UI.ListWidth()) < 1 and ns.UI.ListWidth() ~= 200, ns.UI.ListWidth())
check("and it is remembered", PromptPeonDB.listWidth == ns.UI.ListWidth())
stub.cursorX = -500
edge.scripts.OnUpdate(edge)
check("it can't vanish", ns.UI.ListWidth() == 120, ns.UI.ListWidth())
stub.cursorX = 99999
edge.scripts.OnUpdate(edge)
check("it can't squash the thread", ns.UI.frame:GetWidth() - ns.UI.ListWidth() >= 300, ns.UI.ListWidth())
edge.scripts.OnMouseUp(edge)
local widthWas = ns.UI.ListWidth()
stub.cursorX = 300
edge.scripts.OnUpdate(edge)
check("letting go stops it", ns.UI.ListWidth() == widthWas)
PromptPeonDB.listWidth = nil
ns.UI:ApplyLayout()

-- The window can get small, and smaller still without the list.
local window = ns.UI.frame
local widthBefore, heightBefore = window:GetSize()
check("with the list it keeps room for both", ns.UI.minWidth == 200 + 26 + 300, ns.UI.minWidth)
ns.UI:ToggleList()
check("without the list it can get really small", ns.UI.minWidth == 300, ns.UI.minWidth)
window:SetSize(300, 240)
window.scripts.OnSizeChanged(window)
check("a small window keeps its spells and drops the reload estimate", not ns.UI.reloadHint.shown and Game.spellBar.buttons[2].shown)
check("and Send gets narrower", ns.UI.send.width == 60, ns.UI.send.width)
check("the reply box gives up some room", ns.UI.holder.height == 40, ns.UI.holder.height)
check("the cogwheel and Send stay", ns.UI.options.shown and ns.UI.send.shown)
ns.UI:ToggleList()
check("bringing the list back makes room for it", window:GetWidth() == 526 and PromptPeonDB.width == 526, window:GetWidth())
window:SetSize(widthBefore, heightBefore)
window.scripts.OnSizeChanged(window)
check("a big window gets everything back", ns.UI.reloadHint.shown and ns.UI.holder.height == 64 and ns.UI.send.width == 90)
check("the reload estimate is always there in a big window", ns.UI.reloadHint.shown)

-- Hover.
local tips = 0
local realAdd = GameTooltip.AddLine
GameTooltip.AddLine = function() tips = tips + 1 end
for _, row in ipairs(ns.UI.rows) do
  if row.shown and row.thread then listRow = row end
end
listRow.scripts.OnEnter(listRow)
check("hovering a thread shows a tooltip", tips >= 2, tips)
GameTooltip.AddLine = realAdd

-- The reply box only keeps the keyboard while you are in it.
local replyBox = ns.UI.input.EditBox
replyBox:SetFocus()
stub.mouseOver = true
stub.fire("GLOBAL_MOUSE_DOWN")
check("clicking inside the box keeps the keyboard", replyBox:HasFocus())
stub.mouseOver = false
stub.fire("GLOBAL_MOUSE_DOWN")
check("clicking anywhere else lets it go", not replyBox:HasFocus())
stub.fire("GLOBAL_MOUSE_DOWN")
check("and clicking with no focus does nothing", not replyBox:HasFocus())

-- Drafts survive thread switches.
ns.UI.input.EditBox:SetText("half a thought")
ns.UI:SaveDraft()
check("draft saved", PromptPeonDB.drafts[PromptPeonDB.selected] == "half a thought")

-- Rules that must agree: the reply box, spell numbers, a failed start and a new thread's model.
do
  local box = ns.UI.input.EditBox
  local PARKED = "bbbbbbbb-0000-4000-8000-000000000000"
  local MENU_THREAD = "77777777-0000-0000-0000-000000000007"
  local function threeThreads(extra)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    local data = { ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, pj = { "Shop" }, threads = {
      { id = MENU_THREAD, p = "Shop", t = "Menu", s = "done", u = time(), mi = "open-i", mo = "open-model", ef = "low", m = { { "a", "hi" } } },
      { id = OTHER, p = "Shop", t = "Other", s = "done", u = time() - 5, m = { { "a", "hi" } } },
    }, pk = { { id = PARKED, p = "Shop", t = "Parked", s = "done", u = time() - 9, pk = "s" } } }
    for key, value in pairs(extra or {}) do data[key] = value end
    stub.slotData = snapshot(data)
    PromptPeonDB.selected = MENU_THREAD
    ns:RefreshAndRender()
    stub.timers = {}
  end
  threeThreads()
  PromptPeonDB.drafts, PromptPeonDB.results = {}, {}
  ns.UI.newThreadWords = nil
  box:SetText("")

  ns.UI:StartNewThread()
  local before = #PromptPeonDB.pending
  box:SetText("/peon")
  ns.UI:Send()
  check("the command in the box starts no thread", #PromptPeonDB.pending == before, #PromptPeonDB.pending)
  check("it clears the box instead", box:GetText() == "", box:GetText())
  ns.UI:StopNewThread()

  local function failLast(words)
    local entry = PromptPeonDB.pending[#PromptPeonDB.pending]
    drainSend()
    PromptPeonDB.drafts, PromptPeonDB.results = {}, {}
    threeThreads({ ack = entry.seq, res = { [tostring(entry.seq)] = "failed: there is no project called Shop" } })
    return PromptPeonDB.drafts[MENU_THREAD]
  end
  press.startThread("Shop", "fix the login page")
  check("a failed start gives your words back", failLast() == "fix the login page", PromptPeonDB.drafts[MENU_THREAD])
  PromptPeonDB.drafts = {}
  box:SetText("")
  ns:QueueCommand("new-thread", "new", "approval-required\nShop\nline one\nline two")
  check("all of them, on every line", failLast() == "line one\nline two", PromptPeonDB.drafts[MENU_THREAD])
  PromptPeonDB.drafts = {}
  box:SetText("")

  threeThreads({ pm = { { "Shop", "project-i", "project-model", "high" }, { "Bare", "bare-i", "bare-model", "" } } })
  ns.UI:StartNewThread("Shop")
  check("the page uses the companion app's choice for the project", ns.UI.newThread.instance == "project-i"
    and ns.UI.newThread.model == "project-model" and ns.UI.newThread.effort == "high", ns.UI.newThread.model)
  ns.UI:StopNewThread()
  ns.UI:StartNewThread("Bare")
  check("no effort means none", ns.UI.newThread.model == "bare-model" and ns.UI.newThread.effort == nil, ns.UI.newThread.effort)
  ns.UI:StopNewThread()
  ns.UI:StartNewThread("Nowhere")
  check("a project it doesn't list falls back to the open thread", ns.UI.newThread.model == "open-model", ns.UI.newThread.model)
  ns.UI:StopNewThread()
  ns.UI.newThreadWords = nil
  box:SetText("")
end

-- Thread text stays out until you trust your addons. Status keeps working.
do
  local WORDS = "Deadly Boss Mods and 99 more aren't trusted yet, so thread text stays out of the game."
  local function rows()
    return { { id = THREAD, p = "Shop", t = "A secret-free name", s = "needs", u = time(), hd = true },
             { id = OTHER, p = "Shop", t = "Another", s = "running", a = "Working", u = time() - 5, hd = true } }
  end
  local function arrive(extra)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    local data = { ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = rows(), pk = {} }
    for key, value in pairs(extra or {}) do data[key] = value end
    stub.slotData = snapshot(data)
    PromptPeonDB.selected = THREAD
    ns:RefreshAndRender()
    stub.timers = {}
  end
  local function chatCount(words)
    local count = 0
    for _, line in ipairs(stub.chat) do
      if tostring(line):find(words, 1, true) then count = count + 1 end
    end
    return count
  end
  PromptPeonDB.pending, PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenProjects = {}, {}, {}
  local pendingBefore = #PromptPeonDB.pending
  arrive({ lk = WORDS })
  check("the open thread says why its words aren't there", lineWith("Deadly Boss Mods and 99 more"))
  check("not that you hid it", not lineWith("This thread is hidden"))
  check("the tracker still counts them", PromptPeonTracker.text.text:find("1 working", 1, true), PromptPeonTracker.text.text)
  check("it doesn't go asking for the words", #PromptPeonDB.pending == pendingBefore, #PromptPeonDB.pending)
  check("they aren't filed under Hidden", not ns:IsHidden(ns:ThreadById(THREAD)))
  check("chat says it once", chatCount("Deadly Boss Mods") == 1, chatCount("Deadly Boss Mods"))
  arrive({ lk = WORDS })
  check("and not on every refresh", chatCount("Deadly Boss Mods") == 1, chatCount("Deadly Boss Mods"))
  arrive({ threads = { { id = THREAD, p = "Shop", t = "A secret-free name", s = "done", u = time(), m = { { "a", "the words are back" } } } } })
  check("saying yes brings them back", lineWith("the words are back"))

  -- A newer release is mentioned in the main chat, once. The update itself stays something you run.
  local UPDATE = "Prompt Peon 9.9.9 is out. Close WoW, then double-click install.cmd in %LOCALAPPDATA%\\prompt-peon."
  PromptPeonDB.chatNewsOff = true
  arrive({ up = UPDATE })
  PromptPeonDB.chatNewsOff = nil
  check("chat says a new version is out, even with news off", chatCount(UPDATE) == 1, chatCount("9.9.9"))
  arrive({ up = UPDATE })
  check("and not on every refresh", chatCount(UPDATE) == 1, chatCount("9.9.9"))
  arrive({ up = "Prompt Peon 9.9.10 is out. |cffff0000Close|r WoW." })
  check("a newer one is told about too, and it can't color chat", chatCount("Prompt Peon 9.9.10 is out. ||cffff0000Close||r WoW.") == 1)

  -- A message that couldn't go before the game closed is told about once, and only once.
  PromptPeonDB.clearedAt = nil
  arrive({ clr = { n = 2, at = 12345 } })
  check("chat says messages were lost", chatCount("2 messages you sent") == 1, chatCount("2 messages you sent"))
  arrive({ clr = { n = 2, at = 12345 } })
  check("once", chatCount("2 messages you sent") == 1)
  arrive({ clr = { n = 1, at = 12399 } })
  check("and one reads right", chatCount("A message you sent") == 1)
end

-- A first run that just works.
do
  local LATER = "cccccccc-0000-4000-8000-000000000000"
  local function arrive(threads, extra)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    local data = { ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads, pk = {} }
    for key, value in pairs(extra or {}) do data[key] = value end
    stub.slotData = snapshot(data)
    PromptPeonDB.selected = threads[1] and threads[1].id
    ns:RefreshAndRender()
    stub.timers = {}
  end
  local function seven()
    local rows = {}
    for number = 1, 7 do
      rows[number] = { id = "first-" .. number, p = "Shop", t = "Quest " .. number, s = number == 1 and "needs" or "done", u = time() - number, m = { { "a", "hi" } } }
    end
    return rows
  end

  -- The tracker on a new install.
  PromptPeonDB.tracked, PromptPeonDB.firstTracked = {}, nil
  arrive(seven())
  local tracked = 0
  for number = 1, 7 do if PromptPeonDB.tracked["first-" .. number] then tracked = tracked + 1 end end
  check("a new install tracks its first five quests", tracked == 5 and PromptPeonDB.tracked["first-1"] and not PromptPeonDB.tracked["first-6"], tracked)
  PromptPeonDB.tracked["first-2"] = false
  arrive(seven())
  check("once, and what you untrack stays untracked", PromptPeonDB.tracked["first-2"] == false and not PromptPeonDB.tracked["first-6"])
  PromptPeonDB.tracked, PromptPeonDB.firstTracked = { [LATER] = true }, nil
  arrive(seven())
  check("an install already in use is left alone", not PromptPeonDB.tracked["first-3"])
  PromptPeonDB.tracked, PromptPeonDB.firstTracked = {}, nil
  PromptPeonDB.hiddenThreads = { ["first-1"] = true }
  arrive(seven())
  check("a hidden thread isn't tracked", not PromptPeonDB.tracked["first-1"] and PromptPeonDB.tracked["first-6"])
  PromptPeonDB.hiddenThreads = {}

  -- Party frames.
  PromptPeonDB.partyOn = true
  press.party()
  check("off stays off, instead of falling back to the default", PromptPeonDB.partyOn == false, tostring(PromptPeonDB.partyOn))
  press.party()

  -- Back, always at the top.
  local rows = seven()
  arrive(rows)
  local ui = ns.UI
  check("no Back on the thread itself", not ui.back.shown)
  ui:ToggleOptions()
  check("Options has Back", ui.back.shown and ui.back.text == "Back", ui.back.text)
  check("the title makes room for it", ui.title.lastPoint ~= nil)
  check("nothing below moves over, so it makes no column", ui.meta.lastPoint[2] == ui.back, tostring(ui.meta.lastPoint[2]))
  check("the old button is gone", ui.optionsPage.backToThread == nil)
  ui.back.scripts.OnClick(ui.back)
  check("Back leaves Options", not ui.showOptions and not ui.back.shown)
  check("and the line under the title goes back under it", ui.meta.lastPoint[2] == ui.title, tostring(ui.meta.lastPoint[2]))
  ui.showAchievements = true
  ui:Render()
  check("Achievements has Back", ui.back.shown)
  ui.back.scripts.OnClick(ui.back)
  check("Back leaves Achievements", not ui.showAchievements and not ui.back.shown)
  ui:StartNewThread("Shop")
  check("the New thread page has Back", ui.back.shown)
  ui.back.scripts.OnClick(ui.back)
  check("Back leaves the New thread page", ui.newThread == nil and not ui.back.shown)
  local id = rows[1].id
  ui.views[id] = "changes"
  ui:Render()
  check("a thread's Changes has Back", ui.back.shown)
  ui.back.scripts.OnClick(ui.back)
  check("Back returns to the thread", ui.views[id] == nil and not ui.back.shown)
  ui.views[id], ui.prOpen[id] = "prs", 1
  ui:Render()
  ui.back.scripts.OnClick(ui.back)
  check("Back goes up one level at a time", ui.views[id] == "prs" and ui.prOpen[id] == nil)
  ui.back.scripts.OnClick(ui.back)
  check("and then back to the thread", ui.views[id] == nil)
  ui.showAchievements = true
  ui:Render()
  ui:OpenThread(rows[2].id)
  check("opening a thread leaves the page it was on", not ui.showAchievements and not ui.back.shown and PromptPeonDB.selected == rows[2].id)
  ui.showReport = true
  ui:OpenThread(rows[1].id)
  check("that goes for What happened too", not ui.showReport)

  -- Thinking stays out of the way.
  local function working(extra)
    local row = { id = id, p = "Shop", t = "Busy", s = "running", a = "Thinking", u = time(), m = {
      { "u", "please fix it" }, { "t", "A long private thought", "d", 11 }, { "s", "Ran the tests", "d", 12 } } }
    for key, value in pairs(extra or {}) do row[key] = value end
    return row
  end
  ui.groups = {}
  arrive({ working() })
  check("thinking is folded while it works", not lineWith("A long private thought"))
  check("the steps still show", lineWith("Ran the tests"))
  local foldHead
  for _, head in ipairs(ui.heads) do
    if head.shown and tostring(head.text.text):find("1 thought", 1, true) then foldHead = head end
  end
  check("the group says it's there", foldHead ~= nil)
  foldHead.scripts.OnClick(foldHead)
  check("one click opens it", lineWith("A long private thought"))
  foldHead.scripts.OnClick(foldHead)
  check("another closes it all", not lineWith("A long private thought") and not lineWith("Ran the tests"))
  ui.groups = {}

  -- Steering answers at once.
  local RUN = "run:thread:abc:ordinal:7"
  local function queuedRow()
    return working({ m = { { "u", "please fix it" }, { "u", "do this next", "q", 9, RUN } } })
  end
  local function steerButton()
    for _, button in ipairs(ui.queueButtons or {}) do
      if button.shown and button.label == "Steer" then return button end
    end
  end
  arrive({ queuedRow() })
  local slotBefore = ns.nextSlot
  local steer = steerButton()
  check("a queued message offers Steer", steer ~= nil)
  steer.scripts.OnClick(steer)
  check("the row changes at once", lineWith("Steering it in now"))
  check("with no refresh spent yet", ns.nextSlot == slotBefore, ns.nextSlot - slotBefore)
  check("it can't be clicked twice", steerButton() == nil)
  do
    -- A failed steer can report back right after a reload, before the log has been built.
    local steering, pending = ns.UI.steering, PromptPeonDB.pending
    ns.UI.steering = nil
    PromptPeonDB.pending = { { seq = 9000, thread = "steered", text = "\1steer\nrun-1\nrun-2", command = "steer" } }
    local worked = pcall(ns.ApplyAcks, ns, { ack = 9000, res = { ["9000"] = "failed: too late" } })
    check("a failed steer arriving before the log exists breaks nothing", worked)
    ns.UI.steering, PromptPeonDB.pending = steering, pending
  end
  check("it really went", PromptPeonDB.pending[#PromptPeonDB.pending].command == "steer")
  local steerEntry = PromptPeonDB.pending[#PromptPeonDB.pending]
  drainSend()
  arrive({ queuedRow() }, { ack = steerEntry.seq, res = { [tostring(steerEntry.seq)] = "sent" } })
  check("if T3's answer never comes, the buttons come back in the end", steerButton() ~= nil)
  ui.steering[RUN] = GetTime()
  ui:Render()
  check("until then it still says so", lineWith("Steering it in now"))
  local spent = ns.nextSlot
  ctlStamp = ctlStamp + 1
  stub.slotData = snapshot({ ack = steerEntry.seq, at = ctlStamp, threads = { working() }, pk = {} })
  ns:UpdateNow()
  check("an update gets spent early to show it", ns.nextSlot == spent + 1, ns.nextSlot - spent)
  check("and the row is gone once it isn't queued", not lineWith("do this next"))
  ui.steering = {}
  arrive({ queuedRow() })
  steer = steerButton()
  steer.scripts.OnClick(steer)
  local failing = PromptPeonDB.pending[#PromptPeonDB.pending]
  drainSend()
  arrive({ queuedRow() }, { ack = failing.seq, res = { [tostring(failing.seq)] = "failed: it isn't working right now" } })
  check("if it fails the buttons come back", steerButton() ~= nil and not lineWith("Steering it in now"))
  PromptPeonDB.results = {}
  ui.steering = {}
  PromptPeonDB.selected = nil
end

-- A new thread shows up in the list the moment you start it.
do
  local ui = ns.UI
  local REAL = "dddddddd-0000-4000-8000-000000000000"
  local function arrive(threads, extra)
    ctlStamp = ctlStamp + 1
    local data = { ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads, pk = {}, pj = { "Shop" } }
    for key, value in pairs(extra or {}) do data[key] = value end
    stub.slotData = snapshot(data)
    ns:Refresh()
    ui:Render()
  end
  local function listRow(words)
    for _, row in ipairs(ui.rows) do
      if row.shown and tostring(row.text.text):find(words, 1, true) then return row end
    end
  end
  local open = { id = THREAD, p = "Shop", t = "Open one", s = "done", u = time(), m = { { "a", "hi" } } }
  PromptPeonDB.pending, PromptPeonDB.drafts, PromptPeonDB.results = {}, {}, {}
  PromptPeonDB.selected = THREAD
  stub.now = stub.now + 100
  arrive({ open })
  ui:Toggle()
  if not ui:IsOpen() then ui:Toggle() end
  local slots = ns.nextSlot
  press.startThread("shop", "fix the login page")
  local row = listRow("fix the login page")
  check("a new thread is in the list at once", row ~= nil)
  check("under the project's real name", row and row.thread.p == "Shop", row and row.thread.p)
  check("with no refresh spent on it", ns.nextSlot == slots, ns.nextSlot - slots)
  local selectedBefore = PromptPeonDB.selected
  row.scripts.OnClick(row, "LeftButton")
  check("clicking it changes nothing yet", PromptPeonDB.selected == selectedBefore)
  row.scripts.OnClick(row, "RightButton")
  check("and it has no menu to act on a thread that isn't there", row.thread.starting == true)
  local entry = PromptPeonDB.pending[#PromptPeonDB.pending]
  check("it really went", entry.command == "new")
  drainSend()
  stub.timers = {}
  arrive({ open }, { ack = entry.seq, res = { [tostring(entry.seq)] = "sent" } })
  check("it stays until T3's row arrives", listRow("fix the login page") ~= nil)
  local early
  for _, timer in ipairs(stub.timers) do early = early or timer end
  check("an update is spent early to fetch it", early ~= nil)
  stub.timers = {}
  ctlStamp = ctlStamp + 1
  local real = { id = REAL, p = "Shop", t = "Login page", s = "running", u = time(), m = {} }
  stub.slotData = snapshot({ ack = entry.seq, at = ctlStamp, threads = { real, open }, pk = {} })
  local spent = ns.nextSlot
  ns:UpdateNow()
  check("which spends one", ns.nextSlot == spent + 1, ns.nextSlot - spent)
  check("T3's own row takes over", listRow("Login page") ~= nil and listRow("fix the login page") == nil)

  press.startThread("Shop", "this one will fail")
  entry = PromptPeonDB.pending[#PromptPeonDB.pending]
  drainSend()
  stub.timers = {}
  PromptPeonDB.drafts = {}
  arrive({ real, open }, { ack = entry.seq, res = { [tostring(entry.seq)] = "failed: T3 said no" } })
  check("a start that failed leaves the list", listRow("this one will fail") == nil)
  check("and gives your words back", PromptPeonDB.drafts[PromptPeonDB.selected] == "this one will fail", PromptPeonDB.drafts[PromptPeonDB.selected])
  PromptPeonDB.drafts, PromptPeonDB.results = {}, {}

  press.startThread("Shop", "nothing ever comes back")
  check("it's there", listRow("nothing ever comes back") ~= nil)
  entry = PromptPeonDB.pending[#PromptPeonDB.pending]
  drainSend()
  stub.timers = {}
  stub.now = stub.now + 100
  arrive({ real, open }, { ack = entry.seq, res = { [tostring(entry.seq)] = "sent" } })
  stub.timers = {}
  check("if T3's row never arrives it goes away in the end", listRow("nothing ever comes back") == nil)
  PromptPeonDB.results = {}
  PromptPeonDB.selected = nil
end

-- The quest sound on a finished thread is off unless you want it. The peon says it anyway.
do
  local QUEST = SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE
  local function played(sound)
    for _, id in ipairs(stub.played) do if id == sound then return true end end
    return false
  end
  local thread = { id = "sound-test", p = "Shop", t = "Sounds", s = "done", u = time() }
  stub.played = {}
  PromptPeonDB.questSound = nil
  ns:QuestFeel(thread)
  check("no quest sound by default", not played(QUEST))
  check("the peon still says work complete", #stub.played > 0, #stub.played)
  stub.played = {}
  PromptPeonDB.questSound = true
  ns:QuestFeel(thread)
  check("Options can turn it on", played(QUEST))
  PromptPeonDB.questSound = nil
  stub.played = {}
  PromptPeonDB.peonQuiet = true
  ns:QuestFeel({ id = "sound-test-2", p = "Shop", t = "Sounds", s = "error", u = time() })
  check("a failed thread keeps its sound, or it would be silent", played(SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST))
  PromptPeonDB.peonQuiet = nil
end

-- The quest tracker is an option too, and turning it off doesn't stop the alerts.
do
  local ui = ns.UI
  ui.showOptions = nil
  ui:ToggleOptions()
  local box = ui.optionsPage.checks.tracker
  check("Options has the quest tracker", box ~= nil)
  check("on by default", box.get() == true and PromptPeonTracker.shown)
  box.box.checked = false
  box.box.scripts.OnClick(box.box)
  check("unticking hides it", PromptPeonDB.trackerOff == true and not PromptPeonTracker.shown)
  ui:Render()
  check("and it stays hidden", not PromptPeonTracker.shown)
  box.box.checked = true
  box.box.scripts.OnClick(box.box)
  check("ticking brings it back", PromptPeonDB.trackerOff == nil and PromptPeonTracker.shown)
  ui:ToggleOptions()
end

-- Your side's workers: peons for the Horde, peasants for the Alliance, or whichever you pick.
do
  local WORK, READY = 6197, 6290
  local function says(line)
    stub.played, ns.voiceAt = {}, nil
    ns:PeonSays(line)
    return stub.played[1]
  end
  PromptPeonDB.workers = nil
  stub.faction = "Horde"
  check("the Horde gets peons", ns:WorkerKind() == "peon" and says("work") == WORK)
  stub.faction = "Alliance"
  check("the Alliance gets peasants", ns:WorkerKind() == "peasant" and says("work") == READY)
  check("every line a peon has, a peasant has", says("complete") == 6284 and says("needs") == 6287 and says("more") == 6288)
  stub.played = {}
  ns.Game.pokes, ns.Game.lastPoke, ns.Game.nextLine = nil, nil, nil
  ns.Game:Poke()
  check("poking one gets a peasant's answer", stub.played[1] == 6289, stub.played[1])
  check("with a peasant's face", ns.UI.FaceFor({ id = "nobody" }) == 301)
  PromptPeonDB.workers, PromptPeonDB.faces = "peon", {}
  check("you can pick the other side", PromptPeonDB.workers == "peon" and says("work") == WORK)
  check("and its face", ns.UI.FaceFor({ id = "nobody" }) == 10038)
  PromptPeonDB.workers, PromptPeonDB.faces = nil, {}
  check("or go back to your character's", PromptPeonDB.workers == nil and ns:WorkerKind() == "peasant")
  stub.faction = nil
  ns.UI.showOptions = nil
  ns.UI:ToggleOptions()
  local choice = ns.UI.optionsPage.workers
  check("Options says whose voices they are", choice.text and choice.text:find("Voices: Orc (your side)", 1, true), tostring(choice.text))
  choice.scripts.OnClick(choice)
  ns.UI:SyncOptions()
  check("and pressing it picks them", PromptPeonDB.workers == "peon" and choice.text == "Voices: Orc", tostring(choice.text))
  choice.scripts.OnClick(choice)
  ns.UI:SyncOptions()
  check("then the others", PromptPeonDB.workers == "peasant" and choice.text == "Voices: Human", tostring(choice.text))
  choice.scripts.OnClick(choice)
  ns.UI:SyncOptions()
  check("then the undead", PromptPeonDB.workers == "undead" and choice.text == "Voices: Undead", tostring(choice.text))
  choice.scripts.OnClick(choice)
  check("then your side again", PromptPeonDB.workers == nil)
  stub.race = "Scourge"
  check("a Forsaken gets the undead by itself", ns:WorkerKind() == "undead" and says("work") == 6259)
  local realSecret = _G.issecretvalue
  _G.issecretvalue = function(value) return value == "Scourge" end
  check("a race WoW hides from addons is never compared", ns:WorkerKind() == "peon", ns:WorkerKind())
  _G.issecretvalue = realSecret
  stub.race = nil
  PromptPeonDB.workers, PromptPeonDB.faces = "undead", {}
  check("/peon workers undead picks them", PromptPeonDB.workers == "undead" and ns.UI.FaceFor({ id = "nobody" }) == 137)
  PromptPeonDB.workers, PromptPeonDB.faces = nil, {}
  -- Turning in says goodbye, in everyone's own voice.
  local function bye(kind)
    PromptPeonDB.workers = kind
    stub.played, ns.voiceAt = {}, nil
    PromptPeonDB.stats.turnedIn = 0 -- So no achievement's fanfare plays first.
    ns:Settle({ id = "ffffffff-1111-4000-8000-000000000000", t = "Done", p = "Shop", s = "done" })
    drainSend()
    stub.timers = {}
    PromptPeonDB.pending = {}
    return stub.played[1]
  end
  check("a peon says okie dokie", bye("peon") == 6294, bye("peon"))
  check("a peasant says off I go", bye("peasant") == 6286)
  check("the undead get the last word", bye("undead") == 6260)
  PromptPeonDB.workers = nil
  ns.UI:ToggleOptions()

  -- Veteran agents can wear the game's rare and elite dragons, but only if the player asks for them.
  local holder = CreateFrame("Frame")
  local row = { rank = holder:CreateTexture(), level = holder:CreateFontString(), face = holder:CreateTexture() }
  check("a new install hasn't chosen dragons", PromptPeonDB.eliteFrames == nil)
  ns.UI.ShowRank(row, 10)
  check("even level 10 has no dragon until you ask", not row.rank.shown)
  ns.UI:SyncOptions()
  local eliteBox = ns.UI.optionsPage.checks.elite.box
  check("Options shows Elite frames as off", eliteBox.checked == false)
  eliteBox.checked = true
  eliteBox.scripts.OnClick(eliteBox)
  check("ticking Elite frames turns them on", PromptPeonDB.eliteFrames == true)
  ns.UI.ShowRank(row, 4)
  check("below level 5 there's no dragon", not row.rank.shown)
  ns.UI.ShowRank(row, 5)
  check("level 5 is silver", row.rank.shown and row.rank.texture:find("Rare", 1, true), tostring(row.rank.texture))
  ns.UI.ShowRank(row, 9)
  check("still silver at 9", row.rank.texture:find("Rare", 1, true))
  ns.UI.ShowRank(row, 10)
  check("level 10 is gold", row.rank.shown and row.rank.texture:find("Elite", 1, true), tostring(row.rank.texture))
  eliteBox.checked = false
  eliteBox.scripts.OnClick(eliteBox)
  check("unticking leaves nothing saved", PromptPeonDB.eliteFrames == nil)
  ns.UI.ShowRank(row, 10)
  check("and the dragon is gone again", not row.rank.shown)

  -- The spell bar never loses spells to a narrow window.
  local ui, Game = ns.UI, ns.Game
  local widthBefore = ui.frame:GetWidth()
  ui.frame:SetWidth(1400)
  ui:FitToSize()
  check("in a wide window the spells share the bottom row", (ui.spellLift or 0) == 0, ui.spellLift)
  local function shownSpells()
    local count = 0
    for _, button in ipairs(Game.spellBar.buttons) do if button.shown then count = count + 1 end end
    return count
  end
  local wide = shownSpells()
  local listWas = PromptPeonDB.listHidden
  PromptPeonDB.listHidden = true
  ui.modelChip:Show()
  ui.effortChip:Show()
  ui.frame:SetWidth(300)
  ui:ApplyLayout()
  check("in a narrow one they get their own row", ui.spellLift > 0, ui.spellLift)
  check("with every spell still there", shownSpells() == wide, shownSpells())
  check("and the reply box moves up for them", ui.holder.lastPoint[5] == 40 + ui.spellLift, ui.holder.lastPoint[5])
  PromptPeonDB.listHidden = listWas
  ui.frame:SetWidth(1400)
  ui:ApplyLayout()
  check("back in a wide window they go back", ui.spellLift == 0, ui.spellLift)
  check("on the game's own action bar art", Game.spellBar.stone[1].texture:find("UI-MainMenuBar", 1, true))
  ui.frame:SetWidth(widthBefore)
  ui:FitToSize()
end

-- Respecting the meme.
do
  local ui, Game = ns.UI, ns.Game
  local ID, ID2 = "eeeeeeee-0000-4000-8000-000000000000", "ffffffff-0000-4000-8000-000000000000"
  local function row(extra)
    local data = { id = ID, p = "Shop", t = "Mage", s = "running", u = time(), as = time() - 30, m = { { "a", "hi", "d", 1 } } }
    for key, value in pairs(extra or {}) do data[key] = value end
    return data
  end
  local function arrive(threads)
    ctlStamp = ctlStamp + 1
    stub.now = stub.now + 100
    stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, threads = threads, pk = {} })
    PromptPeonDB.selected = threads[1].id
    ns:RefreshAndRender()
    stub.timers = {}
  end
  PromptPeonDB.workers = "peon"
  PromptPeonDB.peonQuiet = nil
  Game.seeded = true
  Game.calledForMana = {}
  PromptPeonDB.pending, PromptPeonDB.hiddenThreads, PromptPeonDB.hiddenProjects = {}, {}, {}
  arrive({ row({ cu = 50 }) })
  stub.played, stub.errors = {}, {}
  arrive({ row({ cu = 85 }) })
  local playedMana = false
  for _, sound in ipairs(stub.played) do playedMana = playedMana or sound == 541247 end
  check("low mana is said out loud", playedMana)
  check("with the game's red error", stub.errors[1] and stub.errors[1]:find("Not enough mana: Mage", 1, true), stub.errors[1])
  stub.errors = {}
  arrive({ row({ cu = 90 }) })
  check("once", #stub.errors == 0)
  arrive({ row({ cu = 20 }) })
  stub.errors = {}
  arrive({ row({ cu = 85 }) })
  check("a compact fills it up, so it can run dry again", stub.errors[1] ~= nil)
  check("Evocation is the way to compact", press.spell("evocation").prompt == "/compact")
  PromptPeonDB.workers = "peasant"
  Game.calledForMana = {}
  stub.played = {}
  arrive({ row({ cu = 85 }) })
  playedMana = false
  for _, sound in ipairs(stub.played) do playedMana = playedMana or sound == 540801 end
  check("a peasant asks in his own voice", playedMana)
  PromptPeonDB.workers = nil

  arrive({ row() })
  stub.errors = {}
  arrive({ row({ s = "stopped" }) })
  check("stopping one says Interrupted", stub.errors[1] == "Interrupted", stub.errors[1])

  local refused, reason = ns:Enqueue(ID, string.rep("x", ns.MAX_REPLY_BYTES + 1))
  check("too long means full bags", refused == nil and reason:find("bags are full", 1, true) and reason:find("bytes", 1, true), reason)
  ns.snapshot.err = "Can't reach T3 at http://mac:3773."
  check("offline means too far away", ns:Problem():find("You are too far away!", 1, true), ns:Problem())
  ns.snapshot.err = ""

  local function activity(extra)
    arrive({ row(extra) })
    ui:DrawActivity()
    return ui.activity.text
  end
  check("a short wait is just working", not activity({ a = "Thinking" }):find("MORE DOTS", 1, true))
  check("a long one wants more dots", activity({ a = "Thinking", as = time() - 700 }):find("MORE DOTS", 1, true))
  check("a long search has lost Mankrik's wife", activity({ a = "Searching files", as = time() - 200 }):find("Mankrik's wife", 1, true))
  check("a short one hasn't", not activity({ a = "Searching files", as = time() - 20 }):find("Mankrik", 1, true))
  check("three queued is Barrens chat", activity({ qc = 3 }):find("Barrens chat: 3 messages queued", 1, true))
  check("two isn't", not activity({ qc = 2 }):find("Barrens", 1, true))

  local dead = row({ s = "error" })
  arrive({ dead })
  local shown
  local realShow = StaticPopup_Show
  StaticPopup_Show = function(_, name) shown = name end
  PromptPeonDB.corpseRuns = {}
  PromptPeonDB.spellsNoAsk = nil
  Game:Resurrect(dead)
  check("the first resurrect is just a resurrect", not shown:find("corpse run", 1, true), shown)
  PromptPeonDB.corpseRuns[ID] = 2
  Game:Resurrect(dead)
  check("the third is a corpse run", shown:find("corpse run #3", 1, true), shown)
  StaticPopup_Show = realShow
  Game:OnFinished(row({ s = "done" }))
  check("finishing ends the walking", PromptPeonDB.corpseRuns[ID] == nil)

  local chat = #stub.chat
  Game:DropLoot(row({ s = "done" }), { 3, 9000, 8000, 7 })
  check("a legendary drop gets the question", chatHas("Did someone say", chat + 1))
  chat = #stub.chat
  Game:DropLoot(row({ s = "done" }), { 1, 5, 0, 8 })
  check("a small one doesn't", not chatHas("Did someone say", chat + 1))

  arrive({ row({ id = ID, s = "needs" }), row({ id = ID2, t = "Other", s = "needs" }) })
  check("need counts who's waiting", tostring(ui.needIcon.count.text) == "2", tostring(ui.needIcon.count.text))
  ui:NextRoll("need")
  check("clicking need goes to the next one", PromptPeonDB.selected == ID2, PromptPeonDB.selected)
  ui:NextRoll("need")
  check("and around again", PromptPeonDB.selected == ID, PromptPeonDB.selected)
  ctlStamp = ctlStamp + 1
  stub.now = stub.now + 100
  PromptPeonDB.seen[ID2] = -1
  stub.slotData = snapshot({ ack = PromptPeonDB.nextSeq - 1, at = ctlStamp, pk = {}, threads = { row({ id = ID, s = "running" }), row({ id = ID2, t = "Other", s = "done", u = time() + 500, m = { { "a", "fresh", "d", 99 } } }) } })
  ns:RefreshAndRender()
  stub.timers = {}
  check("greed counts unread finished work", #ui.Rolls("greed") == 1 and ui.Rolls("greed")[1].id == ID2, #ui.Rolls("greed"))
  check("nobody waiting means no need", #ui.Rolls("need") == 0)
  PromptPeonDB.selected = nil
  PromptPeonDB.results = {}
  stub.errors = {}
end

-- A hostile snapshot written by the real bridge serializer stays data.
if arg and arg[1] then
  PROMPTPEON_SNAPSHOT = nil
  PWNED = nil
  local chunk = assert(loadfile(arg[1]))
  chunk()
  local hostile = PROMPTPEON_SNAPSHOT
  check("hostile snapshot parses", type(hostile) == "table" and hostile.v == 1)
  check("hostile text ran no code", PWNED == nil)
  local row = hostile.threads[1]
  check("hostile title survives byte for byte", row.t == [[x"]]..[[ PWNED=1 --]], row.t)
  check("hostile message survives", row.m[1][2]:find("]] PWNED=1 --", 1, true), row.m[1][2])
  check("newlines stay newlines", row.m[2][2] == "line one\nline two", row.m[2][2])
  check("pipes stay until drawn", row.m[3][2]:find("|Hitem:1|h", 1, true), row.m[3][2])
  check("drawing escapes them", ns.Plain(row.m[3][2]):find("||Hitem:1||h", 1, true))
  check("utf-8 survives", row.m[4][2] == "Sven zegt: één café", row.m[4][2])
end

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
