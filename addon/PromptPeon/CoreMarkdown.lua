-- Markdown: turns what agents write into something a FontString can draw.

local _, ns = ...

-- A FontString can only change colour mid-line, so bold, code and links are colours. Everything
-- bigger, like headings, lists, code blocks and tables, is separate blocks the log draws.
local Markdown = {}
ns.Markdown = Markdown

local INLINE_CODE, INLINE_BOLD, INLINE_LINK, INLINE_ITALIC = "|cff9fd3c7", "|cffffffff", "|cff70b7ff", "|cffd0ccc0"

-- T3 writes a link to a thread as <t3-thread://v2/ENVIRONMENT/ID> or [label](t3-thread://...), with
-- the ID sometimes percent-escaped. These find them; each hands over everything after the version.
local THREAD_LINK_LABELED = "%[([^%]\n]*)%]%(<?t3%-thread://v[12]/([^%s%)>]+)>?%)"
local THREAD_LINK_BARE = "<t3%-thread://v[12]/([^%s<>]+)>"

local function linkedThread(path)
  local id = path:match("^[^/]+/(.+)$") or path -- v1 links have no environment in front.
  local thread = ns:ThreadById(id)
  if thread then return thread end
  local decoded = id:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  return ns:ThreadById(decoded)
end

--- What a link says: what the agent called it, or else the thread's title.
local function threadLinkWords(label, thread)
  if label and label:match("%S") then return label end
  return thread and thread.t or "a thread"
end

--- One line of text, ready to draw. Pipes are doubled first, so nothing from a thread can
--- become a WoW escape. Only the codes added here can.
function Markdown.Inline(text)
  local out = ns.Plain(text)
  local held = {}
  out = out:gsub("`([^`\n]+)`", function(code)
    held[#held + 1] = INLINE_CODE .. code .. "|r"
    return "\1" .. #held .. "\1"
  end)
  -- Held like code, so the marks below can't reach inside. A thread the game doesn't have stays words.
  local function threadLink(label, path)
    local thread = linkedThread(path)
    -- A label can hold code that was just held, and the swap back at the end only goes one level deep.
    local words = (label and label:match("%S") and label or ns.Plain(threadLinkWords(nil, thread)))
      :gsub("\1(%d+)\1", function(number) return held[tonumber(number)] end)
    if thread and thread.id:match("^[%w:%-_%.~]+$") then
      words = INLINE_LINK .. "|Haddon:peon:" .. thread.id .. "|h" .. words .. "|h|r"
    end
    held[#held + 1] = words
    return "\1" .. #held .. "\1"
  end
  out = out:gsub(THREAD_LINK_LABELED, threadLink)
  out = out:gsub(THREAD_LINK_BARE, function(path) return threadLink(nil, path) end)
  out = out:gsub("%[([^%]\n]+)%]%([^%)\n]+%)", INLINE_LINK .. "%1|r")
  out = out:gsub("%*%*(.-)%*%*", INLINE_BOLD .. "%1|r")
  out = out:gsub("%*([^%s%*][^%*\n]-)%*", INLINE_ITALIC .. "%1|r")
  out = out:gsub("\1(%d+)\1", function(number) return held[tonumber(number)] end)
  return out
end

local function isTableRule(line)
  return line:find("-", 1, true) and line:find("|", 1, true) and line:match("^[%s|:%-]+$") ~= nil
end

local function tableCells(line)
  local body = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  for cell in (body .. "|"):gmatch("(.-)|") do
    cells[#cells + 1] = (cell:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  return cells
end

local function isRule(line)
  local trimmed = line:gsub("%s", "")
  return #trimmed >= 3 and (trimmed:match("^%-+$") or trimmed:match("^%*+$") or trimmed:match("^_+$")) ~= nil
end

local function isSpecial(line, nextLine)
  return line:match("^%s*```") or line:match("^#+%s") or line:match("^%s*>") or line:match("^%s*[-*+]%s+%S")
    or line:match("^%s*%d+[.)]%s+%S") or isRule(line) or (line:find("|", 1, true) and nextLine and isTableRule(nextLine))
end

--- Split a message into blocks: p, h, li, code, quote, rule, table.
function Markdown.Blocks(text)
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  local blocks, index = {}, 1
  while index <= #lines do
    local line = lines[index]
    if not line:match("%S") then
      index = index + 1
    elseif line:match("^%s*```") then
      local code = {}
      index = index + 1
      while index <= #lines and not lines[index]:match("^%s*```") do
        code[#code + 1] = lines[index]
        index = index + 1
      end
      index = index + 1
      blocks[#blocks + 1] = { kind = "code", text = table.concat(code, "\n") }
    elseif line:find("|", 1, true) and lines[index + 1] and isTableRule(lines[index + 1]) then
      local rows = { tableCells(line) }
      index = index + 2
      while index <= #lines and lines[index]:find("|", 1, true) and lines[index]:match("%S") do
        rows[#rows + 1] = tableCells(lines[index])
        index = index + 1
      end
      blocks[#blocks + 1] = { kind = "table", rows = rows }
    elseif line:match("^#+%s") then
      local marks, title = line:match("^(#+)%s+(.-)%s*#*%s*$")
      blocks[#blocks + 1] = { kind = "h", level = #marks, text = title }
      index = index + 1
    elseif isRule(line) then
      blocks[#blocks + 1] = { kind = "rule" }
      index = index + 1
    elseif line:match("^%s*>") then
      local quote = {}
      while index <= #lines and lines[index]:match("^%s*>") do
        quote[#quote + 1] = lines[index]:gsub("^%s*>%s?", "")
        index = index + 1
      end
      blocks[#blocks + 1] = { kind = "quote", text = table.concat(quote, "\n") }
    elseif line:match("^%s*[-*+]%s+%S") or line:match("^%s*%d+[.)]%s+%S") then
      local spaces, mark, body = line:match("^(%s*)([-*+])%s+(.*)$")
      if not spaces then
        local number
        spaces, number, body = line:match("^(%s*)(%d+)[.)]%s+(.*)$")
        mark = number .. "."
      else
        mark = "\226\128\162" -- A bullet, which WoW's fonts can draw.
      end
      index = index + 1
      -- Indented lines under an item belong to it. Joined once at the end: adding them to a growing
      -- string one at a time takes seconds on a long list.
      local parts = { body }
      while index <= #lines and lines[index]:match("^%s+%S") and not isSpecial(lines[index], lines[index + 1]) do
        parts[#parts + 1] = (lines[index]:gsub("^%s+", ""))
        index = index + 1
      end
      body = table.concat(parts, " ")
      blocks[#blocks + 1] = { kind = "li", mark = mark, depth = math.floor(#spaces / 2), text = body }
    else
      local paragraph = { line }
      index = index + 1
      while index <= #lines and lines[index]:match("%S") and not isSpecial(lines[index], lines[index + 1]) do
        paragraph[#paragraph + 1] = lines[index]
        index = index + 1
      end
      blocks[#blocks + 1] = { kind = "p", text = table.concat(paragraph, "\n") }
    end
  end
  return blocks
end

--- Plain words for chat and the tracker, where blocks can't be drawn.
function Markdown.Plain(text)
  local out = {}
  for _, block in ipairs(Markdown.Blocks(text)) do
    if block.kind == "table" then
      for _, row in ipairs(block.rows) do out[#out + 1] = table.concat(row, " - ") end
    elseif block.kind == "li" then
      out[#out + 1] = string.rep("  ", block.depth) .. block.mark .. " " .. block.text
    elseif block.text then
      out[#out + 1] = block.text
    end
  end
  local joined = table.concat(out, "\n")
  joined = joined:gsub(THREAD_LINK_LABELED, function(label, path) return threadLinkWords(label, linkedThread(path)) end)
  joined = joined:gsub(THREAD_LINK_BARE, function(path) return threadLinkWords(nil, linkedThread(path)) end)
  joined = joined:gsub("%*%*(.-)%*%*", "%1"):gsub("`([^`\n]+)`", "%1"):gsub("%[([^%]\n]+)%]%([^%)\n]+%)", "%1")
  return joined
end
