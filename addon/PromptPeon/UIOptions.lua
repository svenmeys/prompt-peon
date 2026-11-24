-- Options: the settings page in the log, with clean flat toggles, sliders and action buttons.

local _, ns = ...
local UI = ns.UI

function UI:ToggleOptions()
  self.showOptions = not self.showOptions or nil
  self.showAchievements, self.showReport, self.shownKey = nil, nil, nil
  if self.showOptions and self.newThread then self:StopNewThread() end
  if self:IsOpen() then self:Render() else self:Toggle() end
end

--- Options as a clean flat settings page in the detail pane.
function UI:BuildOptionsPage()
  local THEME = UI.THEME
  local page = CreateFrame("Frame", nil, self.detailContent)
  page:SetPoint("TOPLEFT")
  page:SetSize(320, 10)
  page.checks, page.sliders = {}, {}
  local y = 0
  local function heading(words)
    if y > 0 then
      y = y + 8
      local rule = page:CreateTexture(nil, "BORDER")
      rule:SetPoint("TOPLEFT", 0, -y)
      rule:SetPoint("TOPRIGHT", 0, -y)
      rule:SetHeight(1)
      rule:SetColorTexture(THEME.divider[1], THEME.divider[2], THEME.divider[3], 0.7)
      y = y + 8
    else
      y = y + 4
    end
    local text = page:CreateFontString(nil, "OVERLAY", "PromptPeonHeader")
    text:SetPoint("TOPLEFT", 0, -y)
    text:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    text:SetText(words)
    y = y + 20
  end
  local function check(key, label, detail, get, set)
    local box = CreateFrame("CheckButton", nil, page)
    box:SetSize(16, 16)
    box:SetPoint("TOPLEFT", 2, -(y + 3))
    UI.SkinSurface(box, THEME.input, THEME.border)
    local mark = box:CreateTexture(nil, "OVERLAY")
    mark:SetPoint("TOPLEFT", 3, -3)
    mark:SetPoint("BOTTOMRIGHT", -3, 3)
    mark:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
    mark:Hide()
    box.mark = mark
    local origSetChecked = box.SetChecked
    box.SetChecked = function(self, on)
      origSetChecked(self, on)
      local checked = on and true or false
      mark:SetShown(checked)
      if checked then
        UI.SetBorderColor(self, THEME.borderAccent[1], THEME.borderAccent[2], THEME.borderAccent[3], THEME.borderAccent[4])
      else
        UI.SetBorderColor(self, THEME.border[1], THEME.border[2], THEME.border[3], THEME.border[4])
      end
    end
    local text = page:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetText(label .. "  |cff7c828d" .. detail .. "|r")
    box:SetScript("OnClick", function(self)
      local nextVal = not self:GetChecked()
      -- Real CheckButton flips before OnClick; stub tests set checked directly before calling OnClick.
      if self.checked == nil then self:SetChecked(nextVal) end
      set(self:GetChecked() and true or false)
      self:SetChecked(get() and true or false)
      UI:Render()
    end)
    page.checks[key] = { box = box, get = get }
    y = y + 24
  end
  local function slider(key, label, low, high, step, get, set, words)
    local text = page:CreateFontString(nil, "OVERLAY", "PromptPeonBody")
    text:SetPoint("TOPLEFT", 2, -y)
    text:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    y = y + 18
    local bar = CreateFrame("Slider", "PromptPeonOption" .. key, page, "UISliderTemplate")
    bar:SetSize(220, 16)
    bar:SetPoint("TOPLEFT", 2, -y)
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
    local action = UI.FlatButton(page, 220, 22, label)
    action:SetPoint("TOPLEFT", 2, -y)
    action:SetScript("OnClick", run)
    page[key] = action
    y = y + 28
  end
  heading("Show")
  check("list", "Thread list", "the threads on the left", function() return not ns.db.listHidden end, function() UI:ToggleList() end)
  check("tracker", "Quest tracker", "your tracked threads on screen", function() return not ns.db.trackerOff end, function(on) ns.db.trackerOff = not on or nil end)
  check("minimap", "Minimap button", "opens the log", function() return not ns.db.minimapOff end, function(on) ns.db.minimapOff = not on or nil end)
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
  check("bell", "Fast updates", "hears the companion app, needs game sound on", function() return not ns.db.bellOff end, function(on) ns.db.bellOff = not on or nil end)
  heading("You")
  button("checkConnection", "Check the connection", function() ns.Chat:CheckConnection() end)
  page.height = y + 8
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
    entry.text:SetText(entry.label .. "  |cfff0c461" .. entry.words(value) .. "|r")
  end
  page.syncing = nil
end
