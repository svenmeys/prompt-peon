-- Tracker: the small line by the minimap, and the threads under it, like tracked quests.

local _, ns = ...
local UI = ns.UI
local STATUS, colored, addFold, showFold = UI.STATUS, UI.Colored, UI.AddFold, UI.ShowFold

--- Where you dragged it, or beside the game's own quests while they're on screen, or under the
--- minimap. A hidden quest list has no place on screen, so anchoring to one hides ours too.
function UI:PlaceTracker()
  local tracker, where = self.tracker, ns.db.tracker
  local theirs = ObjectiveTrackerFrame or QuestWatchFrame
  tracker:ClearAllPoints()
  if where then
    tracker:SetPoint(where[1], UIParent, where[2], where[3], where[4])
  elseif theirs and theirs:IsShown() then
    tracker:SetPoint("TOPRIGHT", theirs, "TOPLEFT", -12, 0)
  else
    tracker:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", 12, -26)
  end
end

function UI:BuildTracker()
  local tracker = CreateFrame("Button", "PromptPeonTracker", UIParent)
  tracker:SetSize(290, 18)
  self.tracker = tracker
  self:PlaceTracker()
  -- Their list comes and goes as you track quests, so ours follows.
  local theirs = ObjectiveTrackerFrame or QuestWatchFrame
  if theirs then
    theirs:HookScript("OnShow", function() UI:PlaceTracker() end)
    theirs:HookScript("OnHide", function() UI:PlaceTracker() end)
  end
  tracker:SetMovable(true)
  tracker:SetClampedToScreen(true)
  tracker:RegisterForDrag("LeftButton")
  tracker:SetScript("OnDragStart", tracker.StartMoving)
  tracker:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relative, x, y = self:GetPoint()
    ns.db.tracker = { point, relative, x, y }
  end)
  tracker:SetScript("OnClick", function() UI:Toggle() end)
  tracker:SetScript("OnEnter", function(self) UI:ShowTrackerTip(self) end)
  tracker:SetScript("OnLeave", function() GameTooltip:Hide() end)
  tracker.text = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  tracker.text:SetAllPoints()
  tracker.text:SetJustifyH("RIGHT")
end

function UI:ShowTrackerTip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
  GameTooltip:AddLine("T3 threads")
  local threads = ns:VisibleThreads()
  for index = 1, math.min(#threads, 10) do
    local thread = threads[index]
    local info = STATUS[thread.s] or STATUS.idle
    GameTooltip:AddLine(colored(info, "[" .. info.tag .. "]") .. " " .. ns.Plain(thread.t), 1, 1, 1)
  end
  GameTooltip:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

--- Gone when there is nothing to say: nobody waiting, nothing unread or pinned, nobody working and
--- no trouble. It comes back by itself the moment any of that changes.
function UI:RenderTracker()
  local counts, inbox, problem = ns:Counts(), ns:Inbox(), ns:Problem()
  local quiet = #inbox == 0 and counts.needs + counts.error + counts.running == 0 and not problem
  self.tracker:SetShown(not ns.db.trackerOff and not quiet)
  if not self.tracker:IsShown() then return end
  local parts = {}
  if counts.needs > 0 then parts[#parts + 1] = colored(STATUS.needs, counts.needs .. " need you") end
  if counts.error > 0 then parts[#parts + 1] = colored(STATUS.error, counts.error .. " failed") end
  if counts.running > 0 then parts[#parts + 1] = colored(STATUS.running, counts.running .. " working") end
  if #parts == 0 then parts[1] = counts.total .. " open" end
  local prefix = problem and colored(STATUS.error, "T3 offline") or ns:Workers().label
  self.tracker.text:SetText(prefix .. ": " .. table.concat(parts, ", "))
  self:RenderTrackedThreads(inbox)
end

local TRACK_WIDTH = 250
local TRACK_MAX = 6

function UI:TrackRow(index)
  self.trackRows = self.trackRows or {}
  local row = self.trackRows[index]
  if row then return row end
  row = CreateFrame("Button", nil, self.tracker)
  row:SetWidth(TRACK_WIDTH)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  addFold(row, 14, "TOPLEFT", -1, 1)
  row.title = row:CreateFontString(nil, "OVERLAY", "PromptPeonHeader")
  row.title:SetPoint("TOPLEFT", 14, 0)
  row.title:SetPoint("TOPRIGHT")
  row.title:SetJustifyH("LEFT")
  row.title:SetWordWrap(false)
  row.body = row:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  row.body:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
  row.body:SetWidth(TRACK_WIDTH - 14)
  row.body:SetJustifyH("LEFT")
  row.body:SetWordWrap(true)
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      UI:ThreadMenu(self, self.thread)
    elseif IsShiftKeyDown() then
      ns:ToggleTracked(self.thread)
    elseif self.thread.s == "needs" then
      UI:OpenThread(self.thread.id) -- It's already unfolded, so a click goes to the thread.
    else
      ns.db.expanded[self.thread.id] = not ns.db.expanded[self.thread.id] or nil
      UI:RenderTracker()
    end
  end)
  row:SetScript("OnEnter", function(self) UI:ShowThreadTip(self, self.thread) end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.trackRows[index] = row
  return row
end

--- The first sentence of a message, cut at a word. The tracker has room for a hint, not a read.
function UI.Gist(text, limit)
  limit = limit or 90
  local plain = ns.Markdown.Plain(text or "")
  local line = plain:match("[^\n]*%S[^\n]*") or ""
  line = line:gsub("^%s+", ""):gsub("^[-*+]%s+", ""):gsub("^\226\128\162%s+", ""):gsub("%s+$", "")
  local sentence = line:match("^(.-[.!?:])%s") or line
  if #sentence <= limit then return sentence end
  local cut = sentence:sub(1, limit):match("^(.*)%s%S*$") or sentence:sub(1, limit)
  -- Never end in the middle of a character.
  while #cut > 0 and bit.band(cut:byte(#cut), 0xC0) == 0x80 do cut = cut:sub(1, -2) end
  if #cut > 0 and cut:byte(#cut) >= 0xC0 then cut = cut:sub(1, -2) end
  return cut .. "..."
end

--- From a todo list: how far along, and the step it is on now.
function UI.TodoSummary(text)
  local done, total, current, firstOpen = 0, 0, nil, nil
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      total = total + 1
      local mark, words = line:match("^%[(.)%]%s*(.*)$")
      if mark == "x" then
        done = done + 1
      elseif mark == ">" then
        current = current or words
      else
        firstOpen = firstOpen or words or line
      end
    end
  end
  if total == 0 then return nil end
  return done .. "/" .. total .. "  " .. UI.Gist(current or firstOpen or "All done", 70)
end

--- What an expanded thread shows: one line each for what it's doing, how far along it is,
--- and the point of what it last said. Details stay in the log, a click away.
local function trackedLines(thread)
  local lines = {}
  local info = STATUS[thread.s] or STATUS.idle
  if thread.a then
    lines[#lines + 1] = colored(info, ns.Plain(thread.a))
  else
    local when = thread.u and thread.u > 0 and (", " .. ns.Ago(time() - thread.u)) or ""
    lines[#lines + 1] = colored(info, info.label .. when)
  end
  local rows = thread.m or {}
  local todo, words, question
  for index = #rows, 1, -1 do
    local kind = rows[index][1]
    if kind == "q" and not question then question = rows[index][2] end
    if kind == "d" and not todo then todo = rows[index][2] end
    if kind == "a" and not words then words = rows[index][2] end
  end
  if question then lines[#lines + 1] = ns.Plain(UI.Gist(question)) end
  local summary = todo and UI.TodoSummary(todo)
  if summary then lines[#lines + 1] = ns.Plain(summary) end
  if words and not question then lines[#lines + 1] = "|cffaaaaaa" .. ns.Plain(UI.Gist(words)) .. "|r" end
  return table.concat(lines, "\n")
end

local CHOICE_HEIGHT = 15
local WHOLE_ON_TRACKER = 300 -- Characters. A request longer than this is read, and approved, in the log.

--- A line under a tracker row that does something when clicked: an answer, Approve, Decline.
function UI:TrackChoice(index)
  self.trackChoices = self.trackChoices or {}
  local line = self.trackChoices[index]
  if line then return line end
  line = CreateFrame("Button", nil, self.tracker)
  line:SetSize(TRACK_WIDTH - 14, CHOICE_HEIGHT)
  line.text = line:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  line.text:SetPoint("TOPLEFT")
  line.text:SetPoint("TOPRIGHT")
  line.text:SetJustifyH("LEFT")
  line.text:SetWordWrap(false)
  -- What the answer means, under it, when the question says.
  line.detail = line:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  line.detail:SetPoint("TOPLEFT", line.text, "BOTTOMLEFT", 8, -1)
  line.detail:SetWidth(TRACK_WIDTH - 22)
  line.detail:SetJustifyH("LEFT")
  line.detail:SetTextColor(0.62, 0.60, 0.54)
  line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight", "ADD")
  -- The lines are reused every time the tracker redraws, and it redraws whenever news arrives. A
  -- press that began on one thread's answer does nothing if the line is another's when you let go.
  line:SetScript("OnMouseDown", function(self) self.pressed = self.what end)
  line:SetScript("OnClick", function(self)
    local pressed = self.pressed
    self.pressed = nil
    if pressed ~= nil and pressed ~= self.what then return end
    self.run()
  end)
  self.trackChoices[index] = line
  return line
end

--- What a thread that's waiting on you shows on the tracker: what it asks, and the lines to click.
--- One click has to be enough and has to be informed, so only a question with one pick, and only a
--- request short enough to read whole here, get their answers on the tracker. The rest go to the log.
local MOST_CHOICES, LONGEST_DETAIL = 5, 160

--- The first `bytes` of some words, cut between characters and never inside one.
local function cut(words, bytes)
  local short = words:sub(1, bytes)
  while #short > 0 and bit.band(short:byte(#short), 0xC0) == 0x80 do short = short:sub(1, -2) end
  if #short > 0 and short:byte(#short) >= 0xC0 then short = short:sub(1, -2) end
  return short
end

--- Whether a question's answers can all be told apart on the tracker: few enough, no two that
--- read the same, and nothing longer to read than fits under it.
local function plainChoices(question)
  if #question.o == 0 or #question.o > MOST_CHOICES then return false end
  local seen = {}
  for _, option in ipairs(question.o) do
    local reads = option[1] .. "\0" .. option[2]
    if seen[reads] or #option[2] > LONGEST_DETAIL then return false end
    seen[reads] = true
  end
  return true
end

local function asking(thread)
  local function toLog(words)
    return { { words = words, what = thread.id .. ":log", run = function() UI:OpenThread(thread.id) end } }
  end
  local choices = UI.OpenQuestion(thread)
  if choices then
    local question = choices.q[1]
    if UI:JustSent(choices.r) then return ns.Plain(UI.Gist(question.t, 200)) .. "\n|cffaaaaaaAnswer sent.|r", {} end
    if #choices.q > 1 or question.m or not plainChoices(question) then
      return ns.Plain(UI.Gist(question.t, 200)), toLog(">> Open the log to answer")
    end
    local lines = {}
    for number, option in ipairs(question.o) do
      lines[#lines + 1] = { words = ns.Plain(option[1]), detail = ns.Plain(option[2]), what = thread.id .. ":" .. choices.r .. ":" .. number, run = function()
        local answer = UI:AnswerFor(thread.id, choices)
        answer.typed[1], answer.picks[1] = nil, { [number] = true }
        UI:SendAnswer(thread, choices)
        UI:Render()
      end }
    end
    if question.c then lines[#lines + 1] = toLog("Something else...")[1] end
    return ns.Plain(question.t), lines
  end
  -- The newest request that's open is the one being waited on.
  local asked
  for _, row in ipairs(thread.m or {}) do
    if row[1] == "p" and row[3] == "r" and type(row[2]) == "string" then asked = row[2] end
  end
  if not asked then return nil end
  local approval = UI.OpenApproval(thread)
  local why = approval and approval.why or ""
  local whole = #asked + #why <= WHOLE_ON_TRACKER
  -- The request in white, then the agent's reason in grey with its own label. Pipes in either are
  -- doubled by ns.Plain, so a request can't colour or label a line of its own.
  local words = (approval and ("Wants to " .. ns.Plain(approval.what) .. ":\n") or "")
    .. ns.Plain(whole and asked or (cut(asked, WHOLE_ON_TRACKER) .. "..."))
    .. (whole and why ~= "" and ("\n|cff9e998aWhy it says it needs this: " .. ns.Plain(why) .. "|r") or "")
  if not approval then return words .. "\n|cffaaaaaaApprove it in T3.|r", {} end
  if UI:JustSent(approval.r) then return words .. "\n|cffaaaaaaSent.|r", {} end
  if not whole then return words, toLog(">> Open the log to read all of it") end
  local what = thread.id .. ":" .. approval.r
  return words, {
    { words = ">> Approve", what = what .. ":accept", run = function() UI:SendApproval(thread, approval, "accept") end },
    { words = "Decline", what = what .. ":decline", run = function() UI:SendApproval(thread, approval, "decline") end },
  }
end

--- The rows under the top line are an inbox: who is waiting on you, then finished work you haven't
--- read, then anything you pinned by hand. A thread that's just working is only in the count above.
--- One that's waiting on you is unfolded already, with its answers to click.
function UI:RenderTrackedThreads(inbox)
  local index, y, total, used = 0, 0, 0, 0
  for _, thread in ipairs(inbox) do
    total = total + 1
    if index < TRACK_MAX then
      index = index + 1
      local row = self:TrackRow(index)
      local info = STATUS[thread.s] or STATUS.idle
      local words, lines
      if thread.s == "needs" then words, lines = asking(thread) end
      local open = words ~= nil or ns.db.expanded[thread.id] == true
      row.thread = thread
      showFold(row, open)
      row.title:SetText(colored(info, "[" .. info.tag .. "]") .. " " .. ns.Plain(thread.t))
      row.body:SetText(open and (words or trackedLines(thread)) or "")
      row.body:SetShown(open)
      local height = 15 + (open and (row.body:GetStringHeight() + 4) or 0)
      row:SetHeight(height) -- Without its lines, which are buttons of their own under it.
      row:ClearAllPoints()
      row:SetPoint("TOPRIGHT", self.tracker, "BOTTOMRIGHT", 0, -2 - y)
      row:Show()
      for _, entry in ipairs(lines or {}) do
        used = used + 1
        local line = self:TrackChoice(used)
        line.run, line.what = entry.run, entry.what
        line.text:SetText("|cffffd100" .. entry.words .. "|r")
        local detail = entry.detail and entry.detail ~= ""
        line.detail:SetText(detail and entry.detail or "")
        line.detail:SetShown(detail or false)
        local tall = CHOICE_HEIGHT + (detail and (line.detail:GetStringHeight() + 3) or 0)
        line:SetHeight(tall)
        line:ClearAllPoints()
        line:SetPoint("TOPRIGHT", self.tracker, "BOTTOMRIGHT", 0, -2 - y - height)
        line:Show()
        height = height + tall
      end
      y = y + height + 2
    end
  end
  for extra = used + 1, #(self.trackChoices or {}) do self.trackChoices[extra]:Hide() end
  for extra = index + 1, #(self.trackRows or {}) do self.trackRows[extra]:Hide() end
  if not self.trackMore then
    self.trackMore = self.tracker:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
    self.trackMore:SetWidth(TRACK_WIDTH)
    self.trackMore:SetJustifyH("LEFT")
  end
  self.trackMore:ClearAllPoints()
  self.trackMore:SetPoint("TOPRIGHT", self.tracker, "BOTTOMRIGHT", 0, -2 - y)
  self.trackMore:SetText(total > index and ("+" .. (total - index) .. " more in the log") or "")
end
