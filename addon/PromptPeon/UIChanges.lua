-- Changes: what a thread changed, file by file, drawn as a diff.

local _, ns = ...
local UI = ns.UI
local diffCounts, plural = UI.DiffCounts, UI.Plural

local DIM_R, DIM_G, DIM_B = 0.70, 0.68, 0.60

-- Text colour and background per kind of line. The background is the chat's code block, tinted.
local DIFF_STYLE = {
  ["+"] = { text = { 0.62, 0.92, 0.64 }, back = { 0.07, 0.26, 0.12, 0.62 } },
  ["-"] = { text = { 0.96, 0.64, 0.58 }, back = { 0.31, 0.09, 0.07, 0.62 } },
  ["@"] = { text = { 0.52, 0.73, 1.00 }, back = { 0.09, 0.15, 0.27, 0.62 } },
  [" "] = { text = { 0.72, 0.87, 0.80 }, back = { 0, 0, 0, 0.38 } },
}

--- Split a line to fit, because a FontString can't indent the rows it wraps. Breaks at a space
--- when one is close, and anywhere when something like a long URL has none. Later rows start two
--- characters in, so wrapped code hangs past the plus or minus.
local function wrapDiffLine(line, columns)
  if #line <= columns then return { line } end
  local chars = {}
  for char in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = char end
  if #chars <= columns then return { line } end
  local rows, start, room = {}, 1, columns
  while start <= #chars do
    local stop = math.min(start + room - 1, #chars)
    if stop < #chars then
      for back = stop, start + math.floor(room * 2 / 3), -1 do
        if chars[back] == " " then
          stop = back
          break
        end
      end
    end
    rows[#rows + 1] = (#rows > 0 and "  " or "") .. table.concat(chars, "", start, stop)
    start = stop + 1
    room = math.max(columns - 2, 1)
  end
  return rows
end

--- A file's patch as runs of the same kind of line, so each run can sit on its own band of colour.
--- Numbers and text are separate blocks with the same rows, so they line up in two columns.
function UI.PatchBlocks(patch, firstOld, firstNew, columns)
  local blocks, numbers, text, size, kind = {}, {}, {}, 0, nil
  local oldLine, newLine = firstOld or 0, firstNew or 0
  columns = columns or 1000000
  local function flush()
    if #text > 0 then
      blocks[#blocks + 1] = { kind = kind, numbers = table.concat(numbers, "\n"), text = table.concat(text, "\n") }
    end
    numbers, text, size = {}, {}, 0
  end
  for line in ((patch or "") .. "\n"):gmatch("(.-)\r?\n") do
    local first = line:sub(1, 1)
    local lineKind = (first == "+" or first == "-" or first == "@") and first or " "
    local number = ""
    local oldStart, newStart = line:match("^@@ %-(%d+)[,%d]* %+(%d+)")
    if oldStart then
      oldLine, newLine = tonumber(oldStart), tonumber(newStart)
    elseif first == "\\" then
      lineKind = " " -- "No newline at end of file" is not a line of the file.
    elseif lineKind == "+" then
      number, newLine = newLine, newLine + 1
    elseif lineKind == "-" then
      number, oldLine = oldLine, oldLine + 1
    else
      number, oldLine, newLine = newLine, oldLine + 1, newLine + 1
    end
    if lineKind ~= kind or size > ns.CHUNK_BYTES then
      flush()
      kind = lineKind
    end
    for index, row in ipairs(wrapDiffLine(line, columns)) do
      local drawn = ns.Plain(row)
      -- A blank row must still take up a row, or the two columns stop lining up.
      text[#text + 1] = drawn ~= "" and drawn or " "
      numbers[#numbers + 1] = index == 1 and string.format("%5s", number) or " "
      size = size + #drawn + 1
    end
  end
  flush()
  return blocks
end

--- How wide one character of code is. The font is monospace, so one measurement does for all.
function UI:CodeCharWidth()
  local meter = self.codeMeter
  if not meter then
    meter = self.detailContent:CreateFontString(nil, "OVERLAY", "PromptPeonCode")
    meter:SetAlpha(0)
    meter:SetPoint("TOPLEFT")
    self.codeMeter = meter
  end
  meter:SetFontObject("PromptPeonCode")
  meter:SetText(string.rep("0", 40))
  return math.max(meter:GetStringWidth() / 40, 1)
end

--- The name first, because a long folder is what should get cut off.
local function fileWords(path)
  local folder, name = path:match("^(.*)/([^/]+)$")
  if not name then return "|cffffd100" .. ns.Plain(path) .. "|r" end
  return "|cffffd100" .. ns.Plain(name) .. "|r  |cff808080" .. ns.Plain(folder) .. "|r"
end

--- ToggleView already asked T3. Until the answer arrives this lists what the thread already knows.
function UI:DrawChanges(canvas, thread)
  local add, bar, foldingHead, width = canvas.add, canvas.bar, canvas.foldingHead, canvas.width
  local kept = ns.loaded[thread.id] or {}
  if kept.dn and kept.dn ~= "" then add(ns.Plain(kept.dn), DIM_R, DIM_G, DIM_B); canvas.y = canvas.y + 6 end
  if not kept.df then
    for _, entry in ipairs(thread.ch or {}) do
      foldingHead(thread.id .. ":known:" .. entry[1], fileWords(entry[1]), diffCounts(entry[3] or 0, entry[4] or 0), true)
    end
    canvas.y = canvas.y + 6
    add(self:LoadingWords(thread), DIM_R, DIM_G, DIM_B)
    return
  end
  if #kept.df > 0 then
    local allAdded, allRemoved = 0, 0
    for _, file in ipairs(kept.df) do
      allAdded, allRemoved = allAdded + file[2], allRemoved + file[3]
    end
    foldingHead(thread.id .. ":summary", "|cffc8c5b8" .. plural(#kept.df, "file") .. " changed|r", diffCounts(allAdded, allRemoved), true)
    canvas.y = canvas.y + 3
  end
  self:DrawDiffFiles(canvas, thread)
end

--- The files of the diff we have, a thread's or one pull request's, each one opening to its changes.
function UI:DrawDiffFiles(canvas, thread)
  local add, bar, foldingHead, width = canvas.add, canvas.bar, canvas.foldingHead, canvas.width
  local kept = ns.loaded[thread.id] or {}
  local function drawPatch(patch, firstOld, firstNew)
    local charWidth = self:CodeCharWidth()
    local gutter = math.ceil(charWidth * 5) + 8
    local textWidth = width - 20 - gutter
    -- One short of what fits, so the game's own wrapping never kicks in and breaks the columns.
    local columns = math.max(math.floor(textWidth / charWidth) - 1, 10)
    for _, block in ipairs(UI.PatchBlocks(patch, firstOld, firstNew, columns)) do
      local style = DIFF_STYLE[block.kind]
      local blockTop = canvas.y
      canvas.y = canvas.y + 2
      add(block.numbers, 0.43, 0.43, 0.43, "PromptPeonCode", 6, gutter, true)
      add(block.text, style.text[1], style.text[2], style.text[3], "PromptPeonCode", 6 + gutter, textWidth)
      bar(0, blockTop, width - 4, canvas.y - blockTop, style.back[1], style.back[2], style.back[3], style.back[4])
    end
  end
  local function drawFilePage(path, key, fileTop)
    local number = self.filePages[key] or 1
    local page = kept.pages and kept.pages[path .. "\n" .. number]
    if not page then
      add(self:IsLoading(thread) and "Asking T3..." or "T3 did not send this. Close and open the file to ask again.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15)
      return
    end
    -- You pressed Next at the bottom, so show the new page from its top.
    if self.scrollToFile == key then
      self.scrollToFile = nil
      local target = fileTop
      C_Timer.After(0, function() self.detailScroll:SetVerticalScroll(target) end)
    end
    local count = page[3]
    if count > 1 then add("Page " .. number .. " of " .. count, DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15) end
    drawPatch(page[6], page[4], page[5])
    local function pager(words, target)
      canvas.y = canvas.y + 2
      foldingHead(thread.id .. ":pager", "|cffffd100" .. words .. "|r", "|cff888888page " .. target .. " of " .. count .. "|r", true, function()
        self.scrollToFile = key
        self:AskFilePage(thread, path, target)
      end)
    end
    if number < count then pager("Next page", number + 1) end
    if number > 1 then pager("Previous page", number - 1) end
  end
  for _, file in ipairs(kept.df) do
    local path, added, removed, patch, fits, secret = file[1], file[2], file[3], file[4], file[5], file[6]
    local top = canvas.y
    local key = thread.id .. ":file:" .. path
    local isOpen = foldingHead(key, fileWords(path), diffCounts(added, removed), nil, not fits and function(nowOpen)
      if nowOpen then self:AskFilePage(thread, path, self.filePages[key] or 1) end
    end or nil)
    bar(0, top - 1, width - 4, 16, 1, 1, 1, 0.05)
    canvas.y = canvas.y + 1
    if isOpen and secret then
      add("Kept out of the game because it looks like a secrets file. Open it in T3.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15)
      canvas.y = canvas.y + 4
    elseif isOpen and not fits then
      drawFilePage(path, key, top)
      canvas.y = canvas.y + 7
    elseif isOpen and patch ~= "" then
      drawPatch(patch)
      canvas.y = canvas.y + 7
    elseif isOpen then
      add("Nothing to show for this file, like a rename or a binary file.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 15)
      canvas.y = canvas.y + 4
    end
  end
end
