-- A stand-in for the WoW client: enough API for the addon to run under luajit.
-- It proves logic, not drawing. Only the real client can prove drawing.
local M = { loaded = {}, slotData = nil, inCombat = false, reloads = 0, sounds = 0, errors = {}, chat = {},
  now = 1000, timers = {}, carriers = {}, saves = {}, carriersExist = true }

local function newObject(kind)
  local object = { kind = kind, shown = true, scripts = {}, text = "", width = 300, height = 100, alpha = 1, value = 0 }
  return setmetatable(object, { __index = function(self, key)
    -- Any method the stub has not modelled is a no-op. Fields stay nil, as on a real frame.
    local value = rawget(self, key)
    if value == nil and type(key) == "string" and key:match("^%u") then return function() end end
    return value
  end })
end

local function makeFrame(kind)
  local frame = newObject(kind)
  frame.SetScript = function(self, name, fn) self.scripts[name] = fn end
  frame.GetScript = function(self, name) return self.scripts[name] end
  frame.HookScript = frame.SetScript
  frame.Show = function(self) self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
  frame.Hide = function(self) self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
  frame.SetShown = function(self, on) if on then self:Show() else self:Hide() end end
  frame.IsShown = function(self) return self.shown end
  frame.SetText = function(self, text) self.text = text; if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end end
  frame.GetText = function(self) return self.text end
  frame.GetWidth = function(self) return self.width end
  frame.GetLeft = function() return 0 end
  frame.GetTop = function() return 1000 end
  frame.SetTexture = function(self, texture) self.texture = texture end
  frame.EnableMouse = function(self, on) self.mouseEnabled = on end
  frame.SetPoint = function(self, ...) self.lastPoint = { ... } end
  frame.SetChecked = function(self, on) self.checked = on end
  frame.GetChecked = function(self) return self.checked end
  frame.SetDesaturated = function(self, on) self.desaturated = on end
  frame.SetFontObject = function(self, font) self.fontObject = font end
  frame.GetEffectiveScale = function() return 1 end
  frame.SetResizeBounds = function(self, w, h) self.minWidth, self.minHeight = w, h end
  frame.GetHeight = function(self) return self.height end
  frame.GetSize = function(self) return self.width, self.height end
  frame.SetWidth = function(self, w) self.width = w end
  frame.SetHeight = function(self, h) self.height = h end
  frame.SetSize = function(self, w, h) self.width, self.height = w, h end
  frame.SetAlpha = function(self, a) self.alpha = a end
  frame.GetAlpha = function(self) return self.alpha end
  frame.SetValue = function(self, v) self.value = v end
  frame.GetValue = function(self) return self.value end
  frame.IsMouseOver = function() return M.mouseOver end
  frame.GetStringHeight = function() return 14 end
  frame.GetStringWidth = function(self)
    local font = self.fontObject
    if type(font) == "string" then font = _G[font] end
    if type(font) == "table" and font.drawsNothing then return 0 end
    return #tostring(self.text or "") * 6
  end
  frame.GetVerticalScroll = function() return 0 end
  frame.GetVerticalScrollRange = function() return 0 end
  frame.HasFocus = function(self) return self.focused end
  frame.SetFocus = function(self) self.focused = true end
  frame.ClearFocus = function(self) self.focused = false end
  frame.CreateFontString = function() return makeFrame("FontString") end
  frame.CreateTexture = function() return makeFrame("Texture") end
  frame.events = {}
  frame.RegisterEvent = function(self, name)
    if not next(self.events) then M.eventFrames[#M.eventFrames + 1] = self end
    self.events[name] = true
  end
  return frame
end

M.eventFrames = {}
M.makeFrame = makeFrame

function M.install()
  for name, size in pairs({ GameFontHighlight = 12, GameFontHighlightSmall = 10, GameFontNormal = 12, GameFontDisable = 12, GameFontNormalLarge = 16 }) do
    M.fontSizes = M.fontSizes or {}
    M.fontSizes[name] = size
    _G[name] = { GetFont = function() return "Fonts\\FRIZQT__.TTF", size, "" end }
  end
  CreateFont = function(name)
    local font = { CopyFontObject = function() end, SetFont = function(self, path, size)
      -- Like the real Font object: it returns nothing, and a font that didn't load draws nothing.
      self.size, self.path = size, path
      self.drawsNothing = (M.missingFonts and M.missingFonts[path]) and true or nil
    end }
    _G[name] = font
    return font
  end
  CreateFrame = function(kind, name, _, template)
    local frame = makeFrame(kind)
    if template == "BasicFrameTemplateWithInset" then
      frame.TitleText = makeFrame("FontString")
      frame.Bg, frame.InsetBg, frame.TitleBg = makeFrame("Texture"), makeFrame("Texture"), makeFrame("Texture")
    end
    if name then _G[name] = frame end
    return frame
  end
  UIParent = makeFrame("Frame")
  UIParent.width, UIParent.height = 2000, 1200
  UIParent.width, UIParent.height = 1920, 1080
  Minimap = makeFrame("Frame")
  GameTooltip = makeFrame("GameTooltip")
  UISpecialFrames = {}
  StaticPopupDialogs = {}
  M.popups = {}
  StaticPopup_Show = function(name, a, b, data) M.popups[#M.popups + 1] = { name = name, a = a, b = b, data = data } end
  SlashCmdList = {}
  SOUNDKIT = { IG_QUEST_LOG_OPEN = 1, IG_QUEST_LIST_COMPLETE = 2, IG_QUEST_LOG_ABANDON_QUEST = 3, UI_EPICLOOT_TOAST = 4,
    LOOT_WINDOW_COIN_SOUND = 5, READY_CHECK = 6, RAID_BOSS_EMOTE_WARNING = 7, UI_RAID_BOSS_DEFEATED = 8, TUTORIAL_POPUP = 9 }
  M.played = {}
  M.cursorX = 0
  date = os.date
  M.instance = nil
  IsInInstance = function() return M.instance ~= nil end
  GetInstanceInfo = function() return M.instance end
  M.cursorY = 0
  M.mouseDown = true
  GetCursorPosition = function() return M.cursorX, M.cursorY end
  IsMouseButtonDown = function() return M.mouseDown end
  PlaySound = function(sound) M.sounds = M.sounds + 1; M.played[#M.played + 1] = sound end
  PlaySoundFile = function(file) M.sounds = M.sounds + 1; M.played[#M.played + 1] = file end
  PlayerFrame = makeFrame("Frame")
  RaidBossEmoteFrame = makeFrame("Frame")
  ChatTypeInfo = { RAID_BOSS_EMOTE = { r = 1, g = 1, b = 0 } }
  M.banners = {}
  RaidNotice_AddMessage = function(_, text) M.banners[#M.banners + 1] = text end
  IsInGroup = function() return M.inGroup end
  SetPortraitTextureFromCreatureDisplayID = function(texture, id) texture.portrait = id end
  UIErrorsFrame = { AddMessage = function(_, text) M.errors[#M.errors + 1] = text end }
  DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) M.chat[#M.chat + 1] = text end }
  InCombatLockdown = function() return M.inCombat end
  IsShiftKeyDown = function() return M.shift end
  UnitName = function() return "Tester" end
  UnitFactionGroup = function() return M.faction or "Horde" end
  UnitRace = function() return "Orc", M.race or "Orc" end
  GetTime = function() return M.now end
  debugprofilestop = function() return M.now * 1000 end
  time = function(when) if when then return os.time(when) end return M.clock or os.time() end
  ReloadUI = function() M.reloads = M.reloads + 1 end
  strsplit = function(sep, text)
    local out = {}
    for part in (text .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
    return unpack(out)
  end
  EventRegistry = { RegisterCallback = function(_, name, fn) M.linkHandler = fn end }
  C_Timer = {
    NewTicker = function(_, fn) M.tick = fn end,
    After = function(_, fn) M.timers[#M.timers + 1] = fn end,
  }
  C_AddOns = {
    LoadAddOn = function(name)
      if M.refuseLoads then return false, "DISABLED" end
      if M.loaded[name] then return false, "ALREADY_LOADED" end
      M.loaded[name] = true
      PROMPTPEON_SNAPSHOT = M.slotData
      return true
    end,
    DoesAddOnExist = function(name) return M.carriersExist or not name:find("Out", 1, true) end,
    DisableAddOn = function(name) M.carriers[name] = true end,
    EnableAddOn = function(name) M.carriers[name] = false end,
    SaveAddOns = function()
      local set = {}
      for index = 1, 96 do
        if M.carriers[string.format("PromptPeonOut%02d", index)] then set[#set + 1] = index end
      end
      M.saves[#M.saves + 1] = set
    end,
  }
end

--- Run everything C_Timer.After has queued, once.
function M.runTimers()
  local due = M.timers
  M.timers = {}
  for _, fn in ipairs(due) do fn() end
end

function M.fire(event, ...)
  for _, frame in ipairs(M.eventFrames) do
    if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
  end
end

return M
