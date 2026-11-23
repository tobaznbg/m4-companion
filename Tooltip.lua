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
    local cmp = ns.Item.RefCompare(item.now, item)
    local unsure = ns.Item.Unsure(item)
    tooltip:AddDoubleLine(C .. "AH jetzt", ns.FormatMoney(item.now) .. (cmp and ("  (" .. cmp .. ")") or "")
      .. (unsure and "  unsicher" or ""), 1, 1, 1, 1, unsure and 0.71 or 1, unsure and 0.28 or 1)
  else
    tooltip:AddLine(C .. "nicht im AH", 0.7, 0.7, 0.7)
  end
  -- The three medians of the hourly cheapest offers (German calendar days, ns.Item).
  local medians = on("range") and ns.Item.MedianText(item, true)
  if medians then
    tooltip:AddDoubleLine(C .. "Marktwert", (medians:gsub("^Marktwert ", "")), 0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- What guild members really sold it for (their ledgers, without names; ns.Item).
  local sold = on("guildSales") and ns.Item.GuildSaleText(item, true)
  if sold then
    tooltip:AddDoubleLine(C .. "Gilde verkauft", sold, 0.7, 0.7, 0.7, 1, 1, 1)
  end
  local trend = on("trend") and ns.Item.TrendText(item)
  if trend then
    local up, down = item.direction == 1, item.direction == -1
    tooltip:AddDoubleLine(C .. "Trend", trend, 0.7, 0.7, 0.7, up and 0.37 or (down and 1 or 0.8),
      up and 0.83 or (down and 0.42 or 0.8), up and 0.55 or (down and 0.42 or 0.8))
  end
  local demand = on("demand") and ns.Item.DemandText(item)
  if demand then
    if item.certain and item.certain >= 1 then
      local n = math.floor(item.certain + 0.5)
      demand = demand .. "  (mind. " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)) .. " / Tag)"
    end
    tooltip:AddDoubleLine(C .. "Nachfrage", demand, 0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- Crafting: cost to make it, profit against selling it, and where the recipe comes from.
  local craft = on("crafting") and crafting(itemID)
  if craft then
    local profit = ns.Item.SellNet(item) - craft.cost
    tooltip:AddLine(" ")
    tooltip:AddLine(C .. "Crafting", 1, 1, 1)
    tooltip:AddDoubleLine("    Herstellkosten", ns.FormatMoney(math.floor(craft.cost + 0.5)), 0.7, 0.7, 0.7, 1, 1, 1)
    tooltip:AddDoubleLine("    Gewinn", (profit >= 0 and "|cff5fd38d" or "|cffff6b6b-")
      .. ns.FormatMoney(math.floor(math.abs(profit) + 0.5)) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
    tooltip:AddDoubleLine("    Rezept", craft.prof .. " · " .. craft.source, 0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- Recipe items: what the recipe teaches and what making its product brings (Crafting.lua).
  local teach = on("recipe") and ns.RecipeTeachInfo and ns.RecipeTeachInfo(itemID)
  if teach then
    local t = teach.teaches
    local function m(c) return ns.FormatMoney(math.floor(c + 0.5), true) end
    local what = t.product and ((ns.ItemName(t.product) or ("#" .. t.product))
      .. (t.qty > 1 and string.format(" x%g", t.qty) or "")) or (t.name or "?")
    local need = ns.ProfessionShort(t.profession) .. (t.skill and (" " .. t.skill) or "")
    tooltip:AddLine(" ")
    tooltip:AddLine(C .. "Rezept lehrt: " .. what .. " (" .. need .. ") · " .. ns.RecipeOwnText(teach), 1, 1, 1)
    local cost = teach.cost and m(teach.cost)
      or ("|cffffb547?|r" .. (teach.missing and (" (kein Preis: " .. (ns.ItemName(teach.missing) or "?") .. ")") or ""))
    local parts
    if t.product then
      parts = { "Herstellung " .. cost, "bringt " .. m(teach.value) .. (teach.onAH and "" or " (Händler)") }
      if teach.profit then
        table.insert(parts, "Gewinn " .. (teach.profit >= 0 and "|cff5fd38d+" or "|cffff6b6b-") .. m(math.abs(teach.profit)) .. "|r")
      end
      local demand = ns.Item.DemandText(teach.product)
      if demand then table.insert(parts, "Nachfrage " .. demand) end
    else
      parts = { "Material " .. cost, "Verzauberung (kein Item)" }
    end
    tooltip:AddLine(C .. "  " .. table.concat(parts, " · "), 0.8, 0.8, 0.8)
  end
  -- Gap between the auction house block and recommendation / merchant price.
  if on("advice") or on("vendor") then tooltip:AddLine(" ") end
  -- Decision as in the Bestand tab; bag entry if the item is carried (bound state).
  if ns.Inventory and on("advice") then
    local inv = ns.db.inventory and ns.db.inventory[ns.CharKey()]
    local entry = inv and ((inv.bags and inv.bags[itemID]) or (inv.bank and inv.bank[itemID]))
    if not entry then
      local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
      entry = { n = 1, q = getInfo and select(3, getInfo(itemID)) or 1 }
    end
    local action, reason = ns.Inventory.Advise(itemID, entry)
    local colors = { AH = { 0.37, 0.83, 0.55 }, ["Händler"] = { 0.85, 0.79, 0.64 }, behalten = { 0.6, 0.6, 0.6 } }
    local c = colors[action] or colors.behalten
    tooltip:AddDoubleLine(C .. "Empfehlung", action, 1, 1, 1, c[1], c[2], c[3])
  end
  if on("vendor") then
    tooltip:AddDoubleLine(C .. "Händler zahlt", item.vendorSell and ns.FormatMoney(item.vendorSell) or "nichts",
      1, 1, 1, 1, 1, 1)
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
