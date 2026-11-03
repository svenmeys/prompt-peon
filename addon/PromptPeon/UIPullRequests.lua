-- Pull requests: the words that sum one up, the list of a thread's, and the page for one of them.

local _, ns = ...
local UI = ns.UI
local diffCounts = UI.DiffCounts

local DIM_R, DIM_G, DIM_B = 0.70, 0.68, 0.60
-- Each answer rides along for a minute after this, so an open one refreshes about every two minutes.
local PR_GOES_STALE = { open = 60, other = 600 }

UI.CHECK_STYLE = {
  success = { "Passed", 0.45, 0.80, 0.45 },
  failure = { "Failed", 0.90, 0.36, 0.30 },
  ["action-required"] = { "Needs you", 1.00, 0.66, 0.26 },
  cancelled = { "Cancelled", 0.90, 0.36, 0.30 },
  pending = { "Running", 0.40, 0.70, 1.00 },
  skipped = { "Skipped", 0.60, 0.60, 0.60 },
  neutral = { "Neutral", 0.60, 0.60, 0.60 },
}

--- "5 pull requests: 1 open, 4 merged."
function UI.PullRequestSummary(prs)
  local counts = { open = 0, merged = 0, closed = 0 }
  for _, pr in ipairs(prs) do counts[pr.st] = (counts[pr.st] or 0) + 1 end
  local parts = {}
  for _, state in ipairs({ "open", "merged", "closed" }) do
    if counts[state] > 0 then parts[#parts + 1] = counts[state] .. " " .. state end
  end
  local head = #prs .. (#prs == 1 and " pull request" or " pull requests")
  return #parts > 0 and (head .. ": " .. table.concat(parts, ", ") .. ".") or (head .. ".")
end

--- All of a pull request's checks as one line: "1 failed, 42 passed, 30 skipped."
function UI.CheckTally(tally)
  local parts = {}
  for _, pair in ipairs(tally or {}) do
    local style = UI.CHECK_STYLE[pair[1]] or UI.CHECK_STYLE.pending
    parts[#parts + 1] = string.format("|cff%02x%02x%02x%d %s|r", style[2] * 255, style[3] * 255, style[4] * 255, pair[2], string.lower(style[1]))
  end
  return #parts > 0 and (table.concat(parts, ", ") .. ".") or "No checks."
end

--- What a comment is, beyond who wrote it: "approved" or "on b.lua:12, resolved".
function UI.EntryWords(entry)
  local verdicts = { approved = "|cff72cc72approved|r", ["changes-requested"] = "|cffffa842asked for changes|r", dismissed = "review dismissed" }
  local parts = { verdicts[entry.st] }
  if entry.pa and entry.pa ~= "" then
    parts[#parts + 1] = "on " .. ns.Plain(entry.pa:match("[^/]+$") or entry.pa) .. (entry.ln and (":" .. entry.ln) or "")
  end
  if entry.rs then parts[#parts + 1] = "resolved" end
  if entry.ol then parts[#parts + 1] = "outdated" end
  return table.concat(parts, ", ")
end

--- Bots and finished business wait behind a button. Most comments on a real pull request come from
--- bots, and T3's own page hides them too. A bot's verdict still counts.
function UI.QuietEntry(entry)
  if entry.st == "approved" or entry.st == "changes-requested" then return false end
  return entry.bt or entry.rs or entry.st == "dismissed"
end

--- One line on where a pull request stands: "Open, CI failing (3/5), needs review, has conflicts".
function UI.PullRequestLine(pr)
  local state = { open = "|cff72cc72Open|r", merged = "|cffab7ef2Merged|r", closed = "|cffe65c4dClosed|r" }
  local parts = { state[pr.st] or ns.Plain(pr.st) }
  if pr.dr then parts[#parts + 1] = "draft" end
  -- Only an open one can still change, so the rest don't need the noise.
  if pr.st == "open" then
    local checks = { failing = "|cffe65c4dCI failing|r", pending = "|cff66b3ffCI running|r", passing = "|cff72cc72CI passing|r" }
    if checks[pr.ck] then
      parts[#parts + 1] = checks[pr.ck] .. ((pr.ct or 0) > 0 and (" (" .. (pr.cp or 0) .. "/" .. pr.ct .. ")") or "")
    end
    local review = { approved = "|cff72cc72approved|r", ["changes-requested"] = "|cffffa842changes requested|r", ["review-required"] = "needs review" }
    if review[pr.rv] then parts[#parts + 1] = review[pr.rv] end
    if pr.mg == "conflicting" then parts[#parts + 1] = "|cffe65c4dhas conflicts|r" end
  end
  if (pr.f or 0) > 0 then parts[#parts + 1] = pr.f .. (pr.f == 1 and " file" or " files") end
  return table.concat(parts, ", ")
end

StaticPopupDialogs["PROMPTPEON_COPY"] = {
  text = "Press Ctrl+C to copy the link to #%s.",
  button1 = "Close",
  hasEditBox = 1,
  maxLetters = 500,
  editBoxWidth = 340,
  EditBoxOnEnterPressed = function(box) box:GetParent():Hide() end,
  EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

--- The game can't open a browser, so the link goes where you can copy it.
function UI:ShowLink(number, url)
  local dialog = StaticPopup_Show("PROMPTPEON_COPY", tostring(number), nil, url)
  local box = dialog and (dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox)
  if box then
    box:SetText(url)
    box:HighlightText()
    box:SetFocus()
  end
end

--- The list of a thread's pull requests, or the page for one.
function UI:DrawPullRequests(canvas, thread)
  local add, drawMarkdown, foldingHead, width = canvas.add, canvas.drawMarkdown, canvas.foldingHead, canvas.width

  local function ago(at)
    return (at or 0) > 0 and ("|cff888888" .. ns.Ago(time() - at) .. "|r") or ""
  end

  --- One comment or review thread. Short ones read like a conversation, long ones wait for a click.
  local function drawEntry(entry, key, startsOpen)
    if self.groups[key] == nil then
      self.groups[key] = startsOpen and not entry.bt and not entry.rs and #(entry.b or "") <= 800
    end
    local who = "|cffffd100" .. ns.Plain(entry.w) .. "|r" .. (entry.bt and " |cff808080bot|r" or "")
    local words = UI.EntryWords(entry)
    if foldingHead(key, who .. (words ~= "" and ("  " .. words) or ""), ago(entry.at)) then
      if entry.pa and entry.pa ~= "" then
        add(ns.Plain(entry.pa) .. (entry.ln and (":" .. entry.ln) or ""), DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15, width - 30)
      end
      if entry.cut then add("Too long to show here. Open it in T3.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
      if (entry.b or "") ~= "" then drawMarkdown(entry.b) end
      for _, reply in ipairs(entry.re or {}) do
        canvas.y = canvas.y + 3
        add("|cffffd100" .. ns.Plain(reply[1]) .. "|r" .. (reply[2] and " |cff808080bot|r" or "") .. "  " .. ago(reply[3]), 1, 1, 1, "PromptPeonSmall", 15, width - 30)
        drawMarkdown(reply[4])
      end
      if (entry.mr or 0) > 0 then add(entry.mr .. " more in T3.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
      canvas.y = canvas.y + 6
    elseif entry.g and entry.g ~= "" then
      add(ns.Plain(entry.g), DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15, width - 30)
      canvas.y = canvas.y + 2
    end
  end

  --- Oldest first, like a conversation, starting from the newest few.
  local function drawDiscussion(page, key)
    local showAll, visible, quiet = self.prAll[key], {}, 0
    for index, entry in ipairs(page.ds) do
      if UI.QuietEntry(entry) then quiet = quiet + 1 end
      if showAll or not UI.QuietEntry(entry) then visible[#visible + 1] = { entry, index } end
    end
    if quiet > 0 then
      foldingHead(key .. ":quiet", "|cffffd100" .. (showAll and "Hide " or "Show ") .. quiet .. " from bots and resolved threads|r", nil, true, function()
        self.prAll[key] = not showAll or nil
      end)
    end
    if #visible == 0 then add(#page.ds == 0 and "No comments yet." or "Nothing from people yet.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
    local limit = self.prShown[key] or 10
    local first = math.max(1, #visible - limit + 1)
    if first > 1 then
      foldingHead(key .. ":older", "|cffffd100Show " .. math.min(first - 1, 20) .. " older|r", nil, true, function() self.prShown[key] = limit + 20 end)
    end
    for position = first, #visible do
      drawEntry(visible[position][1], key .. ":e" .. visible[position][2], true)
    end
    if page.tr then add("T3 only has the newest ones. The rest are on the pull request.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
  end

  --- Everything that happened, newest first.
  local function drawTimeline(page, key)
    local limit = self.prShown[key] or 40
    for index = 1, math.min(limit, #page.tl) do
      local event = page.tl[index]
      local kind = event[1]
      local rowKey = key .. ":r" .. index
      if kind == "note" then
        drawEntry(page.ds[event[3]], key .. ":e" .. event[3], false)
      elseif kind == "commit" then
        foldingHead(rowKey, "|cff66b3ff" .. ns.Plain(event[3]) .. "|r  " .. ns.Plain(event[4]), diffCounts(event[5], event[6]) .. "  " .. ago(event[2]), true)
      elseif kind == "opened" then
        foldingHead(rowKey, "|cffffd100" .. ns.Plain(event[3]) .. "|r opened this", ago(event[2]), true)
      else
        foldingHead(rowKey, kind == "merged" and "|cffab7ef2Merged|r" or "|cffe65c4dClosed|r", ago(event[2]), true)
      end
    end
    if #page.tl > limit then
      foldingHead(key .. ":older", "|cffffd100Show " .. math.min(#page.tl - limit, 40) .. " older|r", nil, true, function() self.prShown[key] = limit + 40 end)
    end
  end

  --- The page you get by clicking a pull request: where it stands, then what it says and what happened.
  local function drawPullRequest(pr, showBack)
    local key = thread.id .. ":pr:" .. pr.n
    local page = (ns.loaded[thread.id] or {}).pullRequests
    page = page and page[pr.n]
    local function section(name, words, right, startsOpen)
      local sectionKey = key .. ":" .. name
      if self.groups[sectionKey] == nil then self.groups[sectionKey] = startsOpen end
      canvas.y = canvas.y + 4
      return foldingHead(sectionKey, "|cffffd100" .. words .. "|r", right)
    end
    if showBack then
      foldingHead(key .. ":back", "|cffffd100< All pull requests|r", nil, true, function()
        self.prOpen[thread.id] = nil
        self.detailScroll:SetVerticalScroll(0)
      end)
      canvas.y = canvas.y + 2
    end
    add("|cffffd100#" .. pr.n .. "|r  " .. ns.Plain(pr.ti), 1.0, 0.82, 0.0, "PromptPeonHeader")
    add(UI.PullRequestLine(pr) .. "  " .. diffCounts(pr.a or 0, pr.d or 0), 0.78, 0.76, 0.68, "PromptPeonSmall")
    local facts = { ns.Plain(pr.r) }
    if pr.hb ~= "" then facts[#facts + 1] = ns.Plain(pr.hb) .. " into " .. ns.Plain(pr.bb) end
    if pr.au ~= "" then facts[#facts + 1] = "by " .. ns.Plain(pr.au) end
    if page and (page.oa or 0) > 0 then facts[#facts + 1] = "opened " .. ns.Ago(time() - page.oa) end
    if page and page.bh then facts[#facts + 1] = page.bh .. " behind" end
    add(table.concat(facts, "  "), DIM_R, DIM_G, DIM_B, "PromptPeonSmall")
    if page and #(page.rv or {}) > 0 then
      local stands = {}
      for _, review in ipairs(page.rv) do
        stands[#stands + 1] = ns.Plain(review[1]) .. " " .. UI.EntryWords({ st = review[2] })
      end
      add(table.concat(stands, ", "), DIM_R, DIM_G, DIM_B, "PromptPeonSmall")
    end
    if page and #(page.lb or {}) > 0 then
      local labels = {}
      for _, label in ipairs(page.lb) do labels[#labels + 1] = ns.Plain(label) end
      add("Labels: " .. table.concat(labels, ", "), DIM_R, DIM_G, DIM_B, "PromptPeonSmall")
    end
    if pr.u then
      local url, number = pr.u, pr.n
      foldingHead(key .. ":link", "|cffffd100Copy the link|r", nil, true, function() UI:ShowLink(number, url) end)
    end
    if not page then
      self:AskPullRequest(thread, pr)
      add(self:LoadingWords(thread), DIM_R, DIM_G, DIM_B, "PromptPeonSmall")
      return
    end
    -- It keeps moving while you read. A merged one mostly doesn't, and each ask makes T3 go and look.
    if GetTime() - page.at > (pr.st == "open" and PR_GOES_STALE.open or PR_GOES_STALE.other) then self:AskPullRequest(thread, pr) end
    if page.er then add("T3 couldn't get all of this: " .. ns.Plain(page.er), 0.90, 0.36, 0.30, "PromptPeonSmall") end
    if page.b and section("summary", "Summary", nil, true) then
      if page.b ~= "" then drawMarkdown(page.b) else add("No description.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
      canvas.y = canvas.y + 4
    end
    if page.ct and section("checks", "Checks", #page.ct > 0 and UI.CheckTally(page.ct) or "None", #(page.cs or {}) > 0) then
      add(UI.CheckTally(page.ct), 1, 1, 1, "PromptPeonSmall", 15, width - 30)
      for _, check in ipairs(page.cs or {}) do
        local style = UI.CHECK_STYLE[check[2]] or UI.CHECK_STYLE.pending
        add(string.format("|cff%02x%02x%02x%s|r  %s", style[2] * 255, style[3] * 255, style[4] * 255, style[1], ns.Plain(check[1])), 1, 1, 1, "PromptPeonSmall", 15, width - 30)
      end
      if (page.cm or 0) > 0 then add(page.cm .. " more in T3.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
    end
    if page.ds and section("discussion", "Discussion (" .. (page.dn or #page.ds) .. ")", nil, true) then drawDiscussion(page, key .. ":discussion") end
    if page.tl and section("timeline", "Timeline (" .. #page.tl .. ")", nil, false) then drawTimeline(page, key .. ":timeline") end
  end

  local prs = thread.prs or {}
  -- With only one, the list would be a pointless extra click.
  local number = self.prOpen[thread.id] or (#prs == 1 and prs[1].n)
  for _, pr in ipairs(prs) do
    if pr.n == number then return drawPullRequest(pr, #prs > 1) end
  end
  add(UI.PullRequestSummary(prs), 1.0, 0.82, 0.0, "PromptPeonHeader")
  canvas.y = canvas.y + 4
  for _, pr in ipairs(prs) do
    local chosen = pr.n
    foldingHead(thread.id .. ":pr:" .. pr.n, "|cffffd100#" .. pr.n .. "|r  " .. ns.Plain(pr.ti), diffCounts(pr.a or 0, pr.d or 0), true, function()
      self.prOpen[thread.id] = chosen
      self.detailScroll:SetVerticalScroll(0)
    end)
    add(UI.PullRequestLine(pr), 0.78, 0.76, 0.68, "PromptPeonSmall", 15, width - 30)
    canvas.y = canvas.y + 4
  end
end
