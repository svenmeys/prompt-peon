-- Render: redraws everything, in order. Everything that changes state ends up calling this.

local _, ns = ...
local UI = ns.UI

local function selectedThread(threads)
  -- A hidden thread can be open while the Hidden group is, and while a search is listing it: either
  -- way you clicked it where it was shown. Anywhere else, picking it falls back to the first one.
  local showsHidden = ns.db.hiddenOpen or UI.filter ~= nil
  local fallback
  for _, thread in ipairs(threads) do
    if thread.id == ns.db.selected and (showsHidden or not ns:IsHidden(thread)) then return thread end
    if not fallback and not ns:IsHidden(thread) then fallback = thread end
  end
  -- Opened from the Snoozed or Settled groups.
  local parked = ns:ThreadById(ns.db.selected)
  if parked and parked.pk and (showsHidden or not ns:IsHidden(parked)) then return parked end
  return fallback
end

--- The tracker and party frames show with the log closed. The rest only draws when it's open.
function UI:Render()
  if not self.tracker then return end
  self:RenderTracker()
  self:RenderParty()
  self:RenderMinimapButton()
  if not self:IsOpen() then return end

  local problem = ns:Problem()
  self.problem:SetText(problem or "")
  self.problem:SetShown(problem ~= nil)
  self.top:ClearAllPoints()
  self.top:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, problem and -54 or -28)

  local threads = ns.snapshot and ns.snapshot.threads or {}
  local thread = selectedThread(threads)
  if thread then ns.db.selected = thread.id end
  self.activityThread = thread

  -- Picking another thread means you moved on. What you wrote waits for next time.
  if self.newThread and self.newThread.selected ~= ns.db.selected then self:StopNewThread() end
  self:RenderList(threads)
  self:RenderDetail(thread)

  local box = self.input.EditBox
  local editing = self.editingQueued
  if thread and editing and editing.thread == thread.id then
    -- It went out while you were editing. Your words stay in the box as an ordinary draft.
    local queued = false
    for _, row in ipairs(thread.m or {}) do
      if row[3] == "q" and row[5] == editing.run then queued = true end
    end
    if not queued then
      self.editingQueued, editing = nil, nil
    end
  end
  if thread and self.newThread then
    self.hint:SetText("What should the new thread do?")
    self:SetNotice("")
  elseif thread then
    if self.draftFor ~= thread.id then
      self.answering = nil -- Before saving, so your answer doesn't become this thread's draft.
      self:SaveDraft() -- What is in the box belongs to the thread it was typed for, even if that's gone.
      self.editingQueued = nil
      self.draftFor = thread.id
      box:SetText(ns.db.drafts[thread.id] or "")
    elseif box:GetText() == "" and ns.db.drafts[thread.id] and not box:HasFocus() and not editing then
      box:SetText(ns.db.drafts[thread.id]) -- A reply that failed comes back here.
    end
    local answering = self.answering
    local choices = answering and UI.OpenQuestion(thread)
    if answering and (not choices or choices.r ~= answering.mark) then
      self:StopAnswering() -- It was answered or changed while you typed.
      answering, choices = nil, nil
    end
    if answering then
      self.hint:SetText("Your answer to: " .. ns.Plain(UI.Gist(choices.q[answering.question].t)))
      self:SetNotice("Enter sends your answer. Empty the box and press Enter to go back.")
    else
      self.hint:SetText(editing and "You are editing a queued message" or "Reply to " .. ns.Plain(thread.t))
      self:SetNotice(editing and "Editing a queued message. Enter saves it. Empty the box and press Enter to stop." or self:ReplyState(thread))
    end
  else
    self.hint:SetText("")
    self:SetNotice("")
  end
  self.updateHint()

  local needsReload = ns:NeedsReload()
  self.reload:SetShown(needsReload)
  self:RenderControls(thread)
  self:PlaceFooter()
  self:RenderReloadHint()
  if ns.Game then ns.Game:RenderSpellBar() end
  self:PlaceNotice()
end
