-- Refresh: spends refresh slots at a pace that makes them last, and says when the budget or the
-- bridge is running out. Each load re-reads Snapshot.lua, so it's the only way new data gets in.
-- The update bell, further down, says when a load is worth it right now.

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
  return first ~= nil and (first.stuck == true or not self:CanSendSilently())
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

-- --- The update bell ----------------------------------------------------------------
-- An addon can't read a file, but it can play a sound and ask whether it is really playing, and an
-- empty file doesn't play. The companion app keeps one of eight silent sound files real: the one
-- for the count in the newest snapshot. So when the bell for the snapshot we have goes quiet,
-- a newer one is waiting, and it's worth a refresh now and not at the next tick. A ninth file is
-- always real, to tell "no news" from "the game's sound is off", where nothing plays at all.
-- Measured on WoW Forever, 2026-11-13. The companion app's side is bells.py.

ns.BELL_COUNT = 8 -- Keep equal to BELL_COUNT in the companion app.
local BELL_ANSWER = 0.2 -- Seconds between playing a sound and asking whether it plays.
local BELL_GAP = 2 -- Never refresh for the bell more often than this.
local BELL_FALSE_ALARMS = 3 -- After this many rings with no news behind them, stop listening.
local BELL_BUDGET, BELL_BUDGET_SECONDS = 20, 600 -- The most refreshes the bell may ask for, and over how long.

local function bellFile(name)
  return "Interface\\AddOns\\" .. addonName .. "\\bells\\" .. name .. ".wav"
end

local function playing(handle)
  if not handle then return false end
  local ok, is = pcall(C_Sound.IsPlaying, handle)
  pcall(StopSound, handle)
  return ok and is == true
end

--- Once a second: is the bell for the snapshot we have still ringing? Costs no refresh.
function ns:Listen()
  if self.hearing or self.bellBroken or not self.db or self.db.bellOff or InCombatLockdown() then return end
  local count = tonumber(self.snapshot and self.snapshot.sg)
  if not count or not (C_Sound and C_Sound.IsPlaying and PlaySoundFile and StopSound) then return end
  local okAlways, _, always = pcall(PlaySoundFile, bellFile("on"), "Master")
  local okBell, _, bell = pcall(PlaySoundFile, bellFile("b" .. (count % self.BELL_COUNT + 1)), "Master")
  self.hearing = true
  C_Timer.After(BELL_ANSWER, function()
    self.hearing = nil
    local hears, rings = playing(okAlways and always), playing(okBell and bell)
    self.bellWorks = hears
    if hears and not rings then self:HeardNews(count) end
  end)
end

--- The bell went quiet, so spend one refresh now. If the snapshot that loads is the one we had,
--- the bell lied, and a bell that keeps lying would use up every refresh, so it gets three tries.
function ns:HeardNews(count)
  if InCombatLockdown() or self.liveProblem or GetTime() - self.lastRefresh < BELL_GAP then return end
  -- Even true news is only worth so many refreshes. Agents flapping between states, or a server that
  -- wants to, would otherwise use them up far faster than the timer does. Past the budget the timer
  -- carries on as before.
  local now, spent = GetTime(), {}
  for _, at in ipairs(self.bellSpent or {}) do
    if now - at < BELL_BUDGET_SECONDS then spent[#spent + 1] = at end
  end
  self.bellSpent = spent
  if #spent >= BELL_BUDGET then return end
  spent[#spent + 1] = now
  self:Refresh()
  if tonumber(self.snapshot and self.snapshot.sg) == count then
    self.bellFalse = (self.bellFalse or 0) + 1
    if self.bellFalse >= BELL_FALSE_ALARMS then self.bellBroken = true end
  else
    self.bellFalse = 0
  end
  if self.UI then self.UI:Render() end
end

--- For the connection check: whether fast updates are working, in words.
function ns:BellWords()
  if self.db.bellOff then return "off. Turn them on in Options." end
  if self.bellBroken then return "off until you reload: the bell rang three times with no news behind it (false alarms)." end
  if not tonumber(self.snapshot and self.snapshot.sg) then return "off: this companion app is from before them. Run the installer again." end
  if self.bellWorks == false then return "off: the game can't hear the bell. Is game sound on?" end
  if self.bellWorks == nil then return "not heard yet. Ask again in a few seconds." end
  return "on. News shows within a second or two."
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
