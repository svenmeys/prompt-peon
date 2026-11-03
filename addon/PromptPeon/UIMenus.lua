-- Menus: the hover tip and right-click menus. Own frames, because the two clients have different
-- menu systems. Model, effort, snooze and hide choices all go through ShowMenu.

local _, ns = ...
local UI = ns.UI
local STATUS, colored = UI.STATUS, UI.Colored

function UI:ShowThreadTip(owner, thread)
  local info = STATUS[thread.s] or STATUS.idle
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ns.Plain(thread.t), 1, 0.82, 0, true)
  GameTooltip:AddLine(colored(info, info.label) .. "  |cff888888" .. ns.Plain(thread.p) .. "|r")
  if thread.a and thread.a ~= info.label then GameTooltip:AddLine(ns.Plain(thread.a), 0.8, 0.8, 0.8, true) end
  if ns.Game and ns.Game.IsLowOnMana(thread) then
    GameTooltip:AddLine("Need more mana! " .. (100 - thread.cu) .. "% context left. Evocation compacts it.", 0.45, 0.65, 1, true)
  elseif thread.cu then
    GameTooltip:AddLine("Context " .. thread.cu .. "%", 0.6, 0.7, 1)
  end
  if ns.Game then
    GameTooltip:AddLine(ns.Game.LevelWords(thread), 1, 0.82, 0, true)
    GameTooltip:AddLine(ns.Game.HealthWords(thread), 0.45, 0.85, 0.5, true)
  end
  GameTooltip:AddLine("Shift-click to track. Right-click for options.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

function UI:BuildMenu()
  -- Clicking anywhere else closes the menu.
  local catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("DIALOG")
  catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  catcher:SetScript("OnClick", function() UI:CloseMenu() end)
  catcher:Hide()
  local menu = CreateFrame("Frame", "PromptPeonMenu", catcher, "BackdropTemplate")
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  menu:SetBackdropColor(0, 0, 0, 0.92)
  menu:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
  self.menuCatcher, self.menu, self.menuButtons = catcher, menu, {}
end

function UI:CloseMenu()
  if self.menuCatcher then self.menuCatcher:Hide() end
end

--- A small native-looking list. Own frames, because the two clients have different menu systems.
--- A menu, in groups. Items are { text, run, keepOpen, checked } or { title } for a group's heading,
--- and false leaves one out.
function UI:ShowMenu(owner, items)
  local shownItems = {}
  for _, item in ipairs(items) do
    if item then shownItems[#shownItems + 1] = item end
  end
  items = shownItems
  if not self.menu then self:BuildMenu() end
  local width, y = 210, 6
  for index, item in ipairs(items) do
    local button = self.menuButtons[index]
    if not button then
      button = CreateFrame("Button", nil, self.menu)
      button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight", "ADD")
      button.text = button:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
      button.text:SetPoint("LEFT", 6, 0)
      button.text:SetPoint("RIGHT", -4, 0)
      button.text:SetJustifyH("LEFT")
      button.text:SetWordWrap(false)
      button:SetScript("OnClick", function(self)
        if not self.keepOpen then UI:CloseMenu() end
        if self.run then self.run() end
      end)
      self.menuButtons[index] = button
    end
    local height = item.title and 17 or 18
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", self.menu, "TOPLEFT", 6, -y)
    button:SetSize(width - 12, height)
    if item.title then
      button.text:SetText("|cff9a9a9a" .. item.title .. "|r")
    else
      button.text:SetText((item.checked and "|TInterface\\Buttons\\UI-CheckBox-Check:12|t " or "") .. item.text)
    end
    button:EnableMouse(not item.title)
    button.run, button.keepOpen = item.run, item.keepOpen or not item.run
    button:Show()
    y = y + height
  end
  for extra = #items + 1, #self.menuButtons do self.menuButtons[extra]:Hide() end
  self.menu:SetSize(width, y + 6)
  self.menu:ClearAllPoints()
  -- Low on the screen it opens upward, so it doesn't cover what you just clicked.
  local bottom = owner:GetBottom()
  if bottom and bottom < UIParent:GetHeight() / 3 then
    self.menu:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, 2)
  else
    self.menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 12, 0)
  end
  self.menu:SetClampedToScreen(true)
  self.menuCatcher:Show()
end

--- The model entry T3 listed, if it did: slug, name, effort option, levels, level names, default.
function UI.FindModel(instance, model)
  for _, provider in ipairs(ns.snapshot and ns.snapshot.md or {}) do
    if provider.i == instance then
      for _, entry in ipairs(provider.m) do
        if entry[1] == model then return entry end
      end
    end
  end
end

function UI.ModelName(instance, model)
  local entry = UI.FindModel(instance, model)
  return entry and entry[2] or model or "Default"
end

function UI.EffortName(instance, model, effort)
  local entry = UI.FindModel(instance, model)
  for index, level in ipairs(entry and entry[4] or {}) do
    if level == effort then return entry[5][index] end
  end
  return effort or "Default"
end

--- Opens on the provider you're using, because that's usually where you stay.
function UI:ModelMenu(owner, current, choose)
  local providers = ns.snapshot and ns.snapshot.md or {}
  local mine = providers[1]
  for _, provider in ipairs(providers) do
    if provider.i == current.instance then mine = provider end
  end
  if mine then self:ProviderMenu(owner, mine, current, choose) end
end

function UI:ProviderMenu(owner, provider, current, choose)
  local providers = ns.snapshot and ns.snapshot.md or {}
  local items = { { title = provider.n } }
  for _, model in ipairs(provider.m) do
    items[#items + 1] = { text = model[2], checked = provider.i == current.instance and model[1] == current.model, run = function()
      -- Keep the effort when the new model has that level too. Otherwise it gets its own default.
      local effort = ""
      for _, level in ipairs(model[4]) do
        if level == current.effort then effort = level end
      end
      choose(provider.i, model[1], effort)
    end }
  end
  if #providers > 1 then
    items[#items + 1] = { text = "Other providers >", keepOpen = true, run = function() UI:ProvidersMenu(owner, current, choose) end }
  end
  self:ShowMenu(owner, items)
end

function UI:ProvidersMenu(owner, current, choose)
  local items = { { title = "Provider" } }
  for _, provider in ipairs(ns.snapshot and ns.snapshot.md or {}) do
    items[#items + 1] = { text = provider.n .. " >", checked = provider.i == current.instance, keepOpen = true, run = function()
      UI:ProviderMenu(owner, provider, current, choose)
    end }
  end
  self:ShowMenu(owner, items)
end

function UI:EffortMenu(owner, current, choose)
  local model = UI.FindModel(current.instance, current.model)
  if not model then return end
  local items = { { title = "Effort for " .. model[2] } }
  local chosen = current.effort or model[6]
  for index, level in ipairs(model[4]) do
    items[#items + 1] = { text = model[5][index], checked = level == chosen, run = function()
      choose(current.instance, current.model, level)
    end }
  end
  self:ShowMenu(owner, items)
end

--- Tell T3, and show it right away. The next refresh says what T3 really has.
function UI:SetThreadModel(thread, instance, model, effort)
  if not ns:QueueCommand(thread.id, "setmodel", instance .. "\n" .. model .. "\n" .. (effort or "")) then return end
  thread.mi, thread.mo, thread.ef = instance, model, effort ~= "" and effort or nil
  self:SetNotice("The next turn uses " .. UI.ModelName(instance, model) .. ".")
  self:Render()
end

--- The right-click menu is a shortcut for threads you aren't looking at. The open thread has real
--- buttons, and model and effort sit by the reply box.
function UI:ThreadMenu(owner, thread, fromParty)
  local open = { text = "Open", run = function() UI:OpenThread(thread.id) end }
  local hide
  if ns.db.hiddenProjects[thread.p] then
    hide = { text = "Show " .. ns.Plain(thread.p), run = function() UI:ToggleHidden(thread) end }
  elseif ns.db.hiddenThreads[thread.id] then
    hide = { text = "Show", run = function() UI:ToggleHidden(thread) end }
  else
    hide = { text = "Hide...", run = function() UI:HideMenu(owner, thread) end }
  end
  if thread.pk then
    self:ShowMenu(owner, {
      open,
      { text = thread.pk == "z" and "Wake it up" or "Reopen", run = function() UI:Unpark(thread) end },
      hide,
    })
    return
  end
  self:ShowMenu(owner, {
    open,
    thread.s == "running" and { text = "Stop", run = function()
      StaticPopup_Show("PROMPTPEON_ABANDON", ns.Plain(thread.t), nil, thread.id)
    end } or { text = thread.s == "error" and "Release Spirit" or "Turn in", run = function()
      UI:ConfirmSettle(thread)
    end },
    thread.s == "error" and ns.Game and { text = "Resurrect", run = function() ns.Game:Resurrect(thread) end } or false,
    thread.s ~= "needs" and { text = "Snooze...", run = function() UI:SnoozeMenu(owner, thread) end } or false,
    { text = ns:IsTracked(thread) and "Stop tracking" or "Track", run = function() ns:ToggleTracked(thread) end },
    fromParty and { text = "Change face", run = function() UI.NextFace(thread) end } or false,
    hide,
  })
end

function UI:HideMenu(owner, thread)
  self:ShowMenu(owner, {
    { title = "Hide" },
    { text = "This thread", run = function() UI:ToggleHidden(thread) end },
    { text = "All of " .. ns.Plain(thread.p), run = function() UI:SetProjectHidden(thread.p, true) end },
  })
end

--- When to wake a snoozed thread, as T3's own snooze offers. Times are this computer's clock.
function UI.SnoozeChoices(now)
  local today = date("*t", now)
  local function morning(days)
    return time({ year = today.year, month = today.month, day = today.day + days, hour = 8, min = 0, sec = 0 })
  end
  local toMonday = (9 - today.wday) % 7 -- Sunday is 1, so Monday is 2.
  if toMonday == 0 then toMonday = 7 end
  return {
    { "For 1 hour", now + 3600 },
    { "For 4 hours", now + 4 * 3600 },
    { "Until tomorrow morning", morning(1) },
    { "Until Monday morning", morning(toMonday) },
  }
end

function UI:SnoozeMenu(owner, thread)
  local items = { { title = "Snooze this thread" } }
  for _, choice in ipairs(UI.SnoozeChoices(time())) do
    items[#items + 1] = { text = choice[1], run = function()
      if ns:QueueCommand(thread.id, "snooze", tostring(choice[2])) then
        UI:SetNotice("Snoozing it until " .. UI.WakeWords(choice[2]) .. ".")
      end
    end }
  end
  self:ShowMenu(owner, items)
end

--- "09:00" today, "Mon 09:00" any other day. Short leaves the day alone, for a list row.
function UI.WakeWords(epoch, short)
  if not epoch then return "later" end
  if date("%Y%j", epoch) == date("%Y%j", time()) then return date("%H:%M", epoch) end
  return date(short and "%a" or "%a %H:%M", epoch)
end

function UI:ProjectMenu(owner, project)
  local hidden = ns.db.hiddenProjects[project] == true
  self:ShowMenu(owner, {
    not hidden and { text = "New thread here", run = function() UI:StartNewThread(project) end } or false,
    not hidden and { text = ns.db.collapsed[project] and "Expand" or "Collapse", run = function()
      ns.db.collapsed[project] = not ns.db.collapsed[project] or nil
      UI:Render()
    end } or false,
    { text = hidden and "Show this project" or "Hide this project", run = function() UI:SetProjectHidden(project, not hidden) end },
  })
end
