-- Frame: builds the flat dark-slate log window and the tabs down its right edge, and opens and closes it.

local _, ns = ...
local UI = ns.UI
local PAD, MIN_WIDTH_NO_LIST, THEME = UI.PAD, UI.MIN_WIDTH_NO_LIST, UI.THEME

-- Six side tabs (three pages + three thread views) fit comfortably in 336px.
local MIN_HEIGHT = 336
UI.MIN_HEIGHT = MIN_HEIGHT
local HEADER_HEIGHT = 30
UI.HEADER_HEIGHT = HEADER_HEIGHT
local IDLE_ALPHA = 0.84 -- The whole window, when the mouse is elsewhere and you are not typing.
local SIDE_TAB = 34 -- Crisp flat tab tile size.
local SIDE_REACH = 36 -- How far the side tab dock extends past the right edge.
UI.SIDE_TAB = SIDE_TAB
UI.SIDE_REACH = SIDE_REACH

--- A sleek flat tab docked flush to the window's right edge, with a 2px gold indicator bar when active.
function UI:SideTab(icon, onClick, tip)
  local tab = CreateFrame("CheckButton", nil, self.frame)
  tab:SetSize(SIDE_TAB, SIDE_TAB)
  UI.SkinSurface(tab, THEME.header, THEME.border)
  -- Active gold edge indicator on the left edge where the tab meets the window.
  local bar = tab:CreateTexture(nil, "OVERLAY")
  bar:SetWidth(2)
  bar:SetPoint("TOPLEFT", 0, -2)
  bar:SetPoint("BOTTOMLEFT", 0, 2)
  bar:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
  bar:Hide()
  tab.activeBar = bar

  tab.icon = tab:CreateTexture(nil, "ARTWORK")
  tab.icon:SetSize(20, 20)
  tab.icon:SetPoint("CENTER", 1, 0)
  local path = icon:find("\\", 1, true) and icon or ("Interface\\Icons\\" .. icon)
  tab.icon:SetTexture(path)
  if path:find("\\Icons\\", 1, true) then tab.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end

  local origSetChecked = tab.SetChecked
  tab.SetChecked = function(self, on)
    origSetChecked(self, on)
    local active = on and true or false
    self.activeBar:SetShown(active)
    if active then
      UI.SetFillColor(self, THEME.panelActive[1], THEME.panelActive[2], THEME.panelActive[3], THEME.panelActive[4])
      UI.SetBorderColor(self, THEME.borderAccent[1], THEME.borderAccent[2], THEME.borderAccent[3], THEME.borderAccent[4])
    else
      UI.SetFillColor(self, THEME.header[1], THEME.header[2], THEME.header[3], THEME.header[4])
      UI.SetBorderColor(self, THEME.border[1], THEME.border[2], THEME.border[3], THEME.border[4])
    end
  end

  tab:SetScript("OnClick", function()
    onClick()
    UI:RenderSideTabs() -- A click flips the checked state by itself. Put it back to what's really open.
  end)
  tab:SetScript("OnEnter", function(self)
    if not self:GetChecked() then
      UI.SetFillColor(self, THEME.panelHover[1], THEME.panelHover[2], THEME.panelHover[3], THEME.panelHover[4])
      UI.SetBorderColor(self, THEME.borderStrong[1], THEME.borderStrong[2], THEME.borderStrong[3], THEME.borderStrong[4])
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    tip(self)
    GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", function(self)
    if not self:GetChecked() then
      UI.SetFillColor(self, THEME.header[1], THEME.header[2], THEME.header[3], THEME.header[4])
      UI.SetBorderColor(self, THEME.border[1], THEME.border[2], THEME.border[3], THEME.border[4])
    end
    GameTooltip:Hide()
  end)
  self.sideTabs[#self.sideTabs + 1] = tab
  return tab
end

--- Runs once, at login. Everything inside the window hangs off what's made here.
function UI:Build()
  self:ApplyFonts()
  self:BuildTracker()

  local frame = CreateFrame("Frame", "PromptPeonFrame", UIParent)
  local maxWidth = math.max(MIN_WIDTH_NO_LIST, UIParent:GetWidth() - SIDE_REACH)
  -- Never bigger than the screen (leaving room for the right-edge tabs), and never shorter than its tabs.
  frame:SetSize(math.min(ns.db.width or 820, maxWidth), math.max(MIN_HEIGHT, math.min(ns.db.height or 520, UIParent:GetHeight())))
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

  -- Flat dark-slate chrome: outer frame background, inset detail surface, header bar, sidebar, footer, 1px borders.
  UI.SkinSurface(frame, THEME.bg, THEME.border)
  frame.Bg = frame._bg

  local titleBg = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  titleBg:SetPoint("TOPLEFT", 1, -1)
  titleBg:SetPoint("TOPRIGHT", -1, -1)
  titleBg:SetHeight(HEADER_HEIGHT)
  titleBg:SetColorTexture(THEME.header[1], THEME.header[2], THEME.header[3], THEME.header[4])
  frame.TitleBg = titleBg

  local titleRule = frame:CreateTexture(nil, "BORDER")
  titleRule:SetPoint("TOPLEFT", titleBg, "BOTTOMLEFT", 0, 0)
  titleRule:SetPoint("TOPRIGHT", titleBg, "BOTTOMRIGHT", 0, 0)
  titleRule:SetHeight(1)
  titleRule:SetColorTexture(THEME.divider[1], THEME.divider[2], THEME.divider[3], THEME.divider[4])

  local insetBg = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  insetBg:SetPoint("TOPLEFT", 1, -(HEADER_HEIGHT + 2))
  insetBg:SetPoint("BOTTOMRIGHT", -1, 1)
  insetBg:SetColorTexture(THEME.bg[1], THEME.bg[2], THEME.bg[3], THEME.bg[4])
  frame.InsetBg = insetBg

  local sidebarBg = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
  sidebarBg:SetPoint("TOPLEFT", 1, -(HEADER_HEIGHT + 2))
  sidebarBg:SetPoint("BOTTOMLEFT", 1, 38)
  sidebarBg:SetWidth(UI.ListWidth() + PAD + 4)
  sidebarBg:SetColorTexture(THEME.sidebar[1], THEME.sidebar[2], THEME.sidebar[3], THEME.sidebar[4])
  frame.SidebarBg = sidebarBg

  local footerBg = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
  footerBg:SetPoint("BOTTOMLEFT", 1, 1)
  footerBg:SetPoint("BOTTOMRIGHT", -1, 1)
  footerBg:SetHeight(37)
  footerBg:SetColorTexture(THEME.footer[1], THEME.footer[2], THEME.footer[3], THEME.footer[4])
  frame.FooterBg = footerBg

  local footerRule = frame:CreateTexture(nil, "BORDER")
  footerRule:SetPoint("BOTTOMLEFT", footerBg, "TOPLEFT", 0, 0)
  footerRule:SetPoint("BOTTOMRIGHT", footerBg, "TOPRIGHT", 0, 0)
  footerRule:SetHeight(1)
  footerRule:SetColorTexture(THEME.divider[1], THEME.divider[2], THEME.divider[3], THEME.divider[4])
  frame.FooterRule = footerRule

  local titleText = frame:CreateFontString(nil, "OVERLAY", "PromptPeonHeader")
  titleText:SetPoint("CENTER", titleBg, "CENTER", 0, 0)
  titleText:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
  titleText:SetText("Prompt Peon")
  frame.TitleText = titleText

  -- Crisp flat close button in the top-right header.
  local closeButton = UI.FlatButton(frame, 22, 20, "x")
  closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
  closeButton:SetScript("OnClick", function() frame:Hide() end)
  closeButton._onEnter = function(self)
    UI.SetFillColor(self, 0.45, 0.16, 0.16, 0.95)
    UI.SetBorderColor(self, THEME.danger[1], THEME.danger[2], THEME.danger[3], 1)
    self.labelText:SetTextColor(1, 0.92, 0.92)
  end
  closeButton._onLeave = function(self)
    self.labelText:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
  end
  self.closeButton = closeButton

  frame:SetScript("OnShow", function(self)
    self:SetAlpha(1)
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN) end
    ns:RefreshAndRender()
    -- On first open, anchored frame widths settle on the next frame; re-render once if detail width wasn't ready.
    if UI.detailScroll and (UI.detailScroll:GetWidth() or 0) <= 100 then
      C_Timer.After(0, function() if UI:IsOpen() then UI:Render() end end)
    end
    if ns.Game and ns.db.away and ns.db.away.kind == "closed" then ns.Game:FinishAway() end
  end)
  frame:SetScript("OnHide", function()
    UI:CloseMenu()
    if UI.input then UI.input.EditBox:ClearFocus() end
    if UI.filterBox then UI.filterBox:ClearFocus() end
    if ns.Game then ns.Game:BeginAway("closed") end
  end)
  -- Fade gently when you are playing, not reading. Frame-rate independent, and stays full while using menus.
  frame:SetScript("OnUpdate", function(self, elapsed)
    local menuOpen = UI.menuCatcher and UI.menuCatcher:IsShown()
    local viewerOpen = UI.viewer and UI.viewer:IsShown()
    local active = self:IsMouseOver(0, 0, 0, SIDE_REACH)
      or (UI.input and UI.input.EditBox:HasFocus())
      or (UI.filterBox and UI.filterBox:HasFocus())
      or menuOpen or viewerOpen
    local want, have = active and 1 or IDLE_ALPHA, self:GetAlpha()
    if math.abs(want - have) > 0.005 then
      local step = math.min(1, (elapsed or 0.016) * 12)
      local nextAlpha = have + (want - have) * step
      if math.abs(want - nextAlpha) <= 0.005 then nextAlpha = want end
      self:SetAlpha(nextAlpha)
    elseif have ~= want then
      self:SetAlpha(want)
    end
    UI:TickActivity()
  end)
  frame:Hide()
  table.insert(UISpecialFrames, "PromptPeonFrame") -- Escape closes it, like the real quest log.
  self.frame = frame
  self.sideTabs = {}

  -- The pages hang off the right edge as tabs. The open thread's own tabs join them in BuildDetail.
  self.reportIcon = self:SideTab("INV_Letter_15", function()
    if UI.showReport then
      UI.showReport = nil
      UI.shownKey = nil
      UI:Render()
    elseif ns.Game then
      ns.Game:OpenReport()
    end
  end, function()
    GameTooltip:AddLine("What happened")
    local report = ns.Game and ns.Game:CurrentReport()
    GameTooltip:AddLine(report and ns.Game.ReportHeadline(report) or (ns.Game and ns.Game.NO_REPORT) or "", 1, 1, 1, true)
  end)
  self.achievementsIcon = self:SideTab("Spell_Holy_SealOfWisdom", function()
    if UI.showAchievements then
      UI.showAchievements = nil
      UI.shownKey = nil
      UI:Render()
    elseif ns.Game then
      ns.Game:OpenAchievements()
    end
  end, function()
    GameTooltip:AddLine("Achievements")
    if ns.Game then GameTooltip:AddLine(ns.Game.EarnedWords(), 1, 1, 1) end
  end)
  self.options = self:SideTab("Interface\\WorldMap\\GEAR_64GREY", function() UI:ToggleOptions() end, function()
    GameTooltip:AddLine("Options")
  end)
  -- The tabs are part of the window: keep them on screen, and count them as "the mouse is on it".
  frame:SetClampRectInsets(0, SIDE_REACH, 0, 0)
  self:PlaceSideTabs()

  -- Everything below hangs off this, so the warning strip only takes space when needed.
  local top = CreateFrame("Frame", nil, frame)
  top:SetSize(1, 1)
  top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(HEADER_HEIGHT + 4))
  self.top = top

  local problem = frame:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  problem:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -(HEADER_HEIGHT + 5))
  problem:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -(HEADER_HEIGHT + 5))
  problem:SetJustifyH("LEFT")
  problem:SetMaxLines(2)
  problem:SetTextColor(1.0, 0.67, 0.28)
  problem:Hide()
  self.problem = problem

  self:BuildList(frame)
  self:BuildDetail(frame)
  self:BuildReply(frame)
  self:BuildFooter(frame)

  frame:HookScript("OnSizeChanged", function() UI:FitToSize() end)

  -- Subtle geometric resize handle in the bottom-right corner.
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  local gripLines = {}
  for i = 1, 2 do
    local line = grip:CreateTexture(nil, "OVERLAY")
    line:SetSize(i == 1 and 9 or 5, 1)
    line:SetPoint("BOTTOMRIGHT", -2, i == 1 and 2 or 6)
    line:SetColorTexture(THEME.borderStrong[1], THEME.borderStrong[2], THEME.borderStrong[3], 0.75)
    gripLines[i] = line
  end
  grip:SetScript("OnEnter", function()
    for _, l in ipairs(gripLines) do l:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1) end
  end)
  grip:SetScript("OnLeave", function()
    for _, l in ipairs(gripLines) do l:SetColorTexture(THEME.borderStrong[1], THEME.borderStrong[2], THEME.borderStrong[3], 0.75) end
  end)
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
    local left, topY = frame:GetLeft(), frame:GetTop()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, topY)
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
    local maxW = math.max(UI.minWidth or MIN_WIDTH_NO_LIST, UIParent:GetWidth() - frame:GetLeft() - SIDE_REACH)
    frame:SetSize(math.max(UI.minWidth or MIN_WIDTH_NO_LIST, math.min(width, maxW)),
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
  self:BuildMinimapButton()

  local listButton = UI.FlatButton(frame, 22, 20, "<")
  listButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -5)
  listButton:SetScript("OnClick", function() UI:ToggleList() end)
  listButton._onEnter = function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.db.listHidden and "Show the thread list" or "Hide the thread list")
    GameTooltip:Show()
  end
  listButton._onLeave = function() GameTooltip:Hide() end
  self.listButton = listButton

  local newButton = UI.FlatButton(frame, 22, 20, "+", true)
  newButton:SetPoint("LEFT", listButton, "RIGHT", 4, 0)
  newButton:SetScript("OnClick", function()
    if UI.newThread then
      UI:StopNewThread()
      UI.input.EditBox:ClearFocus()
      UI:Render()
    elseif ns:ThreadById(ns.db.selected) or (ns.snapshot and ns.snapshot.pj and #ns.snapshot.pj > 0) then
      UI:StartNewThread()
    else
      ns.Chat:ReportReload("No projects loaded yet. Wait for the companion app to connect.")
    end
  end)
  newButton._onEnter = function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("New thread")
    GameTooltip:Show()
  end
  newButton._onLeave = function() GameTooltip:Hide() end
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
  -- Opening a thread always shows what it said. With no Back button, its name in the list is the way home.
  self.views[id], self.prOpen[id], self.shownThread, self.shownKey = nil, nil, nil, nil
  ns.db.selected = id
  if self.frame:IsShown() then self:Render() else self.frame:Show() end
end
