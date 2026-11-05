-- Notice: what happens when a thread changes state, like the peons' voices, sounds and banners.

local _, ns = ...

--- Close to out of context. The game's own voice, because this is the one thing worth interrupting you for.
function ns:CallForMana()
  if self.db.peonQuiet then return end
  local workers = self:Workers()
  if PlaySoundFile then
    PlaySoundFile(workers.mana)
  elseif PlaySound then
    PlaySound(workers.manaKit)
  end
end

--- Tell the player when a thread needs them or an agent has finished.
-- The game's own voice lines, so nothing is shipped with the addon. Each sound kit holds one clip,
-- checked by transcribing it. "More work?" is the human peasant: peons don't have that line.
-- WoW doesn't ship the peasant's "Job's done!", so "Righto." does that job.
ns.WORKERS = {
  peon = {
    label = "Peons",
    voice = "Orc",
    face = 10038,
    idle = "Zug zug.",
    mana = 541247, -- A file, not a kit: an orc saying "I need more mana." Peons have no mana line of their own.
    manaKit = 2294, -- The same line among two others, for a client that can't play by file.
    work = 6197, -- "Work, work."
    complete = 6199, -- "Work complete!"
    needs = 6196, -- "Something need doing?"
    more = 6288, -- "More work?"
    bye = 6294, -- "Okie dokie."
    poked = { 6193, 6194, 6195 }, -- "Yes." "Hm?" "What do you want?"
    annoyed = { 6189, 6190, 6191, 6291 }, -- "What?" "Me busy! Leave me alone!" "No time for play!" "Me not that kind of orc!"
  },
  peasant = {
    label = "Peasants",
    voice = "Human",
    face = 301,
    idle = "Off to the inn.",
    mana = 540801, -- A human saying "I need more mana."
    manaKit = 1885,
    work = 6290, -- "Ready to work!"
    complete = 6284, -- "Righto."
    needs = 6287, -- "What is it?"
    more = 6288, -- "More work?"
    bye = 6286, -- "Off I go then."
    poked = { 6289, 6285, 6284 }, -- "What?" "Alright." "Righto."
    annoyed = { 6282, 6283, 6242 }, -- "I guess I can." "If you want." "No one else available?"
  },
  -- The Scourge's workers don't talk, so a necromancer does, and an abomination when you annoy it.
  undead = {
    label = "Undead",
    voice = "Undead",
    face = 137, -- A ghoul.
    idle = "The dead shall serve.",
    mana = 542637, -- A Forsaken saying "I need more mana."
    manaKit = 2064,
    work = 6259, -- "The shadows beckon."
    complete = 6265, -- "Intriguing."
    needs = 6264, -- "This better be good."
    more = 6263, -- "What does the shadow will?"
    bye = 6260, -- "They'll all be mine in the end."
    poked = { 6261, 6263, 6264 }, -- "The dead shall serve." "What does the shadow will?" "This better be good."
    annoyed = { 6269, 6267, 6270, 6271 }, -- An abomination: "What we do?", then mostly howling.
  },
}
local VOICE_GAP = 20

--- Who works for you: whatever you picked in Options, or else your character's side.
function ns:WorkerKind()
  if self.WORKERS[self.db.workers] then return self.db.workers end
  -- WoW Forever's API docs say a race can be hidden from addons, and comparing a hidden value is an error.
  local race = UnitRace and select(2, UnitRace("player"))
  if not (issecretvalue and issecretvalue(race)) and race == "Scourge" then return "undead" end
  return UnitFactionGroup and UnitFactionGroup("player") == "Alliance" and "peasant" or "peon"
end

function ns:Workers()
  return self.WORKERS[self:WorkerKind()]
end

--- Five agents starting at once is still one peon.
function ns:PeonSays(line)
  if self.db.peonQuiet or not PlaySound then return end
  local now = GetTime()
  self.voiceAt = self.voiceAt or {}
  if self.voiceAt[line] and now - self.voiceAt[line] < VOICE_GAP then return end
  self.voiceAt[line] = now
  PlaySound(self:Workers()[line])
end

--- A new install starts with quests on the tracker, instead of an empty one until an agent next starts.
--- The list comes most urgent first. An install already in use is left as you set it.
function ns:TrackFirstQuests(snapshot)
  if self.db.firstTracked or #snapshot.threads == 0 then return end
  self.db.firstTracked = true
  if next(self.db.tracked) then return end
  local count = 0
  for _, thread in ipairs(snapshot.threads) do
    if count < self.FIRST_TRACKED and not self:IsHidden(thread) then
      self.db.tracked[thread.id] = true
      count = count + 1
    end
  end
end

--- What changed since the last snapshot. Voices, tracking and finish reports all start here.
function ns:NoticeChanges(snapshot)
  self:TrackFirstQuests(snapshot)
  self:SettleStarting(snapshot)
  self:SettleSent()
  local previous, current = self.lastStatus, {}
  local queuedBefore, queuedNow = self.lastQueued or {}, {}
  for _, thread in ipairs(snapshot.threads) do
    current[thread.id] = thread.s
    queuedNow[thread.id] = thread.qc or 0
    local before = previous and previous[thread.id]
    -- Like a quest: once it is on your list it stays there until you turn it in or take it off.
    if (thread.s == "running" or thread.s == "needs") and self.db.tracked[thread.id] == nil and not self:IsHidden(thread) then
      self.db.tracked[thread.id] = true
    end
    if self.Game and not self:IsHidden(thread) then self.Game:NoticeLevel(thread) end
    if previous and not self:IsHidden(thread) then
      -- Fewer waiting and still working means it just took the next one off the queue.
      if thread.s == "running" and (queuedBefore[thread.id] or 0) > (thread.qc or 0) then
        self:PeonSays("more")
      elseif before ~= thread.s then
        if thread.s == "running" then
          self:PeonSays("work")
          if self.Game then self.Game:OnStarted(thread) end
        elseif thread.s == "needs" then
          self:Alert(thread)
        elseif before == "running" then
          -- An agent that keeps starting and stopping shouldn't flood you. One report a minute each.
          self.finishedAt = self.finishedAt or {}
          if not self.finishedAt[thread.id] or GetTime() - self.finishedAt[thread.id] >= 60 then
            self.finishedAt[thread.id] = GetTime()
            self:QuestFeel(thread)
            if self.Chat then self.Chat:ReportFinished(thread) end
          end
        end
      end
    end
  end
  self.lastStatus, self.lastQueued = current, queuedNow
end

--- Finishing should feel like handing in a quest.
function ns:QuestFeel(thread)
  local failed = thread.s == "error"
  if PlaySound and SOUNDKIT then
    -- The peon already says "Work complete!", so the quest sound is only there if you ask for it.
    -- A failure has no line of its own, so it keeps its sound.
    local sound = failed and SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST or (self.db.questSound and SOUNDKIT.IG_QUEST_LIST_COMPLETE)
    if sound and thread.s ~= "stopped" then PlaySound(sound) end
  end
  if self.Game then self.Game:OnFinished(thread) end
  if thread.s == "stopped" then
    if UIErrorsFrame then UIErrorsFrame:AddMessage("Interrupted", 1.0, 0.1, 0.1) end
    return
  end
  if not failed then self:PeonSays("complete") end
  if RaidNotice_AddMessage and RaidBossEmoteFrame and ChatTypeInfo then
    local words = failed and "Quest failed: " or "Quest complete: "
    RaidNotice_AddMessage(RaidBossEmoteFrame, words .. self.Plain(thread.t), ChatTypeInfo["RAID_BOSS_EMOTE"] or { r = 1, g = 0.82, b = 0 })
  end
end

function ns:Alert(thread)
  if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN) end
  self:PeonSays("needs")
  if UIErrorsFrame then
    UIErrorsFrame:AddMessage("T3 needs you: " .. self.Plain(thread.t), 1.0, 0.66, 0.26)
  end
  if self.Chat then self.Chat:ReportNeeds(thread) end
end
