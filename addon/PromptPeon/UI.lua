-- UI: the log. Threads on the left, the open thread on the right, the reply box under it,
-- and a compact floating tracker for when it is closed.
--
-- Plain non-secure frames: nothing here touches the game world, so combat lockdown
-- does not apply to drawing. Rows are reused, so a refresh only rewrites text.
--
-- This file holds the shared dark-slate design tokens and flat UI primitives.

local _, ns = ...

local UI = {}
ns.UI = UI

UI.PAD = 10
UI.TINY_WIDTH = 420
UI.MIN_WIDTH_NO_LIST = 300 -- Small enough to park at the edge of the screen while you play.

-- Clean dark-slate palette: high-contrast typography, 1px hairline borders, restrained gold accent.
local THEME = {
  bg           = { 0.075, 0.092, 0.130, 0.96 },
  header       = { 0.055, 0.068, 0.098, 0.98 },
  sidebar      = { 0.060, 0.074, 0.106, 0.96 },
  footer       = { 0.055, 0.068, 0.098, 0.96 },
  panel        = { 0.105, 0.128, 0.178, 0.96 },
  panelHover   = { 0.145, 0.176, 0.242, 0.98 },
  panelActive  = { 0.165, 0.204, 0.282, 1.00 },
  input        = { 0.050, 0.062, 0.090, 0.95 },
  codeBg       = { 0.048, 0.060, 0.088, 0.88 },
  cardBg       = { 0.095, 0.116, 0.162, 0.88 },
  border       = { 0.195, 0.238, 0.325, 0.90 },
  borderStrong = { 0.310, 0.375, 0.500, 1.00 },
  borderAccent = { 0.920, 0.745, 0.365, 0.95 },
  divider      = { 0.170, 0.208, 0.286, 0.85 },
  rowHover     = { 0.165, 0.204, 0.282, 0.55 },
  rowSelected  = { 0.165, 0.210, 0.295, 0.92 },
  accent       = { 0.940, 0.765, 0.380 },
  text         = { 0.935, 0.930, 0.905 },
  textDim      = { 0.690, 0.715, 0.765 },
  textMuted    = { 0.485, 0.520, 0.585 },
  danger       = { 0.920, 0.370, 0.350 },
}
UI.THEME = THEME

local STATUS = {
  needs   = { label = "Needs you", tag = "!",  r = 1.00, g = 0.67, b = 0.28 },
  error   = { label = "Error",     tag = "x",  r = 0.94, g = 0.38, b = 0.36 },
  running = { label = "Working",   tag = ">",  r = 0.42, g = 0.74, b = 1.00 },
  done    = { label = "Done",      tag = "ok", r = 0.44, g = 0.84, b = 0.56 },
  stopped = { label = "Stopped",   tag = "-",  r = 0.58, g = 0.61, b = 0.67 },
  idle    = { label = "Idle",      tag = "-",  r = 0.58, g = 0.61, b = 0.67 },
}

UI.STATUS = STATUS

local function colored(info, text)
  return string.format("|cff%02x%02x%02x%s|r", info.r * 255, info.g * 255, info.b * 255, text)
end

UI.Colored = colored

--- Attach a crisp 1px flat border and solid fill to any frame using pure color textures
--- (no external art or BackdropTemplate required, pixel-sharp on Classic, Retail and Forever).
function UI.SkinSurface(frame, bg, border, layer)
  local bgTex = frame._bg or frame:CreateTexture(nil, layer or "BACKGROUND")
  bgTex:SetAllPoints()
  if bg then bgTex:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1) end
  frame._bg = bgTex
  if not frame._edges then
    local edges = {}
    local function edge()
      local tex = frame:CreateTexture(nil, "BORDER")
      return tex
    end
    edges.top, edges.bottom, edges.left, edges.right = edge(), edge(), edge(), edge()
    edges.top:SetPoint("TOPLEFT")
    edges.top:SetPoint("TOPRIGHT")
    edges.top:SetHeight(1)
    edges.bottom:SetPoint("BOTTOMLEFT")
    edges.bottom:SetPoint("BOTTOMRIGHT")
    edges.bottom:SetHeight(1)
    edges.left:SetPoint("TOPLEFT")
    edges.left:SetPoint("BOTTOMLEFT")
    edges.left:SetWidth(1)
    edges.right:SetPoint("TOPRIGHT")
    edges.right:SetPoint("BOTTOMRIGHT")
    edges.right:SetWidth(1)
    frame._edges = edges
  end
  if border then UI.SetBorderColor(frame, border[1], border[2], border[3], border[4] or 1) end
  return bgTex
end

function UI.SetBorderColor(frame, r, g, b, a)
  if not frame or not frame._edges then return end
  for _, tex in pairs(frame._edges) do tex:SetColorTexture(r, g, b, a or 1) end
end

function UI.SetFillColor(frame, r, g, b, a)
  if frame and frame._bg then frame._bg:SetColorTexture(r, g, b, a or 1) end
end

--- Create a clean flat button with 1px hairline border and subtle hover feedback.
function UI.FlatButton(parent, width, height, label, accent)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(width, height)
  local baseBg = accent and { 0.24, 0.20, 0.11, 0.96 } or THEME.panel
  local hoverBg = accent and { 0.32, 0.26, 0.14, 1.00 } or THEME.panelHover
  local baseBorder = accent and THEME.borderAccent or THEME.border
  local hoverBorder = accent and THEME.borderAccent or THEME.borderStrong
  UI.SkinSurface(button, baseBg, baseBorder)
  local text = button:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  text:SetPoint("LEFT", 4, 0)
  text:SetPoint("RIGHT", -4, 0)
  text:SetJustifyH("CENTER")
  text:SetWordWrap(false)
  if accent then
    text:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
  else
    text:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
  end
  button.labelText = text
  -- Keep standard Button SetText/GetText semantics while drawing through our crisp FontString.
  button.SetText = function(self, value)
    self.text = value
    text:SetText(value or "")
  end
  button.GetText = function(self) return self.text or text:GetText() end
  if label then button:SetText(label) end
  button:SetScript("OnEnter", function(self)
    UI.SetFillColor(self, hoverBg[1], hoverBg[2], hoverBg[3], hoverBg[4])
    UI.SetBorderColor(self, hoverBorder[1], hoverBorder[2], hoverBorder[3], hoverBorder[4])
    if self._onEnter then self._onEnter(self) end
  end)
  button:SetScript("OnLeave", function(self)
    UI.SetFillColor(self, baseBg[1], baseBg[2], baseBg[3], baseBg[4])
    UI.SetBorderColor(self, baseBorder[1], baseBorder[2], baseBorder[3], baseBorder[4])
    if self._onLeave then self._onLeave(self) end
  end)
  return button
end

--- Attach a crisp geometric chevron/fold indicator (drawn with plain text, no dated plus/minus art).
function UI.AddFold(owner, size, point, x, y)
  local fold = owner:CreateFontString(nil, "OVERLAY", "PromptPeonSmall")
  fold:SetSize(size, size)
  fold:SetPoint(point, owner, point, x, y)
  fold:SetJustifyH("CENTER")
  fold:SetJustifyV("MIDDLE")
  fold:SetTextColor(THEME.textMuted[1], THEME.textMuted[2], THEME.textMuted[3])
  fold:Hide()
  owner.fold = fold
end

--- True shows an open indicator, false a closed indicator, and nil hides it.
function UI.ShowFold(owner, open)
  if open == nil then
    owner.fold:Hide()
    return
  end
  owner.fold:SetText(open and "v" or ">")
  owner.fold:Show()
end

--- Scroll bars only when there is something to scroll, styled cleanly when the client exposes them.
function UI.HideScrollBarWhenIdle(scroll)
  scroll.scrollBarHideable = true
  if ScrollFrame_OnScrollRangeChanged then ScrollFrame_OnScrollRangeChanged(scroll) end
  local bar = scroll.ScrollBar or (scroll.GetName and scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"])
  if type(bar) ~= "table" then return end
  if not bar._flatTrack then
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOP", 0, -14)
    track:SetPoint("BOTTOM", 0, 14)
    track:SetWidth(4)
    track:SetColorTexture(THEME.divider[1], THEME.divider[2], THEME.divider[3], 0.45)
    bar._flatTrack = track
  end
  local thumb = bar.ThumbTexture or (bar.GetThumbTexture and bar:GetThumbTexture())
  if type(thumb) == "table" and thumb.SetColorTexture then
    thumb:SetColorTexture(THEME.borderStrong[1], THEME.borderStrong[2], THEME.borderStrong[3], 0.75)
    thumb:SetSize(6, 28)
  end
end

--- Dynamic line height scaled cleanly with the user's chosen font size.
function UI.FontSize()
  return (ns.db and tonumber(ns.db.fontSize)) or 11
end

function UI.RowHeight()
  return math.max(22, math.floor(UI.FontSize() * 1.85 + 2))
end

function UI.HeadHeight()
  return math.max(18, math.floor(UI.FontSize() * 1.55 + 2))
end

function UI.Plural(count, word)
  return count .. " " .. word .. (count == 1 and "" or "s")
end

--- How a step of work looks, by state: running, failed, cancelled, done.
UI.STEP_MARK = {
  r = { mark = "...", r = 0.42, g = 0.74, b = 1.00 },
  f = { mark = "x",   r = 0.94, g = 0.38, b = 0.36 },
  c = { mark = "-",   r = 0.48, g = 0.52, b = 0.58 },
  d = { mark = "-",   r = 0.58, g = 0.62, b = 0.68 },
}

function UI.DiffCounts(added, removed)
  return "|cff73d68e+" .. added .. "|r  |cfff07a74-" .. removed .. "|r"
end
