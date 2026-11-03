-- Layout: window size, text sizes and opacity, and fitting what's inside the window to its size.

local _, ns = ...
local UI = ns.UI
local PAD, TINY_WIDTH, MIN_WIDTH_NO_LIST = UI.PAD, UI.TINY_WIDTH, UI.MIN_WIDTH_NO_LIST

local LIST_WIDTH = 200 -- Drag the edge of the list to change it.
local LIST_MIN_WIDTH = 120
local DETAIL_MIN_WIDTH = 300
local SHORT_HEIGHT = 340 -- Below this the reply box gives up some room to the thread.

--- The way back from a window that ended up somewhere you can't work with.
function UI:ResetWindow()
  ns.db.width, ns.db.height, ns.db.position = nil, nil, nil
  self.frame:ClearAllPoints()
  self.frame:SetPoint("CENTER")
  self.frame:SetSize(820, 520)
  self:FitToSize()
  self:Render()
end

function UI:ApplyOpacity()
  local frame, opacity = self.frame, ns.db.opacity
  -- Two background layers stack, so each gets the alpha that adds up to what was asked for.
  local layer = 1 - math.sqrt(1 - opacity)
  frame.Bg:SetAlpha(layer)
  frame.InsetBg:SetAlpha(layer)
  frame.TitleBg:SetAlpha(math.min(1, opacity + 0.15))
end

function UI:SetOpacity(value)
  value = math.max(0.1, math.min(1, value))
  ns.db.opacity = value
  self:ApplyOpacity()
end

-- --- Text sizes ---------------------------------------------------------------------

local FONTS = {
  { name = "PromptPeonBody", template = "GameFontHighlight", delta = 0 },
  { name = "PromptPeonSmall", template = "GameFontHighlightSmall", delta = -1 },
  { name = "PromptPeonHeader", template = "GameFontNormal", delta = 0 },
  { name = "PromptPeonHint", template = "GameFontDisable", delta = 0 },
  { name = "PromptPeonTitle", template = "GameFontNormalLarge", delta = 2 },
  { name = "PromptPeonHeading", template = "GameFontNormalLarge", delta = 1 },
  -- WoW has no monospace font, so this one ships with the addon. See IBMPlexMono-LICENSE.txt.
  { name = "PromptPeonCode", template = "GameFontHighlight", delta = -1,
    path = "Interface\\AddOns\\PromptPeon\\IBMPlexMono-Regular.ttf", fallback = "Fonts\\ARIALN.TTF" },
}

function UI:ApplyFonts()
  local size = ns.db.fontSize
  for _, spec in ipairs(FONTS) do
    local font = _G[spec.name] or CreateFont(spec.name)
    local template = _G[spec.template]
    font:CopyFontObject(template)
    local path, _, flags = template:GetFont()
    font:SetFont(spec.path or path, size + spec.delta, flags)
    -- A font that fails to load draws nothing at all, so never leave text without one. A Font object's
    -- SetFont returns nothing on this client, so the only way to know is to measure what it draws.
    if spec.fallback then
      UI.fontProbe = UI.fontProbe or UIParent:CreateFontString(nil, "OVERLAY")
      UI.fontProbe:SetFontObject(font)
      UI.fontProbe:SetText("m")
      if (UI.fontProbe:GetStringWidth() or 0) <= 0 then
        font:SetFont(spec.fallback, size + spec.delta, flags)
      end
      UI.fontProbe:SetText("")
    end
  end
end

--- Text sizes follow one number. Fonts update everything drawn with them.
function UI:SetFontSize(size)
  ns.db.fontSize = math.max(8, math.min(20, size))
  self:ApplyFonts()
  self:Render()
end

function UI.ListWidth()
  return ns.db.listWidth or LIST_WIDTH
end

--- The list can't squeeze the open thread below its smallest width.
function UI:SetListWidth(width)
  local most = math.max(self.frame:GetWidth() - PAD - 16 - DETAIL_MIN_WIDTH, LIST_MIN_WIDTH)
  width = math.floor(math.max(LIST_MIN_WIDTH, math.min(width, most)))
  if width == UI.ListWidth() then return end
  ns.db.listWidth = width
  self:ApplyLayout()
  for _, row in ipairs(self.rows) do row:SetWidth(width) end
end

--- Fit what is inside the window to its size. Runs while you drag it.
function UI:FitToSize()
  local width, height = self.frame:GetSize()
  local hidden = ns.db.listHidden
  local left = hidden and (PAD + 4) or (UI.ListWidth() + PAD + 16)
  local short = height < SHORT_HEIGHT
  local replyHeight = short and 40 or 64
  self.holder:SetHeight(replyHeight)
  -- Above the reply box: what the agent is doing. Model and effort sit beside Send.
  local lift = self.spellLift or 0
  local row = 44 + replyHeight + lift
  local tiny = width < TINY_WIDTH
  self.effortChip:SetWidth(tiny and 60 or 84)
  self.modelChip:SetWidth(tiny and 88 or 124)
  self.effortChip:ClearAllPoints()
  self.effortChip:SetPoint("RIGHT", self.send, "LEFT", -4, 0)
  self.activity:ClearAllPoints()
  self.activity:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", left, row)
  self.activity:SetPoint("RIGHT", self.frame, "RIGHT", -PAD - 6, 0)
  self.detailScroll:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -PAD - 22, 62 + replyHeight + lift)
  self.send:SetWidth(tiny and 60 or 90)

  self:PlaceHeaderButtons()
  self:PlaceFooter()

  self:RenderReloadHint()
  if ns.Game then ns.Game:RenderSpellBar() end
  self:PlaceNotice()
end

--- Along the bottom, from the right: Send, effort, model, then the reload hint.
function UI:PlaceFooter()
  local nearest = self.modelChip:IsShown() and self.modelChip or self.send
  for _, thing in ipairs({ self.reloadHint, self.reload }) do
    thing:ClearAllPoints()
    thing:SetPoint("RIGHT", nearest, "LEFT", -6, 0)
  end
end

--- Everything above the bottom row moves up when the spell bar needs its own row.
function UI:LiftForSpells(lift)
  if lift == (self.spellLift or 0) then return end
  self.spellLift = lift
  self:ApplyLayout()
end

--- How your last send went: in the footer, in whatever room the spells leave.
function UI:PlaceNotice()
  local spells = ns.Game and ns.Game.spellBar
  self.notice:ClearAllPoints()
  self.notice:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 20 + ((spells and (self.spellLift or 0) == 0) and spells:GetWidth() or 0), 16)
  local right = self.reload:IsShown() and self.reload or self.reloadHint:IsShown() and self.reloadHint
    or self.modelChip:IsShown() and self.modelChip or self.send
  self.notice:SetPoint("RIGHT", right, "LEFT", -8, 0)
end

--- Show or hide the thread list. The open thread takes the room.
function UI:ToggleList()
  ns.db.listHidden = not ns.db.listHidden or nil
  self:ApplyLayout()
  self:Render()
  -- Text is measured against the pane's width, which only settles on the next frame.
  C_Timer.After(0, function() UI:Render() end)
end

--- Where the list, title and reply box go. Runs when the list is shown, hidden or resized.
function UI:ApplyLayout()
  local hidden = ns.db.listHidden
  local listWidth = UI.ListWidth()
  local left = hidden and (PAD + 4) or (listWidth + PAD + 16)
  self.listScroll:SetShown(not hidden)
  self.listScroll:SetWidth(listWidth)
  self.listContent:SetWidth(listWidth)
  self.listEdge:SetShown(not hidden)
  self.title:ClearAllPoints()
  self.titleLeft = left
  self.title:SetPoint("RIGHT", self.frame, "RIGHT", -PAD - 6, 0)
  self:PlaceHeaderButtons()
  self.holder:ClearAllPoints()
  local lift = self.spellLift or 0
  self.holder:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", left - 2, 40 + lift)
  self.holder:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -PAD - 6, 40 + lift)
  self.listScroll:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PAD, 40 + lift)
  -- The list decides how small the window may get.
  local smallest = hidden and MIN_WIDTH_NO_LIST or (left + DETAIL_MIN_WIDTH)
  self.minWidth = smallest
  if self.frame:GetWidth() < smallest then
    self.frame:SetWidth(smallest)
    ns.db.width = smallest
  end
  self:FitToSize()
  self.listButton:SetText(hidden and ">" or "<")
end
