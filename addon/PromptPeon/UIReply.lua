-- Reply: the box you type in, the bottom row of buttons, and sending what you wrote: a reply,
-- an edit to a queued message, or a new thread.

local _, ns = ...
local UI = ns.UI
local PAD, TINY_WIDTH, hideScrollBarWhenIdle = UI.PAD, UI.TINY_WIDTH, UI.HideScrollBarWhenIdle

--- A trail for when typing stops working, kept across a reload so it can be read afterwards. Never any words.
function UI:NoteKeyboard(what)
  local trail = ns.db.keyboardTrail or {}
  ns.db.keyboardTrail = trail
  local holding = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
  local under = GetMouseFoci and GetMouseFoci()[1] or GetMouseFocus and GetMouseFocus()
  local function nameOf(thing)
    return thing and thing.GetName and (thing:GetName() or "unnamed") or "nothing"
  end
  trail[#trail + 1] = { at = time(), what = what, holding = holding == self.input.EditBox and "reply box" or nameOf(holding), under = nameOf(under),
    overBox = self.holder:IsMouseOver(), shown = self.frame:IsShown(), fight = InCombatLockdown and InCombatLockdown() or false }
  if #trail > 12 then table.remove(trail, 1) end
end

function UI:BuildReply(frame)
  local holder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  holder:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", UI.ListWidth() + PAD + 14, 40)
  holder:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 6, 40)
  holder:SetHeight(64)
  holder:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  holder:SetBackdropColor(0, 0, 0, 0.55)
  holder:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

  local scroll = CreateFrame("ScrollFrame", "PromptPeonReplyScroll", holder, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -7)
  scroll:SetPoint("BOTTOMRIGHT", -26, 7)
  hideScrollBarWhenIdle(scroll)

  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetFontObject("PromptPeonBody")
  box:SetMaxLetters(ns.MAX_REPLY_BYTES)
  box:SetWidth(200)
  scroll:SetScrollChild(box)
  scroll:SetScript("OnSizeChanged", function(_, width) box:SetWidth(math.max(width, 50)) end)
  --- A click on the box always gets the keyboard, even from whatever was holding it.
  local function takeKeyboard()
    local holding = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if holding and holding ~= box and holding.ClearFocus then holding:ClearFocus() end
    box:SetFocus()
    UI:NoteKeyboard(box:HasFocus() and "took it" or "couldn't take it")
  end
  holder:SetScript("OnMouseDown", takeKeyboard)
  scroll:SetScript("OnMouseDown", takeKeyboard)
  box:SetScript("OnMouseDown", takeKeyboard)

  local hint = holder:CreateFontString(nil, "OVERLAY", "PromptPeonHint")
  hint:SetPoint("TOPLEFT", 9, -8)
  hint:SetPoint("RIGHT", -26, 0)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(false)
  self.hint = hint
  -- Says how the box works for as long as it's empty, including while you're about to type.
  local keys = holder:CreateFontString(nil, "OVERLAY", "PromptPeonHint")
  keys:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -2)
  keys:SetPoint("RIGHT", -26, 0)
  keys:SetJustifyH("LEFT")
  keys:SetWordWrap(false)
  keys:SetText("Enter to send. Shift+Enter for a new line.")
  self.hintKeys = keys
  local function updateHint()
    hint:SetShown(box:GetText() == "")
    keys:SetShown(box:GetText() == "")
  end

  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  -- Enter sends. Shift+Enter makes a new line, as in T3.
  box:SetScript("OnEnterPressed", function(self)
    if IsShiftKeyDown() then self:Insert("\n") else UI:Send() end
  end)
  box:SetScript("OnEditFocusGained", updateHint)
  box:SetScript("OnEditFocusLost", function()
    updateHint()
    UI:NoteKeyboard("lost it")
  end)
  box:SetScript("OnTextChanged", updateHint)
  box:SetScript("OnCursorChanged", function(_, _, y, _, height)
    local top, view = scroll:GetVerticalScroll(), scroll:GetHeight()
    if -y < top then
      scroll:SetVerticalScroll(-y)
    elseif -y + height > top + view then
      scroll:SetVerticalScroll(-y + height - view)
    end
  end)
  -- A WoW text box keeps the keyboard until told otherwise. Click anywhere else and it lets go,
  -- so typing only goes here while the box is what you clicked last.
  local clicks = CreateFrame("Frame")
  clicks:RegisterEvent("GLOBAL_MOUSE_DOWN")
  clicks:SetScript("OnEvent", function()
    if box:HasFocus() and not holder:IsMouseOver() and not box:IsMouseOver() then box:ClearFocus() end
  end)
  self.input = { EditBox = box }
  self.updateHint = updateHint
  self.holder = holder
end

function UI:BuildFooter(frame)
  local send = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  send:SetSize(90, 24)
  send:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 12, 10)
  send:SetText("Send")
  send:SetScript("OnClick", function() UI:Send() end)
  self.send = send

  local reloadHint = CreateFrame("Button", nil, frame)
  reloadHint:SetSize(76, 16)
  reloadHint:SetPoint("RIGHT", send, "LEFT", -6, 0)
  reloadHint.text = reloadHint:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  reloadHint.text:SetAllPoints()
  reloadHint.text:SetJustifyH("RIGHT")
  reloadHint:SetScript("OnEnter", function(self) UI:ShowReloadTip(self) end)
  reloadHint:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.reloadHint = reloadHint

  local notice = frame:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  notice:SetPoint("RIGHT", send, "LEFT", -8, 0)
  notice:SetJustifyH("LEFT")
  notice:SetWordWrap(false)
  self.notice = notice

  -- Only shown when the one thing that needs a loading screen is actually needed.
  local reload = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  reload:SetSize(76, 20)
  reload:SetPoint("RIGHT", send, "LEFT", -6, 0)
  reload:SetNormalFontObject("GameFontNormalSmall")
  reload:SetHighlightFontObject("GameFontHighlightSmall")
  reload:SetText("Reload UI")
  reload:SetScript("OnClick", function()
    if InCombatLockdown() then
      UI:SetNotice("You're in combat. Reload after the fight.")
    else
      ns:Flush()
    end
  end)
  reload:Hide()
  self.reload = reload
end

--- Beside Send, so a reload is never a surprise. Hover it for what it means.
function UI:RenderReloadHint()
  local seconds, left = ns:ReloadIn()
  local hint = self.reloadHint
  -- The button says the same thing when it's there. The smallest window keeps its room for spells,
  -- because chat warns you in time anyway.
  hint:SetShown(not self.reload:IsShown() and self.frame:GetWidth() >= TINY_WIDTH)
  if left == 0 then
    hint.text:SetText("Reload now")
    hint.text:SetTextColor(1.0, 0.30, 0.25)
  else
    hint.text:SetText("Reload in " .. ns.ShortTime(seconds))
    if seconds <= ns.RELOAD_WARN then
      hint.text:SetTextColor(1.0, 0.50, 0.15)
    elseif seconds <= ns.RELOAD_SOON then
      hint.text:SetTextColor(1.0, 0.82, 0.0)
    else
      hint.text:SetTextColor(0.55, 0.55, 0.55)
    end
  end
end

function UI:ShowReloadTip(owner)
  local seconds, left = ns:ReloadIn()
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:AddLine("Reloading")
  local at = ns.snapshot and ns.snapshot.at
  if at then GameTooltip:AddLine("Last update " .. ns.Ago(time() - at) .. ".", 0.6, 0.6, 0.6) end
  if left == 0 then
    GameTooltip:AddLine("Live updates have stopped until you reload.", 1, 1, 1, true)
  else
    GameTooltip:AddLine(left .. " live updates left, " .. ns.AboutTime(seconds) .. " at this pace.", 1, 1, 1, true)
  end
  GameTooltip:AddLine("Addons can only read new data a limited number of times. A reload refills that.", 0.8, 0.8, 0.8, true)
  GameTooltip:AddLine("It reloads your whole UI, not just this addon. It takes a few seconds and you lose nothing.", 0.8, 0.8, 0.8, true)
  GameTooltip:AddLine("It never happens by itself. The Reload UI button shows up when it gets close.", 0.8, 0.8, 0.8, true)
  GameTooltip:Show()
end

function UI:SetNotice(text)
  self.notice:SetText(text or "")
end

function UI:SaveDraft()
  local thread = self.draftFor
  -- While editing, the box holds a queued message, not something you wrote for this thread.
  if not thread or not self.input or self.editingQueued or self.newThread or self.answering then return end
  local text = self.input.EditBox:GetText()
  ns.db.drafts[thread] = text ~= "" and text or nil
end

--- Move a queued message into the box. Whatever you had typed waits in your draft.
function UI:EditQueued(thread, run, text)
  self:SaveDraft()
  self.editingQueued = { thread = thread.id, run = run }
  self.input.EditBox:SetText(ns.Plain(text))
  self.input.EditBox:SetFocus()
  self:Render()
end

--- The New thread page. The reply box holds what the thread should do, until you send or leave.
--- The model starts as this project's latest, then the open thread's, because that's usually right.
function UI:StartNewThread(project)
  local open = ns:ThreadById(ns.db.selected)
  project = project or (open and open.p)
  local instance, model, effort = open and open.mi, open and open.mo, open and open.ef
  for _, row in ipairs(ns.snapshot and ns.snapshot.pm or {}) do
    if row[1] == project then
      instance, model, effort = row[2], row[3], row[4] ~= "" and row[4] or nil
    end
  end
  self:SaveDraft()
  self.editingQueued, self.showReport, self.showAchievements, self.showOptions = nil, nil, nil, nil
  self.newThread = { project = project, instance = instance, model = model, effort = effort, selected = ns.db.selected }
  self.input.EditBox:SetText(self.newThreadWords or "")
  self.input.EditBox:SetFocus()
  if self:IsOpen() then self:Render() else self:Toggle() end
end

--- Keeps what you wrote for next time, and gives the box back to this thread's draft.
function UI:StopNewThread()
  self.newThreadWords = self.input.EditBox:GetText() ~= "" and self.input.EditBox:GetText() or nil
  self.newThread = nil
  self.input.EditBox:SetText(ns.db.drafts[self.draftFor] or "")
end

--- Leave edit mode and give the box back to your own draft.
function UI:StopEditing()
  self.editingQueued = nil
  self.input.EditBox:SetText(ns.db.drafts[self.draftFor] or "")
end

--- Enter or the Send button. The box can hold /peon, a new thread, an edit or a reply, checked in that order.
function UI:Send()
  local box = self.input.EditBox
  local own = ns.Chat and ns.Chat.OwnCommand(box:GetText())
  if own then
    box:SetText("")
    if self.newThread then self:StopNewThread() end
    if self.editingQueued then self:StopEditing() end
    box:ClearFocus()
    self:Toggle()
    return
  end
  local new = self.newThread
  if new then
    local words = ns.Typed(box:GetText()):gsub("^%s+", ""):gsub("%s+$", "")
    if words == "" or words:find("\1", 1, true) then
      self:SetNotice(words == "" and "Say what it should do first." or "That has a character in it that can't be sent.")
      return
    end
    local ok
    local mode = ns:NewThreadMode(new.instance)
    if new.model and new.instance then
      ok = ns:QueueCommand("new-thread", "newm", table.concat({ mode.id, new.project, new.instance, new.model, new.effort or "", words }, "\n"))
    else
      ok = ns:QueueCommand("new-thread", "new", mode.id .. "\n" .. new.project .. "\n" .. words)
    end
    if not ok then return end
    ns:ShowStarting(new.project, words)
    if ns.Chat then ns.Chat:ReportReload("Starting a new thread in " .. ns.Plain(new.project) .. ". " .. mode.note) end
    box:SetText("")
    self:StopNewThread()
    box:ClearFocus()
    self:Render()
    return
  end
  local answering = self.answering
  if answering then
    -- Your own answer to a question. It's one line, the way T3 takes it.
    local text = ns.Typed(box:GetText()):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text:find("\1", 1, true) then
      self:SetNotice("That has a character in it that can't be sent.")
      return
    end
    local thread = ns:ThreadById(answering.thread)
    local choices = UI.OpenQuestion(thread)
    if not choices or choices.r ~= answering.mark then
      self:StopAnswering()
      self:Render()
      self:SetNotice("That question isn't open any more.")
      return
    end
    local answer = self:AnswerFor(thread.id, choices)
    -- Sending nothing is the way out, the same as when editing.
    answer.typed[answering.question] = text ~= "" and text or nil
    if text ~= "" then answer.picks[answering.question] = {} end
    self:StopAnswering()
    box:ClearFocus()
    if text ~= "" and UI.AnswerReady(choices, answer) then self:SendAnswer(thread, choices) end
    self:Render()
    return
  end
  local editing = self.editingQueued
  if editing then
    local text = ns.Typed(box:GetText()):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text:find("\1", 1, true) then
      local reason = text == "" and "Nothing to send yet." or "That has a character in it that can't be sent."
      -- Sending nothing is the way out, so it ends editing and the queued message stays as it was.
      if text == "" then self:StopEditing() end
      self:Render()
      self:SetNotice(reason)
      return
    end
    local ok, reason = ns:QueueCommand(editing.thread, "editq", editing.run .. "\n" .. text)
    if not ok then
      self:SetNotice(reason)
      return
    end
    self:StopEditing()
    box:ClearFocus()
    self:Render()
    return
  end
  -- Whoever the box says it is for, never whichever thread something else just selected.
  local ok, reason = ns:QueueReply(self.draftFor or ns.db.selected, box:GetText())
  if not ok then
    self:SetNotice(reason)
    return
  end
  box:SetText("")
  box:ClearFocus()
  ns:Deliver()
  self:Render()
end

--- What the box should say about the open thread: sending, sent, or what went wrong.
function UI:ReplyState(thread)
  for _, entry in ipairs(ns.db.pending) do
    if entry.thread == thread.id then
      if ns.db.pending[1].stuck then return "The companion app is not answering. Your reply is saved. Press Reload UI to send it." end
      if not ns:CanSendSilently() then return ns.WAITING_FOR_RESTART end
      if InCombatLockdown() then return "Held until the fight ends." end
      return "Sending..."
    end
  end
  local result = ns.db.results[thread.id]
  if not result then return "" end
  if result.text == "sent" then return "Sent " .. ns.Ago(time() - result.at) .. "." end
  return ns.Plain(result.text)
end
