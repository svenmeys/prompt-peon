-- Options: the settings page in the log, with the game's own checkboxes and sliders.

local _, ns = ...
local UI = ns.UI

function UI:ToggleOptions()
  self.showOptions = not self.showOptions or nil
  self.showAchievements, self.showReport = nil, nil
  if self.showOptions and self.newThread then self:StopNewThread() end
  if self:IsOpen() then self:Render() else self:Toggle() end
end

--- Options as a page in the log, with the game's own checkboxes and sliders.
function UI:BuildOptionsPage()
  local page = CreateFrame("Frame", nil, self.detailContent)
  page:SetPoint("TOPLEFT")
  page:SetSize(280, 10)
  page.checks, page.sliders = {}, {}
  local y = 0
  local function heading(words)
    y = y + 6
    local text = page:CreateFontString(nil, "OVERLAY", "PromptPeonHeader")
    text:SetPoint("TOPLEFT", 0, -y)
    text:SetText(words)
    y = y + 18
  end
  local function check(key, label, detail, get, set)
    local box = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    box:SetSize(22, 22)
    box:SetPoint("TOPLEFT", 0, -y)
    local text = page:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
    text:SetPoint("LEFT", box, "RIGHT", 4, 0)
    text:SetText(label .. "  |cff808080" .. detail .. "|r")
    box:SetScript("OnClick", function(self)
      set(self:GetChecked() and true or false)
      UI:Render()
    end)
    page.checks[key] = { box = box, get = get }
    y = y + 23
  end
  local function slider(key, label, low, high, step, get, set, words)
    local text = page:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
    text:SetPoint("TOPLEFT", 4, -y)
    y = y + 16
    local bar = CreateFrame("Slider", "PromptPeonOption" .. key, page, "UISliderTemplate")
    bar:SetSize(200, 16)
    bar:SetPoint("TOPLEFT", 4, -y)
    bar:SetMinMaxValues(low, high)
    bar:SetValueStep(step)
    bar:SetObeyStepOnDrag(true)
    bar:SetScript("OnValueChanged", function(_, value)
      if not page.syncing then set(value) end
    end)
    page.sliders[key] = { bar = bar, text = text, label = label, get = get, words = words }
    y = y + 24
  end
  local function button(key, label, run)
    local action = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    action:SetSize(210, 20)
    action:SetPoint("TOPLEFT", 4, -y)
    action:SetText(label)
    action:SetScript("OnClick", run)
    page[key] = action
    y = y + 24
  end
  heading("Show")
  check("list", "Thread list", "the threads on the left", function() return not ns.db.listHidden end, function() UI:ToggleList() end)
  check("tracker", "Quest tracker", "your tracked threads on screen", function() return not ns.db.trackerOff end, function(on) ns.db.trackerOff = not on or nil end)
  check("party", "Party frames", "agents as party members", function() return ns.db.partyOn == true end, function(on) ns.db.partyOn = on end)
  check("elite", "Elite frames", "silver and gold dragons for veterans", function() return ns.db.eliteFrames == true end, function(on) ns.db.eliteFrames = on or nil end)
  check("askSpells", "Ask before spells", "shows the words first", function() return not ns.db.spellsNoAsk end, function(on) ns.db.spellsNoAsk = not on or nil end)
  button("workers", "", function()
    local order = { [false] = "peon", peon = "peasant", peasant = "undead", undead = false }
    ns.db.workers = order[ns.db.workers or false] or nil
    ns.db.faces = {}
    UI:Render()
  end)
  check("voice", "Workers' voices", "work, work", function() return not ns.db.peonQuiet end, function(on) ns.db.peonQuiet = not on or nil end)
  check("questSound", "Quest sound", "as well, when a thread finishes", function() return ns.db.questSound == true end, function(on) ns.db.questSound = on or nil end)
  check("chatNews", "News in chat", "finished threads, levels, loot", function() return not ns.db.chatNewsOff end, function(on) ns.db.chatNewsOff = not on or nil end)
  check("chatTab", "In its own chat tab", "off puts it in your main chat", function() return not ns.db.chatNewsInMain end, function(on) ns.db.chatNewsInMain = not on or nil end)
  heading("Window")
  slider("Font", "Text size", 8, 20, 1, function() return ns.db.fontSize end, function(value) UI:SetFontSize(value) end,
    function(value) return tostring(math.floor(value + 0.5)) end)
  slider("Opacity", "Background", 0.1, 1, 0.05, function() return ns.db.opacity end, function(value)
    UI:SetOpacity(value)
    UI:SyncOptions()
  end, function(value) return math.floor(value * 100 + 0.5) .. "%" end)
  button("resetWindow", "Reset window size", function() UI:ResetWindow() end)
  heading("Updates")
  slider("Refresh", "Refresh every", 10, 60, 5, function() return ns:RefreshSeconds() end, function(value)
    ns.db.refreshSeconds = math.floor(value + 0.5)
    UI:SyncOptions()
    UI:RenderReloadHint()
  end, function(value)
    local seconds = math.floor(value + 0.5)
    return seconds .. " s, reload " .. ns.AboutTime(seconds * ns.SLOT_COUNT) .. " apart"
  end)
  heading("You")
  button("openStatus", "Show status in chat", function() ns.Chat:Status() end)
  page.height = y
  self.optionsPage = page
end

--- Sets every control from saved settings. `syncing` stops a slider reacting to being set.
function UI:SyncOptions()
  local page = self.optionsPage
  page.syncing = true
  for _, entry in pairs(page.checks) do entry.box:SetChecked(entry.get()) end
  page.workers:SetText("Voices: " .. ns:Workers().voice .. (ns.db.workers and "" or " (your side)"))
  for _, entry in pairs(page.sliders) do
    local value = entry.get()
    entry.bar:SetValue(value)
    entry.text:SetText(entry.label .. "  |cffffd100" .. entry.words(value) .. "|r")
  end
  page.syncing = nil
end
