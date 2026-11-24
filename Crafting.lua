-- Crafting: table (auction house tab and main window). First a choice of all crafting professions (with icon),
-- then every recipe of that profession that makes an item (Data_Recipes.lua, Blizzard
-- API), priced via ns.Item: buy = merchant, else cheapest offer; sell = cheapest offer
-- - 1 copper - 5 % cut, or a merchant if higher. Learned state and skill come from the
-- character's own profession scan (open the profession window once); unlearned recipes
-- get a red marker and, where the planner data knows it, how to learn them.
-- Also answers what a recipe item teaches (ns.RecipeTeaches / ns.RecipeTeachInfo) for the
-- tooltip and the item detail window.
-- Opening the tab starts a live scan (every 15 min at most, only with the AH open).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

-- Copper per unit to buy a reagent (merchant, else cheapest offer, else the average
-- when it is not on offer right now), and whether it comes from a merchant.
local function buy(itemID)
  return ns.Item.BuyCost(ns.Item(itemID))
end

-- Copper per unit the product brings (undercut, minus cut; or a merchant), and
-- whether via the auction house.
local function sell(itemID)
  return ns.Item.SellNet(ns.Item(itemID))
end

local SOURCES = { ["6"] = "Lehrer", ["5"] = "Händler", ["2"] = "Drop", ["4"] = "Quest" }

-- "Lehrer ab 165 (24s)", "Händler/Drop ab 140" etc., and the skill needed.
local function learnInfo(professionID, recipeID)
  local data = ns.DataBySkillLine and ns.DataBySkillLine[professionID]
  if not data then data = ns.SkillData and ns.SkillData[professionID] and ns.SkillData[professionID].recipes end
  local d = data and data[recipeID]
  if not d then return "unbekannt", nil end
  local parts = {}
  for code in tostring(d[7] or ""):gmatch("[^+]+") do table.insert(parts, SOURCES[code] or code) end
  local text = (#parts > 0 and table.concat(parts, "/") or "Quelle ?") .. " ab " .. (d[5] or d[1] or "?")
  if d[6] and d[6] > 0 then text = text .. " (" .. money(d[6]) .. ")" end
  return text, d[5] or d[1]
end

-- A character's profession scans (default: the own one): professionID -> { scan, byItem =
-- { [craftedItemID] = { recipeID (spell), recipe } } } (learned state and skill come from the game).
local function ownScans(charKey)
  local own, prefix = {}, (charKey or ns.CharKey()) .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID then
      local byItem = {}
      for recipeID, r in pairs(scan.recipes or {}) do
        -- Several recipes can make the same item: a learned one wins.
        if r.out and (not byItem[r.out] or r.learned) then byItem[r.out] = { id = recipeID, r = r } end
      end
      own[scan.professionID] = { scan = scan, byItem = byItem }
    end
  end
  return own
end

-- Whose recipe knowledge is shown for a profession: the own character's scan, else the household
-- character with the highest skill in it (a bank character without professions sees what the
-- crafter knows). Returns the character key and its scan, nil if nobody scanned it.
local function knowerOf(professionID)
  local me = ns.CharKey()
  local keys = ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or { me }
  local best, bestScan
  for _, key in ipairs(keys) do
    local scan = ownScans(key)[professionID]
    scan = scan and scan.scan
    if scan then
      if key == me then return me, scan end
      if not bestScan or (scan.rank or 0) > (bestScan.rank or 0) then best, bestScan = key, scan end
    end
  end
  return best, bestScan
end
ns.ProfessionKnower = knowerOf

-- The recipe's spell id from the crafted item (Data_Skill.lua): Data_Recipes has the Blizzard
-- API's recipe ids, the scans, the recipe sources and the skill data spell ids. Cached per
-- profession; nil if the skill data does not know the item.
local spellIndex = {}
local function spellByItem(professionID, itemID)
  local idx = spellIndex[professionID]
  if not idx then
    idx = {}
    local skill = ns.SkillData and ns.SkillData[professionID]
    for spell, d in pairs(skill and skill.recipes or {}) do
      if d.out and not idx[d.out] then idx[d.out] = spell end
    end
    spellIndex[professionID] = idx
  end
  return itemID and idx[itemID]
end

-- All recipes of one profession (Data_Recipes.lua) that make an item, priced via ns.Item; learned
-- state and skill from charKey's scan (default: the own character).
local function rows(filter, professionID, charKey)
  local list = {}
  local data = ns.RecipeData and ns.RecipeData[professionID]
  if not data then return list end
  local mine = ownScans(charKey)[professionID]
  for rid, rec in pairs(data.recipes) do
    local out, quantity, reagentList = rec[2], rec[3] or 1, rec[4] or {}
    local known = mine and out and mine.byItem[out]
    local learned = known and known.r.learned and true or false
    if out and (learned or filter ~= "learned") then
      local cost = ns.Item.MaterialCost(reagentList)
      -- a reagent without any price (nowhere on offer, no merchant): the recipe still shows, its
      -- cost from the priced reagents and no profit (no coins, last in its category)
      local unpriced = cost == nil
      if unpriced then
        cost = 0
        for i = 1, #reagentList, 2 do
          local u = buy(reagentList[i])
          if u then cost = cost + u * reagentList[i + 1] end
        end
      end
      do
        local reagents = {}
        for i = 1, #reagentList, 2 do table.insert(reagents, { i = reagentList[i], n = reagentList[i + 1] }) end
        local unitValue, onAH = sell(out)
        local value = unitValue * quantity
        local profit = not unpriced and (value - cost) or nil
        if filter ~= "profit" or ((profit or 0) > 0 and onAH) then
          local learn, need = nil, nil
          if not learned then
            -- no scan of it: the spell id through the crafted item (sources, skill, trainer)
            local spell = known and known.id or spellByItem(professionID, out)
            if spell then learn, need = learnInfo(professionID, spell) else learn = "Quelle ?" end
          end
          local rank = mine and mine.scan.rank or 0
          local tooHigh = not learned and (not mine or (need and need > rank)) or false
          -- 0 learned, 1 learnable now, 2 later: what can be made now comes first.
          local group = learned and 0 or (tooHigh and 2 or 1)
          table.insert(list, { itemID = out, recipe = rec[1], profession = data.name,
            cat = known and known.r.cat, scat = rec[5], spell = known and known.id or spellByItem(professionID, out) or rid, pid = professionID,
            score = (2 - group) * 1e12 + (profit or -1e11), learned = learned, unpriced = unpriced, learn = learn, tooHigh = tooHigh,
            unsure = ns.Item.Unsure(ns.Item(out)), nowPrice = ns.Item(out).now,
            cost = cost, unitCost = cost / quantity, value = value, profit = profit, onAH = onAH, demand = ns.Item(out).demand or 0,
            produced = quantity, reagents = reagents })
        end
      end
    end
  end
  return list
end

-- Name of the character's profession that makes the item with a learned recipe, or nil.
-- (The P&L books sales of such items to that profession when no craft was logged.)
function ns.CraftedBy(itemID)
  for pid, mine in pairs(ownScans()) do
    local known = mine.byItem[itemID]
    if known and known.r.learned then
      local data = ns.RecipeData and ns.RecipeData[pid]
      return data and data.name or mine.scan.name
    end
  end
end

-- Material cost per unit of an item the character can make with a learned recipe (the
-- cheapest such recipe), or nil. Used as the lowest sensible selling price.
function ns.CraftingCost(itemID)
  local best
  for pid, mine in pairs(ownScans()) do
    local known = mine.byItem[itemID]
    if known and known.r.learned then
      local data = ns.RecipeData and ns.RecipeData[pid]
      for _, rec in pairs(data and data.recipes or {}) do
        if rec[2] == itemID then
          local cost = ns.Item.MaterialCost(rec[4])
          if cost then
            cost = cost / (rec[3] or 1)
            if not best or cost < best then best = cost end
          end
        end
      end
    end
  end
  return best
end

-- Recipe items ----------------------------------------------------------------------
-- What a recipe item ("Muster: Dämmerrüstung") teaches: the watch list (Data_RecipeWatch.lua)
-- first, else the item name without its prefix, looked up in the skill data (Data_Skill.lua,
-- spell ids, skill to learn) and the recipe data (Data_Recipes.lua). The name index is built
-- on the first call, every item's answer is kept.

-- Prefix -> professions it can stand for (narrows down recipes of the same name).
local RECIPE_PREFIXES = {
  { "Rezept", { Alchimie = true, Kochkunst = true } },
  { "Muster", { Lederverarbeitung = true, Schneiderei = true } },
  { "Pläne", { Schmiedekunst = true } },
  { "Bauplan", { Ingenieurskunst = true } },
  { "Schema", { Ingenieurskunst = true } },
  { "Schematic", { Ingenieurskunst = true } },
  { "Formel", { Verzauberkunst = true } },
  { "Handbuch", { ["Erste Hilfe"] = true } },
}

-- Short profession names for compact lines ("Leder 300").
local SHORT = { Lederverarbeitung = "Leder", Schmiedekunst = "Schmied", Verzauberkunst = "Verzauber",
  Ingenieurskunst = "Ingenieur", Kochkunst = "Kochen" }
function ns.ProfessionShort(name) return SHORT[name] or name or "?" end

-- Lower case without spaces and dashes: "Waffe – Kreuzfahrer" = "Waffe - Kreuzfahrer",
-- "Fallschirm-Umhang" = "Fallschirmumhang".
local function norm(name)
  local s = tostring(name or ""):lower():gsub("\226\128\147", ""):gsub("\226\128\148", "")
  s = s:gsub("[%s%-]+", "")
  return s
end

-- The recipe name in a recipe item's name and the professions its prefix stands for;
-- nil if it has none of the prefixes.
local function stripPrefix(name)
  if type(name) ~= "string" then return nil end
  for _, prefix in ipairs(RECIPE_PREFIXES) do
    local rest = name:match("^" .. prefix[1] .. ": (.+)$")
    if rest then return rest, prefix[2] end
  end
end

-- Other spellings of the same recipe: "Eisen in Gold transmutieren" is the spell
-- "Transmutieren: Eisen in Gold", "Stiefel verzaubern - Geschwindigkeit" is "Stiefel - Geschwindigkeit".
local function spellings(rest)
  local list = { rest }
  local what = rest:match("^(.+) transmutieren$")
  if what then table.insert(list, "Transmutieren: " .. what) end
  local slot, effect = rest:match("^(.+) verzaubern %- (.+)$")
  if slot then table.insert(list, slot .. " - " .. effect) end
  return list
end

-- One recipe out of several of the same name: the prefix's professions, then the ones the
-- skill data knows (learnable from an item; the recipe data also lists variants made by
-- other means), then the same era (Forever's own recipe items have ids above 200000 and
-- make items above 200000). nil if it stays ambiguous.
local NEW_IDS = 200000
local function choose(list, professions, itemID)
  local function keep(test)
    local out = {}
    for _, c in ipairs(list) do if test(c) then table.insert(out, c) end end
    if #out > 0 then list = out end
  end
  if professions then keep(function(c) return professions[c.profession] end) end
  if #list > 1 then keep(function(c) return c.spell ~= nil end) end
  if #list > 1 then keep(function(c) return c.product and (c.product > NEW_IDS) == (itemID > NEW_IDS) end) end
  return #list == 1 and list[1] or nil
end

local byName, byProduct   -- normalized recipe name / product item -> { candidates }
local function addCandidate(c)
  local key = norm(c.name)
  local list = byName[key]
  if not list then list = {}; byName[key] = list end
  for _, other in ipairs(list) do
    -- The same recipe from the other data file (or another rank making the same item): fill gaps.
    if other.pid == c.pid and other.product == c.product then
      for k, v in pairs(c) do if other[k] == nil then other[k] = v end end
      return
    end
  end
  table.insert(list, c)
  if c.product then
    byProduct[c.product] = byProduct[c.product] or {}
    table.insert(byProduct[c.product], c)
  end
end

local function buildIndex()
  byName, byProduct = {}, {}
  -- Skill data first: it knows the spell and the skill needed to learn it.
  for pid, prof in pairs(ns.SkillData or {}) do
    for spell, d in pairs(prof.recipes or {}) do
      if d.name then
        addCandidate({ pid = pid, profession = prof.name, spell = spell, name = d.name, product = d.out,
          qty = d.qty or 1, reagents = d.r, skill = d[5] })
      end
    end
  end
  for pid, data in pairs(ns.RecipeData or {}) do
    for recipeID, rec in pairs(data.recipes or {}) do
      if rec[1] then
        addCandidate({ pid = pid, profession = data.name, recipeID = recipeID, name = rec[1], product = rec[2],
          qty = rec[3] or 1, reagents = rec[4] })
      end
    end
  end
end

local function professionID(name)
  for pid, prof in pairs(ns.SkillData or {}) do if prof.name == name then return pid end end
  for pid, data in pairs(ns.RecipeData or {}) do if data.name == name then return pid end end
end

local teaches = {}   -- itemID -> result or false (not a recipe item / not found)

-- ns.RecipeTeaches(itemID) -> { profession, pid, skill, product (nil for enchantments), qty,
--   reagents = { itemID, count, ... }, spell, name, from = "watch"|"name" } or nil.
function ns.RecipeTeaches(itemID)
  if not itemID then return nil end
  local known = teaches[itemID]
  if known ~= nil then return known or nil end
  local watch = ns.RecipeWatch and ns.RecipeWatch[itemID]
  local name = ns.ItemNames and ns.ItemNames[itemID]
  if not name and ns.ItemName then
    name = ns.ItemName(itemID)
    -- Not loaded yet ("Item 123"): ask again next time instead of remembering "no recipe".
    if not watch and (not name or name:match("^Item %d+$")) then return nil end
  end
  local rest, professions = stripPrefix(name)
  if not watch and not rest then teaches[itemID] = false return nil end
  if not byName then buildIndex() end
  local named = {}
  for _, spelling in ipairs(rest and spellings(rest) or {}) do
    for _, c in ipairs(byName[norm(spelling)] or {}) do table.insert(named, c) end
  end
  local pick
  if watch then
    -- The watch list names the product (or, for enchantments, the profession): it decides.
    local list = watch.product and byProduct[watch.product] or named
    for _, c in ipairs(list) do
      if c.profession == watch.profession and (not pick or (c.skill or 0) < (pick.skill or 0)) then pick = c end
    end
    pick = pick or { profession = watch.profession, pid = professionID(watch.profession),
      product = watch.product, qty = 1 }
  else
    pick = choose(named, professions, itemID)
  end
  local result = false
  if pick then
    result = { profession = pick.profession, pid = pick.pid, skill = pick.skill or (watch and watch.skill),
      product = pick.product, qty = pick.qty or 1, reagents = pick.reagents, spell = pick.spell,
      name = pick.name or rest, from = watch and "watch" or "name" }
  end
  teaches[itemID] = result
  return result or nil
end

-- The character's state for a taught recipe: { rank, learned } from the own scan of that
-- profession, nil without one (profession missing or its window never opened).
local function ownState(t)
  local prefix = ns.CharKey() .. ":"
  for key, scan in pairs(ns.db and ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID == t.pid then
      local learned = false
      for id, r in pairs(scan.recipes or {}) do
        if r.learned and ((t.product and r.out == t.product)
          or (not t.product and (id == t.spell or norm(r.name) == norm(t.name)))) then
          learned = true
          break
        end
      end
      return { rank = scan.rank or 0, learned = learned }
    end
  end
end

-- Everything the tooltip and the detail window show for a recipe item, or nil:
-- { teaches, own, cost (material per unit made, nil if a price is missing), missing (item
--   without price), value / onAH (product sells net per unit), profit, product (ns.Item),
--   recipeNow (the recipe item itself in the AH) }
function ns.RecipeTeachInfo(itemID)
  local t = ns.RecipeTeaches(itemID)
  if not t then return nil end
  local info = { teaches = t, own = ownState(t), recipeNow = ns.Item(itemID).now }
  if t.reagents then
    local cost, missing = ns.Item.MaterialCost(t.reagents)
    info.cost, info.missing = cost and cost / (t.qty or 1), missing
  end
  if t.product then
    info.product = ns.Item(t.product)
    info.value, info.onAH = ns.Item.SellNet(info.product)
    if info.cost then info.profit = info.value - info.cost end
  end
  return info
end

-- "schon gelernt", "du: Leder 150" (green when the skill is reached) or "du: kein Leder-Scan".
function ns.RecipeOwnText(info)
  local t, own = info.teaches, info.own
  local prof = ns.ProfessionShort(t.profession)
  if not own then return "|cffff6b6bdu: kein " .. prof .. "-Scan|r" end
  if own.learned then return "|cff5fd38dschon gelernt|r" end
  local reached = not t.skill or own.rank >= t.skill
  return (reached and "|cff5fd38d" or "|cffffb547") .. "du: " .. prof .. " " .. own.rank .. "|r"
end

-- Crafting professions for the chooser, ranked by the cloud's rating (Data_Professions.lua):
-- how many recipes bring gold sustainably (profit with demand) and the best one; the chart
-- is that rating over the last days. The character's skill is shown for own professions.
local function professions()
  local own, list = ownScans(), {}
  local stats = ns.ProfessionStats and ns.ProfessionStats.professions or {}
  for id, data in pairs(ns.RecipeData or {}) do
    local mine, s = own[id], stats[id]
    local lines, series = {}, {}
    if s then
      lines[1] = string.format("%d Rezepte lohnen", s[1] or 0)
      local best = s[2] and data.recipes[s[2]]
      if best then lines[2] = best[1] .. "  |cff5fd38d" .. money(s[3]) .. "|r" end
      for _, point in ipairs(s.series or {}) do table.insert(series, point[3] or 0) end
    end
    table.insert(list, { key = id, label = data.name, icon = data.icon,
      info = mine and string.format("dein Skill %d", mine.scan.rank or 0) or "",
      lines = lines, series = series, score = s and s[5] or 0 })
  end
  table.sort(list, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.label < b.label
  end)
  return list
end

-- Reagents for `count` crafts: need, have (bags + bank), to buy, unit price, cost.
local function detail(e, count)
  local rows, total, buyTotal = {}, 0, 0
  for _, reagent in ipairs(e.reagents or {}) do
    local need = (reagent.n or 1) * count
    local have = ns.Costs.Owned(reagent.i)
    local toBuy = math.max(0, need - have)
    local unit, vendor = buy(reagent.i)
    unit = unit or 0
    total = total + need * unit
    buyTotal = buyTotal + toBuy * unit
    table.insert(rows, { itemID = reagent.i, cells = {
      tostring(need),
      (have >= need and "|cff5fd38d" or "|cffffb547") .. have .. "|r",
      toBuy > 0 and tostring(toBuy) or "|cff5fd38d–|r",
      money(unit) .. (vendor and " |cff99999eH|r" or ""),
      toBuy > 0 and money(toBuy * unit) or "–",
    } })
  end
  local produced = e.produced * count
  local value = e.value * count
  local profit = value - total
  local summary = {
    { string.format("%d× herstellen", count), string.format("ergibt %g Stück", produced) },
    { "Material gesamt", money(total) },
    { "davon noch kaufen", "|cffffb547" .. money(buyTotal) .. "|r" },
    { "Einkauf pro Stück", money(produced > 0 and total / produced or nil) },
    { "Preis jetzt", e.nowPrice and (e.unsure and ("|cffffb547" .. money(e.nowPrice) .. " (unsicher)|r")
      or money(e.nowPrice)) or "nicht im Angebot" },
    { "Verkauf netto", money(value) },
    { "Gewinn", (profit >= 0 and "|cff5fd38d" or "|cffff6b6b-") .. money(math.abs(profit)) .. "|r" },
    { "dein Gold", money(GetMoney()) },
  }
  return {
    title = e.name,
    subtitle = e.profession .. " · " .. (e.learned and "gelernt" or ("nicht gelernt: " .. (e.learn or "?"))),
    columns = { { "Braucht", 56 }, { "Habe", 46 }, { "Kaufen", 54 }, { "Preis", 84 }, { "Kosten", 90 } },
    rows = rows,
    summary = summary,
    hint = "Klick auf Material: im AH suchen  ·  Shift +/−: 10er-Schritte  ·  H = Händler",
  }
end

ns.AHTable.Add({
  ahTab = false, -- only in the main window (the AH tabs are retired, 20 Nov 2026)
  id = "Crafting", label = "Crafting", title = "Crafting",
  chooser = professions,
  sort = "score",          -- learned first, then learnable now, then later; each by profit
  views = { { "profit", "Mit Gewinn" }, { "learned", "Nur gelernte" }, { "all", "Alle Rezepte" } },
  defaultFilters = { demand = "1" },
  rowColor = function(e) return not e.learned and { 0.85, 0.25, 0.25 } or nil end,
  subtitle = function(e)
    if e.learned then return "gelernt" end
    return (e.tooHigh and "|cffff6b6b" or "|cffffb547") .. "nicht gelernt: " .. (e.learn or "?") .. "|r"
  end,
  detail = detail,
  detailCount = true,
  onOpen = function() if ns.AuctionScan then ns.AuctionScan.EnsureFresh() end end,
  info = function() return ns.AuctionScan and ns.AuctionScan.LiveInfo() or nil end,
  columns = {
    { key = "name", title = "Ergebnis", width = 0, align = "LEFT", fmt = function(e)
      return e.name .. (e.produced > 1 and string.format(" |cff99999ex%g|r", e.produced) or "")
    end },
    { key = "cost", title = "Material", width = 90, muted = true, filter = "money",
      fmt = function(e) return money(e.cost) end },
    -- Per unit, next to each other: what one costs to make and what it is offered at.
    { key = "unitCost", title = "Einkauf", width = 85, muted = true, filter = "money", optional = true,
      fmt = function(e) return money(e.unitCost) end },
    { key = "nowPrice", title = "Preis jetzt", width = 90, filter = "money", optional = true,
      fmt = function(e)
        return e.unsure and ("|cffffb547" .. money(e.nowPrice) .. "|r") or money(e.nowPrice)
      end },
    { key = "value", title = "Verkauf", width = 90, filter = "money",
      fmt = function(e)
        local text = (e.onAH and "" or "|cff99999eH |r") .. money(e.value)
        return e.unsure and ("|cffffb547" .. text .. " ?|r") or text
      end },
    { key = "profit", title = "Gewinn", width = 90, filter = "money", fmt = function(e)
      return (e.profit >= 0 and "|cff5fd38d" or "|cffff6b6b") .. (e.profit < 0 and "-" or "")
        .. money(math.abs(e.profit)) .. "|r"
    end },
    { key = "demand", title = "Nachfrage", width = 75, muted = true, filter = "num",
      fmt = function(e) return ns.Item.DemandText(e) or "–" end },
  },
  rows = rows,
})

-- New live prices: recompute the list and the detail panel (AuctionScan loads later).
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function() ns.AHTable.Rebuild() end)
  end
end)

-- Blizzard's profession window (minimal additions, nothing of Blizzard's changed) ------------
-- Recipe list: gold coins left of each recipe name that pays (making it and selling the
-- product via the auction house brings more than the material costs): 1 to 3 by the profit
-- (ns.Coins: margin x demand). Selected recipe:
-- the price next to each reagent and a three line summary under the reagents. Figures from the
-- own profession scan (ns.db.recipes) and ns.Item (BuyCost, SellNet) - no own price logic.

local RIGHT_EDGE = 24 -- prices and summary values end this far from the form's right edge

-- Economics of one recipe (spell id) of the character's scans; nil without a product or price.
-- A recipe from the game's schematic (any recipe id, also one the character does not know, e.g.
-- in another player's profession window): { r = { { i, n }… }, out, qmin, qmax, name } or nil.
function ns.RecipeFromSchematic(recipeID)
  local api = C_TradeSkillUI
  if not (recipeID and api and api.GetRecipeSchematic) then return nil end
  local ok, s = pcall(api.GetRecipeSchematic, recipeID, false)
  if not ok or type(s) ~= "table" or not s.outputItemID then return nil end
  local r = {}
  for _, slot in ipairs(s.reagentSlotSchematics or {}) do
    local reagent = slot.reagents and slot.reagents[1]
    if reagent and reagent.itemID and (slot.quantityRequired or 0) > 0 and slot.reagentType ~= 0 then
      r[#r + 1] = { i = reagent.itemID, n = slot.quantityRequired }
    end
  end
  return { r = r, out = s.outputItemID, qmin = s.quantityMin or 1, qmax = s.quantityMax or s.quantityMin or 1, name = s.name }
end

function ns.RecipeEconomics(recipeID)
  local prefix = ns.CharKey() .. ":"
  local r
  for key, scan in pairs(ns.db and ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.recipes and scan.recipes[recipeID] then r = scan.recipes[recipeID] end
  end
  -- not in the own scans (another player's window): the game's schematic
  if not (r and r.out) then r = ns.RecipeFromSchematic(recipeID) end
  if not (r and r.out) then return nil end
  local cost, reagents = 0, {}
  for _, g in ipairs(r.r or {}) do
    if g.i then
      local unit, vendor = ns.Item.BuyCost(ns.Item(g.i))
      reagents[g.i] = { unit = unit, vendor = vendor, n = g.n or 1 }
      if not unit then return { reagents = reagents, out = r.out } end
      cost = cost + unit * (g.n or 1)
    end
  end
  local qty = ((r.qmin or 1) + (r.qmax or r.qmin or 1)) / 2
  local unitValue, onAH = ns.Item.SellNet(ns.Item(r.out))
  local value = unitValue * qty
  return { cost = cost, value = value, profit = value - cost, onAH = onAH, reagents = reagents, out = r.out }
end

-- "Attraktiv": the cloud's rule for a recipe that brings gold sustainably (collector,
-- ahprofessions.py): at least 5 silver profit per craft via the auction house and demand of at
-- least "mittel"; ranked by profit x demand (capped at 20) - a ranking aid, not gold per day.
local MIN_PROFIT, MIN_DEMAND, DEMAND_CAP = 500, 10, 200 -- demand: units bought per day

-- Gold coins of a recipe (profession window, "Alle Produkte", Berufsübersicht), per item:
--   Marge     = profit / material cost per craft (what one gold put in brings back)
--   Kennzahl  = Marge x demand per day (units of the product sold per day)
--   3 coins from 1.0, 2 from 0.3, 1 below; none without profit (or not sold via the AH).
--   Profit under 10 silver per craft: at most one coin. Demand "kaum" (Item.DEMAND_LEVELS):
--   the coins grey. Without demand data: by the margin alone (demand counted as 1 per day).
-- Returns n, grey.
--   The demand level limits a little: "niedrig" at most two coins, "mittel" three only from twice
--   the Kennzahl (2.0), "hoch" and up as computed.
--   Margin under the minimum margin: no coins at all (not worth the risk).
--   The minimum margin is the filter "Mindestmarge" of Alle Produkte (default 30 %, "aus" = 0).
local COIN_MIN_PROFIT, COIN_THREE, COIN_TWO, COIN_THREE_MID = 1000, 10, 3, 20 -- Kennzahl on units per day
function ns.MinMargin()
  local v = ns.db and ns.db.ui and ns.db.ui.productsMargin
  return (tonumber(v) or 30) / 100
end
--   Saturation (Item.SaturationText): übersättigt one coin less (at least one stays: there
--   is profit), unterversorgt one more (at most three).
function ns.Coins(profit, cost, demand, saturation)
  if not profit or profit <= 0 then return 0, false end
  local margin = (cost and cost > 0) and profit / cost or 10
  if margin < ns.MinMargin() then return 0, false end
  local k = margin * (demand or 10)
  local n = k >= COIN_THREE and 3 or (k >= COIN_TWO and 2 or 1)
  if demand then
    local level = ns.Item.DemandText({ demand = demand })
    if level == "mittel" and k < COIN_THREE_MID then n = math.min(n, 2)
    elseif level == "niedrig" or level == "kaum" then n = math.min(n, 2) end
  end
  local sat = saturation and ns.Item.SaturationText({ saturation = saturation })
  if sat == "übersättigt" then n = math.max(1, n - 1)
  elseif sat == "unterversorgt" then n = math.min(3, n + 1) end
  -- the third coin only for an undersupplied market (also not without a saturation figure):
  -- only there does a further offer sell besides the cheapest
  if sat ~= "unterversorgt" then n = math.min(n, 2) end
  if profit < COIN_MIN_PROFIT then n = 1 end
  local grey = demand ~= nil and demand < ((ns.Item.DEMAND_LEVELS[#ns.Item.DEMAND_LEVELS] or {})[1] or 1)
  return n, grey
end
function ns.CraftAttractive(e)
  if not e.onAH then return false, "verkauft sich nur an Händler" end
  if (e.profit or 0) < MIN_PROFIT then
    return false, (e.profit or 0) > 0 and "Gewinn unter 5 Silber" or "kein Gewinn"
  end
  if (e.demand or 0) < MIN_DEMAND then return false, "Nachfrage zu gering" end
  if (e.cost or 0) > 0 and e.profit / e.cost < ns.MinMargin() then
    return false, string.format("Marge unter %d %%", math.floor(ns.MinMargin() * 100 + 0.5))
  end
  return true, nil, e.profit * math.min(e.demand, DEMAND_CAP)
end

-- "Alle Produkte": every recipe of the open profession (Data_Recipes.lua: all recipes the game
-- knows, drops and rare ones included), in the profession window's look. Left the recipes
-- (filter: attractive / with profit / learned / all), right the card with reagents and figures.
-- Same figures as the coin in the profession window and the old professions page (rows()).
local Products = {}
ns.Products = Products
local FILTERS = {
  { key = "attractive", label = "Attraktiv (Gewinn + Nachfrage)" },
  { key = "profit", label = "Mit Gewinn" },
  { key = "learned", label = "Nur gelernte" },
  { key = "all", label = "Alle Rezepte" },
}
-- Level of the product (the level needed to use it): everything, "for me" (the character's level
-- and the 9 below), or a range. Unknown levels (item not loaded yet) count once they arrive.
local LEVELS = {
  { key = "all", label = "Alle Stufen" },
  { key = "me", label = "Für mich" },
  { key = "1-19", label = "Stufe 1–19" },
  { key = "20-29", label = "Stufe 20–29" },
  { key = "30-39", label = "Stufe 30–39" },
  { key = "40-49", label = "Stufe 40–49" },
  { key = "50-60", label = "Stufe 50–60" },
}
local MAX_REAGENTS = 8
local productsWindow, productsSplit, productsPID
local refreshOverview

local function signedMoney(c)
  c = math.floor((c or 0) + 0.5)
  return c >= 0 and ("|cff5fd38d+" .. money(c) .. "|r") or ("|cffff6b6b-" .. money(-c) .. "|r")
end

local function itemIcon(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end

-- "Mindestmarge": recipes with a known profit below it are left out (and get no coins).
local MARGINS = {
  { key = "0", label = "Aus" }, { key = "10", label = "10 %" }, { key = "20", label = "20 %" },
  { key = "30", label = "30 %" }, { key = "50", label = "50 %" }, { key = "100", label = "100 %" },
}
local function marginKey()
  local ui = ns.db and ns.db.ui
  return ui and ui.productsMargin or "30"
end

local function filterKey()
  local ui = ns.db and ns.db.ui
  return ui and ui.productsFilter or "attractive"
end

local function levelKey()
  local ui = ns.db and ns.db.ui
  return ui and ui.productsLevel or "all"
end

-- The level needed to use an item (0 = none), nil while the client has not loaded it (asked for).
local pendingLevels = false
local function useLevel(itemID)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return 0 end
  local name, _, _, _, minLevel = get(itemID) -- not "get and get(…)": that keeps only the name
  if name then return minLevel or 0 end
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
  pendingLevels = true
  return nil
end

-- An item's quality (0 poor … 5 legendary), nil while the client has not loaded it (asked for;
-- the window follows when it arrives).
local function quality(itemID)
  if not itemID then return nil end
  local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)
  if q == nil and GetItemInfo then q = select(3, GetItemInfo(itemID)) end
  if q == nil then
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    pendingLevels = true
  end
  return q
end

-- The name in its quality color, as Blizzard's recipe form shows it.
local function qualityName(itemID, name)
  local q = quality(itemID)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  return c and c.hex and (c.hex .. name .. "|r") or name
end

local function levelRange(key)
  if key == "me" then
    local lv = UnitLevel and UnitLevel("player") or 60
    return math.max(1, lv - 9), lv
  end
  local lo, hi = tostring(key):match("^(%d+)%-(%d+)$")
  return tonumber(lo), tonumber(hi)
end

local function levelOK(e, lo, hi)
  if not lo then return true end
  if e.gather then
    -- creatures: their level range overlaps; nodes have no level (always kept)
    return not e.lo or (e.lo <= hi and e.hi >= lo)
  end
  local lv = useLevel(e.itemID)
  return lv ~= nil and lv > 0 and lv >= lo and lv <= hi
end

-- Category name and order of the game (asked while the profession is open, kept for later).
local function category(cat)
  if not cat then return nil end
  ns.db.recipeCats = ns.db.recipeCats or {}
  local known = ns.db.recipeCats[cat]
  local api = C_TradeSkillUI and C_TradeSkillUI.GetCategoryInfo
  if api then
    local ok, info = pcall(api, cat)
    if ok and type(info) == "table" and info.name then
      known = { n = info.name, o = info.uiOrder or 0 }
      ns.db.recipeCats[cat] = known
    end
  end
  return known
end

-- Gathering professions: their gathered materials instead of recipes (Data_Gathering.lua),
-- same rules - value = what a unit brings at the auction house after the cut (no material
-- cost), coins and demand as for recipes, "gelernt" = can gather it now. Grouped by the rank
-- of the skill it needs; the card shows the best farm spots instead of reagents.
local GATHER = {
  [393] = { source = "Kürschnerei", icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
  [186] = { source = "Bergbau", icon = "Interface\\Icons\\Trade_Mining" },
  [182] = { source = "Kräuterkunde", icon = "Interface\\Icons\\Trade_Herbalism" },
  [356] = { source = "Angeln", icon = "Interface\\Icons\\Trade_Fishing" },
}
local RANKS = { { 225, "Fachmann (225–300)" }, { 150, "Experte (150–224)" }, { 75, "Geselle (75–149)" }, { 0, "Lehrling (1–74)" } }

local function gatherGroup(pid)
  local g = GATHER[pid]
  if not g then return nil end
  for _, group in ipairs(ns.Gathering or {}) do
    if group.source == g.source then return group end
  end
  return nil
end

local function gatherRows(pid)
  local group = gatherGroup(pid)
  if not group then return {} end
  local F = ns.Farming
  local skill = F and F.ProfessionSkill and F.ProfessionSkill(group.source) or 0
  local list = {}
  for _, entry in ipairs(group.items) do
    local id = entry[1]
    local it = ns.Item(id)
    local value, onAH = ns.Item.SellNet(it)
    local need, lo, hi = entry[2], nil, nil
    if group.kind == "mob" then lo, hi = entry[2], entry[3]; need = F.SkinSkill(lo) end
    if group.kind == "fish" then need = 1 end -- the water decides, not the fish
    list[#list + 1] = { gather = true, kind = group.kind, itemID = id, recipe = ns.ItemName(id) or ("#" .. id),
      need = need, lo = lo, hi = hi, value = value or 0, onAH = onAH, profit = value or 0, cost = 0, produced = 1,
      demand = it.demand or 0, nowPrice = it.now, unsure = ns.Item.Unsure(it), reagents = {},
      learned = (skill or 0) >= need, pid = pid }
  end
  return list
end

local function gatherEntry(pid, itemID)
  local group = gatherGroup(pid)
  for _, entry in ipairs(group and group.items or {}) do
    if entry[1] == itemID then return entry end
  end
end

local function rankOf(need)
  for _, r in ipairs(RANKS) do if (need or 0) >= r[1] then return r[2], r[1] end end
  return RANKS[#RANKS][2], 0
end

-- Best farm spots of a gathered item, up to `max`: { text, right, loc, grey }.
--   mob (skinning)  the creatures of Data_FarmSpots that yield it when skinned, the ones you can
--                   reach (level + 3) and skin first, then by the share of skins that bring it
--   skill (nodes)   the node's main zone and its densest spawn spot (Data_SpotCoords)
local function farmSpots(e, max)
  local F, C = ns.Farming, ns.SpotCoords
  local out = {}
  if e.kind == "mob" then
    local level = UnitLevel and UnitLevel("player") or 60
    local skill = F.ProfessionSkill("Kürschnerei")
    local found = {}
    for _, spot in ipairs(ns.FarmSpots or {}) do
      local npcID, name, lo, hi, zones, skinText = spot[1], spot[2], spot[3], spot[4], spot[5], spot[6]
      if skinText ~= "" then
        for _, d in ipairs(F.ParseDrops(skinText)) do
          if d[1] == e.itemID then
            local reach = level + 3 >= lo and skill ~= nil and skill >= F.SkinSkill(hi)
            local zoneID = tonumber(tostring(zones):match("(%d+)"))
            local c = C and C.npc and C.npc[npcID]
            found[#found + 1] = { name = name, lo = lo, hi = hi, per = d[2] * d[3], reach = reach,
              zone = zoneID and F.ZoneName(zoneID) or "?", c = c }
          end
        end
      end
    end
    table.sort(found, function(a, b)
      if a.reach ~= b.reach then return a.reach end
      if a.per ~= b.per then return a.per > b.per end
      return a.lo < b.lo
    end)
    for i = 1, math.min(max, #found) do
      local f = found[i]
      local loc = f.c and { name = f.name, zone = F.ZoneName(f.c[1]), x = f.c[2], y = f.c[3] } or nil
      -- units per skinning: chance x average quantity (above 1 where a skin can bring several)
      local right = f.per >= 0.995 and (string.format("%.1f", f.per):gsub("%.", ",") .. " pro Häuten")
        or string.format("%d %% der Häutungen", math.floor(f.per * 100 + 0.5))
      out[#out + 1] = { text = f.name, sub = string.format("Stufe %d–%d · %s", f.lo, f.hi, loc and loc.zone or f.zone),
        right = right, loc = loc, grey = not f.reach }
    end
  else
    local nodes = {}
    for _, n in ipairs(C and C.node and C.node[e.itemID] or {}) do nodes[#nodes + 1] = n end
    -- gems and stones come out of the ore's veins: the nodes of the items of the same skill
    if #nodes == 0 then
      local group = gatherGroup(e.pid)
      for _, entry in ipairs(group and group.items or {}) do
        if entry[2] == e.need and entry[1] ~= e.itemID then
          for _, n in ipairs(C and C.node and C.node[entry[1]] or {}) do nodes[#nodes + 1] = n end
        end
      end
    end
    table.sort(nodes, function(a, b) return a[6] > b[6] end) -- the zone with the most spawns first
    for _, n in ipairs(nodes) do
      if #out >= max then break end
      local zone = F.ZoneName(n[3])
      out[#out + 1] = { text = n[2], sub = string.format("%s · %d Fundorte", zone, n[6]), right = "",
        loc = { name = n[2], zone = zone, x = n[4], y = n[5] } }
    end
  end
  return out
end

local function productEntries(pid)
  local key = filterKey()
  local gathering = GATHER[pid] ~= nil
  local list
  if gathering then
    list = {}
    for _, e in ipairs(gatherRows(pid)) do
      if key ~= "learned" or e.learned then list[#list + 1] = e end
      e.catName, e.catOrder = rankOf(e.need)
      if e.kind == "fish" then
        local entry = gatherEntry(pid, e.itemID)
        e.catName, e.catOrder = (entry and entry[2] == 2) and "Schwärme und Treibgut" or "Fische", (entry and entry[2] == 2) and 0 or 1
      end
    end
  else
    list = rows(key == "learned" and "learned" or "all", pid, (knowerOf(pid)))
  end
  local out = {}
  local function entry(e)
    return { key = tostring(e.spell or e.itemID), name = e.recipe, icon = itemIcon(e.itemID), itemID = e.itemID,
      -- demand as the item has it (nil without data, not 0)
      coins = e.onAH and (ns.Coins(e.profit, e.cost, ns.Item(e.itemID).demand, ns.Item(e.itemID).saturation)) or 0,
      coinsGrey = e.onAH and select(2, ns.Coins(e.profit, e.cost, ns.Item(e.itemID).demand, ns.Item(e.itemID).saturation)) or false, locked = not e.learned,
      -- not learned: the name greyed, like a recipe out of reach
      color = not e.learned and { 0.55, 0.55, 0.55 } or nil, e = e,
      -- the profit per craft right in the row (the name is cut before it)
      -- "<demand symbol> +40g 78s": the demand (same symbols as the auction house list), then the
      -- profit; under the minimum margin the profit is grey (no coins either: not worth it)
      value = (e.profit and e.onAH) and (((ns.Item.DemandIcon(ns.Item(e.itemID)) or "") .. " ")
        .. (e.profit < 0 and "|cffff6b6b-" or (((e.cost or 0) > 0 and e.profit / e.cost < ns.MinMargin()) and "|cff999999+" or "|cff5fd38d+"))
        .. money(math.floor(math.abs(e.profit) + 0.5)) .. "|r") or nil }
  end
  -- another player's profession window: what they know is not known here, so nothing is
  -- shown as locked
  local linked = C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked()
  if linked then
    for _, e in ipairs(list) do e.learned, e.tooHigh = true, false end
  end
  -- the filter only leaves recipes out; the game's categories stay as in "Alle Rezepte"
  local kept = {}
  local lo, hi = levelRange(levelKey())
  for _, e in ipairs(list) do
    e.attractive, e.why, e.rank = ns.CraftAttractive(e)
    local min = ns.MinMargin()
    local marginOK = min <= 0 or not (e.profit and (e.cost or 0) > 0 and e.onAH) or e.profit / e.cost >= min
    if (key ~= "attractive" or e.attractive) and (key ~= "profit" or ((e.profit or 0) > 0 and e.onAH))
      and levelOK(e, lo, hi) and marginOK then
      kept[#kept + 1] = e
    end
  end
  list = kept
  local groups, order = {}, {}
  for _, e in ipairs(list) do
    -- the game's category of a scan, else the Blizzard API's (Data_Recipes cats: a profession no
    -- household character has scanned)
    local cats = ns.RecipeData[pid] and ns.RecipeData[pid].cats
    local c = e.catName and { n = e.catName, o = -e.catOrder } or category(e.cat)
      or (e.scat and cats and cats[e.scat] and { n = cats[e.scat], o = e.scat })
    local name = c and c.n or "Weitere"
    local g = groups[name]
    if not g then
      g = { name = name, o = c and c.o or 1e9, items = {} }
      groups[name] = g
      order[#order + 1] = g
    end
    g.items[#g.items + 1] = e
  end
  table.sort(order, function(a, b)
    if a.o ~= b.o then return a.o < b.o end
    return a.name < b.name
  end)
  for _, g in ipairs(order) do
    out[#out + 1] = { key = "h:" .. g.name, header = g.name }
    -- most profit on top within the category (gathering: the value per piece)
    table.sort(g.items, function(a, b)
      local pa = a.unpriced and -math.huge or (a.profit or a.value or 0)
      local pb = b.unpriced and -math.huge or (b.profit or b.value or 0)
      if pa ~= pb then return pa > pb end
      return (a.recipe or "") < (b.recipe or "")
    end)
    for _, e in ipairs(g.items) do out[#out + 1] = entry(e) end
  end
  return out
end

-- How a recipe is learned, from the Forever recipe sources (Data_RecipeSources.lua): one line
-- per way - trainer, vendors of the own faction (NPC, zone), reputation, Merchant's Favor, drop
-- (who drops it, else a random world drop), quest - and a tradeable recipe item with its price
-- at the auction house right now. nil when the sources do not know the recipe.
local KIND = { vendor = "Händler", limited = "Händler (begrenzter Vorrat)", rep = "Ruf-Händler", favor = "Händlergunst",
  cond = "Händler (mit Bedingung)", unknown = "Händler (NPC unbekannt)" }
-- A place on the map: a waypoint (Blizzard's map pin, tracked) where the client offers it, the
-- world map opened on the zone; else zone and coordinates in the chat.
-- loc = { name, zone, x, y } (x, y in percent).
local zoneMaps -- zone name -> uiMapID, from the client's map tree (built once)
local function zoneMapID(zone)
  if not (C_Map and C_Map.GetMapChildrenInfo) then return nil end
  if not zoneMaps then
    zoneMaps = {}
    for _, root in ipairs({ 947, 12, 13 }) do -- Azeroth, Kalimdor, Östliche Königreiche
      local ok, list = pcall(C_Map.GetMapChildrenInfo, root, nil, true)
      for _, m in ipairs(ok and list or {}) do
        if m.name and not zoneMaps[m.name] then zoneMaps[m.name] = m.mapID end
      end
    end
  end
  return zoneMaps[zone]
end

function ns.ShowOnMap(loc)
  if not (loc and loc.zone and loc.x and loc.y) then return end
  local mapID = zoneMapID(loc.zone)
  local done = false
  if mapID and C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
    local ok = pcall(function()
      C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, loc.x / 100, loc.y / 100))
      if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end)
    done = ok
    if ok and OpenWorldMap then pcall(OpenWorldMap, mapID) end
  end
  print(string.format("|cff33ccffm4:|r %s – %s %.1f, %.1f%s", loc.name or "Ziel", loc.zone, loc.x, loc.y,
    done and " (Wegpunkt auf der Karte gesetzt)" or ""))
end

-- How a recipe is learned, as lines { text, loc }: loc (name, zone, x, y) where the place is
-- known, for the map button.
-- Where the household has an item: bags, bank (the playing character live, the others from their
-- stored inventory) and own running auctions. { "Lokm (Taschen, im AH)", … }, empty if nowhere.
local function heldBy(itemID)
  local out = {}
  local me = ns.CharKey()
  local keys = ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or { me }
  local now = time()
  for _, key in ipairs(keys) do
    local places = {}
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    if key == me and count then
      local bags, all = count(itemID, false) or 0, count(itemID, true) or 0
      if bags > 0 then places[#places + 1] = "Taschen" end
      if all > bags then places[#places + 1] = "Bank" end
    else
      local inv = ns.db.inventory and ns.db.inventory[key]
      for _, part in ipairs({ { "bags", "Taschen" }, { "bank", "Bank" } }) do
        local e = inv and inv[part[1]] and inv[part[1]][itemID]
        if e and (e.n or 0) > 0 then places[#places + 1] = part[2] end
      end
    end
    local o = ns.db.owned and ns.db.owned[key]
    for _, a in ipairs(o and o.list or {}) do
      local running = a.s ~= 1 and not (a.tl and a.tl > 0 and (o.t or 0) + a.tl < now)
      if a.i == itemID and running then places[#places + 1] = "im AH" break end
    end
    if #places > 0 then out[#out + 1] = (key:match("^[^-]+") or key) .. " (" .. table.concat(places, ", ") .. ")" end
  end
  return out
end

ns.HeldBy = heldBy

-- The recipe item (pattern, plans, …) that teaches a recipe, from the recipe sources; nil if none.
local function recipeItemOf(pid, spell)
  local srcs = ns.RecipeSources and ns.RecipeSources[pid]
  local entry = srcs and srcs.recipes and srcs.recipes[spell]
  return entry and entry.item
end

local function sourceLines(pid, spell, noItem)
  local srcs = ns.RecipeSources and ns.RecipeSources[pid]
  local entry = srcs and srcs.recipes and srcs.recipes[spell]
  if not entry then return nil end
  local mine = (UnitFactionGroup and UnitFactionGroup("player")) == "Alliance" and "A" or "H"
  local lines = {}
  local function add(text, loc) lines[#lines + 1] = { text = text, loc = loc } end
  if entry.auto then add("Beim Erlernen des Berufs") end
  if entry.t then
    -- the own faction's trainer of that rank
    local tr
    for _, t in ipairs(srcs.trainers or {}) do
      if t[1] == entry.rank and (t[8] == mine or t[8] == "B") then tr = t break end
    end
    if tr then
      add("Lehrer (" .. tr[1] .. "): " .. tr[4] .. " (" .. tr[5] .. ")", tr[6] and { name = tr[4], zone = tr[5], x = tr[6], y = tr[7] } or nil)
    else
      add("Lehrer" .. (entry.rank and (" (" .. entry.rank .. ")") or ""))
    end
  end
  for _, s in ipairs(entry) do
    local npc = s[2] and s[2] > 0 and srcs.npcs and srcs.npcs[s[2]] or nil
    if not npc or npc[5] == "B" or npc[5] == mine or npc[5] == nil then
      -- who and where on the first line (with the map button), the conditions under it
      local text = KIND[s[1]] or s[1]
      if npc then text = text .. ": " .. npc[1] .. " (" .. (npc[2] or "?") .. ")" end
      add(text, npc and npc[3] and { name = npc[1], zone = npc[2], x = npc[3], y = npc[4] } or nil)
      local detail = {}
      if s.rf then detail[#detail + 1] = "Ruf " .. s.rf .. " " .. (s.rs or "") end
      if s.favor then detail[#detail + 1] = s.favor .. " Händlergunst" end
      if (s[3] or 0) > 0 then detail[#detail + 1] = money(s[3]) end
      if s.c == 1 then detail[#detail + 1] = "Classic-Daten" end
      if #detail > 0 then add("|cff999999    " .. table.concat(detail, " · ") .. "|r") end
    end
  end
  if entry.dd then
    -- the creatures that drop it (wowhead's measured chance, >= 1 %), best first; the place
    -- of each from Data_SpotCoords (densest spawn spot)
    local F, C = ns.Farming, ns.SpotCoords
    for i, d in ipairs(entry.dd) do
      if i > 3 then
        add(string.format("|cff999999    und %d weitere|r", #entry.dd - 3))
        break
      end
      local c = C and C.npc and C.npc[d[1]]
      local zone = F and F.ZoneName and F.ZoneName((c and c[1]) or d[3]) or "?"
      local chance = d[6] >= 100 and string.format("%d %%", math.floor(d[6] / 10 + 0.5))
        or (string.format("%.1f %%", d[6] / 10):gsub("%.", ","))
      add("Drop: " .. d[2] .. " (" .. chance .. ")", c and { name = d[2], zone = zone, x = c[2], y = c[3] } or nil)
      local level = (d[4] > 0) and ((d[4] == d[5]) and ("Stufe " .. d[4]) or string.format("Stufe %d–%d", d[4], d[5])) or nil
      add("|cff999999    " .. (level and (level .. " · ") or "") .. zone .. "|r")
    end
  elseif entry.dw then
    add(string.format("Drop: Weltdrop, selten (%d Gegner, Stufe %d–%d)", entry.dw[1], entry.dw[2], entry.dw[3]))
  elseif entry.d then
    if entry.dr then
      add("Drop: " .. table.concat(entry.dr, ", ")
        .. (entry.drMore and string.format(" |cff999999und %d weitere|r", entry.drMore) or ""))
    else
      add("Drop: zufällig (Weltdrop)")
    end
  end
  if entry.q then add("Quest: " .. entry.q) end
  if entry.item and not noItem then
    -- the recipe item at the auction house: cheapest offer and how many (the card shows it as a
    -- slot instead, noItem)
    local it = ns.Item(entry.item)
    if it.now then
      local n = it.offers or it.quantity
      add("Rezept im AH: " .. money(it.now) .. (n and string.format("|cff999999 · %d %s|r", n, n == 1 and "Angebot" or "Angebote") or ""))
    else
      add("|cff999999Rezept handelbar, gerade nicht im AH|r")
    end
  elseif entry.bop then
    add("|cff999999Rezept nicht handelbar (seelengebunden)|r")
  end
  return #lines > 0 and lines or nil
end

-- One short line how the household stands with the recipe that makes an item, the same in the
-- card, the market data window and the tooltip: "gelernt (Lok)", "Rezept da: Lokm (Taschen)", the
-- first way to learn it from the recipe sources ("Drop: zufällig (Weltdrop)"), else the skill
-- data's "Lehrer ab 165"; nil when nothing is known.
function ns.RecipeLearnShort(pid, itemID)
  local knower, scan = knowerOf(pid)
  local spell
  for sid, r in pairs(scan and scan.recipes or {}) do
    if r.out == itemID then
      if r.learned then
        local who = knower ~= ns.CharKey() and (" (" .. (knower:match("^[^-]+") or knower) .. ")") or ""
        return "|cff5fd38dgelernt" .. who .. "|r"
      end
      spell = spell or sid
    end
  end
  spell = spell or spellByItem(pid, itemID)
  if not spell then return nil end
  local recipeItem = recipeItemOf(pid, spell)
  local held = recipeItem and heldBy(recipeItem) or {}
  if #held > 0 then return "|cff5fd38dRezept da: " .. table.concat(held, ", ") .. "|r" end
  local src = sourceLines(pid, spell)
  if src and src[1] then return src[1].text end
  local text = learnInfo(pid, spell)
  return text ~= "unbekannt" and text or nil
end

-- Where an item drops, for any item (market search, item detail): the creatures of
-- Data_FarmSpots that loot or skin it (wowhead's measured share of kills / skins) and, for a
-- recipe item, the recipe sources' drops (dd / dw / dr). Built into one index on first use.
--   ns.ItemDrops(itemID, max) -> { { text, sub, right, loc, chance }… } best first, or nil
--   ns.HasDrops(itemID)       -> true when the index knows a drop
local dropIndex -- itemID -> { candidates… }
local function chanceText(share, skin)
  if share >= 0.995 then return (string.format("%.1f", share):gsub("%.", ",")) .. (skin and " pro Häuten" or " pro Kill") end
  if share >= 0.1 then return string.format("%d %%", math.floor(share * 100 + 0.5)) end
  return (string.format("%.1f %%", share * 100):gsub("%.", ","))
end
local function buildDropIndex()
  dropIndex = {}
  local F, C = ns.Farming, ns.SpotCoords
  local function put(id, c)
    local list = dropIndex[id]
    if not list then list = {}; dropIndex[id] = list end
    list[#list + 1] = c
  end
  for _, spot in ipairs(ns.FarmSpots or {}) do
    local npcID, name, lo, hi, zones, skinText, lootText = spot[1], spot[2], spot[3], spot[4], spot[5], spot[6], spot[7]
    local zoneID = tonumber(tostring(zones or ""):match("(%d+)"))
    for _, part in ipairs({ { lootText, false }, { skinText, true } }) do
      if part[1] and part[1] ~= "" and F and F.ParseDrops then
        for _, d in ipairs(F.ParseDrops(part[1])) do
          put(d[1], { npc = npcID, name = name, lo = lo, hi = hi, zoneID = zoneID, share = d[2] * d[3], skin = part[2] })
        end
      end
    end
  end
  for _, srcs in pairs(ns.RecipeSources or {}) do
    for _, entry in pairs(srcs.recipes or {}) do
      local id = entry.item
      if id then
        if entry.dd then
          for _, d in ipairs(entry.dd) do
            put(id, { npc = d[1], name = d[2], lo = d[4], hi = d[5], zoneID = d[3], share = d[6] / 1000 })
          end
        elseif entry.dw then
          put(id, { world = string.format("Weltdrop, selten (%d Gegner, Stufe %d–%d)", entry.dw[1], entry.dw[2], entry.dw[3]), share = 0 })
        elseif entry.d then
          put(id, { world = entry.dr and table.concat(entry.dr, ", ") or "Zufälliger Weltdrop", share = 0 })
        end
      end
    end
  end
end

function ns.HasDrops(itemID)
  if not dropIndex then buildDropIndex() end
  return dropIndex[itemID] ~= nil
end

function ns.ItemDrops(itemID, max)
  if not dropIndex then buildDropIndex() end
  local list = dropIndex[itemID]
  if not list then return nil end
  local F, C = ns.Farming, ns.SpotCoords
  local level = UnitLevel and UnitLevel("player") or 60
  local sorted, seen = {}, {}
  for _, c in ipairs(list) do
    local key = c.world or (tostring(c.npc) .. (c.skin and "s" or ""))
    if not seen[key] then seen[key] = true; sorted[#sorted + 1] = c end
  end
  -- reachable creatures (level + 3) first, then the best chance
  table.sort(sorted, function(a, b)
    local ra, rb = (a.lo or 0) <= level + 3, (b.lo or 0) <= level + 3
    if ra ~= rb then return ra end
    if a.share ~= b.share then return a.share > b.share end
    return (a.lo or 0) < (b.lo or 0)
  end)
  local out = {}
  for i = 1, math.min(max or 5, #sorted) do
    local c = sorted[i]
    if c.world then
      out[#out + 1] = { text = c.world, sub = "", right = "", chance = 0 }
    else
      local spot = C and C.npc and C.npc[c.npc]
      local zone = F and F.ZoneName and ((spot and F.ZoneName(spot[1])) or (c.zoneID and F.ZoneName(c.zoneID))) or "?"
      local level = (c.lo and c.lo > 0) and ((c.lo == c.hi) and ("Stufe " .. c.lo) or string.format("Stufe %d–%d", c.lo, c.hi or c.lo)) or nil
      out[#out + 1] = { text = c.name .. (c.skin and " (Kürschnerei)" or ""),
        sub = (level and (level .. " · ") or "") .. zone, right = chanceText(c.share, c.skin), chance = c.share,
        loc = spot and { name = c.name, zone = F.ZoneName(spot[1]), x = spot[2], y = spot[3] } or nil }
    end
  end
  return out, #sorted
end

-- A reagent slot like the profession window's: Blizzard's slot template if the client has it,
-- else an item button (icon in the slot frame); "0/20 Name" right of it, the price at the edge.
local function reagentSlot(c)
  local r = {}
  local ok, slot = pcall(CreateFrame, "Button", nil, c, "ItemButtonTemplate")
  if not ok or not slot then slot = CreateFrame("Button", nil, c) end
  slot:SetSize(37, 37)
  r.Slot = slot
  r.Icon = rawget(slot, "icon") or rawget(slot, "Icon")
  if type(r.Icon) ~= "table" then
    r.Icon = slot:CreateTexture(nil, "ARTWORK")
    r.Icon:SetAllPoints()
  end
  local count = rawget(slot, "Count")
  if type(count) == "table" and count.Hide then count:Hide() end
  r.Name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.Name:SetPoint("LEFT", slot, "RIGHT", 8, 0)
  r.Name:SetWidth(150)
  r.Name:SetJustifyH("LEFT")
  r.Name:SetMaxLines(2)
  r.Price = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.Price:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
  r.Price:SetPoint("TOP", slot, "TOP", 0, -12)
  r.Price:SetJustifyH("RIGHT")
  slot:SetScript("OnEnter", function(self)
    if not r.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(r.itemID)
    GameTooltip:Show()
  end)
  slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
  slot:SetScript("OnClick", function(self) if r.itemID then ns.NativeWindow.AltClick(r.itemID, self) end end)
  return r
end

-- The card in the profession window's look: icon and name, how it is learned where Blizzard
-- shows the description, "Reagenzien:" with slots and prices, then the summary rows the
-- profession window gets from this addon (Herstellkosten, Erlös, Nachfrage, line, Gewinn).
local SUMMARY = { "Herstellkosten", "Erlös", "Nachfrage", "Gewinn" }
local GATHER_SUMMARY = { "Preis jetzt", "Erlös (nach Gebühr)", "Nachfrage", "Wert pro Stück" }
local function productCard(c)
  local v = ns.NativeWindow.CardHead(c)
  -- "Erlernen:" with one line per way to learn it (unlearned recipes), where Blizzard shows the
  -- description
  v.LearnHead = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.LearnHead:SetPoint("TOPLEFT", v.Icon, "BOTTOMLEFT", 0, -16)
  v.LearnHead:SetText("Erlernen:")
  -- one font string per way (money icons sit right only in single-line text)
  v.SourceLines, v.MapButtons = {}, {}
  for i = 1, 8 do
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", i == 1 and v.LearnHead or v.SourceLines[i - 1], "BOTTOMLEFT", 0, i == 1 and -5 or -4)
    fs:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE - 20, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    v.SourceLines[i] = fs
    -- "Auf der Karte anzeigen" at the end of a line whose place is known
    local b = CreateFrame("Button", nil, c)
    b:SetSize(16, 16)
    b:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE + 2, 0)
    b:SetPoint("TOP", fs, "TOP", 0, 3)
    b:SetNormalTexture("Interface\\Icons\\INV_Misc_Map_01")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Auf der Karte anzeigen")
      if self.loc then GameTooltip:AddLine(string.format("%s, %s %.1f / %.1f", self.loc.name or "", self.loc.zone, self.loc.x, self.loc.y), 1, 1, 1) end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self) ns.Safe(ns.ShowOnMap, self.loc) end)
    b:Hide()
    v.MapButtons[i] = b
  end
  -- the tradeable recipe item (pattern, plans, …) as a slot like the reagents: icon, tooltip,
  -- Alt+click market data, its price at the auction house
  v.RecipeSlot = reagentSlot(c)
  v.Head:SetText("Reagenzien:")
  v.reagents = {}
  for i = 1, MAX_REAGENTS do v.reagents[i] = reagentSlot(c) end
  -- gathering: "Beste Farmspots:" instead of the reagents, a map button per spot
  v.SpotHead = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.SpotHead:SetText("Beste Farmspots:")
  v.Spots = {}
  for i = 1, 5 do
    -- two lines: the creature (or node) in white, under it level and zone small and grey
    local row = {}
    row.Text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.Text:SetPoint("TOPLEFT", i == 1 and v.SpotHead or v.Spots[i - 1].Sub, "BOTTOMLEFT", 0, i == 1 and -8 or -9)
    row.Text:SetJustifyH("LEFT")
    row.Text:SetWordWrap(false)
    row.Sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.Sub:SetPoint("TOPLEFT", row.Text, "BOTTOMLEFT", 0, -2)
    row.Sub:SetJustifyH("LEFT")
    row.Sub:SetWordWrap(false)
    row.Sub:SetWidth(180)
    row.Right = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.Right:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE - 26, 0)
    row.Right:SetPoint("TOP", row.Sub, "TOP", 0, 0) -- on the second line, right of level and zone
    row.Right:SetJustifyH("RIGHT")
    -- a fixed width (not anchored to row.Right: that one hangs on the text, a loop for WoW)
    row.Text:SetWidth(222)
    local b = CreateFrame("Button", nil, c)
    b:SetSize(20, 20)
    b:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE + 2, 0)
    b:SetPoint("TOP", row.Text, "TOP", 0, 0)
    b:SetNormalTexture("Interface\\Icons\\INV_Misc_Map_01")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Auf der Karte anzeigen")
      if self.loc then GameTooltip:AddLine(string.format("%s, %s %.1f / %.1f", self.loc.name or "", self.loc.zone, self.loc.x, self.loc.y), 1, 1, 1) end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self) ns.Safe(ns.ShowOnMap, self.loc) end)
    row.Map = b
    v.Spots[i] = row
  end
  v.rows = {}
  for i, text in ipairs(SUMMARY) do
    local l = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    l:SetText(text)
    local val = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetJustifyH("RIGHT")
    val:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
    val:SetPoint("TOP", l, "TOP", 0, 0)
    v.rows[i] = { label = l, value = val }
  end
  v.Line = c:CreateTexture(nil, "ARTWORK")
  v.Line:SetColorTexture(1, 0.82, 0, 0.25)
  v.Line:SetHeight(1)
  -- "Auf die Einkaufsliste" under the profit, like the profession window's button: once per
  -- click (Shift: 5), the list opens on it
  local okB, shop = pcall(CreateFrame, "Button", nil, c, "UIPanelButtonTemplate")
  if okB and shop then
    shop:SetSize(170, 22)
    shop:SetText("Auf die Einkaufsliste")
    shop:SetScript("OnClick", function()
      local e = v.entry
      if not (e and ns.ShoppingList and ns.ShoppingList.AddRecipe) then return end
      local w = ns.ShoppingList.AddRecipe({ rid = e.spell, out = e.itemID, name = e.recipe, pid = e.pid,
        q = e.produced, reagents = e.reagents }, IsShiftKeyDown and IsShiftKeyDown() and 5 or 1)
      -- not learned yet: its pattern on the list too (auction house when offered, else its source)
      local pattern = not e.learned and recipeItemOf(e.pid, e.spell)
      if pattern and ns.ShoppingList.AddPattern then
        local now = ns.Item(pattern).now
        ns.ShoppingList.AddPattern({ rid = e.spell, pid = e.pid, item = pattern, name = e.recipe,
          way = now and "ah" or "vendor", price = now })
      end
      if w and ns.ShoppingList.Show then ns.ShoppingList.Show(w.rid) end
    end)
    shop:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Auf die Einkaufsliste")
      GameTooltip:AddLine("Ein Mal pro Klick, mit Shift fünf Mal; was dein Haushalt hat, wird abgezogen. Ein noch nicht gelerntes Rezept kommt mit auf die Liste.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    shop:SetScript("OnLeave", function() GameTooltip:Hide() end)
    shop:Hide()
    v.Shop = shop
  end
  return v
end

-- The card's content scrolls (mouse wheel, Blizzard's scroll bar only when it does not fit): many
-- reagents, ways to learn and the figures are taller than the card.
local function cardScroll(c)
  local ok, s = pcall(CreateFrame, "ScrollFrame", nil, c, "UIPanelScrollFrameTemplate")
  if not ok or not s then s = CreateFrame("ScrollFrame", nil, c) end
  s.scrollBarHideable = true
  -- full width: the content keeps its own margins (icon 22 left, RIGHT_EDGE right), the bar sits
  -- in the right margin instead of adding to it
  s:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -4)
  s:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 6)
  local bar = rawget(s, "ScrollBar")
  if type(bar) == "table" then
    bar:ClearAllPoints()
    bar:SetPoint("TOPRIGHT", s, "TOPRIGHT", -4, -18)
    bar:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -4, 18)
  end
  local content = CreateFrame("Frame", nil, s)
  content:SetSize(math.max(1, c:GetWidth() or 0), 1)
  s:SetScrollChild(content)
  s:EnableMouseWheel(true)
  s:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
  end)
  s:HookScript("OnSizeChanged", function(_, w) if w and w > 0 then content:SetWidth(w) end end)
  return s, content
end

local function showProduct(entry, c)
  if not rawget(c, "m4Product") then
    local scroll, content = cardScroll(c)
    c.m4Product = productCard(content)
    c.m4Product.layer, c.m4Product.scroll = content, scroll
  end
  local v = c.m4Product
  local e = entry and entry.e
  local shown = e ~= nil
  for _, part in ipairs({ v.Icon, v.Ring, v.Name, v.Sub, v.Head, v.LearnHead, v.Line }) do part:SetShown(shown) end
  if not shown then
    for i, fs in ipairs(v.SourceLines) do fs:Hide(); v.MapButtons[i]:Hide() end
    for _, row in ipairs(v.Spots) do row.Text:Hide(); row.Sub:Hide(); row.Right:Hide(); row.Map:Hide() end
    v.SpotHead:Hide()
  end
  for _, row in ipairs(v.rows) do row.label:SetShown(shown); row.value:SetShown(shown) end
  for _, r in ipairs(v.reagents) do r.Slot:Hide(); r.Name:Hide(); r.Price:Hide(); r.itemID = nil end
  do
    local r = v.RecipeSlot
    r.Slot:Hide(); r.Name:Hide(); r.Price:Hide(); r.itemID = nil
  end
  if productsSplit and productsSplit.empty then
    productsSplit.empty:SetText(shown and "" or "Keine Rezepte für diesen Filter.")
  end
  if not shown then
    if v.Shop then v.Shop:Hide() end
    return
  end
  v.Icon:SetTexture(itemIcon(e.itemID))
  v.itemID = e.itemID
  v.Name:SetText(qualityName(e.itemID, e.recipe)
    .. (e.produced > 1 and string.format("  |cff999999x%g|r", e.produced) or ""))
  if e.gather then
    local need = e.kind == "mob" and string.format("Gegner Stufe %d–%d · Häuten ab Skill %d", e.lo, e.hi, e.need)
      or (e.kind == "fish" and "Angeln · der Skill hängt vom Gewässer ab")
      or string.format("ab Skill %d", e.need)
    v.Sub:SetText((e.learned and "|cff5fd38d" or "|cffffb547") .. need .. "|r")
  else
    -- not learned, but the household has its recipe item: say so instead of how to get it
    local recipeItem = not e.learned and recipeItemOf(e.pid, e.spell)
    local held = recipeItem and heldBy(recipeItem) or {}
    if e.learned then
      v.Sub:SetText("gelernt")
    elseif #held > 0 then
      v.Sub:SetText("|cff5fd38dnicht gelernt · Rezept da: " .. table.concat(held, ", ") .. "|r")
    else
      v.Sub:SetText((e.tooHigh and "|cffff6b6b" or "|cffffb547") .. "nicht gelernt"
        .. (e.learn and (": " .. e.learn:gsub("^Quelle %? ", "")) or "") .. "|r")
    end
  end
  for _, row in ipairs(v.Spots) do row.Text:Hide(); row.Sub:Hide(); row.Right:Hide(); row.Map:Hide() end
  v.SpotHead:SetShown(e.gather == true)
  local src = not e.learned and not e.gather and sourceLines(e.pid, e.spell, true) or nil
  local lastSource
  for i, fs in ipairs(v.SourceLines) do
    local line = src and src[i]
    fs:SetText(line and line.text or "")
    fs:SetShown(line ~= nil)
    if line then lastSource = fs end
    local b = v.MapButtons[i]
    b.loc = line and line.loc
    b:SetShown(b.loc ~= nil)
  end
  -- the recipe item under the ways to learn it (not learned, tradeable)
  local recipeItemID = not e.learned and not e.gather and recipeItemOf(e.pid, e.spell)
  local srcs = recipeItemID and ns.RecipeSources[e.pid]
  local bop = srcs and srcs.recipes[e.spell] and srcs.recipes[e.spell].bop
  if recipeItemID and not bop then
    local r = v.RecipeSlot
    local it = ns.Item(recipeItemID)
    r.itemID = recipeItemID
    r.Icon:SetTexture(itemIcon(recipeItemID))
    if SetItemButtonQuality then pcall(SetItemButtonQuality, r.Slot, quality(recipeItemID), recipeItemID) end
    r.Slot:ClearAllPoints()
    r.Slot:SetPoint("TOPLEFT", lastSource or v.LearnHead or v.Icon, "BOTTOMLEFT", 0, -8)
    local n = it.offers or it.quantity
    r.Name:SetText((ns.ItemName(recipeItemID) or ("#" .. recipeItemID))
      .. (it.now and n and string.format("\n|cff999999%d %s|r", n, n == 1 and "Angebot" or "Angebote") or ""))
    r.Price:SetText(it.now and (money(it.now) .. "|cff999999  AH|r") or "|cff999999nicht im AH|r")
    r.Slot:Show(); r.Name:Show(); r.Price:Show()
    lastSource = r.Slot
    src = src or {}
  end
  v.LearnHead:SetShown(src ~= nil)
  v.Head:ClearAllPoints()
  v.Head:SetPoint("TOPLEFT", lastSource or v.Icon, "BOTTOMLEFT", 0, lastSource and -16 or -20)
  v.Head:SetShown(not e.gather)
  local last = v.Head
  if e.gather then
    v.SpotHead:ClearAllPoints()
    v.SpotHead:SetPoint("TOPLEFT", v.Icon, "BOTTOMLEFT", 0, -20)
    last = v.SpotHead
    local spots = farmSpots(e, #v.Spots)
    for i, sp in ipairs(spots) do
      local row = v.Spots[i]
      row.Text:SetText((sp.grey and "|cff999999" or "") .. sp.text .. (sp.grey and "|r" or ""))
      row.Sub:SetText(sp.sub or "")
      row.Right:SetText((sp.grey and "|cff999999" or "") .. sp.right .. (sp.grey and "|r" or ""))
      row.Map.loc = sp.loc
      row.Text:Show(); row.Sub:Show(); row.Right:Show(); row.Map:SetShown(sp.loc ~= nil)
      last = row.Sub
    end
    if #spots == 0 then
      local row = v.Spots[1]
      row.Text:SetText("|cff999999Keine Farmspots bekannt|r")
      row.Text:Show()
      last = row.Text
    end
  end
  for i, g in ipairs(e.reagents or {}) do
    local r = v.reagents[i]
    if not r then break end
    local unit, vendor = buy(g.i)
    local have = ns.Costs and ns.Costs.Owned and ns.Costs.Owned(g.i) or 0
    r.itemID = g.i
    r.Icon:SetTexture(itemIcon(g.i))
    -- the slot's border in the reagent's quality, like Blizzard's item buttons
    if SetItemButtonQuality then pcall(SetItemButtonQuality, r.Slot, quality(g.i), g.i) end
    r.Slot:ClearAllPoints()
    r.Slot:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, i == 1 and -8 or -6)
    r.Name:SetText(string.format("%s%d/%d|r %s", have >= g.n and "|cffffffff" or "|cff999999", have, g.n,
      ns.ItemName(g.i) or ("#" .. g.i)))
    -- no price: a soulbound reagent (never at the auction house) says so - it has to be farmed
    local noPrice = "|cffff6b6bkein Preis|r"
    if not unit then
      local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
      local bind = info and select(14, info(g.i))
      if bind == 1 then noPrice = "|cffffb547gebunden: selbst farmen|r" end
    end
    r.Price:SetText(unit and (money(unit * g.n) .. "|cff999999  " .. (vendor and "H" or "AH") .. "|r") or noPrice)
    r.Slot:Show(); r.Name:Show(); r.Price:Show()
    last = r.Slot
  end
  local values = {
    e.unpriced and (money(e.cost) .. "|cffff6b6b + ?|r") or money(e.cost),
    money(e.value) .. (e.onAH and "" or "|cff999999  H|r"),
    ns.Item.DemandText(e) or "–",
    e.unpriced and "|cff999999? (ein Reagenz ohne Preis)|r" or signedMoney(e.profit),
  }
  local labels = SUMMARY
  if e.gather then
    labels = GATHER_SUMMARY
    values[1] = e.nowPrice and money(e.nowPrice) or "nicht im Angebot"
    values[4] = money(e.value)
  end
  for i, row in ipairs(v.rows) do
    row.label:SetText(labels[i])
    row.label:ClearAllPoints()
    local gap = i == #v.rows and 7 or 0 -- room for the line before "Gewinn"
    row.label:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -14 - (i - 1) * 14 - gap)
    row.value:SetText(values[i])
  end
  local gewinn = v.rows[#v.rows].label
  v.Line:ClearAllPoints()
  v.Line:SetPoint("BOTTOMLEFT", gewinn, "TOPLEFT", 0, 3)
  v.Line:SetPoint("RIGHT", v.layer, "RIGHT", -RIGHT_EDGE + 2, 0)
  -- a recipe that makes an item can go on the shopping list (not a gathered material)
  v.entry = e
  local bottomOf = gewinn
  if v.Shop then
    local can = not e.gather and e.itemID ~= nil and type(e.reagents) == "table" and #e.reagents > 0
    v.Shop:ClearAllPoints()
    -- right-aligned with the values (under the profit's amount)
    v.Shop:SetPoint("TOPRIGHT", v.rows[#v.rows].value, "BOTTOMRIGHT", 2, -12)
    v.Shop:SetShown(can)
    if can then bottomOf = v.Shop end
  end
  -- the content as tall as what it shows (measured once laid out), from the top again
  local scroll, layer = v.scroll, v.layer
  local w = scroll:GetWidth()
  if w and w > 0 then layer:SetWidth(w) end
  scroll:SetVerticalScroll(0)
  local function fit()
    local top, bottom = layer:GetTop(), bottomOf:GetBottom()
    if top and bottom then layer:SetHeight(math.max(1, top - bottom + 18)) end
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  end
  fit()
  if C_Timer then C_Timer.After(0, function() ns.Safe(fit) end) end
end

local function refreshProducts()
  if not (productsWindow and productsSplit and productsPID) then return end
  local data = ns.RecipeData and ns.RecipeData[productsPID]
  local g = GATHER[productsPID]
  if g and gatherGroup(productsPID) then data = { name = g.source, icon = g.icon } end
  local title = "Alle Produkte" .. (data and (" – " .. data.name) or "")
  -- the knowledge of another household character (the own one has no scan of this profession)
  local knower, scan = knowerOf(productsPID)
  if knower and knower ~= ns.CharKey() then
    title = title .. string.format(" (Wissen: %s %d)", knower:match("^[^-]+") or knower, scan and scan.rank or 0)
  end
  local f = productsWindow.frame
  if f.SetTitle then pcall(f.SetTitle, f, title) end
  if data and data.icon and f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, data.icon) end
  LEVELS[2].label = string.format("Für mich (Stufe %d–%d)", levelRange("me"))
  pendingLevels = false
  productsSplit.SetEntries(data and productEntries(productsPID) or {})
  Products.UpdateOwnTabs()
  if not data and productsSplit.empty then productsSplit.empty:SetText("Dieser Beruf stellt keine Produkte her.") end
end

-- "Berufsübersicht": every profession as a slot like Blizzard's profession book - who of the
-- household has it (skill), and how many of its recipes pay right now (collector figures); a
-- click shows its recipes ("Alle Produkte") in the same window.
local OVERVIEW_ICON = "Interface\\Icons\\INV_Misc_Book_11"
local overviewRows = {}

local function professionList()
  local craft, gather = {}, {}
  for pid, data in pairs(ns.RecipeData or {}) do
    craft[#craft + 1] = { pid = pid, name = data.name, icon = data.icon }
  end
  for pid, g in pairs(GATHER) do
    gather[#gather + 1] = { pid = pid, name = g.source, icon = g.icon }
  end
  local function byName(a, b) return a.name < b.name end
  table.sort(craft, byName)
  table.sort(gather, byName)
  return craft, gather
end

-- A profession's line under the name (who has it) and its gold coins right in the row: those of
-- its best recipe right now (ns.Coins, grey with hardly any demand), like the recipe rows.

local function overviewLines(p)
  local knower, scan = knowerOf(p.pid)
  local who
  if knower then
    who = string.format("%s  %d/%d", knower:match("^[^-]+") or knower, scan.rank or 0, scan.max or 0)
  else
    who = "|cff9d9d9dnicht erlernt|r"
  end
  -- the best coins of its recipes now (same rule as the recipe rows)
  local best, grey = 0, false
  for _, e in ipairs(rows("all", p.pid, knower) or {}) do
    if e.onAH and e.profit then
      local n, g = ns.Coins(e.profit, e.cost, ns.Item(e.itemID).demand, ns.Item(e.itemID).saturation)
      if n > best or (n == best and grey and not g) then best, grey = n, g end
    end
  end
  return who, best, grey and "grey" or nil
end

local OVERVIEW_TOP, OVERVIEW_ROW = -50, 70 -- first card under the title bar, row height

local function overviewSlot(parent, p)
  local NW = ns.NativeWindow
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(306, OVERVIEW_ROW - 8)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 0.82, 0, 0.08)
  local slot = NW.Slot(b, p.icon, p.name, "")
  slot:SetPoint("LEFT", 6, 0)
  slot:EnableMouse(false)
  b.slot = slot
  slot.Name:ClearAllPoints()
  slot.Name:SetPoint("BOTTOMLEFT", slot, "RIGHT", 8, 1)
  slot.Sub:ClearAllPoints()
  slot.Sub:SetPoint("TOPLEFT", slot, "RIGHT", 8, -3)
  local pin = CreateFrame("Frame", nil, b)
  pin:SetSize(1, 1)
  pin:SetPoint("RIGHT", b, "RIGHT", -10, 0)
  b.coins = NW.Coins(b, nil)
  b.pin = pin
  b:SetScript("OnClick", function() ns.Safe(Products.Show, p.pid) end)
  b:SetScript("OnEnter", function(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    GameTooltip:SetText(p.name)
    -- from the recipes now (same rule as the coins): how many pay, the best by coins and profit
    local count, best, bestN = 0, nil, 0
    for _, e in ipairs(rows("all", p.pid, (knowerOf(p.pid))) or {}) do
      if e.onAH and (e.profit or 0) > 0 then
        count = count + 1
        local n = ns.Coins(e.profit, e.cost, ns.Item(e.itemID).demand, ns.Item(e.itemID).saturation)
        if n > bestN or (n == bestN and best and e.profit > best.profit) then best, bestN = e, n end
      end
    end
    GameTooltip:AddLine(string.format("%d Rezepte lohnen sich gerade", count), 1, 1, 1)
    if best then
      GameTooltip:AddDoubleLine("Bestes: " .. best.recipe, "+" .. money(best.profit), 1, 1, 1, 0.37, 0.83, 0.55)
    end
    GameTooltip:AddLine("Klick: alle Rezepte, was sie kosten und was sie bringen", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b.p = p
  overviewRows[#overviewRows + 1] = b
  return b
end

-- Two cards like Blizzard's "Berufe" window (its card art, gold title), right under the title
-- bar and as tall as the window: crafting professions, then gathering ones, two per row.
local function buildOverview(page, w)
  local craft, gather = professionList()
  local function section(title, list, y)
    local rowsN = math.ceil(#list / 2)
    local height = 52 + rowsN * OVERVIEW_ROW
    local c = CreateFrame("Frame", nil, page)
    c:SetSize(664, height)
    c:SetPoint("TOPLEFT", w.frame, "TOPLEFT", 5, y)
    local bg = c:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetAtlas("Profession-overview-Card")
    c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.Title:SetPoint("TOPLEFT", 20, -16)
    c.Title:SetText(title)
    for i, p in ipairs(list) do
      local b = overviewSlot(c, p)
      local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
      b:SetPoint("TOPLEFT", c, "TOPLEFT", 16 + col * 322, -40 - row * OVERVIEW_ROW)
    end
    return height
  end
  local h = section("Herstellungsberufe", craft, OVERVIEW_TOP)
  section("Sammelberufe", gather, OVERVIEW_TOP - h + 4)
end

refreshOverview = function()
  for _, b in ipairs(overviewRows) do
    local who, coins, hot = overviewLines(b.p)
    b.slot.Sub:SetText(who)
    b.coins.Set(coins, b.pin, hot)
  end
  local f = productsWindow and productsWindow.frame
  Products.UpdateOwnTabs()
  if f and f.SetTitle then pcall(f.SetTitle, f, "Berufsübersicht") end
  if f and f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, OVERVIEW_ICON) end
end

local function createProducts()
  local NW = ns.NativeWindow
  productsWindow = NW.New({ name = "M4CompanionProducts", title = "Alle Produkte", icon = "Interface\\Icons\\INV_Misc_Coin_02" })
  productsWindow.frame:HookScript("OnShow", function() Products.SyncTab() end)
  -- the house chosen in any window (ledger, market data): prices, profit and coins follow
  ns.AuctionHouse.OnViewChange(function()
    if productsWindow.frame:IsShown() then ns.Safe(refreshProducts); ns.Safe(refreshOverview) end
  end)
  productsWindow.frame:HookScript("OnHide", function() Products.SyncTab() end)
  -- side tabs like Blizzard's profession window: the overview, then the chosen profession's recipes
  productsWindow:AddTab({ key = "overview", title = "Berufsübersicht", icon = OVERVIEW_ICON, overview = true,
    build = buildOverview, onShow = function() refreshOverview() end })
  productsWindow:AddTab({ key = "products", title = "Alle Produkte", icon = "Interface\\Icons\\INV_Misc_Coin_02",
    visible = function() return productsPID ~= nil end, build = function(page)
    productsSplit = NW.Split(page, {
      onSelect = showProduct,
      filter = { groups = {
        { title = "Rezepte", options = FILTERS, get = filterKey, set = function(key)
          ns.db.ui = ns.db.ui or {}
          ns.db.ui.productsFilter = key
          refreshProducts()
        end },
        { title = "Stufe", options = LEVELS, get = levelKey, set = function(key)
          ns.db.ui = ns.db.ui or {}
          ns.db.ui.productsLevel = key
          refreshProducts()
        end },
        -- the one house choice of all windows (AuctionHouse.SetManual): Horde, Allianz, Neutral
        { title = "Auktionshaus", options = { { key = "H", label = "Horde" }, { key = "A", label = "Allianz" },
            { key = "N", label = "Neutral" } },
          get = function() return ns.AuctionHouse.Current() end,
          set = function(key) ns.AuctionHouse.SetManual(key) end },
        { title = "Mindestmarge", options = MARGINS, get = marginKey, set = function(key)
          ns.db.ui = ns.db.ui or {}
          ns.db.ui.productsMargin = key
          refreshProducts()
          ns.Safe(refreshOverview) -- the overview coins follow the margin too
        end },
      } },
    })
  end, onShow = function() refreshProducts() end })
  -- under the window, like under Blizzard's profession window: "Planer" opens the planner (its
  -- own window, PlanWindow.lua) for the chosen profession, "Einkaufsliste" the shopping list
  local f = productsWindow.frame
  local function tab(name, text, onClick)
    local ok, t = pcall(CreateFrame, "Button", name, f, "PanelTabButtonTemplate")
    if not (ok and t) then return nil end
    t:SetText(text)
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, t, 0) end
    t:SetScript("OnClick", function() ns.Safe(onClick) end)
    return t
  end
  Products.ownPlanTab = tab("M4CompanionProductsPlanTab", "Planer", function()
    if ns.PlanWindow and productsPID then ns.PlanWindow.Toggle(productsPID) end
  end)
  Products.ownShopTab = tab("M4CompanionProductsShopTab", "Einkaufsliste", function()
    if ns.ShoppingList then ns.ShoppingList.Toggle() end
  end)
  productsWindow.frame:HookScript("OnShow", function() ns.Safe(Products.UpdateOwnTabs) end)
end

-- The tabs under this window: "Planer" only while a crafting profession is chosen (not on the
-- overview, not for gathering), "Einkaufsliste" always, moving left without the planner.
function Products.UpdateOwnTabs()
  local plan, shop = Products.ownPlanTab, Products.ownShopTab
  if not productsWindow then return end
  local f = productsWindow.frame
  local showPlan = plan ~= nil and productsPID ~= nil and productsWindow.current == "products"
    and ns.PlanWindow ~= nil and ns.PlanWindow.ForProfession(productsPID)
  if plan then
    plan:ClearAllPoints()
    plan:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
    plan:SetShown(showPlan)
  end
  if shop then
    shop:ClearAllPoints()
    if showPlan then shop:SetPoint("LEFT", plan, "RIGHT", 4, 0) else shop:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2) end
  end
  Products.SyncTab()
end

-- The open profession's id (Data_Recipes keys: the skill line, e.g. 165 Lederverarbeitung).
local function openProfessionID()
  local api = C_TradeSkillUI
  if api and api.GetBaseProfessionInfo then
    local ok, info = pcall(api.GetBaseProfessionInfo)
    if ok and type(info) == "table" and info.professionID then return info.professionID end
  end
  if api and api.GetTradeSkillLine then
    local ok, id = pcall(api.GetTradeSkillLine)
    if ok then return id end
  end
  return nil
end

Products.Entries = productEntries -- for tests
Products.SourceLines = sourceLines
Products.OpenProfessionID = openProfessionID

function Products.Show(pid)
  if not productsWindow then createProducts() end
  productsPID = pid or openProfessionID() or productsPID
  productsWindow:UpdateTabs()
  productsWindow:Show()
  if productsPID then productsWindow:SelectTab("products") else productsWindow:SelectTab("overview") end
end

-- "Alle Produkte" of a profession with the recipe that makes itemID selected (button in the
-- market data window). A filter that hides it is set to everything.
function Products.ShowItem(pid, itemID)
  Products.Show(pid)
  local function find()
    for _, en in ipairs(productEntries(pid)) do
      if en.e and en.itemID == itemID then return en end
    end
  end
  local hit = find()
  if not hit then
    ns.db.ui = ns.db.ui or {}
    ns.db.ui.productsFilter, ns.db.ui.productsLevel = "all", "all"
    refreshProducts()
    hit = find()
  end
  if hit and productsSplit and productsSplit.Select then productsSplit.Select(hit.key) end
end

-- The overview (button in the profession book): closes the window when it shows the overview.
function Products.ShowOverview()
  if not productsWindow then createProducts() end
  if productsWindow.frame:IsShown() and productsWindow.current == "overview" then
    productsWindow.frame:Hide()
    return
  end
  productsWindow:Show()
  productsWindow:SelectTab("overview")
end

-- "Berufsübersicht" in Blizzard's profession window ("Berufe", K; loads on demand). In this client
-- the profession book is ProfessionsFrame itself (its overview page, side tabs per profession),
-- which every character can open, also one without professions. ProfessionsBookFrame is taken
-- where a client has the separate book.
local bookButton
local function attachBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if type(book) ~= "table" then book = rawget(_G, "ProfessionsFrame") end
  if bookButton or type(book) ~= "table" then return end
  local ok, b = pcall(CreateFrame, "Button", "M4CompanionBookOverview", book, "UIPanelButtonTemplate")
  if not ok or not b then return end
  b:SetText("Berufsübersicht")
  b:SetSize(140, 22)
  b:SetPoint("TOPRIGHT", book, "TOPRIGHT", -14, -26)
  b:SetFrameLevel((book:GetFrameLevel() or 0) + 10)
  b:SetScript("OnClick", function() ns.Safe(Products.ShowOverview) end)
  bookButton = b
end
if ns.On then
  ns.On("ADDON_LOADED", function(_, name)
    if name == "Blizzard_ProfessionsBook" or name == "Blizzard_Professions" then ns.Safe(attachBook) end
  end)
  ns.On("TRADE_SKILL_SHOW", function() ns.Safe(attachBook) end)
  ns.On("PLAYER_LOGIN", function()
    ns.Safe(attachBook)
    if hooksecurefunc and rawget(_G, "ToggleProfessionsBook") then
      hooksecurefunc("ToggleProfessionsBook", function() ns.Safe(attachBook) end)
    end
  end)
end

-- The tabs under the profession window look selected while their window is open.
function Products.SyncTab()
  local function set(tab, open)
    if not tab then return end
    local fn = open and PanelTemplates_SelectTab or PanelTemplates_DeselectTab
    if fn then pcall(fn, tab) end
  end
  set(Products.tab, productsWindow and productsWindow.frame:IsShown())
  local shop = ns.ShoppingList and ns.ShoppingList.Frame and ns.ShoppingList.Frame()
  set(Products.shopTab, shop and shop:IsShown())
  local plan = ns.PlanWindow and ns.PlanWindow.Frame and ns.PlanWindow.Frame()
  set(Products.planTab, plan and plan:IsShown())
  set(Products.ownPlanTab, plan and plan:IsShown())
  set(Products.ownShopTab, shop and shop:IsShown())
end

-- "Planer" leftmost under the profession window, only for crafting professions (PlanWindow.lua);
-- without it "Alle Produkte" moves to its place. Follows the open profession (TRADE_SKILL_SHOW,
-- and a switch inside the window: checked by the page's update).
function Products.UpdateTabs()
  local tab, plan = Products.tab, Products.planTab
  local pf = rawget(_G, "ProfessionsFrame")
  if not (tab and type(pf) == "table") then return end
  local pid = openProfessionID()
  Products.tabPID = pid or false
  local showPlan = plan ~= nil and ns.PlanWindow ~= nil and ns.PlanWindow.ForProfession(pid)
  tab:ClearAllPoints()
  if showPlan then
    plan:Show()
    tab:SetPoint("LEFT", plan, "RIGHT", 4, 0)
  else
    if plan then plan:Hide() end
    tab:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", 12, 2)
  end
  Products.SyncTab()
end

-- The tab: closes the window, unless it shows another profession (then it switches).
function Products.Toggle(pid)
  pid = pid or openProfessionID()
  if productsWindow and productsWindow.frame:IsShown() and productsWindow.current == "products"
    and (not pid or pid == productsPID) then
    productsWindow.frame:Hide()
  else
    Products.Show(pid)
  end
end

-- Item data arrives (the levels asked for by the level filter): the open list follows, once
-- per burst.
local levelRefresh = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
  if not (pendingLevels and productsWindow and productsWindow.frame:IsShown()) or levelRefresh then return end
  levelRefresh = true
  C_Timer.After(0.5, function()
    levelRefresh = false
    ns.Safe(refreshProducts)
  end)
end)

-- New live prices: the open list follows.
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function()
      if productsWindow and productsWindow.frame:IsShown() then ns.Safe(refreshProducts) end
    end)
  end
end)

local function profTrace(key, value)
  if ns.db then ns.db.professionsTrace = ns.db.professionsTrace or {}; ns.db.professionsTrace[key] = value end
end

local function recipeIDOf(row)
  local ok, node = pcall(function() return row:GetElementData() end)
  if not ok or type(node) ~= "table" then return nil end
  local data = node.GetData and node:GetData() or node
  local info = type(data) == "table" and data.recipeInfo
  return type(info) == "table" and info.recipeID or nil
end

local function updateList(list)
  local box = rawget(list, "ScrollBox")
  if type(box) ~= "table" or not box.ForEachFrame then return end
  local n = 0
  box:ForEachFrame(function(row)
    local id = recipeIDOf(row)
    local label = rawget(row, "Label")
    if not (id and type(label) == "table") then
      if row.m4Coins then row.m4Coins.Set(0) end -- a category row: no coins, name in place
      return
    end
    n = n + 1
    local e = ns.RecipeEconomics(id)
    if not row.m4Coins then row.m4Coins = ns.NativeWindow.Coins(row, label) end
    local coins, grey = 0, false
    if e and e.profit and e.onAH then coins, grey = ns.Coins(e.profit, e.cost, ns.Item(e.out).demand, ns.Item(e.out).saturation) end
    -- left of the skill-up arrow when it shows, else where it sits
    local ups = rawget(row, "SkillUps")
    row.m4Coins.Set(coins, type(ups) == "table" and ups.IsShown and ups:IsShown() and ups or nil, grey and "grey" or nil)
  end)
  profTrace("listRows", n)
end

-- The reagent slots of the schematic form (frames that carry a reagent schematic).
local function reagentSlots(form)
  local out = {}
  local slots = rawget(form, "reagentSlots")
  if type(slots) == "table" then
    for _, list in pairs(slots) do
      if type(list) == "table" then
        for _, slot in ipairs(list) do out[#out + 1] = slot end
      end
    end
  end
  return out
end

local function slotItem(slot)
  local s = rawget(slot, "reagentSlotSchematic")
  local reagent = type(s) == "table" and s.reagents and s.reagents[1]
  return reagent and reagent.itemID, s and s.quantityRequired
end

-- The "Im AH zeigen" buttons of the profession window: enabled while the auction house is open.
local ahButtons = {}
local function updateAHButtons(open)
  for _, b in ipairs(ahButtons) do b:SetEnabled(open) end
end
if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function() updateAHButtons(true) end)
  ns.On("AUCTION_HOUSE_CLOSED", function() updateAHButtons(false) end)
end

local function updateForm(form)
  local info = rawget(form, "currentRecipeInfo")
  if (type(info) ~= "table") and form.GetRecipeInfo then
    local ok, v = pcall(form.GetRecipeInfo, form)
    info = ok and v or nil
  end
  local id = type(info) == "table" and info.recipeID or nil
  local e = id and ns.RecipeEconomics(id)
  local fmt = function(c) return ns.FormatMoney(c, true) end
  local slots = reagentSlots(form)
  profTrace("slots", #slots)
  local lowest
  for _, slot in ipairs(slots) do
    local itemID, need = slotItem(slot)
    if not slot.m4Price then
      -- on the slot (hides with it when Blizzard puts the slot back in its pool), placed by
      -- the form's right edge
      slot.m4Price = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      slot.m4Price:SetJustifyH("RIGHT")
      local nameFS = rawget(slot, "Name") or (type(rawget(slot, "Button")) == "table" and rawget(slot.Button, "Name"))
      if type(nameFS) == "table" and nameFS.GetFontObject and nameFS:GetFontObject() then
        slot.m4Price:SetFontObject(nameFS:GetFontObject())
      end
    end
    -- right column of the form, on the height of the slot
    do
      local _, fy = form:GetCenter()
      local _, sy = slot:GetCenter()
      slot.m4Price:ClearAllPoints()
      if fy and sy then slot.m4Price:SetPoint("RIGHT", form, "RIGHT", -RIGHT_EDGE, sy - fy) end
    end
    local r = e and e.reagents and itemID and e.reagents[itemID]
    if itemID and r and r.unit then
      slot.m4Price:SetText(fmt(r.unit * (need or r.n)) .. "|cff999999  " .. (r.vendor and "H" or "AH") .. "|r")
    elseif itemID then
      slot.m4Price:SetText("|cffff6b6bkein Preis|r")
    else
      slot.m4Price:SetText("")
    end
    if slot:IsShown() then
      local b = slot:GetBottom()
      if b and (not lowest or b < lowest:GetBottom()) then lowest = slot end
    end
  end
  -- Summary: three rows like Blizzard's (gold label left, value right in the price column).
  if not form.m4Rows then
    form.m4Rows = {}
    for i, text in ipairs({ "Herstellkosten", "Erlös", "Gewinn" }) do
      local l = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      l:SetText(text)
      local v = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      v:SetJustifyH("RIGHT")
      form.m4Rows[i] = { label = l, value = v }
    end
  end
  local values
  if e and e.cost and e.value then
    local p = e.profit
    values = { fmt(e.cost), fmt(e.value) .. (e.onAH and "" or "|cff999999  H|r"),
      p >= 0 and ("|cff5fd38d+" .. fmt(p) .. "|r") or ("|cffff6b6b-" .. fmt(-p) .. "|r") }
  end
  -- a thin line between revenue and profit
  if not form.m4Line then
    form.m4Line = form:CreateTexture(nil, "ARTWORK")
    form.m4Line:SetColorTexture(1, 0.82, 0, 0.25)
    form.m4Line:SetHeight(1)
  end
  for i, row in ipairs(form.m4Rows) do
    row.label:ClearAllPoints()
    row.value:ClearAllPoints()
    local gap = i >= 3 and 7 or 0 -- room for the line before "Gewinn"
    if lowest then
      row.label:SetPoint("TOPLEFT", lowest, "BOTTOMLEFT", 0, -12 - (i - 1) * 14 - gap)
    else
      row.label:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 20, 60 - (i - 1) * 14 - gap)
    end
    if i == 3 then
      form.m4Line:ClearAllPoints()
      form.m4Line:SetPoint("BOTTOMLEFT", row.label, "TOPLEFT", 0, 3)
      local lx, fr = row.label:GetLeft(), form:GetRight()
      form.m4Line:SetWidth(lx and fr and math.max(1, fr - RIGHT_EDGE - lx) or 200)
      form.m4Line:SetShown(values ~= nil)
    end
    local _, fy = form:GetCenter()
    local _, ly = row.label:GetCenter()
    if fy and ly then row.value:SetPoint("RIGHT", form, "RIGHT", -RIGHT_EDGE, ly - fy) end
    row.label:SetShown(values ~= nil)
    row.value:SetText(values and values[i] or "")
  end
  -- "Einkaufsliste" under the profit: the recipe with the count of Blizzard's number box onto
  -- the shopping list (ShoppingList.lua), which opens
  if not form.m4Shop then
    local ok, b = pcall(CreateFrame, "Button", nil, form, "UIPanelButtonTemplate")
    if ok and b then
      b:SetSize(110, 20)
      b:SetText("Einkaufsliste")
      b:SetScript("OnClick", function()
        local rid = b.m4Recipe
        if not (rid and ns.ShoppingList) then return end
        local box = form.m4Page and rawget(form.m4Page, "CreateMultipleInputBox")
        local n = 1
        if type(box) == "table" and box.GetValue then
          local okV, v = pcall(box.GetValue, box)
          if okV and tonumber(v) and tonumber(v) > 0 then n = tonumber(v) end
        end
        if ns.ShoppingList.Add(rid, n) then ns.ShoppingList.Show(rid) end
      end)
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Auf die Einkaufsliste")
        GameTooltip:AddLine("So oft wie im Zahlenfeld unten (sonst 1×); was dein Haushalt hat, wird abgezogen.", 1, 1, 1, true)
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
      form.m4Shop = b
    end
  end
  if form.m4Shop then
    local gewinn = form.m4Rows[3].value
    form.m4Shop.m4Recipe = id
    form.m4Shop:ClearAllPoints()
    form.m4Shop:SetPoint("TOPRIGHT", gewinn, "BOTTOMRIGHT", 0, -10)
    form.m4Shop:SetShown(values ~= nil and e and e.out ~= nil)
  end
  -- "Im AH zeigen" under it: the product in the auction house's own search (Deals.Search), to
  -- see the offers and buy as usual; greyed out while the auction house is closed
  if not form.m4ShowAH then
    local ok, b = pcall(CreateFrame, "Button", nil, form, "UIPanelButtonTemplate")
    if ok and b then
      b:SetSize(110, 20)
      b:SetText("Im AH zeigen")
      b:SetMotionScriptsWhileDisabled(true) -- the tooltip says why it is grey
      b:SetScript("OnClick", function(self)
        if self.m4Item and ns.Deals and ns.AHSearch and ns.AHSearch.IsOpen() then
          ns.Safe(ns.Deals.Search, self.m4Item)
        end
      end)
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Im Auktionshaus zeigen")
        if self:IsEnabled() then
          GameTooltip:AddLine("Sucht " .. (self.m4Item and ns.ItemName(self.m4Item) or "das Produkt")
            .. " im Auktionshaus: Angebote ansehen und wie gewohnt kaufen.", 1, 1, 1, true)
        else
          GameTooltip:AddLine("Erst das Auktionshaus öffnen.", 1, 0.42, 0.42, true)
        end
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
      form.m4ShowAH = b
      ahButtons[#ahButtons + 1] = b
    end
  end
  if form.m4ShowAH then
    local b = form.m4ShowAH
    b.m4Item = e and e.out
    b:ClearAllPoints()
    if form.m4Shop then
      b:SetPoint("TOPRIGHT", form.m4Shop, "BOTTOMRIGHT", 0, -4)
    else
      b:SetPoint("TOPRIGHT", form.m4Rows[3].value, "BOTTOMRIGHT", 0, -10)
    end
    b:SetShown(values ~= nil and e and e.out ~= nil)
    b:SetEnabled(ns.AHSearch and ns.AHSearch.IsOpen() or false)
  end
end

local function attachProfessions()
  local pf = rawget(_G, "ProfessionsFrame")
  local page = type(pf) == "table" and rawget(pf, "CraftingPage")
  if type(page) ~= "table" or page.m4Info then
    profTrace("frame", type(pf) == "table" and (type(page) == "table" and "page" or "no page") or "no ProfessionsFrame")
    return
  end
  local list, form = rawget(page, "RecipeList"), rawget(page, "SchematicForm")
  if type(form) == "table" then form.m4Page = page end
  profTrace("frame", "list=" .. type(list) .. " form=" .. type(form))
  local layer = CreateFrame("Frame", nil, page)
  page.m4Info = layer
  -- "Alle Produkte": a tab under the profession window (Blizzard's tab template), like the
  -- trade book's tab under the auction house was; shown selected while the window is open
  local okT, tab = pcall(CreateFrame, "Button", "M4CompanionProductsTab", pf, "PanelTabButtonTemplate")
  if okT and tab then
    tab:SetText("Alle Produkte")
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
    tab:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", 12, 2)
    Products.tab = tab
    -- "Planer" left of it (PlanWindow.lua), for crafting professions (Products.UpdateTabs)
    local okP, plan = pcall(CreateFrame, "Button", "M4CompanionPlannerTab", pf, "PanelTabButtonTemplate")
    if okP and plan then
      plan:SetText("Planer")
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, plan, 0) end
      plan:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", 12, 2)
      plan:SetScript("OnClick", function() if ns.PlanWindow then ns.Safe(ns.PlanWindow.Toggle) end end)
      Products.planTab = plan
    end
    tab:SetScript("OnClick", function() ns.Safe(Products.Toggle) end)
    -- "Einkaufsliste" next to it (ShoppingList.lua): the list is always one click away
    local okS, shop = pcall(CreateFrame, "Button", "M4CompanionShoppingTab", pf, "PanelTabButtonTemplate")
    if okS and shop then
      shop:SetText("Einkaufsliste")
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, shop, 0) end
      shop:SetPoint("LEFT", tab, "RIGHT", 4, 0)
      shop:SetScript("OnClick", function() if ns.ShoppingList then ns.Safe(ns.ShoppingList.Toggle) end end)
      Products.shopTab = shop
    end
    Products.UpdateTabs()
  end
  local elapsed = 0
  layer:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.4 then return end
    elapsed = 0
    -- another profession opened inside the window: the planner tab follows
    if Products.tab and (openProfessionID() or false) ~= Products.tabPID then ns.Safe(Products.UpdateTabs) end
    if type(list) == "table" then ns.Safe(updateList, list) end
    if type(form) == "table" and form:IsShown() then ns.Safe(updateForm, form) end
  end)
end

if ns.On then
  ns.On("TRADE_SKILL_SHOW", function()
    ns.Safe(attachProfessions)
    ns.Safe(Products.UpdateTabs)
    if C_Timer then
      C_Timer.After(0.3, function()
        ns.Safe(attachProfessions)
        ns.Safe(Products.UpdateTabs)
      end)
    end
  end)
end
