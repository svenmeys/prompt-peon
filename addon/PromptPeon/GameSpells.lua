-- Spells: prompts worth having one click away, on a bar along the bottom of the log.

local _, ns = ...
local Game = ns.Game

-- Spells are prompts worth having one click away. They go through the same send as a typed reply,
-- so a busy agent gets them next, and nothing here decides anything for the agent.
Game.SPELLS = {
  { id = "sunder", name = "Sunder the Build", icon = "Ability_Warrior_Sunder", onlyWhenRed = true,
    prompt = "CI is failing on this thread's pull request. Read the real logs, find the actual cause and fix it. Commit it locally and tell me when it's ready. Don't push, and don't skip or disable any checks." },
  { id = "sight", name = "Far Sight", icon = "Spell_Nature_FarSight",
    prompt = "Where are we? In plain words: what's finished, what's left, and what you're unsure about. Don't change anything for this." },
  { id = "dispel", name = "Dispel Magic", icon = "Spell_Holy_DispelMagic",
    prompt = "You may be going in circles. Stop. Say the real problem in one sentence and what you've already tried, then try something different." },
  { id = "light", name = "Holy Light", icon = "Spell_Holy_HolyBolt",
    prompt = "Prove it works. Run the project's real checks for what you changed, show the actual output, and fix what fails." },
  { id = "detect", name = "Detect Magic", icon = "Spell_Holy_Dizzy",
    prompt = "Review your own changes like a skeptical reviewer. List real bugs with file and line, and skip style. Fix the ones you're sure about and tell me the rest." },
  { id = "polymorph", name = "Polymorph", icon = "Spell_Nature_Polymorph",
    prompt = "Look at what you added. Remove anything the goal doesn't need and simplify what's left, without changing behavior." },
  { id = "hammer", name = "Hammer of Justice", icon = "Spell_Holy_SealOfMight",
    prompt = "Stop after the current step. Make no more changes. Tell me where things stand and what you need from me." },
  { id = "intellect", name = "Arcane Intellect", icon = "Spell_Holy_MagicalSentry",
    prompt = "Write a short handoff: the goal, where things stand, decisions made and why, the next step, and anything that would surprise someone picking this up." },
  { id = "evocation", name = "Evocation", icon = "Spell_Nature_Purge",
    prompt = "/compact" },
  { id = "execute", name = "Execute", icon = "INV_Sword_48",
    prompt = "Finish this off. Get it to a working state, commit it locally with a clear message, and tell me what's left. Don't push." },
}

local GLOBAL_COOLDOWN = 1.5
local SPELL_COOLDOWN = 30

--- The same words the game uses, for the same reasons.
local function refuse(words)
  if UIErrorsFrame then UIErrorsFrame:AddMessage(words, 1.0, 0.1, 0.1) end
  return false
end

StaticPopupDialogs["PROMPTPEON_CAST"] = {
  text = "%s\n\n%s",
  button1 = "Cast",
  button2 = "Not now",
  OnAccept = function(_, data)
    local thread = ns:ThreadById(data.thread)
    if thread then Game:CastNow(data.spell, thread) end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function Game:SpellReady(spell, thread)
  if not thread then return refuse("You have no target.") end
  if thread.s == "error" then return refuse("Your target is dead.") end
  local now = GetTime()
  self.casts = self.casts or {}
  local key = thread.id .. ":" .. spell.id
  if (self.lastCast and now - self.lastCast < GLOBAL_COOLDOWN) or (self.casts[key] and now - self.casts[key] < SPELL_COOLDOWN) then
    return refuse("Spell is not ready yet.")
  end
  return true
end

--- A spell is a real order to a real agent, so it shows you the words first. Options can turn this off.
function Game:Cast(spell, thread)
  if not self:SpellReady(spell, thread) then return false end
  if ns.db.spellsNoAsk then return self:CastNow(spell, thread) end
  StaticPopup_Show("PROMPTPEON_CAST", spell.name .. " at " .. ns.Plain(thread.t) .. "?", spell.prompt, { spell = spell, thread = thread.id })
  return true
end

function Game:CastNow(spell, thread)
  if not self:SpellReady(spell, thread) then return false end
  local now = GetTime()
  local key = thread.id .. ":" .. spell.id
  local ok, reason = ns:QueueReply(thread.id, spell.prompt)
  if not ok then return refuse(reason) end
  self.lastCast, self.casts[key] = now, now
  ns:Deliver()
  self:Earn("spell")
  if ns.UI then ns.UI:Render() end
  return true
end

-- Sized so the buttons land in the slots of the game's action bar art, at two thirds of its size.
local SPELL_SIZE = 24
local SPELL_STEP = 28
local SPELL_EDGE = 5
local SPELL_BAR_HEIGHT = 29
local SPELL_PIECE_WIDTH = 171

function Game:BuildSpellBar()
  local UI = ns.UI
  local bar = CreateFrame("Frame", nil, UI.frame)
  bar:SetSize(1, SPELL_BAR_HEIGHT)
  -- The game's own action bar. Each piece holds six slots, cut off at however many we use.
  bar.stone = {}
  for piece, top in ipairs({ 0.83203125, 0.58203125 }) do
    local stone = bar:CreateTexture(nil, "BACKGROUND")
    stone:SetTexture("Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf")
    stone:SetHeight(SPELL_BAR_HEIGHT)
    stone:SetPoint("TOPLEFT", bar, "TOPLEFT", (piece - 1) * SPELL_PIECE_WIDTH, 0)
    stone.top = top
    bar.stone[piece] = stone
  end
  bar.buttons = {}
  for index, spell in ipairs(Game.SPELLS) do
    local button = CreateFrame("Button", nil, bar)
    button:SetSize(SPELL_SIZE, SPELL_SIZE)
    button.spell = spell
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexture("Interface\\Icons\\" .. spell.icon)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- Without the icon's own rough edge.
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:SetScript("OnClick", function(self) Game:Cast(self.spell, ns:ThreadById(ns.db.selected)) end)
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.spell.name, 1, 0.82, 0)
      GameTooltip:AddLine("Instant cast. Sends the open thread:", 0.6, 0.6, 0.6)
      GameTooltip:AddLine(self.spell.prompt, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.buttons[index] = button
  end
  self.spellBar = bar
end

--- Along the bottom, as many as the window has room for.
function Game:RenderSpellBar()
  local UI = ns.UI
  if not UI.frame or not UI.reload then return end
  if not self.spellBar then self:BuildSpellBar() end
  local thread = ns:ThreadById(ns.db.selected)
  local width = UI.frame:GetWidth()
  local room = width - 12 - UI.send:GetWidth() - 22
  if UI.reload:IsShown() or UI.reloadHint:IsShown() then room = room - 82 end
  if UI.modelChip:IsShown() then room = room - UI.modelChip:GetWidth() - 6 end
  if UI.effortChip:IsShown() then room = room - UI.effortChip:GetWidth() - 3 end
  local red = false -- Sunder only makes sense while CI is failing on an open pull request.
  for _, pr in ipairs(thread and thread.prs or {}) do
    if pr.st == "open" and pr.ck == "failing" then red = true end
  end
  local wanted = 0
  for _, button in ipairs(self.spellBar.buttons) do
    if not button.spell.onlyWhenRed or red then wanted = wanted + 1 end
  end
  -- Too narrow to share the bottom row, so the bar gets a row of its own above the buttons.
  local stacked = SPELL_EDGE + wanted * SPELL_STEP > room
  UI:LiftForSpells(stacked and SPELL_BAR_HEIGHT + 1 or 0)
  if stacked then room = UI.frame:GetWidth() - 24 end
  self.spellBar:ClearAllPoints()
  self.spellBar:SetPoint("BOTTOMLEFT", UI.frame, "BOTTOMLEFT", 10, stacked and 36 or 6)
  local x, now = SPELL_EDGE, GetTime()
  for _, button in ipairs(self.spellBar.buttons) do
    local shown = (not button.spell.onlyWhenRed or red) and x + SPELL_SIZE <= room
    button:SetShown(shown or false)
    if shown then
      button:ClearAllPoints()
      button:SetPoint("LEFT", self.spellBar, "LEFT", x, 0)
      x = x + SPELL_STEP
      local cast = thread and self.casts and self.casts[thread.id .. ":" .. button.spell.id]
      button.icon:SetDesaturated(not thread or thread.s == "error" or (cast and now - cast < SPELL_COOLDOWN) or false)
    end
  end
  self.spellBar:SetWidth(math.max(x, 1))
  for piece, stone in ipairs(self.spellBar.stone) do
    local shows = math.min(x - (piece - 1) * SPELL_PIECE_WIDTH, SPELL_PIECE_WIDTH)
    stone:SetShown(shows > 0)
    if shows > 0 then
      stone:SetWidth(shows)
      stone:SetTexCoord(0, shows / SPELL_PIECE_WIDTH, stone.top, stone.top + 0.16796875)
    end
  end
end
