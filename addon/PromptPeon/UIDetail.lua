-- Detail: builds the right-hand pane, its reusable pieces, and asks the bridge for what isn't here yet.
-- UIMessages.lua decides what the pane shows.

local _, ns = ...
local UI = ns.UI
local PAD, BACK_WIDTH, addFold, hideScrollBarWhenIdle = UI.PAD, UI.BACK_WIDTH, UI.AddFold, UI.HideScrollBarWhenIdle

local LOAD_PATIENCE = 30

function UI:BuildDetail(frame)
  local title = frame:CreateFontString(nil, "OVERLAY", "PromptPeonTitle")
  title:SetPoint("TOPLEFT", self.top, "BOTTOMLEFT", UI.ListWidth() + PAD + 16, -2)
  title:SetPoint("RIGHT", frame, "RIGHT", -PAD - 6, 0)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  self.title = title
  self.titleLeft = UI.ListWidth() + PAD + 16

  -- At the top, where it's there however far you've scrolled.
  local back = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  back:SetSize(BACK_WIDTH, 18)
  back:SetText("Back")
  back:SetScript("OnClick", function() UI:GoBack() end)
  back:Hide()
  self.back = back

  local meta = frame:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  meta:SetPoint("RIGHT", frame, "RIGHT", -PAD - 6, 0)
  meta:SetJustifyH("LEFT")
  meta:SetWordWrap(false)
  self.meta = meta

  -- What you do to the open thread, as small icon buttons beside its name.
  local function action(onClick)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(24, 18)
    button.icon = button:CreateTexture(nil, "OVERLAY")
    button.icon:SetSize(14, 14)
    button.icon:SetPoint("CENTER")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.label, 1, 0.82, 0)
      GameTooltip:AddLine(self.detail, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:Hide()
    return button
  end
  -- Two more ways to look at a thread, like T3's: what it changed and who it sent out.
  local function viewButton(name, verb, icon)
    local button = action(function() UI:ToggleView(name, verb) end)
    button.icon:SetTexture("Interface\\Icons\\" .. icon)
    return button
  end
  self.changes = viewButton("changes", "diff", "INV_Scroll_03")
  self.pullRequests = viewButton("prs", nil, "INV_Misc_Map_01")
  self.agents = viewButton("agents", "agents", "Ability_Warrior_BattleShout")
  self.primary = action(function() UI:PrimaryAction() end)
  self.secondary = action(function() UI:SecondaryAction() end)
  self.snoozeButton = action(function(button)
    local thread = ns:ThreadById(ns.db.selected)
    if thread then UI:SnoozeMenu(button, thread) end
  end)
  self.hideButton = action(function()
    local thread = ns:ThreadById(ns.db.selected)
    if thread then UI:ToggleHidden(thread) end
  end)

  -- Model and effort sit by the reply box, where T3 keeps them too.
  local function chip(width, onClick)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(width, 18)
    button:SetNormalFontObject("GameFontNormalSmall")
    button:SetHighlightFontObject("GameFontHighlightSmall")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("The next turn uses this.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:Hide()
    return button
  end
  self.effortChip = chip(84, function(self)
    local current, choose = UI:ModelTarget(ns:ThreadById(ns.db.selected))
    if current then UI:EffortMenu(self, current, choose) end
  end)
  self.modelChip = chip(124, function(self)
    local current, choose = UI:ModelTarget(ns:ThreadById(ns.db.selected))
    if current then UI:ModelMenu(self, current, choose) end
  end)
  self.views = {}
  self.steering = {}
  self.filePages = {}

  local scroll = CreateFrame("ScrollFrame", "PromptPeonDetailScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -8)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 22, 126)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(10, 10)
  scroll:SetScrollChild(content)
  hideScrollBarWhenIdle(scroll)
  self.detailScroll, self.detailContent = scroll, content
  self.lines = {}
  self.heads = {}
  self.groups = {} -- Work groups you opened or closed by hand.
  self.prOpen, self.prShown, self.prAll, self.prAsked = {}, {}, {}, {} -- Which pull request page, and how much of it.

  -- What the agent is doing right now, ticking between refreshes. Sits above the reply box.
  local activity = frame:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
  activity:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", UI.ListWidth() + PAD + 16, 108)
  activity:SetPoint("RIGHT", frame, "RIGHT", -PAD - 6, 0)
  activity:SetJustifyH("LEFT")
  activity:SetWordWrap(false)
  self.activity = activity

  local empty = frame:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
  empty:SetPoint("CENTER", scroll, "CENTER")
  self.empty = empty
end

--- Text blocks are reused between redraws, so a refresh only rewrites text.
function UI:Line(index)
  local line = self.lines[index]
  if line then return line end
  line = self.detailContent:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
  line:SetJustifyH("LEFT")
  line:SetJustifyV("TOP")
  line:SetWordWrap(true)
  self.lines[index] = line
  return line
end

--- A clickable "+ 3 thoughts, 9 steps" line above a group of work.
function UI:GroupHead(index)
  local head = self.heads[index]
  if head then
    head.right:SetText("")
    head.onClick = nil
    return head
  end
  head = CreateFrame("Button", nil, self.detailContent)
  addFold(head, 14, "LEFT", -1, 0)
  -- A column at the right edge, so counts line up however long the names are.
  head.right = head:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  head.right:SetPoint("RIGHT", -4, 0)
  head.right:SetJustifyH("RIGHT")
  head.right:SetWordWrap(false)
  head.text = head:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  head.text:SetPoint("LEFT", 15, 0)
  head.text:SetPoint("RIGHT", head.right, "LEFT", -8, 0)
  head.text:SetJustifyH("LEFT")
  head.text:SetWordWrap(false)
  head:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight", "ADD")
  head:SetScript("OnClick", function(self)
    local nowOpen = not self.open
    UI.groups[self.key] = nowOpen
    if self.onClick then self.onClick(nowOpen, self) end
    UI:Render()
  end)
  self.heads[index] = head
  return head
end

--- One picture in a thread. Clicking it opens it large.
function UI:Picture(index)
  self.pictures = self.pictures or {}
  local pic = self.pictures[index]
  if pic then return pic end
  pic = CreateFrame("Button", nil, self.detailContent)
  pic.tex = pic:CreateTexture(nil, "ARTWORK")
  pic.tex:SetAllPoints()
  pic:SetScript("OnClick", function(self) UI:ShowPicture(self.path, self.pictureWidth, self.pictureHeight, self.label) end)
  self.pictures[index] = pic
  return pic
end

function UI:ShowPicture(path, pictureWidth, pictureHeight, label)
  local viewer = self.viewer
  if not viewer then
    viewer = CreateFrame("Button", "PromptPeonPicture", UIParent, "BackdropTemplate")
    viewer:SetFrameStrata("DIALOG")
    viewer:SetPoint("CENTER")
    viewer:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
    viewer:SetBackdropColor(0, 0, 0, 0.92)
    viewer:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    viewer:SetScript("OnClick", function(self) self:Hide() end)
    viewer.tex = viewer:CreateTexture(nil, "ARTWORK")
    viewer.tex:SetPoint("TOPLEFT", 6, -6)
    viewer.caption = viewer:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
    viewer.caption:SetPoint("BOTTOM", 0, 5)
    table.insert(UISpecialFrames, "PromptPeonPicture") -- Escape closes it.
    self.viewer = viewer
  end
  local scale = math.min(UIParent:GetWidth() * 0.8 / pictureWidth, UIParent:GetHeight() * 0.8 / pictureHeight)
  local shownWidth, shownHeight = pictureWidth * scale, pictureHeight * scale
  viewer.tex:SetSize(shownWidth, shownHeight)
  viewer.tex:SetTexture(path)
  viewer.caption:SetText(ns.Plain(label) .. "  |cff888888Click to close|r")
  viewer:SetSize(shownWidth + 12, shownHeight + 30)
  viewer:Show()
end

--- Show what the thread changed, or its agents, instead of its messages. Asks the bridge every
--- time you open one, so you see the latest, and shows what we have until that arrives.
function UI:ToggleView(name, verb)
  local thread = ns:ThreadById(ns.db.selected)
  if not thread then return end
  if name == "prs" then self.prOpen[thread.id] = nil end -- The icon always starts from the list.
  if self.views[thread.id] == name then
    self.views[thread.id] = nil
  else
    self.views[thread.id] = name
    self.askedAt = GetTime()
    self.askedFor = name
    local kept = ns.loaded[thread.id]
    if kept then
      if name == "changes" then kept.df, kept.dn, kept.pages = nil, nil, nil elseif name == "agents" then kept.ax = nil end
    end
    if verb then ns:QueueCommand(thread.id, verb) end -- Pull requests come with the thread.
  end
  self.shownThread = nil
  self:Render()
end

--- True while we are waiting for the bridge to send a view, so refreshes come sooner.
function UI:IsLoading(thread)
  if thread and thread.pk and not thread.m and not thread.hd and self.viewAskedFor == thread.id
    and GetTime() - (self.viewAskedAt or 0) <= LOAD_PATIENCE then
    return true
  end
  local kept = thread and ns.loaded[thread.id] or {}
  if thread and self.askedOlder == thread.id and GetTime() - self.askedOlderAt <= LOAD_PATIENCE
    and kept.olderBefore ~= self.askedOlderBefore then
    return true
  end
  local view = thread and self.views and self.views[thread.id]
  if not view then return false end
  if view == "changes" and self.askedFile and GetTime() - self.askedFileAt <= LOAD_PATIENCE
    and not (kept.pages and kept.pages[self.askedFile]) then
    return true
  end
  if view == "prs" then
    for _, pr in ipairs(thread.prs or {}) do
      local asked = self.prAsked[thread.id .. ":" .. pr.n]
      if asked and GetTime() - asked <= LOAD_PATIENCE and not (kept.pullRequests and kept.pullRequests[pr.n]) then return true end
    end
    return false
  end
  if view ~= self.askedFor or GetTime() - (self.askedAt or 0) > LOAD_PATIENCE then return false end
  return not (view == "changes" and kept.df or view == "agents" and kept.ax)
end

--- Each ask makes T3 go and look, so once per pull request until it has had time to answer.
function UI:AskPullRequest(thread, pr)
  local key = thread.id .. ":" .. pr.n
  if not self.prAsked[key] or GetTime() - self.prAsked[key] > LOAD_PATIENCE then
    self.prAsked[key] = GetTime()
    ns:QueueCommand(thread.id, "pr", tostring(pr.n))
  end
end

--- Fetch the messages before the oldest one we have.
function UI:AskOlder(thread)
  local older = (ns.loaded[thread.id] or {}).older
  local first = (older and older[1]) or (thread.m and thread.m[1])
  if not first or not first[4] then return end
  self.askedOlder, self.askedOlderAt, self.askedOlderBefore = thread.id, GetTime(), first[4]
  ns:QueueCommand(thread.id, "older", tostring(first[4]))
end

--- Big files come a page at a time. Asks for the page unless we already have it.
function UI:AskFilePage(thread, path, number)
  self.filePages[thread.id .. ":file:" .. path] = number
  local kept = ns.loaded[thread.id]
  local wanted = path .. "\n" .. number
  if kept and kept.pages and kept.pages[wanted] then return end
  self.askedFile, self.askedFileAt = wanted, GetTime()
  ns:QueueCommand(thread.id, "file", wanted)
end

function UI:LoadingWords(thread)
  if self:IsLoading(thread) then return "Asking T3..." end
  if thread and thread.pk then return "T3 did not send this. Open another thread and come back to ask again." end
  return "T3 did not send this. Press the button twice to ask again."
end

--- Snoozed and settled threads don't ride along in every refresh, so ask when you open one.
function UI:AskForParked(thread)
  if not thread.pk then
    self.viewAskedFor = nil
    return
  end
  if thread.hd or thread.m or self.viewAskedFor == thread.id then return end
  self.viewAskedFor, self.viewAskedAt = thread.id, GetTime()
  ns:QueueCommand(thread.id, "view")
end
