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

function UI:RenderTracker()
  self.tracker:SetShown(not ns.db.trackerOff)
  if ns.db.trackerOff then return end
  local counts = ns:Counts()
  local parts = {}
  if counts.needs > 0 then parts[#parts + 1] = colored(STATUS.needs, counts.needs .. " need you") end
  if counts.error > 0 then parts[#parts + 1] = colored(STATUS.error, counts.error .. " failed") end
  if counts.running > 0 then parts[#parts + 1] = colored(STATUS.running, counts.running .. " working") end
  if #parts == 0 then parts[1] = counts.total .. " open" end
  local prefix = ns:Problem() and colored(STATUS.error, "T3 offline") or ns:Workers().label
  self.tracker.text:SetText(prefix .. ": " .. table.concat(parts, ", "))
  self:RenderTrackedThreads()
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

function UI:RenderTrackedThreads()
  local index, y, total = 0, 0, 0
  for _, thread in ipairs(ns:VisibleThreads()) do
    if ns:IsTracked(thread) then
      total = total + 1
      if index < TRACK_MAX then
        index = index + 1
        local row = self:TrackRow(index)
        local info = STATUS[thread.s] or STATUS.idle
        local open = ns.db.expanded[thread.id] == true
        row.thread = thread
        showFold(row, open)
        row.title:SetText(colored(info, "[" .. info.tag .. "]") .. " " .. ns.Plain(thread.t))
        row.body:SetText(open and trackedLines(thread) or "")
        row.body:SetShown(open)
        local height = 15 + (open and (row.body:GetStringHeight() + 4) or 0)
        row:SetHeight(height)
        row:ClearAllPoints()
        row:SetPoint("TOPRIGHT", self.tracker, "BOTTOMRIGHT", 0, -2 - y)
        row:Show()
        y = y + height + 2
      end
    end
  end
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
