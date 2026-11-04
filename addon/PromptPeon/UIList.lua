-- List: the threads on the left, under project headers, with Snoozed, Settled and Hidden below.

local _, ns = ...
local UI = ns.UI
local PAD, addFold, showFold, hideScrollBarWhenIdle = UI.PAD, UI.AddFold, UI.ShowFold, UI.HideScrollBarWhenIdle

local ROW_HEIGHT = 20
local HEADER_HEIGHT = 22

function UI:BuildList(frame)
  local scroll = CreateFrame("ScrollFrame", "PromptPeonListScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", self.top, "BOTTOMLEFT", PAD, -2)
  scroll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 40)
  scroll:SetWidth(UI.ListWidth())
  self.listScroll = scroll
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(UI.ListWidth(), 10)
  scroll:SetScrollChild(content)
  hideScrollBarWhenIdle(scroll)
  -- Inside the list, where rows make room for it. Left outside it, it covers the thread's name.
  local bar = _G["PromptPeonListScrollScrollBar"]
  if type(bar) == "table" then
    bar:ClearAllPoints()
    bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -16)
    bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 16)
  end
  self.listContent = content
  self.rows = {}

  -- The edge of the list: a thin line that lights up, and that you can drag.
  local edge = CreateFrame("Button", nil, frame)
  edge:SetWidth(10)
  edge:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2, 0)
  edge:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 2, 0)
  edge.line = edge:CreateTexture(nil, "OVERLAY")
  edge.line:SetColorTexture(1, 0.82, 0, 0.14)
  edge.line:SetWidth(2)
  edge.line:SetPoint("TOP")
  edge.line:SetPoint("BOTTOM")
  local function stopDragging(self)
    if not self.dragging then return end
    self.dragging = nil
    UI:Render()
  end
  edge:SetScript("OnEnter", function(self)
    self.line:SetColorTexture(1, 0.82, 0, 0.6)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Drag to resize the list")
    GameTooltip:Show()
  end)
  edge:SetScript("OnLeave", function(self)
    self.line:SetColorTexture(1, 0.82, 0, 0.14)
    GameTooltip:Hide()
  end)
  edge:SetScript("OnMouseDown", function(self)
    self.dragging = true
    GameTooltip:Hide()
  end)
  edge:SetScript("OnMouseUp", stopDragging)
  edge:SetScript("OnHide", stopDragging)
  edge:SetScript("OnUpdate", function(self)
    if not self.dragging then return end
    local cursor = GetCursorPosition() / frame:GetEffectiveScale()
    UI:SetListWidth(cursor - frame:GetLeft() - PAD - 6)
  end)
  self.listEdge = edge
end

function UI:Row(index)
  local row = self.rows[index]
  if row then return row end
  row = CreateFrame("Button", nil, self.listContent)
  row:SetHeight(ROW_HEIGHT)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight", "ADD")
  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints()
  row.selected:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
  row.selected:SetVertexColor(1.0, 0.82, 0.0, 0.6)
  row.selected:Hide()
  addFold(row, 16, "LEFT", 2, 0)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.text:SetPoint("LEFT", 4, 0)
  row.text:SetPoint("RIGHT", -4, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row.statusIcon = row:CreateTexture(nil, "OVERLAY")
  row.statusIcon:SetSize(14, 14)
  row.statusIcon:SetPoint("RIGHT", -4, 0)
  row.trackIcon = row:CreateTexture(nil, "OVERLAY")
  row.trackIcon:SetSize(12, 12)
  row.trackIcon:SetPoint("RIGHT", row.statusIcon, "LEFT", -2, 0)
  row.trackIcon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02")
  row.when = row:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  row.when:SetPoint("RIGHT", row.statusIcon, "LEFT", -3, 0)
  -- In the Hidden group: bring this back.
  row.showButton = CreateFrame("Button", nil, row)
  row.showButton:SetSize(16, 16)
  row.showButton:SetPoint("RIGHT", -3, 0)
  row.showButton.icon = row.showButton:CreateTexture(nil, "ARTWORK")
  row.showButton.icon:SetAllPoints()
  row.showButton.icon:SetTexture("Interface\\Icons\\Spell_Holy_MindVision")
  row.showButton:SetHighlightTexture("Interface\\Icons\\Spell_Holy_MindVision", "ADD")
  row.showButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.words)
    GameTooltip:Show()
  end)
  row.showButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.showButton:Hide()
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if self.thread and self.thread.starting then return end -- It isn't a thread yet.
    if button == "RightButton" then
      if self.thread then
        UI:ThreadMenu(self, self.thread)
      elseif self.project then
        UI:ProjectMenu(self, self.project)
      elseif self.hiddenProject then
        UI:ProjectMenu(self, self.hiddenProject)
      end
      return
    end
    if self.foldKey then
      ns.db[self.foldKey] = not ns.db[self.foldKey] or nil
    elseif self.project then
      ns.db.collapsed[self.project] = not ns.db.collapsed[self.project] or nil
    elseif self.thread and IsShiftKeyDown() then
      ns:ToggleTracked(self.thread)
      return
    elseif self.thread then
      UI:SaveDraft()
      ns.db.selected = self.thread.id
    end
    UI:Render()
  end)
  row:SetScript("OnEnter", function(self)
    if self.thread and not self.thread.starting then UI:ShowThreadTip(self, self.thread) end
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.rows[index] = row
  return row
end

--- Projects in order of their most urgent thread. Threads arrive sorted by urgency.
local function grouped(threads)
  local order, byProject = {}, {}
  for _, thread in ipairs(threads) do
    if not byProject[thread.p] then
      byProject[thread.p] = {}
      order[#order + 1] = thread.p
    end
    table.insert(byProject[thread.p], thread)
  end
  return order, byProject
end

--- The game's own mark for a thread, and how bright: a mark you have already read fades.
function UI.RowMark(thread)
  if thread.pk == "z" then return "Interface\\Icons\\Spell_Nature_Sleep", 1 end
  local read = thread.pk or (ns.Game and not ns.Game.IsUnread(thread))
  if thread.s == "needs" then return "Interface\\GossipFrame\\ActiveQuestIcon", 1 end
  if thread.s == "error" then return "Interface\\RaidFrame\\ReadyCheck-NotReady", read and 0.6 or 1 end
  if thread.s == "running" then return UI.ActivityIcon(thread), 1 end
  if thread.s == "done" then return "Interface\\Buttons\\UI-CheckBox-Check", read and 0.5 or 1 end
  if thread.s == "stopped" then return "Interface\\Buttons\\UI-GroupLoot-Pass-Up", 0.6 end
  return nil, 1
end

--- Reuses rows from the top down, then hides whichever are left over.
function UI:RenderList(threads)
  local visible, hidden = {}, {}
  for _, thread in ipairs(threads) do
    if ns:IsHidden(thread) then hidden[#hidden + 1] = thread else visible[#visible + 1] = thread end
  end
  local snoozed, settled = {}, {}
  for _, thread in ipairs(ns.snapshot and ns.snapshot.pk or {}) do
    if thread.pk == "l" then -- Only here so a link can open it. It isn't on your list.
    elseif ns:IsHidden(thread) then
      hidden[#hidden + 1] = thread
    elseif thread.pk == "z" then
      snoozed[#snoozed + 1] = thread
    else
      settled[#settled + 1] = thread
    end
  end
  for _, row in ipairs(ns.starting) do
    if not ns:IsHidden(row) then table.insert(visible, 1, row) end
  end
  local order, byProject = grouped(visible)
  local index, y = 0, 0
  local width = self.listContent:GetWidth()
  local function place(height)
    index = index + 1
    local row = self:Row(index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.listContent, "TOPLEFT", 0, -y)
    row:SetWidth(width)
    row:SetHeight(height)
    row:Show()
    row.statusIcon:Hide()
    row.trackIcon:Hide()
    row.when:Hide()
    row.showButton:Hide()
    row.hiddenProject = nil
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    y = y + height
    return row
  end
  local function threadRow(thread, dim)
    local row = place(ROW_HEIGHT)
    row.project, row.thread, row.isHiddenHeader, row.foldKey = nil, thread, nil, nil
    showFold(row, nil)
    row.text:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.selected:SetShown(ns.db.selected == thread.id)
    row.text:SetFontObject("PromptPeonSmall")
    local title = ns.Plain(thread.t)
    if dim then title = "|cff808080" .. title .. "|r" end
    row.text:SetText(title)
    local icon, alpha = UI.RowMark(thread)
    local inset = 20
    if icon then
      row.statusIcon:SetTexture(icon)
      row.statusIcon:SetAlpha(alpha)
      row.statusIcon:SetDesaturated((dim and thread.pk ~= "z") or false)
      row.statusIcon:Show()
    end
    if ns:IsTracked(thread) and not thread.pk and not thread.starting then
      row.trackIcon:Show()
      inset = inset + 14
    end
    if thread.pk == "z" then
      row.when:SetText("|cff9fb8d6" .. UI.WakeWords(thread.zu, true) .. "|r")
      row.when:Show()
      inset = inset + math.ceil(row.when:GetStringWidth()) + 4
    end
    row.text:SetPoint("RIGHT", row, "RIGHT", -inset, 0)
  end
  local function showEye(row, words, run)
    row.showButton.words = words
    row.showButton:SetScript("OnClick", run)
    row.showButton:Show()
    row.statusIcon:Hide()
    row.trackIcon:Hide()
    row.when:Hide()
    row.text:SetPoint("RIGHT", row, "RIGHT", -22, 0)
  end
  --- A group below the projects, closed until you open it.
  local function bottomGroup(label, threads, foldKey)
    local isHidden = foldKey == "hiddenOpen"
    local projects, byName = grouped(threads)
    -- A hidden project with nothing in it right now still has to be findable, or you could never show it.
    if isHidden then
      for name in pairs(ns.db.hiddenProjects) do
        if not byName[name] then
          byName[name] = {}
          projects[#projects + 1] = name
        end
      end
    end
    local empty = 0
    for _, name in ipairs(projects) do
      if #byName[name] == 0 then empty = empty + 1 end
    end
    if #threads + empty == 0 then return end
    local header = place(HEADER_HEIGHT)
    header.project, header.thread, header.isHiddenHeader, header.foldKey = nil, nil, isHidden or nil, foldKey
    header.selected:Hide()
    header.text:SetFontObject("PromptPeonSmall")
    showFold(header, ns.db[foldKey] == true)
    header.text:SetPoint("LEFT", header, "LEFT", 20, 0)
    -- Only the newest settled threads reach the game, so a number there would stick at the cap.
    local count = foldKey == "settledOpen" and "" or (" (" .. (#threads + empty) .. ")")
    header.text:SetText("|cff808080" .. label .. count .. "|r")
    if ns.db[foldKey] then
      -- These come from every project, so say which, newest project first.
      for _, project in ipairs(projects) do
        local name = project
        local row = place(ROW_HEIGHT)
        row.project, row.thread, row.isHiddenHeader, row.foldKey = nil, nil, nil, nil
        row.selected:Hide()
        row.text:SetFontObject("PromptPeonSmall")
        showFold(row, nil)
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.text:SetText("|cffb8a56a" .. ns.Plain(name) .. "|r")
        if isHidden and ns.db.hiddenProjects[name] then
          row.hiddenProject = name
          showEye(row, "Show this project", function() UI:SetProjectHidden(name, false) end)
        end
        for _, thread in ipairs(byName[name]) do
          threadRow(thread, true)
          if isHidden and not ns.db.hiddenProjects[name] then
            local item = thread
            showEye(self.rows[index], "Show this thread", function() UI:ToggleHidden(item) end)
          end
        end
      end
    end
  end
  for _, project in ipairs(order) do
    local collapsed = ns.db.collapsed[project]
    local header = place(HEADER_HEIGHT)
    header.project, header.thread, header.isHiddenHeader, header.foldKey = project, nil, nil, nil
    header.selected:Hide()
    header.text:SetFontObject("PromptPeonHeader")
    showFold(header, not collapsed)
    header.text:SetPoint("LEFT", header, "LEFT", 20, 0)
    header.text:SetText(ns.Plain(project) .. "  |cff888888(" .. #byProject[project] .. ")|r")
    if not collapsed then
      for _, thread in ipairs(byProject[project]) do threadRow(thread, false) end
    end
  end
  -- Everything that isn't asking for you goes below the projects, closed by default.
  bottomGroup("Snoozed", snoozed, "snoozedOpen")
  bottomGroup("Settled", settled, "settledOpen")
  bottomGroup("Hidden", hidden, "hiddenOpen")
  -- The snapshot is cut at a cap. Say so, so a missing thread isn't a mystery.
  local total = tonumber(ns.snapshot and ns.snapshot.tc)
  if total and total > #threads then
    local row = place(ROW_HEIGHT)
    row.project, row.thread, row.isHiddenHeader, row.foldKey = nil, nil, nil, nil
    row.selected:Hide()
    showFold(row, nil)
    row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.text:SetFontObject("PromptPeonSmall")
    row.text:SetText("|cff808080Showing " .. #threads .. " of " .. math.floor(total) .. " threads. The rest are in T3.|r")
  end
  for extra = index + 1, #self.rows do self.rows[extra]:Hide() end
  self.listContent:SetHeight(math.max(y, 10))
  -- A list too long for its pane makes room for the scroll bar.
  local fits = y <= (self.listScroll:GetHeight() or 0)
  local rowWidth = fits and UI.ListWidth() or (UI.ListWidth() - 20)
  self.listContent:SetWidth(rowWidth)
  for placed = 1, index do self.rows[placed]:SetWidth(rowWidth) end
end
