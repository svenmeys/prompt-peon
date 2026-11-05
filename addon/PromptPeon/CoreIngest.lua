-- Ingest: reads each snapshot the bridge wrote, keeps what only rides along for a minute,
-- and applies the bridge's answers about what you sent. Also which threads you can see.

local _, ns = ...

--- Hidden threads stay in the log's Hidden section and nowhere else, so a screenshot is clean.
function ns:IsHidden(thread)
  return self.db.hiddenThreads[thread.id] == true or self.db.hiddenProjects[thread.p] == true
end

function ns:VisibleThreads()
  local out = {}
  for _, thread in ipairs(self.snapshot and self.snapshot.threads or {}) do
    if not self:IsHidden(thread) then out[#out + 1] = thread end
  end
  return out
end

--- Like quests: pin any thread. Working agents track themselves unless you untrack them.
function ns:IsTracked(thread)
  local choice = self.db.tracked[thread.id]
  if choice ~= nil then return choice end
  return thread.s == "running" or thread.s == "needs"
end

function ns:ToggleTracked(thread)
  self.db.tracked[thread.id] = not self:IsTracked(thread)
  if self.UI then self.UI:Render() end
end

--- What you hid goes from the game right away, not only from the next snapshot: its words, and any
--- diff or report you opened earlier. Its title and status stay, so you can find it to show it again.
function ns:ScrubHidden()
  if not self.db or not self.snapshot then return end
  for _, list in ipairs({ self.snapshot.threads or {}, self.snapshot.pk or {} }) do
    for _, thread in ipairs(list) do
      if thread.hd or self:IsHidden(thread) then
        self.loaded[thread.id] = nil
        thread.m, thread.ch, thread.ag, thread.df, thread.ax, thread.fp, thread.ob, thread.vm = nil, nil, nil, nil, nil, nil, nil, nil
        thread.prs, thread.pd = nil, nil
        if self.UI and self.UI.views then self.UI.views[thread.id] = nil end
      end
    end
  end
end

--- Snoozed and settled threads ride in their own list, so look there too.
function ns:ThreadById(id)
  for _, thread in ipairs(self.snapshot and self.snapshot.threads or {}) do
    if thread.id == id then return thread end
  end
  for _, thread in ipairs(self.snapshot and self.snapshot.pk or {}) do
    if thread.id == id then return thread end
  end
end

-- --- Reading the snapshot ----------------------------------------------------

--- Take whatever the last load left in the global. Anything unusable is ignored,
--- and the previous snapshot stays on screen rather than an empty log.
function ns:Ingest()
  local snapshot = _G.PROMPTPEON_SNAPSHOT
  _G.PROMPTPEON_SNAPSHOT = nil
  if type(snapshot) ~= "table" or snapshot.v ~= 1 or type(snapshot.threads) ~= "table" then
    return false
  end
  -- Older means a lower revision from the same bridge run. The clock can't say: it can move back.
  if self.snapshot and snapshot.sid and snapshot.sid == self.snapshot.sid and (snapshot.rv or 0) < (self.snapshot.rv or 0) then
    return false
  end
  -- The bridge lost T3 and has nothing to offer. Never let that read as an empty log.
  if self.snapshot and #snapshot.threads == 0 and (snapshot.err or "") ~= "" then
    snapshot.threads = self.snapshot.threads
    snapshot.pk = self.snapshot.pk
  end
  if type(snapshot.pk) ~= "table" then snapshot.pk = {} end
  local before = {}
  for _, thread in ipairs(self.snapshot and self.snapshot.threads or {}) do before[thread.id] = thread end
  self.snapshot = snapshot
  self.snapshotAge = time() - (snapshot.at or 0)
  -- Diffs and agent reports only ride along for a minute, so keep what arrives.
  local everything = {}
  for _, thread in ipairs(snapshot.threads) do everything[#everything + 1] = thread end
  for _, thread in ipairs(snapshot.pk) do
    everything[#everything + 1] = thread
    -- You just turned this in or snoozed it, so what it said is already here.
    local was = before[thread.id]
    if was and was.m and not thread.hd then
      local kept = self.loaded[thread.id] or {}
      kept.vm = was.m
      self.loaded[thread.id] = kept
    end
  end
  for _, thread in ipairs(everything) do
    if thread.df or thread.ax or thread.fp or thread.ob or thread.vm or thread.pd then
      local kept = self.loaded[thread.id] or {}
      if thread.pd then
        kept.pullRequests = kept.pullRequests or {}
        kept.pullRequests[thread.pd[1]] = thread.pd[2]
        thread.pd[2].at = GetTime()
      end
      if thread.vm then kept.vm = thread.vm end
      -- The same answer keeps riding along for a minute, so only take each one once.
      if thread.ob and kept.olderBefore ~= thread.oc then
        local merged = {}
        for _, row in ipairs(thread.ob) do merged[#merged + 1] = row end
        for _, row in ipairs(kept.older or {}) do merged[#merged + 1] = row end
        kept.older, kept.olderMore, kept.olderBefore = merged, thread.om, thread.oc
      end
      if thread.df then kept.df, kept.dn, kept.dp = thread.df, thread.dn, thread.dp end
      if thread.ax then kept.ax = thread.ax end
      if thread.fp then
        kept.pages = kept.pages or {}
        kept.pages[thread.fp[1] .. "\n" .. thread.fp[2]] = thread.fp
      end
      self.loaded[thread.id] = kept
    end
  end
  for _, thread in ipairs(snapshot.pk) do
    local kept = self.loaded[thread.id]
    if kept and kept.vm and not thread.hd then thread.m = kept.vm end
  end
  self:ScrubHidden()
  self:ApplyAcks(snapshot)
  -- The bridge cleared this when the game last closed. It says nothing about any thread.
  if snapshot.quiet then return true end
  if self.Chat and self.db then
    if snapshot.lk and snapshot.lk ~= self.withheldSaid then self.Chat:ReportReload(self.Plain(snapshot.lk)) end
    self.withheldSaid = snapshot.lk
    if snapshot.up and snapshot.up ~= self.updateSaid then self.Chat:ReportReload(self.Plain(snapshot.up)) end
    self.updateSaid = snapshot.up
    local cleared = snapshot.clr
    if cleared and cleared.at ~= self.db.clearedAt then
      self.db.clearedAt = cleared.at
      local who = cleared.n == 1 and "A message you sent" or (cleared.n .. " messages you sent")
      self.Chat:ReportReload(who .. " just before the game last closed didn't reach T3. Nothing you type stays on disk, so send again if you still need to.")
    end
  end
  if self.Game and self.db then self.Game:OnSnapshot(snapshot) end
  self:NoticeChanges(snapshot)
  return true
end

--- A new thread goes in the list the moment you start it. T3's own row takes over when it arrives.
function ns:ShowStarting(project, prompt)
  local known = {}
  for _, thread in ipairs(self.snapshot and self.snapshot.threads or {}) do known[thread.id] = true end
  for _, name in ipairs(self.snapshot and self.snapshot.pj or {}) do
    if name:lower() == project:lower() then project = name end
  end
  local seq = self.db.pending[#self.db.pending].seq
  self.starting[#self.starting + 1] = { id = "starting:" .. seq, seq = seq, p = project, t = prompt, s = "running",
    a = "Starting", starting = true, known = known, at = GetTime() }
end

--- The new thread didn't start, so its row shouldn't wait out the timer.
function ns:DropStarting(seq)
  for index, row in ipairs(self.starting) do
    if row.seq == seq then
      table.remove(self.starting, index)
      return
    end
  end
end

--- Each real thread that has appeared replaces one row, and a row nobody answered goes in the end.
function ns:SettleStarting(snapshot)
  local kept, taken = {}, {}
  for _, row in ipairs(self.starting) do
    local arrived = GetTime() - row.at >= self.STARTING_SHOWS_FOR
    for _, thread in ipairs(snapshot.threads) do
      if not arrived and thread.p == row.p and not row.known[thread.id] and not taken[thread.id] then
        taken[thread.id], arrived = true, true
      end
    end
    if not arrived then kept[#kept + 1] = row end
  end
  self.starting = kept
end

--- Remember where the thread stood when you sent this, so T3's own copy can be told from what was
--- already there. Rows are compared by number: T3 may show the words differently from how you typed them.
function ns:MarkSending(entry)
  local newest, queued, ahead = 0, 0, 0
  local thread = self:ThreadById(entry.thread)
  for _, row in ipairs(thread and thread.m or {}) do
    if row[1] == "u" and row[3] == "q" then
      queued = queued + 1
    elseif row[1] == "u" then
      newest = math.max(newest, tonumber(row[4]) or 0)
    end
  end
  for _, list in ipairs({ self.db.pending, self.sentShowing }) do
    for _, other in ipairs(list) do
      if other ~= entry and other.thread == entry.thread and not other.command then ahead = ahead + 1 end
    end
  end
  entry.after, entry.queuedBefore, entry.ahead = newest, queued, ahead
end

--- The companion app confirms a message before it has T3's copy of it. Yours stays until that copy
--- comes, and goes in the end if it never does. Only an update can change this, so it can't run out in a fight.
function ns:SettleSent()
  local kept = {}
  for _, entry in ipairs(self.sentShowing) do
    local thread = self:ThreadById(entry.thread)
    local newer, queued = 0, 0
    for _, row in ipairs(thread and thread.m or {}) do
      if row[1] == "u" and row[3] == "q" then
        queued = queued + 1
      elseif row[1] == "u" and (tonumber(row[4]) or 0) > (entry.after or math.huge) then
        newer = newer + 1
      end
    end
    local arrived = newer + math.max(0, queued - (entry.queuedBefore or 0)) > (entry.ahead or 0)
    if not arrived and GetTime() - entry.shownSince < self.STARTING_SHOWS_FOR then kept[#kept + 1] = entry end
  end
  self.sentShowing = kept
end

--- T3 has it, so spend one update now to show it, rather than leaving it to the next one.
function ns:UpdateNow()
  if InCombatLockdown() then return end
  self:Refresh()
  if self.UI then self.UI:Render() end
end

--- Read the bridge's answers: what went, what didn't, and what has to go again.
function ns:ApplyAcks(snapshot)
  local db = self.db
  if not db then return end
  local ack = tonumber(snapshot.ack) or 0
  if db.nextSeq <= ack then db.nextSeq = ack + 1 end -- Survives a deleted SavedVariables file.
  local kept = {}
  for _, entry in ipairs(db.pending) do
    local sum = snapshot.rc and tonumber(snapshot.rc[tostring(entry.seq)])
    if entry.seq > ack then
      kept[#kept + 1] = entry
    elseif sum and sum ~= self.Crc32(entry.thread .. "\0" .. entry.text) % 4294967296 then
      -- Another WoW account on this install used this number, so that result isn't ours.
      -- Nothing of ours went, so it goes again under a new number.
      if self.tx and self.tx.entry == entry then self.tx = nil end
      entry.seq, entry.tries = db.nextSeq, 0
      db.nextSeq = db.nextSeq + 1
      kept[#kept + 1] = entry
    else
      -- No outcome means we don't know, and "we don't know" must never read as "sent".
      local result = snapshot.res and snapshot.res[tostring(entry.seq)]
        or "unknown: the companion app no longer has this result. Check the thread in T3."
      -- A command that worked has nothing to say: its effect shows in the log itself.
      if not (entry.command and result == "sent") then
        db.results[entry.thread] = { text = result, at = time() }
      end
      if result == "sent" and not entry.command then
        entry.shownSince = GetTime()
        self.sentShowing[#self.sentShowing + 1] = entry
      end
      local starts = entry.command == "new" or entry.command == "newm"
      if result == "sent" and (starts or entry.command == "steer") then
        C_Timer.After(2.5, function() ns:UpdateNow() end)
      elseif starts then
        self:DropStarting(entry.seq)
      elseif entry.command == "steer" and self.UI and self.UI.steering then -- Not built yet, right after a reload.
        self.UI.steering[entry.text:match("\n(.*)$") or ""] = nil
      end
      -- It didn't go, so give the words back rather than making you type them again.
      if result:sub(1, 6) == "failed" and not entry.command and not db.drafts[entry.thread] then
        db.drafts[entry.thread] = entry.text
      end
      -- The same goes for what you wrote for a new thread that didn't start.
      if result:sub(1, 6) == "failed" and db.selected and not db.drafts[db.selected] then
        if entry.command == "newm" then
          db.drafts[db.selected] = entry.text:match("^[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n(.*)$")
        elseif entry.command == "new" then
          db.drafts[db.selected] = entry.text:match("^[^\n]*\n[^\n]*\n[^\n]*\n(.*)$")
        end
      end
      if result ~= "sent" and self.Chat then self.Chat:ReportFailure(entry, result) end
    end
  end
  db.pending = kept
  self:WriteOutbox()
  self:StartNextSend()
end
