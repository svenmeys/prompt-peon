-- Achievements: the list, earning them, and the counts behind the ones that take a while.

local _, ns = ...
local Game = ns.Game

Game.ACHIEVEMENTS = {
  { id = "zugzug", name = "Zug Zug", icon = "INV_Misc_Head_Orc_01", text = "Gave an agent its first order from inside the game." },
  { id = "spell", name = "Fresh Off The Trainer", icon = "INV_Misc_Book_09", text = "Cast your first spell at an agent." },
  { id = "questhub", name = "Quest Hub", icon = "INV_Letter_15", text = "Turned in 10 threads.", stat = "turnedIn", goal = 10 },
  { id = "raid", name = "Raid Leader", icon = "Ability_Warrior_BattleShout", text = "Had 5 agents working at the same time." },
  { id = "maxlevel", name = "Max Level", icon = "Spell_Holy_SealOfWisdom", text = "Took a thread to level 10: 100 finished turns." },
  { id = "legendary", name = "Legendary Drop", icon = "INV_Sword_48", text = "A single change over 5,000 lines. Are you sure about this?" },
  { id = "necromancer", name = "Necromancer", icon = "Spell_Shadow_RaiseDead", text = "Resurrected 5 dead agents.", stat = "resurrected", goal = 5 },
  { id = "hogger", name = "Hogger", icon = "Ability_Hunter_Pet_Wolf", text = "5 failed runs in a row. He got you.", stat = "failStreak", goal = 5 },
  { id = "leeroy", name = "Leeroy Jenkins", icon = "Ability_Warrior_Charge", text = "Let an agent loose with full access, right on main." },
  { id = "reload", name = "Reload Hero", icon = "INV_Misc_PocketWatch_01", text = "Pressed Reload UI 10 times.", stat = "reloads", goal = 10 },
  { id = "night", name = "Night Elf", icon = "Spell_Nature_Sleep", text = "Had an agent working between 3 and 5 in the morning. Go to bed." },
  { id = "peon", name = "Me Not That Kind Of Orc", icon = "INV_Pick_02", text = "Annoyed a peon 50 times.", stat = "annoyed", goal = 50 },
}

function Game.EarnedWords()
  local earned = 0
  for _, entry in ipairs(Game.ACHIEVEMENTS) do
    if ns.db.achievements[entry.id] then earned = earned + 1 end
  end
  return earned .. " of " .. #Game.ACHIEVEMENTS .. " earned"
end

function Game:Earn(id)
  local earned = ns.db.achievements
  if earned[id] then return end
  earned[id] = time()
  for _, entry in ipairs(Game.ACHIEVEMENTS) do
    if entry.id == id then
      if ns.Chat then
        ns.Chat:News("Achievement earned: |cffffd100|Haddon:peon:achievements|h[" .. entry.name .. "]|h|r " .. entry.text)
      end
      self:Banner("Achievement earned: " .. entry.name)
      if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then PlaySound(SOUNDKIT.READY_CHECK) end
    end
  end
end

--- Add one to a running count, and earn something when it gets there.
function Game:Count(name, goal, achievement)
  local stats = ns.db.stats
  stats[name] = (stats[name] or 0) + 1
  if goal and stats[name] >= goal then self:Earn(achievement) end
end

function Game:OpenAchievements()
  if ns.UI.newThread then ns.UI:StopNewThread() end
  ns.UI.showAchievements, ns.UI.showOptions, ns.UI.showReport = true, nil, nil
  if ns.UI:IsOpen() then ns.UI:Render() else ns.UI:Toggle() end
end

--- What the addon's other parts tell us when a thread starts or stops.
function Game:OnStarted(thread)
  if thread.rm == "full-access" and (thread.b == "main" or thread.b == "master") then self:Earn("leeroy") end
  local hour = tonumber(date("%H"))
  if hour and hour >= 3 and hour < 5 then self:Earn("night") end
end

function Game:OnFinished(thread)
  local stats = ns.db.stats
  if thread.s == "done" and thread.id then ns.db.corpseRuns[thread.id] = nil end
  if thread.s == "error" then
    stats.failStreak = (stats.failStreak or 0) + 1
    if stats.failStreak >= 5 then self:Earn("hogger") end
  elseif thread.s ~= "stopped" then
    stats.failStreak = 0
  end
end
