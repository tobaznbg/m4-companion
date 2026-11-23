-- Tooltip: the item's market data (ns.Item) and the recommendation, everywhere.
local ADDON, ns = ...

-- Crafting section ------------------------------------------------------------------
-- Every recipe that makes an item, from all professions (Data_Recipes.lua), built once.
local byItem
local function recipesFor(itemID)
  if not byItem then
    byItem = {}
    for pid, data in pairs(ns.RecipeData or {}) do
      for _, rec in pairs(data.recipes) do
        if rec[2] then
          byItem[rec[2]] = byItem[rec[2]] or {}
          table.insert(byItem[rec[2]], { pid = pid, prof = data.name, rec = rec })
        end
      end
    end
  end
  return byItem[itemID]
end

-- The character's scan of a profession: learned state and spell id per crafted item.
local function scanned(pid, itemID)
  local prefix = ns.CharKey() .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID == pid then
      local found
      for spellID, r in pairs(scan.recipes or {}) do
        if r.out == itemID and (not found or r.learned) then found = { id = spellID, learned = r.learned } end
      end
      return found, scan
    end
  end
end

local SOURCES = { ["6"] = "Lehrer", ["5"] = "Händler", ["2"] = "Drop", ["4"] = "Quest" }

-- "gelernt", "Lehrer ab 165 (24s)", "Drop ab 300" or "Quelle unbekannt".
local function source(pid, itemID)
  -- the household's knowledge and the recipe sources, as in "Alle Produkte" (Crafting.lua)
  if ns.RecipeLearnShort then return ns.RecipeLearnShort(pid, itemID) or "Quelle unbekannt" end
  local found = scanned(pid, itemID)
  if found and found.learned then return "|cff5fd38dgelernt|r" end
  local data = ns.DataBySkillLine and ns.DataBySkillLine[pid]
  local d = found and data and data[found.id]
  if not d then return "Quelle unbekannt" end
  local parts = {}
  for code in tostring(d[7] or ""):gmatch("[^+]+") do table.insert(parts, SOURCES[code] or code) end
  local text = (#parts > 0 and table.concat(parts, "/") or "Quelle ?") .. " ab " .. tostring(d[5] or d[1] or "?")
  if d[6] and d[6] > 0 then text = text .. " (" .. ns.FormatMoney(d[6]) .. ")" end
  return text
end

-- Material cost per unit of one recipe (merchant, else cheapest offer), nil if a price is missing.
local function recipeCost(rec)
  local cost = ns.Item.MaterialCost(rec[4])
  return cost and cost / (rec[3] or 1)
end

-- Best recipe for the item: a learned one first, then the cheapest. Cached briefly
-- (tooltips are redrawn constantly). Returns { cost, prof, source } or nil.
local cache = {}
local function crafting(itemID)
  local c = cache[itemID]
  if c and GetTime() - c[2] < 30 then return c[1] or nil end
  local best
  for _, entry in ipairs(recipesFor(itemID) or {}) do
    local cost = recipeCost(entry.rec)
    local found = scanned(entry.pid, itemID)
    local learned = found and found.learned or false
    if cost and (not best or (learned and not best.learned) or (learned == best.learned and cost < best.cost)) then
      best = { cost = cost, prof = entry.prof, pid = entry.pid, learned = learned }
    end
  end
  if best then best.source = source(best.pid, itemID) end
  cache[itemID] = { best or false, GetTime() }
  return best
end

-- Best recipe for an item for other views (sniper detail): { cost (per unit), prof, source, learned } or nil.
ns.CraftInfo = crafting

local function addLines(tooltip, itemID)
  if not itemID or tooltip.cfDone == itemID then return end
  -- Reduced-UI (settings, main window): no M4 lines in item tooltips.
  if ns.db.settings and ns.db.settings.reducedUI then return end
  tooltip.cfDone = itemID
  local C = "|cff4fc2a1M4|r "
  local item = ns.Item(itemID)
  -- Lines can be switched off in the settings (ns.db.settings.tooltip, main window).
  local show = ns.db.settings and ns.db.settings.tooltip or {}
  local function on(key) return show[key] ~= false end
  if not on("price") then
    -- no price line
  elseif item.now then
    local unsure = ns.Item.Unsure(item)
    tooltip:AddDoubleLine(C .. "AH jetzt", ns.FormatMoney(item.now) .. (unsure and "  unsicher" or ""),
      1, 1, 1, 1, unsure and 0.71 or 1, unsure and 0.28 or 1)
  else
    tooltip:AddLine(C .. "nicht im AH", 0.7, 0.7, 0.7)
  end
  -- What guild members really sold it for (their ledgers, without names; ns.Item).
  local sold = on("guildSales") and ns.Item.GuildSaleText(item, true)
  if sold then
    tooltip:AddDoubleLine(C .. "Gilde verkauft", sold, 0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- Crafting: one line, the profit (or loss) of making it - for a recipe item of making what it
  -- teaches. Market value, trend, demand and the recipe's details: market data window.
  local profit
  local craft = on("crafting") and crafting(itemID)
  if craft then profit = ns.Item.SellNet(item) - craft.cost end
  local teach = not profit and on("recipe") and ns.RecipeTeachInfo and ns.RecipeTeachInfo(itemID)
  if teach and teach.teaches.product then profit = teach.profit or false end
  if profit ~= nil then
    local text = profit == false and "|cffffb547? (ein Preis fehlt)|r"
      or ((profit >= 0 and "|cff5fd38d+" or "|cffff6b6b-") .. ns.FormatMoney(math.floor(math.abs(profit) + 0.5)) .. "|r")
    tooltip:AddDoubleLine(C .. (teach and "Crafting (Produkt)" or "Crafting"), text, 0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- Where the full detail opens (ItemDetail.lua); switchable like the other lines.
  if on("hint") then tooltip:AddLine(C .. "Alt+Klick: Details", 0.55, 0.55, 0.55) end
  tooltip:Show()
end

-- The game tooltip (bags, AH, hovering a chat link) and the item link window a click on a
-- chat link opens (ItemRefTooltip). Both get the lines, on every client generation, and
-- both forget the shown item when cleared (else a second click on the same link stays bare).
local TOOLTIPS = { GameTooltip, ItemRefTooltip }
if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then
      ns.Safe(addLines, tooltip, data and data.id)
    end
  end)
end
for _, tt in ipairs(TOOLTIPS) do
  if tt and tt.HookScript then
    -- Older clients without the tooltip data processor, and as a fallback when it does not
    -- report the link window: the classic script (addLines runs once per shown item).
    if tt.HasScript == nil or tt:HasScript("OnTooltipSetItem") then
      tt:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        ns.Safe(addLines, tooltip, link and tonumber(link:match("item:(%d+)")))
      end)
    end
    tt:HookScript("OnTooltipCleared", function(tooltip) tooltip.cfDone = nil end)
  end
end
