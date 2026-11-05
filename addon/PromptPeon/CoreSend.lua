-- Send: the reply queue, and pacing frames out through the send addons, with a reload as the fallback.

local addonName, ns = ...

local band, lshift = bit.band, bit.lshift

--- True when the send addons exist. They are only listed if they were there when the
--- game started, so right after an update this is false until the next restart.
function ns:CanSendSilently()
  return C_AddOns.DoesAddOnExist(addonName .. "Out01")
    and C_AddOns.DoesAddOnExist(string.format("%sOut%02d", addonName, self.OUT_COUNT))
end

--- Whose addon list the send flags are saved under. The game's own addon list goes by GUID. WoW Forever
--- quietly ignores a name here, so nothing changes and nothing reaches the disk. Its API docs say the GUID
--- can be secret when identities are restricted, and addon code can't pass a secret on. So keep the one from login.
function ns:CharacterKey()
  local guid = UnitGUID("player")
  if not (issecretvalue and issecretvalue(guid)) then self.characterKey = guid end
  return self.characterKey
end

--- Put one frame on disk. Nil clears every bit.
function ns:WriteFrame(frame)
  local me = self:CharacterKey()
  if not me then return end -- The send times out and goes the slow way, through a reload.
  for index = 1, self.OUT_COUNT do
    local byte = frame and frame:byte(math.floor((index - 1) / 8) + 1) or 0
    local set = band(byte, lshift(1, (index - 1) % 8)) ~= 0
    if self.carrier[index] ~= set then
      local name = string.format("%sOut%02d", addonName, index)
      if set then C_AddOns.DisableAddOn(name, me) else C_AddOns.EnableAddOn(name, me) end
      self.carrier[index] = set
    end
  end
  local started = debugprofilestop()
  C_AddOns.SaveAddOns()
  self.lastSaveMs = debugprofilestop() - started
  self.worstSaveMs = math.max(self.worstSaveMs or 0, self.lastSaveMs)
end

--- One string of seq:thread:hex entries, written to SavedVariables only by a reload.
--- This is the fallback for a reply the silent path could not deliver.
function ns:WriteOutbox()
  local parts = {}
  for _, entry in ipairs(self.db.pending) do
    parts[#parts + 1] = entry.seq .. ":" .. self.ToHex(entry.thread) .. ":" .. self.ToHex(entry.text)
  end
  _G.PromptPeonOutbox = table.concat(parts, ";")
end

--- Queue a reply. Returns nil and a reason when it was refused; the caller keeps the text.
--- What you typed. The first byte of a command can't be typed, but it can be pasted.
function ns:QueueReply(threadId, typed)
  if typed:find("\1", 1, true) then return nil, "That has a character in it that can't be sent." end
  local ok, reason = self:Enqueue(threadId, typed)
  if ok then
    self:PeonSays("work")
    if self.Game then self.Game:Earn("zugzug") end
  end
  return ok, reason
end

--- Replies and commands all come through here, so this is where the limits are.
function ns:Enqueue(threadId, typed)
  local text = self.Typed(typed):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "Nothing to send yet." end
  if #text > self.MAX_REPLY_BYTES then
    return nil, "Your bags are full. Keep replies under " .. self.MAX_REPLY_BYTES .. " bytes."
  end
  if not threadId then return nil, "Pick a thread first." end
  -- Keep equal to good_thread_id in the bridge.
  if #threadId > 200 or threadId:find("[%s%c|]") then
    return nil, "You can't reply to this one from here. Open it in T3."
  end
  local db = self.db
  db.pending[#db.pending + 1] = { seq = db.nextSeq, thread = threadId, text = text, at = time(), tries = 0 }
  db.nextSeq = db.nextSeq + 1
  db.drafts[threadId] = nil
  db.results[threadId] = nil
  self:WriteOutbox()
  return true
end

--- Whether a new thread on this provider can use this mode, and "off" if the installer's answer is what stops it.
--- Only so the menu is honest. The bridge decides.
function ns:ModeAvailable(mode, instance)
  if mode.free and not (self.snapshot and self.snapshot.fa) then return false, "off" end
  for _, provider in ipairs(self.snapshot and self.snapshot.md or {}) do
    if provider.i == instance and provider.rm then
      for _, id in ipairs(provider.rm) do
        if id == mode.id then return true end
      end
      return false
    end
  end
  return true
end

--- The mode a new thread gets: your last pick if it can have it, or else the one that asks.
function ns:NewThreadMode(instance)
  for _, mode in ipairs(self.RUNTIME_MODES) do
    if mode.id == self.db.newMode and self:ModeAvailable(mode, instance) then return mode end
  end
  return self.RUNTIME_MODES[1]
end

--- A command for the bridge, sent the same way as a reply. Failures still reach the player.
function ns:QueueCommand(threadId, verb, argument)
  -- A draft you are writing isn't what this is about, so it stays where it is.
  local draft = self.db.drafts[threadId]
  local ok, reason = self:Enqueue(threadId, "\1" .. verb .. "\n" .. (argument or ""))
  self.db.drafts[threadId] = draft
  if ok then
    self.db.pending[#self.db.pending].command = verb
    if verb == "new" or verb == "newm" then self:PeonSays("work") end
    if verb == "settle" and self.Game then self.Game:Count("turnedIn", 10, "questhub") end
    self:Deliver()
  elseif self.Chat then
    self.Chat:ReportReload(reason)
  end
  return ok, reason
end

--- Turn a thread in, and remember it so the last one can be undone.
function ns:Settle(thread)
  if not self:QueueCommand(thread.id, "settle") then return end
  self.db.lastSettled = { id = thread.id, title = thread.t }
  self:PeonSays("bye")
  if self.Chat then self.Chat:ReportSettled(thread) end
end

--- Tell the bridge what you hid, so it keeps that text out of the game. Its copy is the one
--- that counts. At login the list goes again even if it was sent before, in case the bridge lost it.
local HIDDEN_MARGIN = 100 -- Room for the command's own bytes.
function ns:SendHidden(atLogin)
  local db = self.db
  local projects, threads = {}, {}
  -- A name with a line break in it would split into two lines.
  for project in pairs(db.hiddenProjects) do
    if not tostring(project):find("%c") then projects[#projects + 1] = "p:" .. project end
  end
  for id in pairs(db.hiddenThreads) do
    if not tostring(id):find("%c") then threads[#threads + 1] = "t:" .. id end
  end
  table.sort(projects)
  table.sort(threads)
  for _, line in ipairs(threads) do projects[#projects + 1] = line end
  local room, kept, size = self.MAX_REPLY_BYTES - #"\1hidden\n" - HIDDEN_MARGIN, {}, 0
  for _, line in ipairs(projects) do
    if size + #line + 1 > room then break end
    kept[#kept + 1] = line
    size = size + #line + 1
  end
  local text = table.concat(kept, "\n")
  local before = db.hiddenSent or ""
  if text == before and (not atLogin or text == "") then return end
  local ok = self:QueueCommand("settings", "hidden", text)
  if not ok then return end
  db.hiddenSent = text
  if #kept < #projects and self.Chat then
    self.Chat:ReportReload("Too many hidden threads for T3 to hear about. " .. (#projects - #kept) .. " of them will still show their text in the game. Hide whole projects instead.")
  end
  return true
end

--- Start the oldest reply going out. Held during a fight, and sent as soon as it ends.
--- Strictly one at a time and in order: the bridge's answer means "everything up to
--- this number", so a later reply must never overtake one that has not arrived.
function ns:StartNextSend()
  if self.tx or not self.db or InCombatLockdown() or not self:CanSendSilently() then return end
  local entry = self.db.pending[1]
  if not entry or entry.stuck or entry.waiting then return end
  entry.tries = (entry.tries or 0) + 1
  self.tx = { entry = entry, frames = self.Frames(self.EncodeMessage(entry.seq, entry.thread, entry.text)), index = 0, nextAt = 0 }
  self.sender:Show()
end

--- Send what is queued. Only falls back to a reload if the send addons are missing.
function ns:Deliver()
  if self:CanSendSilently() then
    self:StartNextSend()
  else
    self:Flush()
  end
end

--- One frame per step. Each stays on disk long enough for the bridge's next read to see it.
function ns:SendStep()
  local tx = self.tx
  if not tx then
    self.sender:Hide()
    return
  end
  local now = GetTime()
  if now < tx.nextAt then return end
  tx.index = tx.index + 1
  if tx.index <= #tx.frames then
    self:WriteFrame(tx.frames[tx.index])
    tx.nextAt = now + (tx.index == 1 and self.FIRST_FRAME_SECONDS or self.FRAME_SECONDS)
    return
  end
  self:WriteFrame(nil)
  self.tx = nil
  self.sender:Hide()
  local entry = tx.entry
  entry.waiting = true
  C_Timer.After(1.5, function() ns:CheckDelivered(entry, 1) end)
end

function ns:IsPending(entry)
  for _, candidate in ipairs(self.db.pending) do
    if candidate == entry then return true end
  end
  return false
end

--- Spend a refresh to read the bridge's answer. Resend if it never heard us.
function ns:CheckDelivered(entry, attempt)
  if not self:IsPending(entry) then return end
  if InCombatLockdown() then
    C_Timer.After(5, function() ns:CheckDelivered(entry, attempt) end)
    return
  end
  self:Refresh()
  if self:IsPending(entry) then
    if attempt == 1 then
      C_Timer.After(2.5, function() ns:CheckDelivered(entry, 2) end)
    elseif (entry.tries or 0) < self.MAX_TRIES then
      entry.waiting = nil
      self:StartNextSend()
    else
      entry.waiting = nil
      entry.stuck = true
      if self.Chat then self.Chat:ReportStuck(entry) end
    end
  end
  if self.UI then self.UI:Render() end
end

--- A reload writes SavedVariables, and the bridge reads any reply still waiting there.
function ns:Flush()
  self.db.reopen = self.UI and self.UI:IsOpen() or false
  if self.Game then self.Game:Count("reloads", 10, "reload") end
  ReloadUI()
end
