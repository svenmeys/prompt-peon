-- Minimap: a button on the edge of the minimap that opens the log, like most addons have.
-- Drag it round the edge. Options can hide it.

local _, ns = ...
local UI = ns.UI

local START_ANGLE = 205 -- Lower left, clear of the clock and the tracking button.

--- Where the button's centre goes for an angle, counted from the minimap's centre. A square
--- minimap, which some map addons make, gets the corners too.
function UI.MinimapSpot(angle, width, height, round)
  local x, y = math.cos(math.rad(angle)), math.sin(math.rad(angle))
  local reachX, reachY = width / 2 + 5, height / 2 + 5
  if not round then
    local longest = math.max(math.abs(x), math.abs(y))
    if longest > 0 then x, y = x / longest, y / longest end
    reachX, reachY = reachX - 2, reachY - 2
  end
  return x * reachX, y * reachY
end

function UI:PlaceMinimapButton()
  local round = not GetMinimapShape or GetMinimapShape() == "ROUND"
  local x, y = UI.MinimapSpot(ns.db.minimapAngle or START_ANGLE, Minimap:GetWidth(), Minimap:GetHeight(), round)
  self.minimapButton:ClearAllPoints()
  self.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

--- The angle from the minimap's centre to the mouse, for dragging the button round. A minimap that
--- another addon has hidden has no centre, and then the button stays where it is.
local function cursorAngle()
  local centreX, centreY = Minimap:GetCenter()
  if not centreX then return ns.db.minimapAngle or START_ANGLE end
  local scale = Minimap:GetEffectiveScale()
  local x, y = GetCursorPosition()
  return math.deg(math.atan2(y / scale - centreY, x / scale - centreX)) % 360
end

--- The same art and sizes the game's own minimap buttons use.
function UI:BuildMinimapButton()
  local button = CreateFrame("Button", "PromptPeonMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local back = button:CreateTexture(nil, "BACKGROUND")
  back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  back:SetSize(20, 20)
  back:SetPoint("TOPLEFT", 7, -5)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetTexture("Interface\\QuestFrame\\UI-QuestLog-BookIcon")
  button.icon:SetSize(18, 18)
  button.icon:SetPoint("TOPLEFT", 7, -6)
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  -- How many threads are waiting on you, like the count on a bag slot.
  button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  button.count:SetPoint("BOTTOMRIGHT", -4, 5)
  button:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      if not UI.showOptions then UI:ToggleOptions() elseif not UI:IsOpen() then UI:Toggle() end
    else
      UI:Toggle()
    end
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      ns.db.minimapAngle = cursorAngle()
      UI:PlaceMinimapButton()
    end)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    local counts = ns:Counts()
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Prompt Peon")
    if counts.needs > 0 then GameTooltip:AddLine(counts.needs .. " waiting on you", 1.00, 0.66, 0.26) end
    if counts.running > 0 then GameTooltip:AddLine(counts.running .. " working", 0.40, 0.70, 1.00) end
    if counts.needs + counts.running == 0 then GameTooltip:AddLine("Nothing running.", 1, 1, 1) end
    GameTooltip:AddLine("Click to open the log. Right-click for Options. Drag to move.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.minimapButton = button
  self:PlaceMinimapButton()
  self:RenderMinimapButton()
end

function UI:RenderMinimapButton()
  local button = self.minimapButton
  if not button then return end
  button:SetShown(not ns.db.minimapOff)
  local waiting = ns:Counts().needs
  button.count:SetText(waiting > 0 and waiting or "")
end
