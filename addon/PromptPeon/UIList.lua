-- List: the threads on the left, under project headers, with Snoozed, Settled and Hidden below.

local _, ns = ...
local UI = ns.UI
local PAD, addFold, showFold, hideScrollBarWhenIdle = UI.PAD, UI.AddFold, UI.ShowFold, UI.HideScrollBarWhenIdle
local STATUS, colored = UI.STATUS, UI.Colored

local ROW_HEIGHT = 20
local HEADER_HEIGHT = 22
local FILTER_HEIGHT = 24 -- The search box above the list, and the gap under it.
local TAG_WIDTH = 20
-- Soft colours that read on the dark window, so a project is a colour as well as two letters.
local TAG_COLORS = { "7fb2e5", "e5b27f", "9fd18b", "d89bd8", "e5d27f", "7fd6cf", "e59a8a", "b3a6ee" }

--- A project's two letters and its colour: the first letter of its first two words, or its first
--- two letters when it is one word. The same project always gets the same colour.
function UI.ProjectTag(project)
  local name = tostring(project or "")
  local first, second = name:match("^%W*(%w)%w*%W+(%w)")
  local letters = first and (first .. second) or name:match("%w%w?") or "?"
  return letters:upper(), TAG_COLORS[ns.Crc32(name) % #TAG_COLORS + 1]
end

function UI:BuildList(frame)
  local scroll = CreateFrame("ScrollFrame", "PromptPeonListScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", self.top, "BOTTOMLEFT", PAD, -2 - FILTER_HEIGHT)
  scroll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 40)
  scroll:SetWidth(UI.ListWidth())
  self.listScroll = scroll
  -- Type to narrow the list down: the game's own search box, as wide as the list.
  local filter = CreateFrame("EditBox", "PromptPeonListFilter", frame, "SearchBoxTemplate")
  filter:SetHeight(20)
  filter:SetPoint("BOTTOMLEFT", scroll, "TOPLEFT", 6, 4)
  filter:SetPoint("BOTTOMRIGHT", scroll, "TOPRIGHT", -2, 4)
  filter:SetAutoFocus(false)
  filter:HookScript("OnTextChanged", function(self)
    local words = ns.Typed(self:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if words == (UI.filter or "") then return end
    UI.filter = words ~= "" and words or nil
    if UI:IsOpen() then UI:Render() end
  end)
  self.filterBox = filter
  -- A text box keeps the keyboard until told otherwise. Click anywhere else and it lets go.
  local clicks = CreateFrame("Frame")
  clicks:RegisterEvent("GLOBAL_MOUSE_DOWN")
  clicks:SetScript("OnEvent", function()
    if filter:HasFocus() and not filter:IsMouseOver() then filter:ClearFocus() end
  end)
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
  -- Two letters for the thread's project, in that project's colour, in a column of their own.
  row.tag = row:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  row.tag:SetPoint("LEFT", 6, 0)
  row.tag:SetWidth(TAG_WIDTH)
  row.tag:SetJustifyH("LEFT")
  row.tag:SetWordWrap(false)
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
      elseif self.hiddenProject then
        UI:ProjectMenu(self, self.hiddenProject)
      end
      return
    end
    if self.foldKey then
      ns.db[self.foldKey] = not ns.db[self.foldKey] or nil
    elseif self.thread and IsShiftKeyDown() then
      ns:ToggleTracked(self.thread)
      return
    elseif self.thread then
      UI:OpenThread(self.thread.id) -- Out of any page or view, to the thread itself.
      return
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

--- Whether a thread's name or its project's has what you typed in the search box.
function UI:MatchesFilter(thread)
  local words = self.filter
  if not words then return true end
  return tostring(thread.t or ""):lower():find(words, 1, true) ~= nil or tostring(thread.p or ""):lower():find(words, 1, true) ~= nil
end

--- Reuses rows from the top down, then hides whichever are left over. While you're searching,
--- every group that has a match is open, whatever you folded, and the rest are left out.
function UI:RenderList(threads)
  local searching = self.filter ~= nil
  local visible, hidden = {}, {}
  for _, thread in ipairs(threads) do
    if not self:MatchesFilter(thread) then -- Left out while you search.
    elseif ns:IsHidden(thread) then hidden[#hidden + 1] = thread else visible[#visible + 1] = thread end
  end
  local snoozed, settled = {}, {}
  for _, thread in ipairs(ns.snapshot and ns.snapshot.pk or {}) do
    if thread.pk == "l" then -- Only here so a link can open it. It isn't on your list.
    elseif not self:MatchesFilter(thread) then
    elseif ns:IsHidden(thread) then
      hidden[#hidden + 1] = thread
    elseif thread.pk == "z" then
      snoozed[#snoozed + 1] = thread
    else
      settled[#settled + 1] = thread
    end
  end
  for _, row in ipairs(ns.starting) do
    if not ns:IsHidden(row) and self:MatchesFilter(row) then table.insert(visible, 1, row) end
  end
  -- Sorted by what a thread wants from you, not by project: whoever is waiting on you, finished work
  -- you haven't read, agents at work, and then the quiet ones. Each line says its project in two letters.
  local needs, unread, working, quiet = {}, {}, {}, {}
  for _, thread in ipairs(visible) do
    local wants = not thread.starting and ns:WantsYou(thread)
    local group = wants == "needs" and needs or wants == "unread" and unread or (thread.starting or thread.s == "running") and working or quiet
    group[#group + 1] = thread
  end
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
    row.tag:SetText("")
    row.hiddenProject = nil
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    y = y + height
    return row
  end
  local function threadRow(thread, dim)
    local row = place(ROW_HEIGHT)
    row.thread, row.isHiddenHeader, row.foldKey = thread, nil, nil
    showFold(row, nil)
    local letters, color = UI.ProjectTag(thread.p)
    row.tag:SetText("|cff" .. (dim and "707070" or color) .. letters .. "|r")
    row.text:SetPoint("LEFT", row, "LEFT", 10 + TAG_WIDTH, 0)
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
  --- A group of threads under one coloured heading. With a fold key it can be closed, and stays
  --- how you left it, except while you search.
  local function group(label, info, threads, closedKey)
    if #threads == 0 then return end
    local closed = closedKey and ns.db[closedKey] and not searching
    local header = place(HEADER_HEIGHT)
    header.thread, header.isHiddenHeader, header.foldKey = nil, nil, closedKey
    header.selected:Hide()
    header.text:SetFontObject("PromptPeonHeader")
    if closedKey then showFold(header, not closed) else showFold(header, nil) end
    header.text:SetPoint("LEFT", header, "LEFT", closedKey and 20 or 6, 0)
    header.text:SetText(colored(info, label) .. "  |cff888888(" .. #threads .. ")|r")
    if not closed then
      for _, thread in ipairs(threads) do threadRow(thread, false) end
    end
  end
  --- A group at the bottom, closed until you open it. Hidden also lists each project you hid as a
  --- line of its own, so it can be shown again even when none of its threads are here right now.
  local function bottomGroup(label, threads, foldKey)
    local isHidden = foldKey == "hiddenOpen"
    local projects = {}
    if isHidden and not searching then
      for name in pairs(ns.db.hiddenProjects) do projects[#projects + 1] = name end
      table.sort(projects)
    end
    -- A hidden project's threads go under its line. The rest are a flat list.
    local loose, under, empty = {}, {}, 0
    for _, thread in ipairs(threads) do
      if isHidden and ns.db.hiddenProjects[thread.p] and not searching then
        under[thread.p] = under[thread.p] or {}
        table.insert(under[thread.p], thread)
      else
        loose[#loose + 1] = thread
      end
    end
    for _, name in ipairs(projects) do
      if not under[name] then empty = empty + 1 end
    end
    if #threads + empty == 0 then return end
    local header = place(HEADER_HEIGHT)
    header.thread, header.isHiddenHeader, header.foldKey = nil, isHidden or nil, foldKey
    header.selected:Hide()
    header.text:SetFontObject("PromptPeonSmall")
    local open = searching or ns.db[foldKey] == true
    showFold(header, open)
    header.text:SetPoint("LEFT", header, "LEFT", 20, 0)
    -- Only the newest settled threads reach the game, so a number there would stick at the cap.
    local count = foldKey == "settledOpen" and "" or (" (" .. (#threads + empty) .. ")")
    header.text:SetText("|cff808080" .. label .. count .. "|r")
    if not open then return end
    for _, name in ipairs(projects) do
      local row = place(ROW_HEIGHT)
      row.thread, row.isHiddenHeader, row.foldKey = nil, nil, nil
      row.selected:Hide()
      row.text:SetFontObject("PromptPeonSmall")
      showFold(row, nil)
      local letters = UI.ProjectTag(name)
      row.tag:SetText("|cff707070" .. letters .. "|r")
      row.text:SetPoint("LEFT", row, "LEFT", 10 + TAG_WIDTH, 0)
      row.text:SetText("|cffb8a56a" .. ns.Plain(name) .. "|r  |cff808080whole project|r")
      row.hiddenProject = name
      showEye(row, "Show this project", function() UI:SetProjectHidden(name, false) end)
      for _, thread in ipairs(under[name] or {}) do threadRow(thread, true) end
    end
    for _, thread in ipairs(loose) do
      threadRow(thread, true)
      if isHidden and not ns.db.hiddenProjects[thread.p] then
        local item = thread
        showEye(self.rows[index], "Show this thread", function() UI:ToggleHidden(item) end)
      end
    end
  end
  group("Needs you", STATUS.needs, needs)
  group("Unread", STATUS.done, unread)
  group("Working", STATUS.running, working, "workingClosed")
  group("Quiet", STATUS.idle, quiet, "quietClosed")
  -- Parked threads go at the bottom, closed by default.
  bottomGroup("Snoozed", snoozed, "snoozedOpen")
  bottomGroup("Settled", settled, "settledOpen")
  bottomGroup("Hidden", hidden, "hiddenOpen")
  if searching and index == 0 then
    local row = place(ROW_HEIGHT)
    row.thread, row.isHiddenHeader, row.foldKey = nil, nil, nil
    row.selected:Hide()
    showFold(row, nil)
    row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.text:SetFontObject("PromptPeonSmall")
    row.text:SetText("|cff808080No thread or project has that in its name.|r")
  end
  -- The snapshot is cut at a cap. Say so, so a missing thread isn't a mystery.
  local total = tonumber(ns.snapshot and ns.snapshot.tc)
  if total and total > #threads then
    local row = place(ROW_HEIGHT)
    row.thread, row.isHiddenHeader, row.foldKey = nil, nil, nil
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
