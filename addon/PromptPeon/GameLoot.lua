-- Loot: a finished change drops loot, sized by how much it changed.

local _, ns = ...
local Game = ns.Game

local LOOT_TIERS = {
  { below = 10, word = "Tattered", color = "9d9d9d" },
  { below = 50, word = "Plain", color = "ffffff" },
  { below = 200, word = "Sturdy", color = "1eff00" },
  { below = 1000, word = "Fine", color = "0070dd" },
  { below = 5000, word = "Epic", color = "a335ee" },
  { below = math.huge, word = "Legendary", color = "ff8000" },
}

--- What a change is worth. `change` is files, lines added, lines removed.
function Game.LootFor(change)
  local added, removed = change[2], change[3]
  local size = added + removed
  for tier, entry in ipairs(LOOT_TIERS) do
    if size < entry.below then
      local suffix = "of Refactoring"
      if removed > added * 2 then
        suffix = "of Deletion"
      elseif added > removed * 4 then
        suffix = "of Creation"
      end
      return { name = entry.word .. " Patch " .. suffix, color = entry.color, tier = tier }
    end
  end
end

function Game:CheckLoot(snapshot)
  local looted = ns.db.looted
  for _, thread in ipairs(snapshot.threads) do
    local change = thread.lc
    if change then
      -- The first look only sets the starting line. Old work isn't new loot.
      if looted[thread.id] == nil then
        looted[thread.id] = self.seeded and 0 or change[4]
      end
      if change[4] > looted[thread.id] and thread.s ~= "running" and not ns:IsHidden(thread) then
        looted[thread.id] = change[4]
        self:DropLoot(thread, change)
      end
    end
  end
end

function Game:DropLoot(thread, change)
  local loot = Game.LootFor(change)
  local link = "|cff" .. loot.color .. "|Haddon:peon:changes:" .. thread.id .. "|h[" .. loot.name .. "]|h|r"
  local details = string.format("+%d -%d in %d %s", change[2], change[3], change[1], change[1] == 1 and "file" or "files")
  if ns.Chat then
    local legendary = loot.tier == #LOOT_TIERS
    ns.Chat:News(legendary and ("Did someone say " .. link .. "? " .. ns.Plain(thread.t) .. " just found it (" .. details .. ")")
      or (ns.Plain(thread.t) .. " found loot: " .. link .. " (" .. details .. ")"))
  end
  if ns.db.away then table.insert(ns.db.away.loot, link .. " " .. details) end
  if PlaySound and SOUNDKIT then
    local sound = loot.tier >= 5 and SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.LOOT_WINDOW_COIN_SOUND
    if sound then PlaySound(sound) end
  end
  if loot.tier >= 5 then self:Banner(ns.Plain(thread.t) .. " looted [" .. loot.name .. "]!") end
  if loot.tier == 6 then self:Earn("legendary") end
end

function Game:Banner(words)
  if RaidNotice_AddMessage and RaidBossEmoteFrame and ChatTypeInfo then
    RaidNotice_AddMessage(RaidBossEmoteFrame, words, ChatTypeInfo["RAID_BOSS_EMOTE"] or { r = 1, g = 0.82, b = 0 })
  end
end
