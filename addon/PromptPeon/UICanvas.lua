-- Canvas: one redraw of the open thread. It tracks how far down the pane we've drawn, and draws
-- text, bars, markdown and clickable heads there. The pages in other files all draw on it, so it's
-- a table: `canvas.y` is that position, and they all move it.

local _, ns = ...
local UI = ns.UI
local showFold = UI.ShowFold

local MAX_TABLE_ROWS, MAX_TABLE_COLUMNS, MAX_TABLE_CELL = 40, 8, 300
local WIDEST_EXPANDED_COLUMN = 480 -- Past this a cell wraps, so one long cell can't make a table thousands wide.
local SLIDER_HEIGHT = 17
local SIDEWAYS_STEP = 40

UI.tableOffsets = {} -- How far you scrolled each expanded table, by its key.

--- The strip an expanded table scrolls sideways in, with its bar. It clips what's outside it.
function UI:TableScroller(index)
  self.tableScrollers = self.tableScrollers or {}
  local scroller = self.tableScrollers[index]
  if scroller then return scroller end
  scroller = CreateFrame("ScrollFrame", nil, self.detailContent)
  local content = CreateFrame("Frame", nil, scroller)
  content:SetSize(10, 10)
  scroller:SetScrollChild(content)
  -- Thread links in a cell still work, the same way they do in the log.
  content:SetHyperlinksEnabled(true)
  content:SetScript("OnHyperlinkClick", function(_, link, _, button) ns.Chat:OnLink(link, button) end)
  scroller.content, scroller.lines, scroller.bars, scroller.offset = content, {}, {}, 0
  local slider = CreateFrame("Slider", nil, self.detailContent, "UISliderTemplate")
  slider:SetScript("OnValueChanged", function(_, value)
    scroller.offset = value
    scroller:SetHorizontalScroll(value)
    if scroller.key then UI.tableOffsets[scroller.key] = value end
  end)
  scroller.slider = slider
  -- Shift and the wheel scroll it sideways. The wheel alone still scrolls the thread.
  scroller:SetScript("OnMouseWheel", function(_, delta)
    if IsShiftKeyDown() then
      slider:SetValue(scroller.offset - delta * SIDEWAYS_STEP)
    else
      local outer = UI.detailScroll
      local scroll = outer:GetScript("OnMouseWheel")
      if scroll then scroll(outer, delta) end
    end
  end)
  self.tableScrollers[index] = scroller
  return scroller
end

--- One per redraw. The page functions decide what goes on it.
function UI:NewCanvas(width)
  local canvas = { y = 0, heads = 0, width = width }
  local index, barCount = 0, 0

  --- One block of text. With `stay`, the next block goes beside it, for table cells.
  local function add(text, r, g, b, font, x, blockWidth, stay)
    index = index + 1
    local line = self:Line(index)
    line:SetFontObject(font or "PromptPeonBody")
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", x or 0, -canvas.y)
    line:SetWidth(blockWidth or (width - 4 - (x or 0)))
    line:SetText(text)
    line:SetTextColor(r, g, b)
    line:Show()
    local height = line:GetStringHeight()
    if not stay then canvas.y = canvas.y + height + 3 end
    return height
  end
  --- A flat rectangle behind or beside text: code backgrounds, table stripes, quote bars.
  local function bar(x, top, barWidth, height, r, g, b, a)
    barCount = barCount + 1
    self.bars = self.bars or {}
    local texture = self.bars[barCount]
    if not texture then
      texture = self.detailContent:CreateTexture(nil, "BACKGROUND")
      self.bars[barCount] = texture
    end
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", x, -top)
    texture:SetSize(barWidth, height)
    texture:SetColorTexture(r, g, b, a)
    texture:Show()
  end
  local BODY_R, BODY_G, BODY_B = 0.88, 0.86, 0.79

  local function foldingHead(key, words, right, noFold, onClick, x)
    canvas.heads = canvas.heads + 1
    local head = self:GroupHead(canvas.heads)
    head.key, head.open = key, self.groups[key] == true
    head.onClick = onClick
    if noFold then showFold(head, nil) else showFold(head, head.open) end
    head:ClearAllPoints()
    head:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", x or 0, -canvas.y)
    head:SetSize(width - 4 - (x or 0), 14)
    head.text:SetText(words)
    head.right:SetText(right or "")
    head:Show()
    canvas.y = canvas.y + 17
    return head.open
  end

  --- Every row in order, at `y` counted from the table's top. `put` draws one cell and says how
  --- tall it is; `stripe` draws the header rule and every other row's shading.
  local function drawCells(rows, columns, widths, stripeWidth, put, stripe)
    local y = 0
    for rowIndex, row in ipairs(rows) do
      local x, tallest, top = 4, 0, y
      for column = 1, columns do
        local words = ns.Markdown.Inline(row[column] or "")
        local height
        if rowIndex == 1 then
          height = put(words, 1.0, 0.82, 0.0, x, top, widths[column] - 8)
        else
          height = put(words, BODY_R, BODY_G, BODY_B, x, top, widths[column] - 8)
        end
        tallest = math.max(tallest, height)
        x = x + widths[column]
      end
      y = top + tallest + 4
      if rowIndex == 1 then
        stripe(0, y - 2, stripeWidth, 1, 0.6, 0.55, 0.35, 0.8)
        y = y + 1
      elseif rowIndex % 2 == 1 then
        stripe(0, top - 1, stripeWidth, tallest + 3, 1, 1, 1, 0.04)
      end
    end
    return y
  end

  local scrollers = 0
  --- Bounded, because every row costs every column: a tiny hostile table could mean 40,000 text blocks.
  --- Squeezed to the window until you expand it. Expanded, each column is as wide as its longest
  --- cell, and a table wider than the window scrolls sideways inside its own strip.
  local function drawTable(allRows, key)
    local rows = {}
    for index = 1, math.min(#allRows, MAX_TABLE_ROWS) do
      local cells = {}
      for column = 1, math.min(#allRows[index], MAX_TABLE_COLUMNS) do
        cells[column] = ns.Chunks(allRows[index][column] or "", MAX_TABLE_CELL)[1] or ""
      end
      rows[index] = cells
    end
    local columns = 0
    for _, row in ipairs(rows) do columns = math.max(columns, #row) end
    if not self.measure then
      self.measure = self.detailContent:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
      self.measure:Hide()
    end
    local expanded = self.groups[key] == true
    -- Wide enough for the longest cell, shared out if the table is wider than the window.
    local widths, total = {}, 0
    for column = 1, columns do
      local widest = 30
      for _, row in ipairs(rows) do
        self.measure:SetText(ns.Markdown.Inline(row[column] or ""))
        widest = math.max(widest, (self.measure:GetStringWidth() or 0) + 12)
      end
      widths[column] = math.min(widest, WIDEST_EXPANDED_COLUMN)
      total = total + widths[column]
    end
    local room = width - 8
    canvas.y = canvas.y + 2
    local sideways = expanded and total > room
    if sideways then
      scrollers = scrollers + 1
      local scroller = self:TableScroller(scrollers)
      local used = 0
      local function put(words, r, g, b, x, y, cellWidth)
        used = used + 1
        local line = scroller.lines[used]
        if not line then
          line = scroller.content:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
          line:SetJustifyH("LEFT")
          line:SetJustifyV("TOP")
          line:SetWordWrap(true)
          scroller.lines[used] = line
        end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", scroller.content, "TOPLEFT", x, -y)
        line:SetWidth(cellWidth)
        line:SetText(words)
        line:SetTextColor(r, g, b)
        line:Show()
        return line:GetStringHeight()
      end
      local stripes = 0
      local function stripe(x, y, stripeWidth, height, r, g, b, a)
        stripes = stripes + 1
        local texture = scroller.bars[stripes]
        if not texture then
          texture = scroller.content:CreateTexture(nil, "BACKGROUND")
          scroller.bars[stripes] = texture
        end
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", scroller.content, "TOPLEFT", x, -y)
        texture:SetSize(stripeWidth, height)
        texture:SetColorTexture(r, g, b, a)
        texture:Show()
      end
      for index = 1, #scroller.lines do scroller.lines[index]:Hide() end
      for index = 1, #scroller.bars do scroller.bars[index]:Hide() end
      local height = drawCells(rows, columns, widths, total + 4, put, stripe)
      local inner, view = total + 8, room + 4
      scroller:ClearAllPoints()
      scroller:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -canvas.y)
      scroller:SetSize(view, height)
      scroller.content:SetSize(inner, height)
      scroller:Show()
      canvas.y = canvas.y + height + 2
      -- Where you scrolled to stays put while the thread refreshes.
      local range = inner - view
      local offset = math.max(0, math.min(self.tableOffsets[key] or 0, range))
      scroller.key, scroller.offset = key, offset
      scroller:SetHorizontalScroll(offset)
      local slider = scroller.slider
      slider:ClearAllPoints()
      slider:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 4, -canvas.y)
      slider:SetSize(view - 8, SLIDER_HEIGHT)
      slider:SetMinMaxValues(0, range)
      slider:SetValue(offset)
      slider:Show()
      canvas.y = canvas.y + SLIDER_HEIGHT + 2
    else
      if total > room then
        local fitted = 0
        for column = 1, columns do
          widths[column] = math.max(40, widths[column] * room / total)
          fitted = fitted + widths[column]
        end
        total = fitted
      end
      local base = canvas.y
      local function put(words, r, g, b, x, y, cellWidth)
        canvas.y = base + y
        return add(words, r, g, b, "PromptPeonBody", x, cellWidth, true)
      end
      local function stripe(x, y, stripeWidth, height, r, g, b, a) bar(x, base + y, stripeWidth, height, r, g, b, a) end
      canvas.y = base + drawCells(rows, columns, widths, math.min(total, room) + 4, put, stripe)
    end
    if #allRows > MAX_TABLE_ROWS then
      add((#allRows - MAX_TABLE_ROWS) .. " more rows in T3.", 0.70, 0.68, 0.60, "PromptPeonSmall", 4)
    end
    foldingHead(key, expanded and "|cffffd100Collapse table|r" or "|cffffd100Expand table|r",
      sideways and "|cff888888Drag the bar, or hold Shift and scroll|r" or "", true, nil, 4)
    canvas.y = canvas.y + 4
  end
  --- `key` names the message, so each of its tables remembers whether you expanded it.
  local function drawMarkdown(text, key)
    local tables = 0
    for _, block in ipairs(ns.Markdown.Blocks(text)) do
      if block.kind == "h" then
        canvas.y = canvas.y + 3
        for _, chunk in ipairs(ns.Chunks(block.text)) do
          add(ns.Markdown.Inline(chunk), 1.0, 0.82, 0.0, block.level <= 2 and "PromptPeonHeading" or "PromptPeonHeader")
        end
        canvas.y = canvas.y + 1
      elseif block.kind == "li" then
        local x = math.min(block.depth, 6) * 12 -- A hostile indent can't push text off the window.
        local markWidth = #block.mark > 3 and 18 or 11
        add(block.mark, 0.70, 0.68, 0.60, "PromptPeonBody", x + 2, markWidth, true)
        for _, chunk in ipairs(ns.Chunks(block.text)) do
          add(ns.Markdown.Inline(chunk), BODY_R, BODY_G, BODY_B, "PromptPeonBody", x + 2 + markWidth)
        end
      elseif block.kind == "code" then
        local top = canvas.y
        canvas.y = canvas.y + 4
        for _, chunk in ipairs(ns.Chunks(block.text)) do
          add(ns.Plain(chunk), 0.72, 0.87, 0.80, "PromptPeonCode", 8, width - 20)
        end
        canvas.y = canvas.y + 2
        bar(0, top, width - 4, canvas.y - top, 0, 0, 0, 0.38)
        canvas.y = canvas.y + 5
      elseif block.kind == "quote" then
        local top = canvas.y
        for _, chunk in ipairs(ns.Chunks(block.text)) do
          add(ns.Markdown.Inline(chunk), 0.68, 0.66, 0.60, "PromptPeonBody", 10)
        end
        bar(2, top, 2, canvas.y - top - 2, 0.6, 0.55, 0.35, 0.9)
        canvas.y = canvas.y + 3
      elseif block.kind == "rule" then
        canvas.y = canvas.y + 3
        bar(0, canvas.y, width - 4, 1, 0.6, 0.6, 0.6, 0.35)
        canvas.y = canvas.y + 6
      elseif block.kind == "table" then
        tables = tables + 1
        -- A page without a message key goes by the table's header instead.
        drawTable(block.rows, "table:" .. (key or table.concat(block.rows[1] or {}, "|")) .. ":" .. tables)
      else
        for _, chunk in ipairs(ns.Chunks(block.text)) do
          add(ns.Markdown.Inline(chunk), BODY_R, BODY_G, BODY_B)
        end
        canvas.y = canvas.y + 3
      end
    end
  end
  local function addChunks(text, r, g, b, font)
    for _, chunk in ipairs(ns.Chunks(text)) do add(ns.Plain(chunk), r, g, b, font) end
  end

  canvas.add, canvas.addChunks, canvas.bar = add, addChunks, bar
  canvas.drawMarkdown, canvas.foldingHead = drawMarkdown, foldingHead
  return canvas
end
