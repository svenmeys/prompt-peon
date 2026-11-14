-- Messages: redraws the open thread. It picks the page to show, or draws the thread's messages
-- itself, grouped into work you can fold. Also the line saying what the agent is doing right now.

local _, ns = ...
local UI = ns.UI
local STATUS, colored, plural, showFold, STEP_MARK = UI.STATUS, UI.Colored, UI.Plural, UI.ShowFold, UI.STEP_MARK

local MORE_DOTS_AFTER = 10 * 60 -- Seconds working before the raid leader loses patience.
local MANKRIK_AFTER = 2 * 60 -- Seconds searching before it's a lost cause.
local STEER_SHOWS_FOR = 30 -- Seconds. Long enough for T3 to answer, and the buttons come back if it never does.
local DIM_R, DIM_G, DIM_B = 0.70, 0.68, 0.60

local function isWork(kind)
  return kind == "t" or kind == "s" or kind == "n" or kind == "d"
end

local PREVIEW_PATH = "Interface\\AddOns\\PromptPeon\\previews\\"

--- A small icon button for a queued message: steer, edit or cancel.
function UI:QueueButton(index)
  self.queueButtons = self.queueButtons or {}
  local button = self.queueButtons[index]
  if button then return button end
  button = CreateFrame("Button", nil, self.detailContent)
  button:SetSize(16, 16)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetAllPoints()
  button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(self.label, 1, 0.82, 0)
    GameTooltip:AddLine(self.detail, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetScript("OnClick", function(self) self.action() end)
  self.queueButtons[index] = button
  return button
end

--- An open question's answers, as the companion app sent them, checked here because a bad shape
--- must draw as words and never break the log. Nil means show the question as words.
function UI.QuestionChoices(value)
  -- The mark is a fingerprint of the question and its answers, 32 characters. A shorter one is from
  -- a companion app that only marked the question's id, and that isn't enough to answer by number.
  if type(value) ~= "table" or type(value.r) ~= "string" or #value.r ~= 32 or not value.r:match("^%x+$") then return nil end
  if type(value.q) ~= "table" or #value.q == 0 or #value.q > 4 then return nil end
  for _, question in ipairs(value.q) do
    if type(question) ~= "table" or type(question.t) ~= "string" or type(question.h) ~= "string" or type(question.o) ~= "table" then return nil end
    if #question.o > 10 or (#question.o == 0 and question.c ~= true) then return nil end
    for _, option in ipairs(question.o) do
      if type(option) ~= "table" or type(option[1]) ~= "string" or type(option[2]) ~= "string" then return nil end
    end
  end
  return value
end

--- The question this thread is waiting on, if the game can answer it.
function UI.OpenQuestion(thread)
  if not thread or not thread.uq then return nil end
  for _, row in ipairs(thread.m or {}) do
    if row[1] == "q" and UI.QuestionChoices(row[5]) then return row[5] end
  end
end

--- What this thread is asking to be allowed to do, if yolo mode lets the game answer it: the
--- request's mark and its words. Nil with yolo mode off, and for anything the game can't answer.
--- With several open at once it is the newest, which is the one T3 and the companion app wait on.
function UI.OpenApproval(thread)
  if not thread or thread.s ~= "needs" or thread.uq or not (ns.snapshot and ns.snapshot.yo) then return nil end
  local rows = thread.m or {}
  for index = #rows, 1, -1 do
    local row = rows[index]
    if row[1] == "p" and row[3] == "r" then
      -- The mark stands for the request and every word shown, so only a whole one counts.
      local with = type(row[5]) == "table" and row[5] or {}
      local mark = with.r
      if type(mark) == "string" and #mark == 32 and mark:match("^%x+$") and type(row[2]) == "string" and type(with.k) == "string"
        and (with.y == nil or type(with.y) == "string") then
        -- The request, what kind of thing it is, and the agent's own reason, each kept apart.
        return { r = mark, text = row[2], what = with.k, why = with.y }
      end
      return nil
    end
  end
end

UI.answers, UI.answerSent = {}, {}

--- True for a while after an answer or a decision went, so its buttons can't be pressed twice.
function UI:JustSent(mark)
  local sent = self.answerSent[mark]
  return sent ~= nil and GetTime() - sent < STEER_SHOWS_FOR
end

--- Yolo mode: Approve or Decline what the agent asks to do. The companion app decides whether it goes.
function UI:SendApproval(thread, approval, decision)
  if self:JustSent(approval.r) then return false end
  if not ns:QueueCommand(thread.id, "approve", approval.r .. "\n" .. decision) then return false end
  self.answerSent[approval.r] = GetTime()
  self:Render()
  return true
end

--- What you have picked so far. A new question starts fresh.
function UI:AnswerFor(threadId, choices)
  local answer = self.answers[threadId]
  if not answer or answer.mark ~= choices.r then
    answer = { mark = choices.r, picks = {}, typed = {} }
    for index = 1, #choices.q do answer.picks[index] = {} end
    self.answers[threadId] = answer
  end
  return answer
end

--- One answer clicked. A question with one answer swaps it, one with several ticks it on or off.
function UI:PickAnswer(thread, choices, index, number)
  local answer = self:AnswerFor(thread.id, choices)
  if choices.q[index].m then
    answer.picks[index][number] = not answer.picks[index][number] or nil
  else
    answer.picks[index] = { [number] = true }
  end
  answer.typed[index] = nil
end

--- "Something else": the reply box holds your own answer until you press Enter.
function UI:TypeAnswer(thread, choices, index)
  self:SaveDraft()
  self.editingQueued = nil
  self.answering = { thread = thread.id, mark = choices.r, question = index }
  self.input.EditBox:SetText(self:AnswerFor(thread.id, choices).typed[index] or "")
  self.input.EditBox:SetFocus()
end

--- Leave your own answer and give the box back to your draft.
function UI:StopAnswering()
  self.answering = nil
  self.input.EditBox:SetText(ns.db.drafts[self.draftFor] or "")
end

function UI.AnswerReady(choices, answer)
  for index = 1, #choices.q do
    if not answer.typed[index] and not next(answer.picks[index]) then return false end
  end
  return true
end

--- Sends which answers you picked, counted from 1, or what you typed. The companion app looks up
--- T3's own words for them, so only the question's real answers can go.
function UI:SendAnswer(thread, choices)
  local answer = self:AnswerFor(thread.id, choices)
  local lines = { choices.r }
  for index, question in ipairs(choices.q) do
    if answer.typed[index] then
      lines[#lines + 1] = "t:" .. answer.typed[index]
    else
      local picked = {}
      for number = 1, #question.o do
        if answer.picks[index][number] then picked[#picked + 1] = tostring(number) end
      end
      if #picked == 0 then return false end
      lines[#lines + 1] = "o:" .. table.concat(picked, ",")
    end
  end
  if not ns:QueueCommand(thread.id, "answer", table.concat(lines, "\n")) then return false end
  self.answerSent[choices.r] = GetTime()
  return true
end

-- Options and the like don't need a thread, and with none open they're how you find out why.
local NO_THREAD = { id = "", t = "", p = "", s = "idle" }

--- Draws whichever page is open, or else the thread's messages. Runs on every refresh.
function UI:RenderDetail(thread)
  if not thread and (self.showOptions or self.showAchievements or (self.showReport and ns.Game and ns.Game.report)) then thread = NO_THREAD end
  local width = math.max(self.detailScroll:GetWidth(), 100)
  self.detailContent:SetWidth(width)
  for _, line in ipairs(self.lines) do line:Hide() end
  for _, head in ipairs(self.heads) do head:Hide() end
  for _, bar in ipairs(self.bars or {}) do bar:Hide() end
  for _, pic in ipairs(self.pictures or {}) do pic:Hide() end
  for _, scroller in ipairs(self.tableScrollers or {}) do
    scroller:Hide()
    scroller.slider:Hide()
  end
  for _, button in ipairs(self.queueButtons or {}) do button:Hide() end
  if self.optionsPage then self.optionsPage:Hide() end

  if not thread then
    self.title:SetText("")
    self.meta:SetText("")
    self.empty:SetText(ns.snapshot and not ns.snapshot.quiet and "No open threads. " .. ns:Workers().idle or "Waiting for the companion app.")
    self.empty:Show()
    self.shownThread = nil
    return
  end
  self.empty:Hide()
  self:AskForParked(thread)

  local info = STATUS[thread.s] or STATUS.idle
  self.title:SetText(ns.Plain(thread.t))
  local meta = colored(info, info.label) .. "  |cff888888" .. ns.Plain(thread.p)
  if thread.pk == "z" then
    meta = "|cff9fb8d6Snoozed until " .. UI.WakeWords(thread.zu) .. "|r  |cff888888" .. ns.Plain(thread.p)
  elseif thread.pk and thread.pk ~= "l" then
    meta = "|cff888888Settled  " .. ns.Plain(thread.p)
  end
  if thread.b and thread.b ~= "" then meta = meta .. " / " .. ns.Plain(thread.b) end
  if thread.mo and thread.mo ~= "" then
    meta = meta .. " / " .. ns.Plain(UI.ModelName(thread.mi, thread.mo))
    if thread.ef then meta = meta .. " " .. ns.Plain(UI.EffortName(thread.mi, thread.mo, thread.ef)) end
  end
  if thread.u and thread.u > 0 then meta = meta .. " / " .. ns.Ago(time() - thread.u) end
  self.meta:SetText(meta .. "|r")

  local canvas = self:NewCanvas(width)
  local add, addChunks, drawMarkdown, foldingHead = canvas.add, canvas.addChunks, canvas.drawMarkdown, canvas.foldingHead
  local queueButtons = 0
  -- One clickable line, the way a quest offers its rewards: an answer to pick, or Approve and Decline.
  -- `what` names the thing a click does. A line is reused as the thread redraws, and a press that
  -- began on one thing must not land on another.
  local function choiceLine(words, picked, onClick, what)
    canvas.heads = canvas.heads + 1
    local head = self:GroupHead(canvas.heads)
    head.key, head.open = "answer:" .. (what or canvas.heads), false
    showFold(head, nil)
    head:ClearAllPoints()
    head:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, -canvas.y)
    head:SetSize(width - 12, 16)
    head.text:SetText((picked and "|cffffd100" or "|cffe0ddd0") .. words .. "|r")
    head.onClick = onClick
    head:Show()
    canvas.y = canvas.y + 18
  end

  if thread.s == "needs" then
    add(thread.nb and "This agent asked you something. Your reply here answers it."
      or thread.uq and UI.OpenQuestion(thread) and "This agent is asking you something. Pick your answer below."
      or thread.uq and "This agent is asking you something. Answer it in T3. A reply here only queues a message."
      or UI.OpenApproval(thread) and "This agent is waiting for your approval. Read what it asks, then Approve or Decline below."
      or "This agent is waiting for your approval. Answer it in T3. A reply here only queues a message.", 1.0, 0.66, 0.26)
    canvas.y = canvas.y + 6
  end
  if thread.e then
    addChunks(thread.e, 0.90, 0.36, 0.30)
    canvas.y = canvas.y + 6
  end

  local function drawWork(row)
    local kind, text, state = row[1], row[2], row[3] or "d"
    if kind == "t" then
      local chunks = ns.Chunks(text)
      for number, chunk in ipairs(chunks) do
        add((number == 1 and "Thinking: " or "") .. ns.Markdown.Inline(chunk), 0.60, 0.66, 0.78, "PromptPeonSmall")
      end
    elseif kind == "s" then
      local style = STEP_MARK[state] or STEP_MARK.d
      add(style.mark .. " " .. ns.Plain(text), style.r, style.g, style.b, "PromptPeonSmall")
    elseif kind == "d" then
      addChunks(text, 0.80, 0.78, 0.60, "PromptPeonSmall")
    else
      addChunks(text, 0.55, 0.53, 0.48, "PromptPeonSmall")
    end
  end

  local pics = 0
  local function drawPicture(row)
    local label, file, pictureWidth, pictureHeight, note = row[2], row[5], row[6], row[7], row[8]
    if not file or file == 0 then
      add(ns.Plain(label) .. (note and note ~= "" and ("  |cff888888" .. ns.Plain(note) .. "|r") or ""), 0.62, 0.60, 0.54, "PromptPeonSmall")
      canvas.y = canvas.y + 4
      return
    end
    pics = pics + 1
    local pic = self:Picture(pics)
    local room = math.min(width - 8, 420)
    local scale = math.min(1, room / pictureWidth)
    pic:ClearAllPoints()
    pic:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -canvas.y)
    pic:SetSize(pictureWidth * scale, pictureHeight * scale)
    pic.path = PREVIEW_PATH .. string.format("p%02d", file)
    pic.tex:SetTexture(pic.path)
    pic.pictureWidth, pic.pictureHeight, pic.label = pictureWidth, pictureHeight, label
    pic:Show()
    canvas.y = canvas.y + pictureHeight * scale + 3
    add(ns.Plain(label), 0.62, 0.60, 0.54, "PromptPeonSmall")
    canvas.y = canvas.y + 5
  end

  local newPage = self.newThread
  local options = not newPage and self.showOptions
  local achievements = not newPage and not options and self.showAchievements and ns.Game
  local report = not newPage and not options and not achievements and self.showReport and ns.Game and ns.Game.report or nil
  local page = newPage or options or achievements or report
  local view = newPage and "new" or options and "options" or achievements and "achievements" or report and "report" or self.views[thread.id]
  local kept = ns.loaded[thread.id] or {}
  if options then
    self.title:SetText("Options")
    self.meta:SetText("")
  elseif newPage then
    self.title:SetText("New thread")
    self.meta:SetText("")
  elseif achievements then
    self.title:SetText("Achievements")
    self.meta:SetText("|cff888888" .. ns.Game.EarnedWords() .. "|r")
  elseif report then
    self.title:SetText(report.title)
    self.meta:SetText("")
  elseif ns.Game then
    ns.Game:MarkSeen(thread)
  end
  -- The open thread's tabs. They stay put whatever page is open, and each is pressed in while
  -- you're looking at its view. There is no Back button: the pressed tab is the way back.
  local threadView = self.views[thread.id]
  local function viewTab(tab, name, shown, label, count, detail)
    local showing = not page and threadView == name
    tab:SetShown(shown or false)
    tab:SetChecked(showing)
    tab.label = label
    tab.detail = showing and "Click again to see what it said." or detail
    tab.count:SetText(count > 0 and count or "")
  end
  local files, pulls, sent = kept.df and #kept.df or 0, #(thread.prs or {}), thread.agn or 0
  viewTab(self.changes, "changes", thread.ch ~= nil or thread.cd or kept.df ~= nil or threadView == "changes",
    files > 0 and ("Changes (" .. files .. ")") or "Changes", files, "What this thread changed, file by file.")
  viewTab(self.pullRequests, "prs", thread.prs ~= nil or threadView == "prs",
    "Pull requests (" .. pulls .. ")", pulls, UI.PullRequestSummary(thread.prs or {}))
  viewTab(self.agents, "agents", thread.ag ~= nil or threadView == "agents",
    "Agents (" .. sent .. ")", sent, "Who it sent out, and what they came back with.")
  self:PlaceHeaderButtons()
  if options then
    if not self.optionsPage then self:BuildOptionsPage() end
    self.optionsPage:Show()
    self:SyncOptions()
    canvas.y = self.optionsPage.height
  elseif newPage then
    self:DrawNewThread(canvas, newPage)
  elseif achievements then
    self:DrawAchievements(canvas)
  elseif report then
    self:DrawReport(canvas, report)
  elseif view == "changes" then
    self:DrawChanges(canvas, thread)
  elseif view == "agents" then
    self:DrawAgents(canvas, thread)
  elseif view == "prs" then
    self:DrawPullRequests(canvas, thread)
  end

  local rows = view and {} or (thread.m or {})
  if thread.pk and not view and not page and not thread.m and not thread.hd then
    add(self:LoadingWords(thread), DIM_R, DIM_G, DIM_B)
  end
  local olderRows = kept.older
  if not view then
    local hasMore = thread.hm
    if kept.olderMore ~= nil then hasMore = kept.olderMore end
    if hasMore then
      local waiting = self:IsLoading(thread)
      foldingHead(thread.id .. ":older", "|cffffd100Show older messages|r", waiting and "|cff888888Asking T3...|r" or "", true, function()
        if not self:IsLoading(thread) then self:AskOlder(thread) end
      end)
      canvas.y = canvas.y + 4
    elseif olderRows then
      add("This is the start of the thread.", 0.70, 0.68, 0.60, "PromptPeonSmall")
      canvas.y = canvas.y + 4
    end
    if olderRows then
      local merged = {}
      for _, row in ipairs(olderRows) do merged[#merged + 1] = row end
      for _, row in ipairs(rows) do merged[#merged + 1] = row end
      rows = merged
    end
  end
  local lastRole
  local position = 1
  while position <= #rows do
    local row = rows[position]
    if isWork(row[1]) then
      local first, thoughts, steps, failed = position, 0, 0, 0
      while position <= #rows and isWork(rows[position][1]) do
        local kind = rows[position][1]
        if kind == "t" then thoughts = thoughts + 1 elseif kind == "s" then steps = steps + 1 end
        if rows[position][3] == "f" then failed = failed + 1 end
        position = position + 1
      end
      -- Thinking stays folded until you ask for it. The steps of work still going on show by
      -- themselves, like the end of a T3 thread.
      local key = thread.id .. ":" .. tostring(rows[first][4] or first)
      local isOpen = self.groups[key] == true
      local going = self.groups[key] == nil and position > #rows and (thread.s == "running" or thread.s == "needs")
      local parts = {}
      if thoughts > 0 then parts[#parts + 1] = plural(thoughts, "thought") end
      if steps > 0 then parts[#parts + 1] = plural(steps, "step") end
      if #parts == 0 then parts[1] = "Notes" end
      local label = table.concat(parts, ", ")
      if failed > 0 then label = label .. ", |cffe65c4d" .. failed .. " failed|r" end
      canvas.heads = canvas.heads + 1
      local head = self:GroupHead(canvas.heads)
      head.key, head.open = key, isOpen
      showFold(head, isOpen)
      head:ClearAllPoints()
      head:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -canvas.y)
      head:SetSize(width - 4, 14)
      head.text:SetText("|cff8c8a80" .. label .. "|r")
      head:Show()
      canvas.y = canvas.y + 17
      for number = first, position - 1 do
        if isOpen or (going and rows[number][1] ~= "t") then drawWork(rows[number]) end
      end
      canvas.y = canvas.y + 5
      lastRole = nil
    elseif row[1] == "sa" then
      -- A subagent: one line with its state. Click for what it came back with.
      canvas.heads = canvas.heads + 1
      local head = self:GroupHead(canvas.heads)
      local key = thread.id .. ":agent:" .. tostring(row[4] or position)
      local isOpen = self.groups[key]
      if isOpen == nil then isOpen = false end
      local style = STEP_MARK[row[3] or "d"] or STEP_MARK.d
      local words = row[3] == "r" and "working" or row[3] == "f" and "failed" or row[3] == "c" and "stopped" or "done"
      head.key, head.open = key, isOpen
      if row[5] and row[5] ~= "" then showFold(head, isOpen) else showFold(head, nil) end
      head:ClearAllPoints()
      head:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -canvas.y)
      head:SetSize(width - 4, 14)
      head.text:SetText(string.format("|cff%02x%02x%02xAgent: %s (%s)|r", style.r * 255, style.g * 255, style.b * 255, ns.Plain(row[2]), words))
      head:Show()
      canvas.y = canvas.y + 17
      if isOpen and row[5] then drawMarkdown(row[5], key) end
      canvas.y = canvas.y + 4
      lastRole = nil
      position = position + 1
    elseif row[1] == "i" then
      drawPicture(row)
      lastRole = nil
      position = position + 1
    elseif row[1] == "p" then
      -- What it wants to do, as plain words and never as Markdown: this is read before it's approved.
      -- The request is in the code font. The agent's reason comes after, grey, under its own
      -- heading, so nothing written inside a request can pass for a reason.
      local with = type(row[5]) == "table" and row[5] or {}
      add("The agent is asking for your approval" .. (type(with.k) == "string" and (" to " .. ns.Plain(with.k)) or "") .. ":", 1.0, 0.66, 0.26)
      addChunks(row[2], 1.0, 0.85, 0.60, "PromptPeonCode")
      if type(with.y) == "string" and with.y ~= "" then
        add("Why it says it needs this (this part is not what runs):", 0.62, 0.60, 0.54, "PromptPeonSmall")
        addChunks(with.y, 0.62, 0.60, 0.54, "PromptPeonSmall")
      end
      local approval = UI.OpenApproval(thread)
      local mark = with.r
      if not approval or approval.r ~= mark then
        add("Approve it in T3.", 0.62, 0.60, 0.54, "PromptPeonSmall")
      elseif self:JustSent(approval.r) then
        add("Sent. The agent goes on when T3 has it.", 0.62, 0.60, 0.54, "PromptPeonSmall")
      else
        choiceLine(">> Approve", true, function() UI:SendApproval(thread, approval, "accept") end, approval.r .. ":accept")
        choiceLine("Decline", false, function() UI:SendApproval(thread, approval, "decline") end, approval.r .. ":decline")
      end
      canvas.y = canvas.y + 8
      lastRole = nil
      position = position + 1
    elseif row[1] == "q" then
      add("The agent is asking:", 1.0, 0.66, 0.26)
      local choices = thread.uq and UI.QuestionChoices(row[5])
      if not choices then
        addChunks(row[2], 1.0, 0.85, 0.60)
      else
        local answer = self:AnswerFor(thread.id, choices)
        for index, question in ipairs(choices.q) do
          if #choices.q > 1 and question.h ~= "" then add(ns.Plain(question.h), 0.80, 0.68, 0.30, "PromptPeonSmall") end
          addChunks(question.t, 1.0, 0.85, 0.60)
          for number, option in ipairs(question.o) do
            local picked = answer.picks[index][number]
            local mark = question.m and (picked and "[x] " or "[  ] ") or (picked and "(o) " or "(  ) ")
            choiceLine(mark .. ns.Plain(option[1]), picked, function() UI:PickAnswer(thread, choices, index, number) end, choices.r .. ":" .. index .. ":" .. number)
            if option[2] ~= "" then add(ns.Plain(option[2]), 0.62, 0.60, 0.54, "PromptPeonSmall", 34) end
          end
          if question.c then
            local typed = answer.typed[index]
            choiceLine(typed and ("(o) Your own answer: " .. ns.Plain(typed)) or "(  ) Something else. Type your own answer",
              typed ~= nil, function() UI:TypeAnswer(thread, choices, index) end, choices.r .. ":" .. index .. ":type")
          end
          canvas.y = canvas.y + 4
        end
        -- One Send takes every question's answer, so with several it says so.
        local count = #choices.q
        if self:JustSent(choices.r) then
          add((count == 1 and "Answer sent" or count == 2 and "Both answers sent" or "All " .. count .. " answers sent")
            .. ". The agent goes on when T3 has " .. (count == 1 and "it." or "them."), 0.62, 0.60, 0.54, "PromptPeonSmall")
        elseif UI.AnswerReady(choices, answer) then
          choiceLine(count == 1 and ">> Send your answer" or count == 2 and ">> Send both answers" or ">> Send all " .. count .. " answers",
            true, function() UI:SendAnswer(thread, choices) end, choices.r .. ":send")
        else
          add(count > 1 and "Pick an answer for each question, then send them together." or "Pick an answer, then send it.", 0.62, 0.60, 0.54, "PromptPeonSmall")
        end
      end
      canvas.y = canvas.y + 8
      lastRole = nil
      position = position + 1
    else
      local queued = row[3] == "q"
      local role = queued and "uq" or row[1]
      if role ~= lastRole then
        if queued then
          add("You (queued, goes next)", 0.80, 0.68, 0.30)
        elseif row[1] == "u" then
          add("You", 1.0, 0.82, 0.0)
        else
          add("Agent", 0.40, 0.70, 1.00)
        end
        lastRole = role
      end
      -- Old data has no run, and the bridge can't act on a message it can't name.
      local run = queued and row[5]
      if type(run) ~= "string" or run == "" or run:find("%c") then run = nil end
      local steered = run and self.steering[run]
      if steered and GetTime() - steered < STEER_SHOWS_FOR then
        addChunks(row[2], 0.75, 0.73, 0.65)
        add("Steering it in now...", 1.0, 0.82, 0.0, "PromptPeonSmall")
      elseif run then
        -- Its buttons sit on the message's first line, so the text leaves them room.
        local top = canvas.y
        for _, chunk in ipairs(ns.Chunks(row[2])) do
          add(ns.Plain(chunk), 0.75, 0.73, 0.65, nil, 0, width - 66)
        end
        local buttons = {}
        if thread.s == "running" then
          buttons[#buttons + 1] = { "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", "Steer", "Send this now, into what the agent is doing, instead of waiting for it to finish.",
            function()
              if ns:QueueCommand(thread.id, "steer", run) then
                UI.steering[run] = GetTime()
                UI:Render()
              end
            end }
        end
        buttons[#buttons + 1] = { "Interface\\Icons\\INV_Feather_05", "Edit", "Change it before it goes.", function() UI:EditQueued(thread, run, row[2]) end }
        buttons[#buttons + 1] = { "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Cancel", "Don't send it.", function() ns:QueueCommand(thread.id, "cancelq", run) end }
        local x = width - 4 - #buttons * 19
        for _, spec in ipairs(buttons) do
          queueButtons = queueButtons + 1
          local button = self:QueueButton(queueButtons)
          button:ClearAllPoints()
          button:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", x, -top)
          button.icon:SetTexture(spec[1])
          button.label, button.detail, button.action = spec[2], spec[3], spec[4]
          button:Show()
          x = x + 19
        end
      elseif row[1] == "a" then
        drawMarkdown(row[2], thread.id .. ":" .. tostring(row[4] or position))
      else
        addChunks(row[2], queued and 0.75 or 0.95, queued and 0.73 or 0.93, queued and 0.65 or 0.85)
      end
      canvas.y = canvas.y + 8
      position = position + 1
    end
  end
  if thread.hd and not view then
    add(ns.snapshot.lk and ns.Plain(ns.snapshot.lk) or "This thread is hidden, so its text stays out of the game. Show it to read it here.", 0.70, 0.68, 0.60, "PromptPeonSmall")
  elseif #rows == 0 and #ns.db.pending == 0 and #ns.sentShowing == 0 and not view then
    add("No messages in this update. Open the thread in T3 for its history.", 0.65, 0.62, 0.55)
  end
  -- Your reply shows straight away, and stays until T3's own copy of it arrives.
  for _, list in ipairs({ ns.sentShowing, ns.db.pending }) do
    for _, entry in ipairs(list) do
      if entry.thread == thread.id and not entry.command and not view and not thread.hd and not ns:IsHidden(thread) then
        if lastRole ~= "u" then
          add("You", 1.0, 0.82, 0.0)
          lastRole = "u"
        end
        addChunks(entry.text, 0.75, 0.73, 0.65)
        canvas.y = canvas.y + 8
      end
    end
  end
  if not view and thread.s == "error" and ns.Game then
    canvas.y = canvas.y + 6
    add("This agent died.", 0.90, 0.36, 0.30, "PromptPeonHeader")
    foldingHead(thread.id .. ":resurrect", "|cffffd100Resurrect|r", "|cff888888tell it to try again|r", true, function() ns.Game:Resurrect(thread) end)
    foldingHead(thread.id .. ":release", "|cffffd100Release Spirit|r", "|cff888888turn it in|r", true, function() UI:ConfirmSettle(thread) end)
  end

  self.detailContent:SetHeight(math.max(canvas.y, 10))

  -- Jump to the newest message on a new thread, or when already at the bottom.
  -- If you scrolled up to read, a new message leaves you where you are.
  local scroll = self.detailScroll
  local wasAtBottom = scroll:GetVerticalScroll() >= scroll:GetVerticalScrollRange() - 30
  if not view and olderRows and self.olderShown ~= #olderRows then
    -- Older messages arrived above what you were reading. Keep your eyes on the same line.
    local grew = self.shownThread == thread.id and canvas.y - (self.shownHeight or canvas.y) or 0
    self.olderShown = #olderRows
    if grew > 0 then
      local from = scroll:GetVerticalScroll()
      C_Timer.After(0, function() scroll:SetVerticalScroll(from + grew) end)
    end
  elseif view then
    -- These read from the top, and keep your place while they fill in.
    if self.shownThread ~= thread.id then scroll:SetVerticalScroll(0) end
  elseif self.shownThread ~= thread.id or (self.shownHeight ~= canvas.y and wasAtBottom) then
    C_Timer.After(0, function() scroll:SetVerticalScroll(scroll:GetVerticalScrollRange()) end)
  end
  self.shownThread, self.shownHeight = thread.id, canvas.y
  self.activityThread = thread
  self:DrawActivity()
end

--- "Thinking... 1m 12s". Runs between refreshes, so the clock and dots keep moving.
function UI:DrawActivity()
  local thread, line = self.activityThread, self.activity
  if not thread then
    line:SetText("")
    return
  end
  local text
  if thread.s == "running" then
    local dots = string.rep(".", math.floor(GetTime() % 3) + 1)
    local words = ns.Plain(thread.a or "Working")
    local busy = thread.as and thread.as > 0 and time() - thread.as or 0
    if busy >= MORE_DOTS_AFTER then dots = "......... MORE DOTS" end
    text = colored(STATUS.running, words .. dots)
    if busy > 0 then text = text .. "  |cff888888" .. ns.Clock(busy) .. "|r" end
    if busy >= MANKRIK_AFTER and words:find("^Searching") then text = text .. "  |cff888888Has anyone seen Mankrik's wife?|r" end
  elseif thread.s == "needs" then
    text = colored(STATUS.needs, ns.Plain(thread.a or "Waiting for you"))
  end
  if thread.qc and thread.qc > 0 then
    local queued = "|cffccae4d" .. (thread.qc >= 3 and "Barrens chat: " or "") .. plural(thread.qc, "message") .. " queued|r"
    text = text and (text .. "  " .. queued) or queued
  end
  line:SetText(text or "")
end

function UI:TickActivity()
  local now = GetTime()
  if self.nextActivityTick and now < self.nextActivityTick then return end
  self.nextActivityTick = now + 1
  self:DrawActivity()
end
