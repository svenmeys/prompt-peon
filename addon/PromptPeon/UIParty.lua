-- Party: agents as party members, on the game's own party frame art.

local _, ns = ...
local UI = ns.UI

local PARTY_MAX = 5
-- Real faces, drawn by the game from its own models. These are creature display IDs: a peon first,
-- because everyone starts as one, then Thrall, Jaina, Cairne, Sylvanas, Vol'jin, Magni, Tyrande,
-- Hogger, Bolvar and Van Cleef for anyone you promote with Change face.
local FACES = { 4527, 2970, 4307, 11657, 10357, 3597, 7274, 384, 5566, 2029 }

function UI.FaceFor(thread)
  return ns.db.faces[thread.id] or ns:Workers().face
end

--- Around the circle: your side's worker, then the famous faces.
function UI.NextFace(thread)
  local current = UI.FaceFor(thread)
  local nextFace = FACES[1]
  for index, candidate in ipairs(FACES) do
    if candidate == current then nextFace = FACES[index + 1] or ns:Workers().face end
  end
  ns.db.faces[thread.id] = nextFace
  UI:Render()
end

-- With Elite frames on, level 5 earns the silver dragon and level 10 the gold one, the frames the game
-- gives rares and elites. A new install has them off.
local RANKS = {
  { level = 10, file = "Interface\\TargetingFrame\\UI-TargetingFrame-Elite" },
  { level = 5, file = "Interface\\TargetingFrame\\UI-TargetingFrame-Rare" },
}

--- The art faces the other way, with the portrait on the right, so it's flipped to wrap ours.
function UI.ShowRank(row, level)
  local rank
  if ns.db.eliteFrames then
    for _, entry in ipairs(RANKS) do
      if not rank and level >= entry.level then rank = entry end
    end
  end
  row.rank:SetShown(rank ~= nil)
  -- The dragon has a ring for the level, so the number moves into it.
  row.level:ClearAllPoints()
  if rank then
    row.level:SetPoint("CENTER", row, "TOPLEFT", 12.5, -38.5)
  else
    row.level:SetPoint("BOTTOMLEFT", row.face, "BOTTOMLEFT", -1, -2)
    return
  end
  row.rank:SetTexture(rank.file)
  row.rank:SetTexCoord(1, 0.55, 0, 0.78125)
  row.rank:SetSize(67, 58)
end

local ACTIVITY_ICONS = {
  { words = "Thinking", icon = "Spell_Holy_MindVision" },
  { words = "Writing", icon = "INV_Misc_Note_01" },
  { words = "Running", icon = "Trade_Engineering" },
  { words = "Editing", icon = "INV_Feather_05" },
  { words = "Searching", icon = "INV_Misc_Spyglass_02" },
  { words = "Agent", icon = "Spell_Holy_PrayerOfHealing" },
  { words = "Waiting on", icon = "INV_Misc_PocketWatch_01" },
  { words = "Waiting for", icon = "INV_Misc_QuestionMark" },
}

local PARTY_BORDERS = {
  needs = { 1.00, 0.45, 0.15 },
  running = { 0.40, 0.70, 1.00 },
  done = { 0.35, 0.85, 0.40 },
  error = { 0.90, 0.25, 0.20 },
  stopped = { 0.60, 0.60, 0.60 },
}

--- A still icon for what the agent is doing. Hover the frame for the words.
function UI.ActivityIcon(thread)
  if thread.s == "error" or thread.s == "stopped" then return "Interface\\Buttons\\UI-GroupLoot-Pass-Up" end
  if thread.s ~= "running" and thread.s ~= "needs" then return "Interface\\RaidFrame\\ReadyCheck-Ready" end
  local words = tostring(thread.a or "")
  for _, entry in ipairs(ACTIVITY_ICONS) do
    if words:sub(1, #entry.words) == entry.words then return "Interface\\Icons\\" .. entry.icon end
  end
  return "Interface\\Icons\\INV_Misc_Gear_01"
end

--- Progress through the agent's todo list, from 0 to 1. Full if it has none.
function UI.TodoProgress(thread)
  local rows = thread.m or {}
  for index = #rows, 1, -1 do
    if rows[index][1] == "d" then
      local done, total = 0, 0
      for line in (rows[index][2] .. "\n"):gmatch("(.-)\n") do
        total = total + 1
        if line:sub(1, 3) == "[x]" then done = done + 1 end
      end
      return total > 0 and done / total or 1
    end
  end
  return 1
end

local function partyBar(parent, height, r, g, b)
  local bar = CreateFrame("StatusBar", nil, parent)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(r, g, b)
  bar:SetMinMaxValues(0, 1)
  bar:SetHeight(height)
  return bar
end

function UI:BuildParty()
  local holder = CreateFrame("Frame", "PromptPeonParty", UIParent)
  holder:SetSize(200, 10)
  holder:SetMovable(true)
  holder:SetClampedToScreen(true)
  holder:Hide()
  self.party, self.partyRows = holder, {}
end

function UI:PartyRow(index)
  local row = self.partyRows[index]
  if row then return row end
  -- Laid out like Blizzard's own party frame, on its own art, with a cast bar added below.
  row = CreateFrame("Button", nil, self.party)
  row:SetSize(190, 46)
  row:SetPoint("TOPLEFT", self.party, "TOPLEFT", 0, -(index - 1) * 50)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:RegisterForDrag("LeftButton")
  row:SetScript("OnDragStart", function() UI.party:StartMoving() end)
  row:SetScript("OnDragStop", function()
    UI.party:StopMovingOrSizing()
    local point, _, relative, x, y = UI.party:GetPoint()
    ns.db.partyPosition = { point, relative, x, y }
  end)
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      UI:ThreadMenu(self, self.thread, true)
    elseif IsShiftKeyDown() then
      ns:ToggleTracked(self.thread)
    else
      if ns.Game then ns.Game:Poke() end
      UI:OpenThread(self.thread.id)
    end
  end)
  row:SetScript("OnEnter", function(self) UI:ShowThreadTip(self, self.thread) end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.face = row:CreateTexture(nil, "BACKGROUND")
  row.face:SetSize(37, 37)
  row.face:SetPoint("TOPLEFT", 7, -6)
  row.art = row:CreateTexture(nil, "BORDER")
  row.art:SetSize(128, 64)
  row.art:SetPoint("TOPLEFT", 0, -2)
  row.art:SetTexture("Interface\\TargetingFrame\\UI-PartyFrame")
  row.name = row:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  row.name:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 48, -11)
  row.name:SetWidth(140)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row.health = partyBar(row, 8, 0.25, 0.80, 0.30)
  row.health:SetWidth(70)
  row.health:SetPoint("TOPLEFT", 47, -12)
  row.mana = partyBar(row, 8, 0.25, 0.45, 1.00)
  row.mana:SetWidth(70)
  row.mana:SetPoint("TOPLEFT", 47, -21)
  -- What it is doing, as a still debuff icon on the portrait. Nothing here moves.
  row.debuff = row:CreateTexture(nil, "OVERLAY")
  row.debuff:SetSize(16, 16)
  row.debuff:SetPoint("BOTTOMRIGHT", row.face, "BOTTOMRIGHT", 5, -3)
  row.debuffBorder = row:CreateTexture(nil, "OVERLAY", nil, 1)
  row.debuffBorder:SetSize(18, 18)
  row.debuffBorder:SetPoint("CENTER", row.debuff, "CENTER")
  row.debuffBorder:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
  row.debuffBorder:SetTexCoord(0, 0.2734375, 0, 0.5625)
  row.rank = row:CreateTexture(nil, "BORDER", nil, 1)
  row.rank:SetPoint("TOPLEFT", -17, 1)
  row.rank:Hide()
  row.oom = row:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  row.oom:SetPoint("LEFT", row.mana, "RIGHT", 4, 0)
  row.oom:SetTextColor(0.45, 0.65, 1)
  row.oom:SetText("OOM")
  row.level = row:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  row.level:SetPoint("BOTTOMLEFT", row.face, "BOTTOMLEFT", -1, -2)
  row.level:SetTextColor(1, 0.82, 0)
  self.partyRows[index] = row
  return row
end

function UI:RenderParty()
  if not self.party then return end
  local spot = ns.db.partyPosition
  self.party:ClearAllPoints()
  if spot then
    self.party:SetPoint(spot[1], UIParent, spot[2], spot[3], spot[4])
  else
    -- Beside a real party, never on top of it.
    local inGroup = IsInGroup and IsInGroup()
    if ObjectiveTrackerFrame then
      -- Retail and Forever can put your own frame anywhere, even at the bottom, so they get a spot of their own.
      self.party:SetPoint("TOPLEFT", UIParent, "TOPLEFT", inGroup and 190 or 26, -128)
    else
      self.party:SetPoint("TOPLEFT", PlayerFrame, "BOTTOMLEFT", inGroup and 180 or 16, -24)
    end
  end
  local index = 0
  local function addMember(thread)
    if index >= PARTY_MAX then return end
    index = index + 1
    local row = self:PartyRow(index)
    row.thread = thread
    local face = UI.FaceFor(thread)
    if row.shownFace ~= face then
      SetPortraitTextureFromCreatureDisplayID(row.face, face)
      row.shownFace = face
    end
    local working = thread.s == "running" or thread.s == "needs"
    -- Finished ones step back a little, so the ones still going stand out.
    local light = working and 1 or 0.6
    row.face:SetVertexColor(light, light, light)
    row.name:SetText(ns.Plain(thread.t))
    local health = ns.Game and ns.Game.Health(thread) or UI.TodoProgress(thread)
    row.health:SetValue(health)
    if health < 0.4 then
      row.health:SetStatusBarColor(0.90, 0.25, 0.20)
    else
      row.health:SetStatusBarColor(0.25, 0.80, 0.30)
    end
    row.level:SetText(ns.Game and ns.Game.LevelOf(thread) or "")
    UI.ShowRank(row, ns.Game and ns.Game.LevelOf(thread) or 1)
    row.face:SetDesaturated(thread.s == "error")
    row.mana:SetValue(1 - (thread.cu or 0) / 100)
    row.oom:SetShown((ns.Game and ns.Game.IsLowOnMana(thread)) or false)
    row.debuff:SetTexture(UI.ActivityIcon(thread))
    local border = PARTY_BORDERS[thread.s] or PARTY_BORDERS.done
    row.debuffBorder:SetVertexColor(border[1], border[2], border[3])
    row:Show()
  end
  if ns.db.partyOn then
    local threads = ns:VisibleThreads()
    -- Working ones first, so a finished one never pushes a busy one out of the party.
    for _, thread in ipairs(threads) do
      if thread.s == "running" or thread.s == "needs" then addMember(thread) end
    end
    for _, thread in ipairs(threads) do
      if thread.s ~= "running" and thread.s ~= "needs" and ns:IsTracked(thread) then addMember(thread) end
    end
  end
  for extra = index + 1, #self.partyRows do self.partyRows[extra]:Hide() end
  self.partyCount = index
  self.party:SetShown(index > 0)
end
