-- Controls: the buttons around the open thread, what each one does, and the questions they ask first.

local _, ns = ...
local UI = ns.UI
local PAD = UI.PAD

function UI:SetProjectHidden(project, hidden)
  ns.db.hiddenProjects[project] = hidden or nil
  ns:ScrubHidden()
  ns:SendHidden()
  UI:Render()
end

function UI:ToggleHidden(thread)
  -- Hidden along with its whole project, so showing it means showing the project.
  if ns.db.hiddenProjects[thread.p] then
    ns.db.hiddenProjects[thread.p] = nil
  else
    ns.db.hiddenThreads[thread.id] = not ns.db.hiddenThreads[thread.id] or nil
  end
  ns:ScrubHidden()
  ns:SendHidden()
  self:Render()
end

--- Bring a snoozed or settled thread back to the list.
function UI:Unpark(thread)
  ns:QueueCommand(thread.id, thread.pk == "z" and "unsnooze" or "unsettle")
end

--- Turning a thread in takes it off your list, so one stray click shouldn't do it.
function UI:ConfirmSettle(thread)
  StaticPopup_Show(thread.s == "error" and "PROMPTPEON_RELEASE" or "PROMPTPEON_TURN_IN", ns.Plain(thread.t), nil, thread.id)
end

--- The buttons above the open thread.
function UI:PrimaryAction()
  local thread = ns:ThreadById(ns.db.selected)
  if not thread then return end
  if thread.pk then
    self:Unpark(thread)
  elseif thread.s == "running" then
    StaticPopup_Show("PROMPTPEON_ABANDON", ns.Plain(thread.t), nil, thread.id)
  elseif thread.s == "error" and ns.Game then
    ns.Game:Resurrect(thread)
  else
    self:ConfirmSettle(thread)
  end
end

function UI:SecondaryAction()
  local thread = ns:ThreadById(ns.db.selected)
  if not thread then return end
  if thread.s == "error" then self:ConfirmSettle(thread) else ns:ToggleTracked(thread) end
end

--- Whatever model and effort the box by the reply controls: a new thread's, or the open one's.
function UI:ModelTarget(thread)
  local new = self.newThread
  if new then
    return { instance = new.instance, model = new.model, effort = new.effort }, function(instance, model, effort)
      new.instance, new.model, new.effort = instance, model, effort ~= "" and effort or nil
      UI:Render()
    end
  end
  if thread and thread.mi then
    return { instance = thread.mi, model = thread.mo, effort = thread.ef }, function(instance, model, effort)
      UI:SetThreadModel(thread, instance, model, effort)
    end
  end
end

--- The thread's name gets whatever the icons leave, and an icon that doesn't apply leaves no gap.
function UI:PlaceHeaderButtons()
  self.title:SetPoint("TOPLEFT", self.top, "BOTTOMLEFT", self.titleLeft, -2)
  local step, buttons = 26, { self.hideButton, self.snoozeButton, self.secondary, self.primary }
  local shown = 0
  for _, button in ipairs(buttons) do
    if button:IsShown() then shown = shown + 1 end
  end
  self.title:SetPoint("RIGHT", self.frame, "RIGHT", -PAD - 6 - shown * step, 0)
  local slot = 0
  for _, button in ipairs(buttons) do
    button:ClearAllPoints()
    if button:IsShown() then
      button:SetPoint("LEFT", self.title, "RIGHT", 4 + slot * step, 0)
      slot = slot + 1
    end
  end
end

--- The threads waiting on you for an answer or an approval, in list order.
function UI.Waiting()
  local waiting = {}
  for _, thread in ipairs(ns:VisibleThreads()) do
    if thread.s == "needs" then waiting[#waiting + 1] = thread end
  end
  return waiting
end

--- Open the next thread waiting on you, round and round. What the key binding does.
function UI:NextWaiting()
  local waiting = UI.Waiting()
  if #waiting == 0 then
    if ns.Chat then ns.Chat:ReportReload("Nobody is waiting on you.") end
    return
  end
  local pick = waiting[1]
  for index, thread in ipairs(waiting) do
    if thread.id == ns.db.selected and self:IsOpen() then pick = waiting[index % #waiting + 1] end
  end
  self:OpenThread(pick.id)
end

--- Open the log with the cursor in the reply box. What the other key binding does.
--- The cursor goes there a moment later, once the game is done with the key you pressed. Given the
--- keyboard straight away, the box could get that same key: a letter typed into your reply, or Enter sending it.
function UI:StartReply()
  if not self.frame or InCombatLockdown() then return end
  if not self:IsOpen() then self.frame:Show() end
  C_Timer.After(0, function()
    if UI:IsOpen() and not InCombatLockdown() then UI.input.EditBox:SetFocus() end
  end)
end

UI.sideTabTop = -36 -- Just under the title bar, where the spellbook starts its tabs.
UI.sideTabPitch = 49 -- The spellbook's: its tab art is 56 tall, so closer and the plates overlap.
UI.sideTabGap = 8 -- Between the pages and the open thread's own tabs.

--- Stacks the shown tabs down the right edge, so a missing one leaves no hole: the pages first, then,
--- after a gap, the open thread's. UIFrame.lua's MIN_HEIGHT is what all six need.
function UI:PlaceSideTabs()
  local y, gapped = UI.sideTabTop, false
  for _, tab in ipairs(self.sideTabs) do
    if tab:IsShown() then
      if tab.ofThread and not gapped then
        gapped = true
        if y ~= UI.sideTabTop then y = y - UI.sideTabGap end
      end
      tab:ClearAllPoints()
      tab:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 0, y)
      y = y - UI.sideTabPitch
    end
  end
end

--- Each page's tab is pressed while its page is open. RenderDetail sets the open thread's own tabs.
function UI:RenderSideTabs()
  if not self.sideTabs then return end
  local game = ns.Game
  self.reportIcon:SetShown(game ~= nil)
  self.achievementsIcon:SetShown(game ~= nil)
  local function light(button, lit)
    button.icon:SetDesaturated(not lit)
    button.icon:SetAlpha(lit and 1 or 0.6)
  end
  local report = (self.showReport and game and game.report) and true or false
  self.reportIcon:SetChecked(report)
  light(self.reportIcon, report or (game and game.reportFresh and true) or false)
  self.achievementsIcon:SetChecked(self.showAchievements and true or false)
  light(self.achievementsIcon, self.showAchievements and true or false)
  self.options:SetChecked(self.showOptions and true or false)
  light(self.options, true)
  self:PlaceSideTabs()
end

--- Which buttons the open thread gets, and what each one says in its current state.
function UI:RenderControls(thread)
  local onPage = self.newThread or self.showOptions or self.showAchievements or (self.showReport and ns.Game and ns.Game.report)
  local open = thread and not onPage
  -- A thread you followed a link to isn't on your list, so there's nothing to turn in or reopen.
  self.primary:SetShown((open and thread.pk ~= "l") or false)
  self.secondary:SetShown((open and not thread.pk) or false)
  self.hideButton:SetShown(open or false)
  self.snoozeButton:SetShown((open and not thread.pk and thread.s ~= "needs") or false)
  if open then
    local function set(button, icon, label, detail, dimmed)
      button.icon:SetTexture("Interface\\" .. icon)
      button.icon:SetDesaturated(dimmed or false)
      button.label, button.detail = label, detail
    end
    set(self.snoozeButton, "Icons\\Spell_Nature_Sleep", "Snooze", "Put it to sleep for a while. It moves to the bottom of the list and comes back by itself.")
    if thread.pk == "z" then
      set(self.primary, "Icons\\Spell_Holy_MindVision", "Wake it up", "It's snoozed until " .. UI.WakeWords(thread.zu) .. ". Bring it back now.")
    elseif thread.pk then
      set(self.primary, "GossipFrame\\AvailableQuestIcon", "Reopen", "It's turned in. Put it back on your list.")
    elseif thread.s == "running" then
      set(self.primary, "Buttons\\UI-GroupLoot-Pass-Up", "Stop", "Stop the agent. It asks you first.")
    elseif thread.s == "error" and ns.Game then
      set(self.primary, "Icons\\Spell_Holy_Resurrection", "Resurrect", "Tell it to try again, a different way.")
    else
      set(self.primary, "GossipFrame\\ActiveQuestIcon", "Turn in", "Mark it finished, like handing in a quest. It asks you first, and you can reopen it from Settled.")
    end
    if thread.s == "error" then
      set(self.secondary, "Icons\\Spell_Shadow_GhostKey", "Release Spirit", "Mark it finished, and leave it dead. It asks you first.")
    elseif ns:IsTracked(thread) then
      set(self.secondary, "Icons\\INV_Misc_Spyglass_02", "Tracked", "On the tracker and the party frames. Click to take it off.")
    else
      set(self.secondary, "Icons\\INV_Misc_Spyglass_02", "Track", "Keep it on the tracker and the party frames.", true)
    end
    if ns.db.hiddenProjects[thread.p] then
      set(self.hideButton, "Icons\\Ability_Stealth", "Show " .. ns.Plain(thread.p), "This whole project is hidden. Bring all of it back, with its text.", true)
    elseif ns.db.hiddenThreads[thread.id] then
      set(self.hideButton, "Icons\\Ability_Stealth", "Show", "Bring it back, with its text.", true)
    else
      set(self.hideButton, "Icons\\Ability_Stealth", "Hide", "Hide it. Only its title and status stay in the game.")
    end
  end
  -- The open thread's tabs stay while a page is open, so nothing on the edge moves when you
  -- press one. They only go when there is no thread to have them.
  if not thread then
    self.changes:Hide()
    self.pullRequests:Hide()
    self.agents:Hide()
  end
  self:RenderSideTabs()
  self:PlaceHeaderButtons()

  local current = (not onPage or self.newThread) and self:ModelTarget(thread) or nil
  local hasCatalog = ns.snapshot and ns.snapshot.md and #ns.snapshot.md > 0
  local entry = current and UI.FindModel(current.instance, current.model)
  self.modelChip:SetShown((current and hasCatalog) or false)
  self.effortChip:SetShown((entry and #entry[4] > 0) or false)
  if current and hasCatalog then self.modelChip:SetText(ns.Plain(UI.ModelName(current.instance, current.model))) end
  if entry and #entry[4] > 0 then self.effortChip:SetText(ns.Plain(UI.EffortName(current.instance, current.model, current.effort or entry[6]))) end
  self.modelChip:ClearAllPoints()
  if self.effortChip:IsShown() then
    self.modelChip:SetPoint("RIGHT", self.effortChip, "LEFT", -3, 0)
  else
    self.modelChip:SetPoint("RIGHT", self.effortChip, "RIGHT", 0, 0)
  end
end

StaticPopupDialogs["PROMPTPEON_ABANDON"] = {
  text = "Abandon %s?\n\nThe agent stops now.",
  button1 = "Abandon",
  button2 = "Keep working",
  OnAccept = function(_, threadId) ns:QueueCommand(threadId, "stop") end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local function settleById(_, threadId)
  local thread = ns:ThreadById(threadId)
  if thread then ns:Settle(thread) end
end

StaticPopupDialogs["PROMPTPEON_TURN_IN"] = {
  text = "Turn in %s?\n\nIt's marked finished and leaves your list. You can reopen it from Settled.",
  button1 = "Turn in",
  button2 = "Not yet",
  OnAccept = settleById,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

StaticPopupDialogs["PROMPTPEON_RELEASE"] = {
  text = "Release Spirit on %s?\n\nIt's marked finished and stays dead. You can reopen it from Settled.",
  button1 = "Release Spirit",
  button2 = "Not yet",
  OnAccept = settleById,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}
