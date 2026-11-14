-- UI: the log. Threads on the left under project headers, the open thread
-- on the right, the reply box under it, and a small tracker for when it is closed.
--
-- Plain non-secure frames: nothing here touches the game world, so combat lockdown
-- does not apply to drawing. Rows are reused, so a refresh only rewrites text.
--
-- This file holds only what several UI files share. Each of them starts from ns.UI.

local _, ns = ...

local UI = {}
ns.UI = UI

UI.PAD = 10
UI.TINY_WIDTH = 420
UI.MIN_WIDTH_NO_LIST = 300 -- Small enough to park at the edge of the screen while you play.

local STATUS = {
  needs = { label = "Needs you", tag = "!", r = 1.00, g = 0.66, b = 0.26 },
  error = { label = "Error", tag = "x", r = 0.90, g = 0.36, b = 0.30 },
  running = { label = "Working", tag = ">", r = 0.40, g = 0.70, b = 1.00 },
  done = { label = "Done", tag = "ok", r = 0.45, g = 0.80, b = 0.45 },
  stopped = { label = "Stopped", tag = "-", r = 0.65, g = 0.62, b = 0.55 },
  idle = { label = "Idle", tag = "-", r = 0.65, g = 0.62, b = 0.55 },
}

UI.STATUS = STATUS

local function colored(info, text)
  return string.format("|cff%02x%02x%02x%s|r", info.r * 255, info.g * 255, info.b * 255, text)
end

UI.Colored = colored

-- WoW's own collapse buttons, the ones in the crafting window.
local FOLD_OPEN = "Interface\\Buttons\\UI-MinusButton-Up"
local FOLD_CLOSED = "Interface\\Buttons\\UI-PlusButton-Up"

function UI.AddFold(owner, size, point, x, y)
  local fold = owner:CreateTexture(nil, "OVERLAY")
  fold:SetSize(size, size)
  fold:SetPoint(point, owner, point, x, y)
  fold:Hide()
  owner.fold = fold
end

--- True shows a minus, false a plus, and nil nothing, for a line with nothing to open.
function UI.ShowFold(owner, open)
  if open == nil then
    owner.fold:Hide()
    return
  end
  owner.fold:SetTexture(open and FOLD_OPEN or FOLD_CLOSED)
  owner.fold:Show()
end

--- Scroll bars only when there is something to scroll.
function UI.HideScrollBarWhenIdle(scroll)
  scroll.scrollBarHideable = true
  if ScrollFrame_OnScrollRangeChanged then ScrollFrame_OnScrollRangeChanged(scroll) end
end

function UI.Plural(count, word)
  return count .. " " .. word .. (count == 1 and "" or "s")
end

--- How a step of work looks, by state: running, failed, cancelled, done.
UI.STEP_MARK = {
  r = { mark = "...", r = 0.40, g = 0.70, b = 1.00 },
  f = { mark = "x", r = 0.90, g = 0.36, b = 0.30 },
  c = { mark = "-", r = 0.50, g = 0.48, b = 0.44 },
  d = { mark = "-", r = 0.62, g = 0.60, b = 0.54 },
}

function UI.DiffCounts(added, removed)
  return "|cff7fd18a+" .. added .. "|r  |cffe07a6e-" .. removed .. "|r"
end
