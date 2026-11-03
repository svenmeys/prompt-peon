-- Game: what makes agents feel like party members. Nothing here is needed to use T3.
-- This file holds the peon's clicks, levels, health, death and mana. The other Game files add to it.
-- The addon has to work without these files: a file added since the game started stays invisible
-- until the next full restart, so everything else checks ns.Game before using it.
local _, ns = ...

local Game = {}
ns.Game = Game

-- --- The peon, when you click it -------------------------------------------------

local ANNOYED_AFTER = 4 -- Clicks in a row, like in Warcraft 3.
local POKE_WINDOW = 5 -- Seconds before it calms down again.

--- Click it too often and it gets annoyed.
function Game:Poke()
  if ns.db.peonQuiet or not PlaySound then return end
  local now = GetTime()
  if not self.lastPoke or now - self.lastPoke > POKE_WINDOW then self.pokes = 0 end
  self.lastPoke = now
  self.pokes = (self.pokes or 0) + 1
  local annoyed = self.pokes >= ANNOYED_AFTER
  local lines = annoyed and ns:Workers().annoyed or ns:Workers().poked
  if annoyed then
    self:Count("annoyed", 50, "peon")
  end
  self.nextLine = (self.nextLine or 0) + 1
  PlaySound(lines[(self.nextLine - 1) % #lines + 1])
end

-- --- Levels, health ---------------------------------------------------------------

local DING_SOUND = 888 -- The real level up.

--- Level is how much work a thread has finished: turns, on a rising curve, so a ding means something.
function Game.LevelOf(thread)
  return math.max(1, math.floor(math.sqrt(thread.tn or 0)))
end

function Game.LevelWords(thread)
  local level = Game.LevelOf(thread)
  return string.format("Level %d (%d/%d turns)", level, thread.tn or 0, (level + 1) ^ 2)
end

--- Health is how this turn is going. Every failed step costs some, and a failed run is death.
function Game.Failures(thread)
  local failed, rows = 0, thread.m or {}
  for index = #rows, 1, -1 do
    local row = rows[index]
    if row[1] == "u" and row[3] ~= "q" then break end
    if row[1] == "s" and row[3] == "f" then failed = failed + 1 end
  end
  return failed
end

function Game.Health(thread)
  if thread.s == "error" then return 0 end
  return math.max(1 - Game.Failures(thread) * 0.15, 0.1)
end

function Game.HealthWords(thread)
  if thread.s == "error" then return "Dead" end
  local failed = Game.Failures(thread)
  if failed == 0 then return "Health full" end
  return (failed >= 3 and "Your gear is damaged: " or "Health: ") .. failed .. (failed == 1 and " failed step" or " failed steps")
end

--- Ding. Remembered, so a reload never dings again.
function Game:NoticeLevel(thread)
  local levels = ns.db.levels
  local level = Game.LevelOf(thread)
  local before = levels[thread.id]
  levels[thread.id] = level
  if not before or level <= before then return end
  if level >= 10 then self:Earn("maxlevel") end
  if PlaySound then PlaySound(DING_SOUND) end
  local words = ns.Plain(thread.t) .. " reached level " .. level .. "!"
  if RaidNotice_AddMessage and RaidBossEmoteFrame and ChatTypeInfo then
    RaidNotice_AddMessage(RaidBossEmoteFrame, words, ChatTypeInfo["RAID_BOSS_EMOTE"] or { r = 1, g = 0.82, b = 0 })
  end
  if ns.Chat then ns.Chat:News(words) end
end

-- --- Death ------------------------------------------------------------------------

local RESURRECT = "That failed. Read the error, work out what actually went wrong, and try again a different way. If it can't work, tell me why."

StaticPopupDialogs["PROMPTPEON_RESURRECT"] = {
  text = "Resurrect %s?\n\nThis goes to the agent:\n%s",
  button1 = "Resurrect",
  button2 = "Not now",
  OnAccept = function(_, threadId)
    local thread = ns:ThreadById(threadId)
    if thread then Game:ResurrectNow(thread) end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function Game:Resurrect(thread)
  if ns.db.spellsNoAsk then return self:ResurrectNow(thread) end
  local runs = ns.db.corpseRuns[thread.id] or 0
  local name = ns.Plain(thread.t) .. (runs > 0 and ("\n\nThis is corpse run #" .. (runs + 1) .. ".") or "")
  StaticPopup_Show("PROMPTPEON_RESURRECT", name, RESURRECT, thread.id)
end

function Game:ResurrectNow(thread)
  local ok, reason = ns:QueueReply(thread.id, RESURRECT)
  if ok then
    ns:Deliver()
    ns.db.corpseRuns[thread.id] = (ns.db.corpseRuns[thread.id] or 0) + 1
    self:Count("resurrected", 5, "necromancer")
  elseif ns.Chat then
    ns.Chat:ReportReload(reason)
  end
  if ns.UI then ns.UI:Render() end
end

-- --- Need more mana -----------------------------------------------------------------

local LOW_MANA = 20 -- Percent of context left.

function Game.IsLowOnMana(thread)
  return thread.cu ~= nil and 100 - thread.cu <= LOW_MANA
end

--- Once each time it gets low. A compact fills it back up, which arms this again.
function Game:CheckMana(snapshot)
  self.calledForMana = self.calledForMana or {}
  for _, thread in ipairs(snapshot.threads) do
    if thread.cu and not Game.IsLowOnMana(thread) then
      self.calledForMana[thread.id] = nil
    elseif Game.IsLowOnMana(thread) and not self.calledForMana[thread.id] then
      self.calledForMana[thread.id] = true
      if self.seeded and thread.s == "running" and not ns:IsHidden(thread) then
        ns:CallForMana()
        if UIErrorsFrame then UIErrorsFrame:AddMessage("Not enough mana: " .. ns.Plain(thread.t), 1.0, 0.1, 0.1) end
        if ns.Chat then
          ns.Chat:News(ns.Plain(thread.t) .. " needs more mana: " .. (100 - thread.cu) .. "% context left. Evocation compacts it.")
        end
      end
    end
  end
end
