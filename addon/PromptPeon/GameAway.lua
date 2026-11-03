-- Away: what's unread, and the report on what happened while you were in a dungeon, logged out,
-- or had the log closed. Also where each new snapshot reaches the game side.

local _, ns = ...
local Game = ns.Game

-- --- What happened while you were away --------------------------------------------

local AWAY_DUNGEON = 5 * 60 -- Seconds. Shorter than this is not worth a report.
local AWAY_CLOSED = 10 * 60
local RANK = { needs = 1, error = 2, done = 3, running = 4 }

local function newestAgentRow(thread)
  local rows = thread.m or {}
  for index = #rows, 1, -1 do
    if rows[index][1] == "a" then return rows[index] end
  end
end

local function newestOrder(thread)
  local row = newestAgentRow(thread)
  return row and row[4] or 0
end

--- News in a thread you have not looked at since. New threads count once the session has begun.
function Game.IsUnread(thread)
  return newestOrder(thread) > (ns.db.seen[thread.id] or 0)
end

function Game:MarkSeen(thread)
  ns.db.seen[thread.id] = math.max(newestOrder(thread), ns.db.seen[thread.id] or 0)
end

--- Each new snapshot passes through here on the game side.
function Game:OnSnapshot(snapshot)
  for _, thread in ipairs(snapshot.threads) do
    -- The first look only sets the starting line, or everything old would read as news.
    if ns.db.seen[thread.id] == nil then ns.db.seen[thread.id] = self.seeded and 0 or newestOrder(thread) end
  end
  self:CheckLoot(snapshot)
  self:CheckMana(snapshot)
  local working = 0
  for _, thread in ipairs(snapshot.threads) do
    if thread.s == "running" then working = working + 1 end
  end
  if working >= 5 then self:Earn("raid") end
  self.seeded = true
  if self.reportWhenFresh and (snapshot.at or 0) >= self.reportWhenFresh then
    self.reportWhenFresh = nil
    self:FinishAway()
  end
end

--- Note where every thread stands, so the report can say what moved.
function Game:BeginAway(kind, place)
  if ns.db.away then return end
  local base = {}
  for _, thread in ipairs(ns.snapshot and ns.snapshot.threads or {}) do
    base[thread.id] = { s = thread.s, o = newestOrder(thread), t = thread.tn or 0, c = thread.lc and thread.lc[4] or 0 }
  end
  ns.db.away = { kind = kind, place = place, since = time(), base = base, loot = {} }
end

--- Wait for news from after you came back. The snapshot in hand can be older than that.
function Game:EndAway()
  if not ns.db.away or self.reportWhenFresh then return end
  self.reportWhenFresh = time()
  if not InCombatLockdown() then ns:RefreshAndRender() end
end

local function awayTitle(away)
  if away.kind == "dungeon" then return "While you were in " .. ns.Plain(away.place or "that dungeon") end
  if away.kind == "offline" then return "While you were logged out" end
  return "While you were out questing"
end

Game.NO_REPORT = "Nothing to report yet. One appears after you've been away: 10 minutes with the log closed, a dungeon, or logging out."

--- Compares where each thread is now with where it stood when you left.
function Game.BuildReport(away, threads, now)
  local report = { title = awayTitle(away), minutes = math.floor((now - away.since) / 60), entries = {}, loot = away.loot or {} }
  local counts = { done = 0, needs = 0, error = 0, running = 0 }
  local messages, turns, added, removed, files = 0, 0, 0, 0, 0
  for _, thread in ipairs(threads) do
    local base = away.base[thread.id]
    local fresh = 0
    for _, row in ipairs(thread.m or {}) do
      if row[1] == "a" and row[4] > (base and base.o or 0) then fresh = fresh + 1 end
    end
    local moved = not base or fresh > 0 or base.s ~= thread.s or thread.s == "needs"
    if moved and not ns:IsHidden(thread) then
      counts[thread.s] = (counts[thread.s] or 0) + 1
      messages = messages + fresh
      local newTurns = math.max((thread.tn or 0) - (base and base.t or 0), 0)
      turns = turns + newTurns
      local change = thread.lc and thread.lc[4] > (base and base.c or 0) and thread.lc or nil
      if change then
        files, added, removed = files + change[1], added + change[2], removed + change[3]
      end
      local row = newestAgentRow(thread)
      report.entries[#report.entries + 1] = {
        id = thread.id, p = thread.p, title = thread.t, s = thread.s, isNew = not base, fresh = fresh, turns = newTurns,
        gist = fresh > 0 and row and ns.UI and ns.UI.Gist(row[2]) or nil, change = change,
      }
    end
  end
  table.sort(report.entries, function(a, b)
    local rankA, rankB = RANK[a.s] or 9, RANK[b.s] or 9
    if rankA ~= rankB then return rankA < rankB end
    return a.fresh > b.fresh
  end)
  report.counts, report.messages, report.turns = counts, messages, turns
  report.added, report.removed, report.files = added, removed, files
  return report
end

--- One line of what happened: "2 finished, 1 needs you, 1 failed."
function Game.ReportHeadline(report)
  local parts, counts = {}, report.counts
  if counts.done > 0 then parts[#parts + 1] = counts.done .. " finished" end
  if counts.needs > 0 then parts[#parts + 1] = counts.needs .. (counts.needs == 1 and " needs you" or " need you") end
  if counts.error > 0 then parts[#parts + 1] = counts.error .. " failed" end
  if counts.running > 0 then parts[#parts + 1] = counts.running .. " still working" end
  if #parts == 0 then return "Nothing happened. Your peons slept." end
  return table.concat(parts, ", ") .. "."
end

--- Turns the absence into a report, if you were gone long enough and something moved.
function Game:FinishAway()
  local away = ns.db.away
  ns.db.away = nil
  if not away then return end
  local waited = time() - away.since
  if waited < (away.kind == "closed" and AWAY_CLOSED or AWAY_DUNGEON) then return end
  local report = Game.BuildReport(away, ns.snapshot and ns.snapshot.threads or {}, time())
  if #report.entries == 0 then return end
  self.report, self.reportFresh = report, true
  -- Kept for after a reload, but not the agents' words: those stay out of the saved file.
  local kept = {}
  for key, value in pairs(report) do kept[key] = value end
  kept.entries = {}
  for index, entry in ipairs(report.entries) do
    local plain = {}
    for key, value in pairs(entry) do plain[key] = value end
    plain.gist = nil
    kept.entries[index] = plain
  end
  ns.db.lastReport = kept
  local link = "|cffffd100|Haddon:peon:report|h[What happened]|h|r"
  if ns.Chat then ns.Chat:News(report.title .. ": " .. Game.ReportHeadline(report) .. " " .. link) end
  if PlaySound and SOUNDKIT and SOUNDKIT.TUTORIAL_POPUP then PlaySound(SOUNDKIT.TUTORIAL_POPUP) end
  if away.kind == "closed" and ns.UI then
    ns.UI.showReport = true
    ns.UI:Render()
  end
end

--- The last report, without anything you've hidden since.
function Game:CurrentReport()
  local report = self.report or ns.db.lastReport
  if not report then return nil end
  local shown = {}
  for _, entry in ipairs(report.entries or {}) do
    if not ns:IsHidden({ id = entry.id, p = entry.p }) then shown[#shown + 1] = entry end
  end
  report.entries = shown
  self.report = report
  return report
end

function Game:OpenReport()
  if not self:CurrentReport() then
    if ns.Chat then ns.Chat:ReportReload(Game.NO_REPORT) end
    return
  end
  self.reportFresh = nil
  if ns.UI.newThread then ns.UI:StopNewThread() end
  ns.UI.showReport, ns.UI.showOptions, ns.UI.showAchievements = true, nil, nil
  if ns.UI:IsOpen() then ns.UI:Render() else ns.UI:Toggle() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGOUT" then
    Game:BeginAway("offline")
    return
  end
  local inside = IsInInstance and IsInInstance()
  local away = ns.db.away
  if inside and not (away and away.kind == "dungeon") then
    -- An earlier absence ends where the dungeon starts, with nobody there to read it.
    ns.db.away = nil
    Game:BeginAway("dungeon", GetInstanceInfo and GetInstanceInfo() or nil)
  elseif not inside and away and away.kind ~= "closed" then
    Game:EndAway()
  end
end)
