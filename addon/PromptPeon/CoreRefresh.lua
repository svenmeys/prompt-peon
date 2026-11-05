-- Refresh: spends refresh slots at a pace that makes them last, and says when the budget or the
-- bridge is running out. Each load re-reads Snapshot.lua, so it's the only way new data gets in.

local addonName, ns = ...

--- Counts for the tracker, in display order.
function ns:Counts()
  local counts = { needs = 0, running = 0, error = 0, total = 0 }
  for _, thread in ipairs(self:VisibleThreads()) do
    counts.total = counts.total + 1
    if counts[thread.s] then counts[thread.s] = counts[thread.s] + 1 end
  end
  return counts
end

--- The one line telling the player whether to trust what they see. Nil means healthy.
function ns:Problem()
  local snapshot = self.snapshot
  if not snapshot then
    return "No data from the companion app yet. Is it running on this machine?"
  end
  if self.liveProblem then return self.liveProblem end
  if self.nextSlot > 1 and self.snapshotAge > self.BRIDGE_QUIET_AFTER then
    return "The companion app has gone quiet, so this list may be old. Is it still running on this machine?"
  end
  if snapshot.err and snapshot.err ~= "" then
    local since = snapshot.errAt and snapshot.errAt > 0 and (" (since " .. self.Ago(time() - snapshot.errAt) .. ")") or ""
    local far = snapshot.err:find("^Can't reach") and "You are too far away! " or ""
    return far .. self.Plain(snapshot.err) .. since .. " Showing the last threads we saw."
  end
  return nil
end

-- From here on the log offers the reload, and from the second one chat says so too.
ns.RELOAD_SOON = 30 * 60
ns.RELOAD_WARN = 10 * 60

--- Seconds between updates when nothing is being waited for. Depends on the log and on the agents.
function ns:RefreshWait()
  local pace = self:RefreshSeconds()
  if self.UI and self.UI:IsOpen() then return pace end
  local counts = self:Counts()
  -- Half again as slow with the log closed: 20 open is 30 closed.
  if counts.running + counts.needs > 0 then return math.ceil(pace * self.REFRESH_WATCHING / self.REFRESH_OPEN) end
  return self.REFRESH_CLOSED
end

--- Live updates left, and how long they last from here. Every update spent takes one wait off, so a
--- burst of clicks costs what it really costs and isn't assumed to go on for hours.
function ns:ReloadIn()
  local left = math.max(0, self.SLOT_COUNT - self.nextSlot + 1)
  return left * self:RefreshWait(), left
end

--- How often the log refreshes while open, from Options. Each one loads a file from disk, and Blizzard's
--- addon rules name "unnecessary loading from the hard disk", so 10 seconds is as fast as this goes.
function ns:RefreshSeconds()
  local chosen = self.db and tonumber(self.db.refreshSeconds)
  if not chosen then return self.REFRESH_OPEN end
  return math.max(10, math.min(60, chosen))
end

--- "about 2 hours", for a sentence.
function ns.AboutTime(seconds)
  if seconds < 60 then return "under a minute" end
  if seconds < 3600 then
    local minutes = math.ceil(seconds / 60)
    return "about " .. minutes .. (minutes == 1 and " minute" or " minutes")
  end
  local hours = math.floor(seconds / 3600 + 0.5)
  return "about " .. hours .. (hours == 1 and " hour" or " hours")
end

--- "~2h", for a small space.
function ns.ShortTime(seconds)
  if seconds < 60 then return "<1m" end
  if seconds < 3600 then return "~" .. math.ceil(seconds / 60) .. "m" end
  return "~" .. math.floor(seconds / 3600 + 0.5) .. "h"
end

--- With the log closed nothing else tells you, so say it in chat. Once each.
function ns:WarnAboutReload()
  if not self.Chat then return end
  local seconds, left = self:ReloadIn()
  if left == 0 and not self.warnedStopped then
    self.warnedStopped = true
    self.Chat:ReportReload("Live updates have stopped. Press Reload UI in the log when it suits you, and they start again.")
  elseif left > 0 and seconds <= self.RELOAD_WARN and not self.warnedSoon then
    self.warnedSoon = true
    self.Chat:ReportReload(self.AboutTime(seconds) .. " of live updates left. Press Reload UI in the log when it suits you.")
  end
end

--- Whether the one action that needs a loading screen is worth offering.
function ns:NeedsReload()
  if self.liveProblem then return true end
  if self:ReloadIn() <= self.RELOAD_SOON then return true end
  local first = self.db and self.db.pending[1]
  return first ~= nil and first.stuck == true
end

--- Spend one slot to re-read Snapshot.lua. Slots only come back with a reload.
function ns:Refresh()
  if self.nextSlot > self.SLOT_COUNT then
    self.liveProblem = "Live updates have stopped. Press Reload UI to start them again."
    self:WarnAboutReload()
    return false
  end
  local name = string.format("%sIn%03d", addonName, self.nextSlot)
  self.nextSlot = self.nextSlot + 1
  self.lastRefresh = GetTime()
  self:WarnAboutReload()
  local started = debugprofilestop()
  local loaded, reason = C_AddOns.LoadAddOn(name)
  self.lastLoadMs = debugprofilestop() - started
  if not loaded then
    self.loadFailures = self.loadFailures + 1
    -- A few misses can be one disabled slot. Repeated misses mean this client will not do it.
    if self.loadFailures >= 3 then
      self.liveProblem = "Live refresh is not working (" .. tostring(reason)
        .. "). Press Reload UI to update, and keep the Prompt Peon internals enabled in the addon list."
    end
    return false
  end
  self.loadFailures = 0
  self.liveProblem = nil
  return self:Ingest()
end

--- Runs every 5 seconds and decides whether this moment is worth a slot.
function ns:Tick()
  if InCombatLockdown() then return end
  if self.liveProblem then
    -- Another addon can use up a few helpers, so don't give up for good. Try once a minute.
    if self.nextSlot <= self.SLOT_COUNT and GetTime() - self.lastRefresh >= 60 then self:RefreshAndRender() end
    return
  end
  local wait = self:RefreshWait()
  if self.UI and self.UI:IsOpen() and self.UI:IsLoading(self:ThreadById(self.db.selected)) then wait = 5 end
  -- Just logged in: the real one is on its way. If the companion app isn't running it never comes,
  -- so hurry for a minute at most, or that alone would use up every update in about 80 minutes.
  if self.snapshot and self.snapshot.quiet and self.nextSlot <= self.QUIET_RUSH_SLOTS then wait = 5 end
  if GetTime() - self.lastRefresh < wait then return end
  self:RefreshAndRender()
end

function ns:RefreshAndRender()
  -- Slots are a budget, so opening and closing the log quickly must not spend them.
  if self.lastRefresh == 0 or GetTime() - self.lastRefresh >= 5 then
    self:Refresh()
  end
  if self.UI then self.UI:Render() end
end
