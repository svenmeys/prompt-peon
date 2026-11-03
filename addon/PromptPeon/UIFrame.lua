-- Frame: builds the log window and its title bar buttons, and opens and closes it.

local _, ns = ...
local UI = ns.UI
local PAD, MIN_WIDTH_NO_LIST = UI.PAD, UI.MIN_WIDTH_NO_LIST

local MIN_HEIGHT = 240
local IDLE_ALPHA = 0.82 -- The whole window, when the mouse is elsewhere and you are not typing.

--- Runs once, at login. Everything inside the window hangs off what's made here.
function UI:Build()
  self:ApplyFonts()
  self:BuildTracker()

  local frame = CreateFrame("Frame", "PromptPeonFrame", UIParent, "BasicFrameTemplateWithInset")
  -- Never bigger than the screen, whatever got saved.
  frame:SetSize(math.min(ns.db.width or 820, UIParent:GetWidth()), math.min(ns.db.height or 520, UIParent:GetHeight()))
  local spot = ns.db.position
  if spot then
    frame:SetPoint(spot[1], UIParent, spot[2], spot[3], spot[4])
  else
    frame:SetPoint("CENTER")
  end
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:SetFrameStrata("MEDIUM")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relative, x, y = self:GetPoint()
    ns.db.position = { point, relative, x, y }
  end)
  frame:SetScript("OnShow", function(self)
    self:SetAlpha(1)
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN) end
    ns:RefreshAndRender()
    if ns.Game and ns.db.away and ns.db.away.kind == "closed" then ns.Game:FinishAway() end
  end)
  frame:SetScript("OnHide", function()
    if UI.input then UI.input.EditBox:ClearFocus() end
    if ns.Game then ns.Game:BeginAway("closed") end
  end)
  -- Fade a little when you are playing, not reading. Text stays readable.
  frame:SetScript("OnUpdate", function(self)
    local active = self:IsMouseOver() or UI.input.EditBox:HasFocus()
    local want, have = active and 1 or IDLE_ALPHA, self:GetAlpha()
    if math.abs(want - have) > 0.01 then self:SetAlpha(have + (want - have) * 0.2) end
    UI:TickActivity()
  end)
  frame:Hide()
  table.insert(UISpecialFrames, "PromptPeonFrame") -- Escape closes it, like the real quest log.
  self.frame = frame

  frame.TitleText:SetText("Prompt Peon")

  local options = CreateFrame("Button", nil, frame)
  options:SetSize(16, 16)
  options:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -27, -4)
  options:SetNormalTexture("Interface\\WorldMap\\GEAR_64GREY")
  options:SetHighlightTexture("Interface\\WorldMap\\GEAR_64GREY", "ADD")
  options:SetScript("OnClick", function() UI:ToggleOptions() end)
  options:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Options")
    GameTooltip:Show()
  end)
  options:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.options = options

  -- Beside the cogwheel and as quiet as it, until there's news.
  local function topIcon(icon, anchor, onClick, tip)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(16, 16)
    button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    local path = icon:find("\\", 1, true) and icon or ("Interface\\Icons\\" .. icon)
    button.icon:SetTexture(path)
    if path:find("\\Icons\\", 1, true) then button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    button:SetHighlightTexture(path, "ADD")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      tip()
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
  end
  self.achievementsIcon = topIcon("Spell_Holy_SealOfWisdom", options, function()
    if UI.showAchievements then
      UI.showAchievements = nil
      UI:Render()
    elseif ns.Game then
      ns.Game:OpenAchievements()
    end
  end, function()
    GameTooltip:AddLine("Achievements")
    if ns.Game then GameTooltip:AddLine(ns.Game.EarnedWords(), 1, 1, 1) end
  end)
  self.reportIcon = topIcon("INV_Letter_15", self.achievementsIcon, function()
    if UI.showReport then
      UI.showReport = nil
      UI:Render()
    elseif ns.Game then
      ns.Game:OpenReport()
    end
  end, function()
    GameTooltip:AddLine("What happened")
    local report = ns.Game and ns.Game:CurrentReport()
    GameTooltip:AddLine(report and ns.Game.ReportHeadline(report) or (ns.Game and ns.Game.NO_REPORT) or "", 1, 1, 1, true)
  end)
  -- The game's own loot dice. Need comes before greed: unblock someone before admiring finished work.
  local function rollIcon(kind, art, anchor, title, detail)
    local button = topIcon(art, anchor, function() UI:NextRoll(kind) end, function()
      GameTooltip:AddLine(title .. " (" .. #UI.Rolls(kind) .. ")")
      GameTooltip:AddLine(detail, 1, 1, 1, true)
    end)
    button.count = button:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
    button.count:SetPoint("BOTTOMRIGHT", 3, -2)
    return button
  end
  self.greedIcon = rollIcon("greed", "Interface\\Buttons\\UI-GroupLoot-Coin-Up", self.reportIcon, "Greed", "Finished work you haven't read. Click for the next one.")
  self.needIcon = rollIcon("need", "Interface\\Buttons\\UI-GroupLoot-Dice-Up", self.greedIcon, "Need", "They're waiting on you. Click for the next one.")


  -- Everything below hangs off this, so the warning strip only takes space when needed.
  local top = CreateFrame("Frame", nil, frame)
  top:SetSize(1, 1)
  top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -30)
  self.top = top

  local problem = frame:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  problem:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -28)
  problem:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -28)
  problem:SetJustifyH("LEFT")
  problem:SetMaxLines(2)
  problem:SetTextColor(1.0, 0.66, 0.26)
  problem:Hide()
  self.problem = problem

  self:BuildList(frame)
  self:BuildDetail(frame)
  self:BuildReply(frame)
  self:BuildFooter(frame)

  frame:HookScript("OnSizeChanged", function() UI:FitToSize() end)

  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -3, 3)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  -- Our own drag, not the game's StartSizing, which sent the window flying to the edge of the screen.
  local function stopResizing()
    if not grip.start then return end
    grip.start = nil
    ns.db.width, ns.db.height = frame:GetSize()
    ns.db.position = { "TOPLEFT", "BOTTOMLEFT", frame:GetLeft(), frame:GetTop() }
    UI:Render()
  end
  grip:SetScript("OnMouseDown", function()
    -- Pin the top left, so only the corner you hold moves.
    local left, top = frame:GetLeft(), frame:GetTop()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    local x, y = GetCursorPosition()
    grip.start = { x = x, y = y, width = frame:GetWidth(), height = frame:GetHeight() }
  end)
  grip:SetScript("OnMouseUp", stopResizing)
  grip:SetScript("OnHide", stopResizing)
  grip:SetScript("OnUpdate", function()
    local start = grip.start
    if not start then return end
    if not IsMouseButtonDown("LeftButton") then
      stopResizing() -- You let go somewhere we didn't hear about.
      return
    end
    local x, y = GetCursorPosition()
    local scale = frame:GetEffectiveScale()
    local width = start.width + (x - start.x) / scale
    local height = start.height + (start.y - y) / scale
    frame:SetSize(math.max(UI.minWidth or MIN_WIDTH_NO_LIST, math.min(width, UIParent:GetWidth() - frame:GetLeft())),
      math.max(MIN_HEIGHT, math.min(height, frame:GetTop())))
  end)
  self.grip = grip

  -- A log in the middle of the screen gets you killed. It comes back after the fight.
  local combat = CreateFrame("Frame")
  combat:RegisterEvent("PLAYER_REGEN_DISABLED")
  combat:RegisterEvent("PLAYER_REGEN_ENABLED")
  combat:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
      if UI:IsOpen() then
        UI:SaveDraft()
        UI.hiddenForCombat = true
        frame:Hide()
      end
    else
      if UI.hiddenForCombat then
        UI.hiddenForCombat = false
        frame:Show()
      end
      ns:StartNextSend()
    end
  end)

  self:BuildParty()
  local listButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  listButton:SetSize(22, 18)
  listButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -3)
  listButton:SetScript("OnClick", function() UI:ToggleList() end)
  listButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.db.listHidden and "Show the thread list" or "Hide the thread list")
    GameTooltip:Show()
  end)
  listButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.listButton = listButton

  local newButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  newButton:SetSize(22, 18)
  newButton:SetPoint("LEFT", listButton, "RIGHT", 2, 0)
  newButton:SetText("+")
  newButton:SetScript("OnClick", function()
    if UI.newThread then
      UI:StopNewThread()
      UI.input.EditBox:ClearFocus()
      UI:Render()
    elseif ns:ThreadById(ns.db.selected) then
      UI:StartNewThread()
    else
      ns.Chat:ReportReload("Open a thread first, or right-click a project and pick New thread here.")
    end
  end)
  newButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("New thread")
    GameTooltip:Show()
  end)
  newButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.newButton = newButton
  self:ApplyLayout()
  self:ApplyOpacity()
  self:RenderTracker()
  self:RenderParty()
  if ns.db.reopen then
    ns.db.reopen = false
    frame:Show()
  end
end

function UI:IsOpen()
  return self.frame and self.frame:IsShown()
end

function UI:Toggle()
  if not self.frame then return end
  self.frame:SetShown(not self.frame:IsShown())
end

function UI:OpenThread(id)
  if not self.frame then return end
  self:SaveDraft()
  if self.newThread then self:StopNewThread() end
  self.showOptions, self.showAchievements, self.showReport = nil, nil, nil
  ns.db.selected = id
  if self.frame:IsShown() then self:Render() else self.frame:Show() end
end
