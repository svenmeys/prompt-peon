-- Chat: what Prompt Peon says in your chat, and the links it prints.
-- /peon and /t3 open or close the log. Everything else has a button.

local addonName, ns = ...

local Chat = {}
ns.Chat = Chat

local LINK_OWNER = "peon"
local COLOR = "|cff66ccff"
local CHAT_LINE_BYTES = 400
local COLOR_GOLD = "|cffffd100"

local NEWS_TAB = "Peon"

local function say(text)
  DEFAULT_CHAT_FRAME:AddMessage(COLOR .. "Peon|r " .. text)
end

--- Where news goes: its own chat tab unless you chose otherwise, and nowhere if you turned it off.
--- Things you asked for and things that went wrong still use your main chat, so you see them.
--- pa-lean: a tab you close by hand comes back with the next news. Options is how to turn it off.
local function newsFrame()
  if ns.db.chatNewsOff then return nil end
  if ns.db.chatNewsInMain or not FCF_OpenNewWindow or not FCF_GetChatWindowInfo then return DEFAULT_CHAT_FRAME end
  for index = 1, NUM_CHAT_WINDOWS or 10 do
    local name, _, _, _, _, _, shown, _, docked = FCF_GetChatWindowInfo(index)
    if name == NEWS_TAB and (shown or docked) then return FCF_GetChatFrameByID(index) end
  end
  -- Opening a tab selects it, and you shouldn't lose your general chat over a finished thread.
  local before = FCFDock_GetSelectedWindow and GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow(GENERAL_CHAT_DOCK)
  local frame = FCF_OpenNewWindow(NEWS_TAB, true)
  if before and FCF_SelectDockFrame then FCF_SelectDockFrame(before) end
  return frame or DEFAULT_CHAT_FRAME -- Every chat tab is taken.
end

--- A clickable [Title] that opens that thread.
local CHAT_PREVIEW_LINES = 3

local function threadLink(thread)
  local label = "[" .. ns.Plain(thread.t) .. "]"
  return COLOR .. "|Haddon:" .. LINK_OWNER .. ":" .. tostring(thread.id) .. "|h" .. label .. "|h|r"
end

local function latestAgentText(thread)
  local messages = thread.m or {}
  for index = #messages, 1, -1 do
    if messages[index][1] == "a" then return messages[index][2] end
  end
end

--- The whole text as chat lines, each line of the message split further if it is long.
local function chatLines(text)
  local lines = {}
  for line in (ns.Markdown.Plain(text) .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      for _, chunk in ipairs(ns.Chunks(line, CHAT_LINE_BYTES)) do
        lines[#lines + 1] = ns.Plain(chunk)
      end
    end
  end
  return lines
end

--- Print a heading and the start of the text. Chat is where other addons and chat logs keep a copy,
--- so it gets enough to know what happened. The log has the rest, uncut.
local function sayLong(heading, text)
  local frame = newsFrame()
  if not frame then return end
  local lines = chatLines(text or "")
  if #lines == 0 then
    frame:AddMessage(COLOR .. "Peon|r " .. heading .. ".")
    return
  end
  frame:AddMessage(COLOR .. "Peon|r " .. heading .. ": " .. lines[1])
  for index = 2, math.min(#lines, CHAT_PREVIEW_LINES) do
    frame:AddMessage(lines[index], 0.85, 0.92, 1.0)
  end
  if #lines > CHAT_PREVIEW_LINES then
    frame:AddMessage("... the rest is in the log.", 0.6, 0.6, 0.6)
  end
end

--- Something that happened by itself: a thread finished, levelled up or found loot.
function Chat:News(words)
  local frame = newsFrame()
  if frame then frame:AddMessage(COLOR .. "Peon|r " .. words) end
end

function Chat:ReportFinished(thread)
  local words = thread.s == "error" and "failed" or thread.s == "stopped" and "stopped" or "finished"
  sayLong(threadLink(thread) .. " " .. words, latestAgentText(thread))
end

function Chat:ReportNeeds(thread)
  Chat:News(threadLink(thread) .. " needs you. Answer it in T3.")
end

function Chat:ReportFailure(entry, result)
  local thread = ns:ThreadById(entry.thread)
  say((thread and threadLink(thread) or "Your reply") .. " did not go through: " .. ns.Plain(result))
end

function Chat:ReportStuck(entry)
  local thread = ns:ThreadById(entry.thread)
  say((thread and threadLink(thread) or "Your reply") .. ": the companion app is not answering. Your reply is saved. Press Reload UI in the log to send it.")
end

function Chat:ReportSettled(thread)
  say("Turned in " .. ns.Plain(thread.t) .. ". " .. COLOR_GOLD .. "|Haddon:" .. LINK_OWNER .. ":unsettle:" .. tostring(thread.id) .. "|h[Undo]|h|r")
end

--- Bring a turned-in thread back.
function Chat:Undo(id)
  local last = ns.db.lastSettled
  if not ns:QueueCommand(id, "unsettle") then return end
  local known = last and last.id == id
  say("Asked T3 to bring back " .. (known and ns.Plain(last.title) or "that thread") .. ".")
  if known then ns.db.lastSettled = nil end -- A second click has nothing left to undo.
end

function Chat:List()
  local threads = ns:VisibleThreads()
  if #threads == 0 then
    say("No open threads.")
    return
  end
  for _, thread in ipairs(threads) do
    say(threadLink(thread) .. " " .. (ns.UI and ns.UI.StatusLabel(thread) or thread.s))
  end
end

function Chat:ReportReload(words)
  say(words)
end

function Chat:Status()
  local seconds, left = ns:ReloadIn()
  local updated = ns.snapshot and ns.Ago(time() - (ns.snapshot.at or 0)) or "never"
  say(string.format("%d live updates left before you need a reload, %s at this pace. The last one took %.1f ms. Companion app last heard %s.",
    left, ns.AboutTime(seconds), ns.lastLoadMs or 0, updated))
  if ns.worstSaveMs then
    say(string.format("Sending: the last step took %.1f ms, the slowest %.1f ms.", ns.lastSaveMs, ns.worstSaveMs))
  end
end

--- Typing the command into the reply box closes the log. It isn't a message for your agent.
function Chat.OwnCommand(text)
  local typed = text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  return typed == "/peon" or typed == "/t3"
end

--- Clicking a thread name in chat opens it in the log.
function Chat:OnLink(link, button)
  -- Everything after the owner, because some thread IDs have colons in them.
  local id = link:match("^addon:" .. LINK_OWNER .. ":(.+)$")
  if not id then return end
  if id == "report" then
    if ns.Game then ns.Game:OpenReport() end
    return
  end
  if id == "achievements" then
    if ns.Game then ns.Game:OpenAchievements() end
    return
  end
  -- Any addon can print a link that looks like these, so a click only ever does something small.
  local changedThread = id:match("^changes:(.+)$")
  if changedThread then
    -- Fetching a diff brings file contents into the game folder, so that takes a second, clear click.
    if ns.UI and ns:ThreadById(changedThread) then ns.UI:OpenThread(changedThread) end
    return
  end
  local settledThread = id:match("^unsettle:(.+)$")
  if settledThread then
    local last = ns.db.lastSettled
    if last and last.id == settledThread then
      self:Undo(settledThread)
    else
      say("Nothing to undo there.")
    end
    return
  end
  if not ns:ThreadById(id) then return end
  if ns.UI then ns.UI:OpenThread(id) end
end

SLASH_PROMPTPEON1 = "/peon"
SLASH_PROMPTPEON2 = "/t3"
SlashCmdList.PROMPTPEON = function()
  if ns.UI then ns.UI:Toggle() end
end

if EventRegistry then
  EventRegistry:RegisterCallback("SetItemRef", function(_, link, _, button) Chat:OnLink(link, button) end, Chat)
end
