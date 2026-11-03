-- Pages: what the pane shows when it isn't a thread's messages: the away report, the new thread
-- page, achievements, and the agents a thread sent out.

local _, ns = ...
local UI = ns.UI
local STATUS, colored, plural, diffCounts, STEP_MARK = UI.STATUS, UI.Colored, UI.Plural, UI.DiffCounts, UI.STEP_MARK

local DIM_R, DIM_G, DIM_B = 0.70, 0.68, 0.60

--- What moved while you were gone. The order and the words come from Game.BuildReport.
function UI:DrawReport(canvas, report)
  local add, foldingHead, width = canvas.add, canvas.foldingHead, canvas.width
  local words = ns.Game.ReportHeadline(report)
  add(words, 1.0, 0.82, 0.0, "PromptPeonHeader")
  local facts = { report.minutes .. (report.minutes == 1 and " minute" or " minutes") }
  if report.turns > 0 then facts[#facts + 1] = plural(report.turns, "turn") end
  if report.messages > 0 then facts[#facts + 1] = plural(report.messages, "message") end
  if report.files > 0 then facts[#facts + 1] = plural(report.files, "file") .. " changed  " .. diffCounts(report.added, report.removed) end
  add(table.concat(facts, ", "), 0.70, 0.68, 0.60, "PromptPeonSmall")
  canvas.y = canvas.y + 6
  for _, entry in ipairs(report.entries) do
    local info = STATUS[entry.s] or STATUS.idle
    local right = entry.isNew and "new" or entry.fresh > 0 and plural(entry.fresh, "message") or ""
    local id = entry.id
    foldingHead("report:" .. id, colored(info, "[" .. info.tag .. "]") .. " |cffffd100" .. ns.Plain(entry.title) .. "|r", right ~= "" and ("|cff888888" .. right .. "|r") or nil, true, function()
      UI.showReport = nil
      ns.db.selected = id
    end)
    if entry.gist and entry.gist ~= "" then add(ns.Plain(entry.gist), 0.78, 0.76, 0.68, "PromptPeonSmall", 15, width - 20) end
    if entry.change then
      add(plural(entry.change[1], "file") .. " changed  " .. diffCounts(entry.change[2], entry.change[3]), 0.60, 0.60, 0.55, "PromptPeonSmall", 15)
    end
    canvas.y = canvas.y + 4
  end
  if #report.loot > 0 then
    canvas.y = canvas.y + 4
    add("Loot", 1.0, 0.82, 0.0, "PromptPeonHeader")
    for _, item in ipairs(report.loot) do add(item, 1, 1, 1, "PromptPeonSmall", 15) end
    canvas.y = canvas.y + 4
  end
  canvas.y = canvas.y + 4
end

--- Project and approvals are menus. What it should do goes in the reply box.
function UI:DrawNewThread(canvas, new)
  local add, foldingHead = canvas.add, canvas.foldingHead
  foldingHead("new:project", "|cff9a9a9aProject|r  |cffffd100" .. ns.Plain(new.project) .. "|r", "|cff888888change|r", true, function(_, head)
    local items = { { title = "Project" } }
    for _, name in ipairs(ns.snapshot and ns.snapshot.pj or {}) do
      items[#items + 1] = { text = ns.Plain(name), checked = name == new.project, run = function()
        new.project = name
        UI:Render()
      end }
    end
    UI:ShowMenu(head, items)
  end)
  local mode = ns:NewThreadMode(new.instance)
  foldingHead("new:mode", "|cff9a9a9aApprovals|r  |cffffd100" .. mode.label .. "|r", "|cff888888change|r", true, function(_, head)
    local items = { { title = "Approvals" } }
    for _, choice in ipairs(ns.RUNTIME_MODES) do
      local available, why = ns:ModeAvailable(choice, new.instance)
      if available then
        items[#items + 1] = { text = choice.label, checked = choice == mode, run = function()
          ns.db.newMode = choice.id
          UI:Render()
        end }
      elseif why == "off" then
        items[#items + 1] = { text = "|cff808080" .. choice.label .. " (off)|r", run = function()
          UI:SetNotice(choice.label .. " is off, because you said no at install. Run the Prompt Peon installer again to turn it on.")
        end }
      end
    end
    UI:ShowMenu(head, items)
  end)
  canvas.y = canvas.y + 6
  add("Type what it should do below, then press Send. Model and effort are by the box.", 0.85, 0.83, 0.75, "PromptPeonSmall")
  if mode.free then
    add(mode.note, 1.0, 0.66, 0.26, "PromptPeonSmall")
  else
    add(mode.note, 0.60, 0.60, 0.55, "PromptPeonSmall")
  end
end

--- Earned ones first.
function UI:DrawAchievements(canvas)
  local add, foldingHead, width = canvas.add, canvas.foldingHead, canvas.width
  local Game, earned = ns.Game, ns.db.achievements
  local function row(entry, isEarned)
    local icon = "|TInterface\\Icons\\" .. entry.icon .. ":14|t "
    if isEarned then
      foldingHead("achievement:" .. entry.id, icon .. "|cffffd100" .. entry.name .. "|r", "|cff888888" .. date("%d %b %Y", earned[entry.id]) .. "|r", true)
      add(entry.text, 0.85, 0.83, 0.75, "PromptPeonSmall", 15, width - 20)
    else
      local progress = entry.stat and ((ns.db.stats[entry.stat] or 0) .. " of " .. entry.goal) or nil
      foldingHead("achievement:" .. entry.id, icon .. "|cff808080" .. entry.name .. "|r", progress and ("|cff888888" .. progress .. "|r") or nil, true)
      add(entry.text, 0.50, 0.50, 0.48, "PromptPeonSmall", 15, width - 20)
    end
    canvas.y = canvas.y + 4
  end
  for _, entry in ipairs(Game.ACHIEVEMENTS) do
    if earned[entry.id] then row(entry, true) end
  end
  for _, entry in ipairs(Game.ACHIEVEMENTS) do
    if not earned[entry.id] then row(entry, false) end
  end
  canvas.y = canvas.y + 4
end

local AGENT_WORDS = { r = "working", f = "failed", c = "stopped", d = "done" }

--- Who the thread sent out. What they said arrives separately, once ToggleView has asked.
function UI:DrawAgents(canvas, thread)
  local add, drawMarkdown, foldingHead = canvas.add, canvas.drawMarkdown, canvas.foldingHead
  local words = (ns.loaded[thread.id] or {}).ax
  for _, agent in ipairs(thread.ag or {}) do
    local id, name, state, model, started = agent[1], agent[2], agent[3], agent[4], agent[5]
    local style = STEP_MARK[state or "d"] or STEP_MARK.d
    local key = thread.id .. ":agent:" .. id
    local isOpen = self.groups[key] == true
    local details = AGENT_WORDS[state] or "done"
    if started and started > 0 then details = details .. ", " .. ns.Ago(time() - started) end
    local title = string.format("|cff%02x%02x%02x%s|r", style.r * 255, style.g * 255, style.b * 255, ns.Plain(name))
    if model and model ~= "" then title = title .. "  |cff808080" .. ns.Plain(model) .. "|r" end
    foldingHead(key, title, "|cff888888" .. details .. "|r")
    if isOpen then
      local pair = words and words[id]
      if pair then
        if pair[1] ~= "" then
          add("What it was asked", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 12)
          drawMarkdown(pair[1])
        end
        if pair[2] ~= "" then
          add("What it came back with", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 12)
          drawMarkdown(pair[2])
        elseif state == "r" then
          add("Still working.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 12)
        end
      elseif words then
        add("Too long to show here. Open it in T3.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 12)
      else
        add(self:LoadingWords(thread), DIM_R, DIM_G, DIM_B, "PromptPeonSmall", 12)
      end
      canvas.y = canvas.y + 4
    end
  end
  local older = (thread.agn or 0) - #(thread.ag or {})
  if older > 0 then
    canvas.y = canvas.y + 4
    add(older .. " older " .. (older == 1 and "agent" or "agents") .. " in T3.", DIM_R, DIM_G, DIM_B, "PromptPeonSmall")
  end
end
