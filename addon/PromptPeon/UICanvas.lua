-- Canvas: one redraw of the open thread. It tracks how far down the pane we've drawn, and draws
-- text, bars, markdown and clickable heads there. The pages in other files all draw on it, so it's
-- a table: `canvas.y` is that position, and they all move it.

local _, ns = ...
local UI = ns.UI
local showFold = UI.ShowFold

local MAX_TABLE_ROWS, MAX_TABLE_COLUMNS, MAX_TABLE_CELL = 40, 8, 300

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
  --- Bounded, because every row costs every column: a tiny hostile table could mean 40,000 text blocks.
  local function drawTable(allRows)
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
    -- Wide enough for the longest cell, shared out if the table is wider than the window.
    local widths, total = {}, 0
    for column = 1, columns do
      local widest = 30
      for _, row in ipairs(rows) do
        self.measure:SetText(ns.Markdown.Inline(row[column] or ""))
        widest = math.max(widest, (self.measure:GetStringWidth() or 0) + 12)
      end
      widths[column] = widest
      total = total + widest
    end
    local room = width - 8
    if total > room then
      for column = 1, columns do widths[column] = math.max(40, widths[column] * room / total) end
    end
    canvas.y = canvas.y + 2
    for rowIndex, row in ipairs(rows) do
      local x, tallest, top = 4, 0, canvas.y
      for column = 1, columns do
        local words = ns.Markdown.Inline(row[column] or "")
        local height
        if rowIndex == 1 then
          height = add(words, 1.0, 0.82, 0.0, "PromptPeonBody", x, widths[column] - 8, true)
        else
          height = add(words, BODY_R, BODY_G, BODY_B, "PromptPeonBody", x, widths[column] - 8, true)
        end
        tallest = math.max(tallest, height)
        x = x + widths[column]
      end
      canvas.y = top + tallest + 4
      if rowIndex == 1 then
        bar(0, canvas.y - 2, math.min(total, room) + 4, 1, 0.6, 0.55, 0.35, 0.8)
        canvas.y = canvas.y + 1
      elseif rowIndex % 2 == 1 then
        bar(0, top - 1, math.min(total, room) + 4, tallest + 3, 1, 1, 1, 0.04)
      end
    end
    if #allRows > MAX_TABLE_ROWS then
      add((#allRows - MAX_TABLE_ROWS) .. " more rows in T3.", 0.70, 0.68, 0.60, "PromptPeonSmall", 4)
    end
    canvas.y = canvas.y + 4
  end
  local function drawMarkdown(text)
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
        drawTable(block.rows)
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

  local function foldingHead(key, words, right, noFold, onClick)
    canvas.heads = canvas.heads + 1
    local head = self:GroupHead(canvas.heads)
    head.key, head.open = key, self.groups[key] == true
    head.onClick = onClick
    if noFold then showFold(head, nil) else showFold(head, head.open) end
    head:ClearAllPoints()
    head:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -canvas.y)
    head:SetSize(width - 4, 14)
    head.text:SetText(words)
    head.right:SetText(right or "")
    head:Show()
    canvas.y = canvas.y + 17
    return head.open
  end

  canvas.add, canvas.addChunks, canvas.bar = add, addChunks, bar
  canvas.drawMarkdown, canvas.foldingHead = drawMarkdown, foldingHead
  return canvas
end
