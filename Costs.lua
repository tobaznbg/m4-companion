-- Costs: profession helpers for the planner. Prices come from ns.Item only.
local ADDON, ns = ...

local Costs = {}
ns.Costs = Costs

-- Copper per unit to buy a reagent, and where ("Händler" or "AH").
function Costs.Buy(itemID)
  local unit, vendor = ns.Item.BuyCost(ns.Item(itemID))
  if not unit then return nil end
  return unit, vendor and "Händler" or "AH"
end

function Costs.VendorSell(itemID)
  return ns.Item(itemID).vendorSell or 0
end

-- Copper per unit an auction brings (Item.SellNet), or nil if it only goes to a merchant.
function Costs.AuctionSell(itemID)
  local net, viaAH = ns.Item.SellNet(ns.Item(itemID))
  return viaAH and net or nil
end

-- Units in bags and bank: the larger of the game's count and the last bag/bank scan
-- (ns.db.inventory; the bank only counts once it was opened).
function Costs.Owned(itemID)
  local count = (C_Item and C_Item.GetItemCount) or GetItemCount
  local n = count and count(itemID, true) or 0
  local inv = ns.db and ns.db.inventory and ns.CharKey and ns.db.inventory[ns.CharKey()]
  if inv then
    local stored = 0
    for _, place in ipairs({ inv.bags or {}, inv.bank or {} }) do
      local e = place[itemID]
      stored = stored + (e and e.n or 0)
    end
    n = math.max(n, stored)
  end
  return n
end

-- Units on offer at the auction house now (listed quantity), or nil if not known.
function Costs.Supply(itemID)
  local e = ns.Item(itemID)
  if e.vendorBuy then return nil end
  local listings = ns.Item.Listings and ns.Item.Listings(itemID)
  if listings and #listings > 0 then
    local n = 0
    for _, l in ipairs(listings) do n = n + l.count end
    return n, listings
  end
  return e.quantity
end

-- Copper per unit when buying `count` units at the auction house: the cheapest offers
-- first; units beyond the listed supply count at SCARCE_FACTOR times the dearest offer
-- (they have to wait for new listings or be farmed). Second value: true when the supply
-- is short. nil without a price.
Costs.SCARCE_FACTOR = 2
function Costs.BuyMany(itemID, count)
  local unit, where = Costs.Buy(itemID)
  if not unit or where == "Händler" or count <= 0 then return unit, false end
  local supply, listings = Costs.Supply(itemID)
  if not supply then return unit, false end
  local have = Costs.Owned(itemID)
  local buy = count - have
  if buy <= 0 then return unit, false end
  local total, left, top = 0, buy, unit
  for _, l in ipairs(listings or {}) do
    if left <= 0 then break end
    local take = math.min(left, l.count)
    total, left, top = total + take * l.unit, left - take, l.unit
  end
  if not listings then
    local take = math.min(left, supply)
    total, left = total + take * unit, left - take
  end
  local short = left > 0
  total = total + left * top * Costs.SCARCE_FACTOR
  -- Owned units count at the normal price (they could be sold instead).
  return math.ceil((total + have * unit) / count), short
end

-- Character context for the planner's ways (Planner.Options): faction, level, Merchant's
-- Favor (currency 3402) and reputation standings by faction name.
Costs.FAVOR_CURRENCY = 3402
function Costs.Context()
  local char = ns.db and ns.db.chars and ns.CharKey and ns.db.chars[ns.CharKey()] or {}
  local factionName = (UnitFactionGroup and UnitFactionGroup("player")) or char.faction
  local ctx = {
    faction = factionName == "Horde" and "H" or (factionName == "Alliance" and "A" or nil),
    level = (UnitLevel and UnitLevel("player")) or char.level,
  }
  local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(Costs.FAVOR_CURRENCY)
  if info and info.quantity then ctx.favor = info.quantity end
  local standings
  local function readStandings()
    standings = {}
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
      for i = 1, C_Reputation.GetNumFactions() do
        local f = C_Reputation.GetFactionDataByIndex(i)
        if f and f.name and not f.isHeader then standings[f.name] = f.reaction end
      end
    elseif GetNumFactions and GetFactionInfo then
      for i = 1, GetNumFactions() do
        local name, _, standingID, _, _, _, _, _, isHeader = GetFactionInfo(i)
        if name and not isHeader then standings[name] = standingID end
      end
    end
  end
  function ctx.standing(name)
    if not standings then readStandings() end
    return standings[name]
  end
  return ctx
end

-- Copper of a tradeable pattern on offer at the auction house now, if not far above its
-- usual price; nil otherwise.
function Costs.PatternPrice(itemID)
  local e = ns.Item(itemID)
  if not e.now then return nil end
  if e.ref and e.ref > 0 and e.now > e.ref * ns.Planner.AH_PATTERN_OVER_REF then return nil end
  return e.now
end

-- Skill data of a profession from ns.SkillData, or nil (placeholder or not generated yet).
local function skillData(professionID)
  local skill = ns.SkillData and ns.SkillData[professionID]
  if type(skill) == "table" and type(skill.recipes) == "table" and next(skill.recipes) then return skill end
end
Costs.SkillData = skillData

-- The character's own profession scans by profession ID.
local function ownScans(charKey)
  local own, prefix = {}, (charKey or ns.CharKey()) .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID then own[scan.professionID] = scan end
  end
  return own
end

-- Rank and cap of a profession: the character snapshot is newer than the last time
-- the profession window was opened.
local function ownSkill(name, scan, charKey)
  local rank, max = scan and scan.rank, scan and scan.max
  local char = ns.db.chars and ns.db.chars[charKey or ns.CharKey()]
  for _, prof in ipairs(char and char.professions or {}) do
    if name and prof.name == name then rank, max = prof.rank or rank, prof.max or max end
  end
  return rank, max
end

local function professionName(professionID, scan)
  local recipeData = ns.RecipeData and ns.RecipeData[professionID]
  local skill = ns.SkillData and ns.SkillData[professionID]
  return (scan and scan.profession) or (recipeData and recipeData.name) or (skill and skill.name)
end

-- Latest recipe scan of the player's professions that have planner data:
-- returns a list of { scan, data, rank, max, name, pid, skill }.
function Costs.Professions()
  local list = {}
  for pid, scan in pairs(ownScans()) do
    local skill = skillData(pid)
    local data = skill and skill.recipes or (ns.DataBySkillLine and ns.DataBySkillLine[pid])
    if data then
      local rank, max = ownSkill(scan.profession, scan)
      table.insert(list, { scan = scan, data = data, rank = rank, max = max, name = scan.profession,
        pid = pid, skill = skill })
    end
  end
  return list
end

-- Planner input for any crafting profession, also one the character does not have:
-- { pid, name, scan (own, or nil), rank, max (nil when not learned), skill, data }.
-- Without data the second value says why: "nodata" (no skill data for the profession)
-- or "noscan" (only the old data, which needs the own scan for reagents and products).
function Costs.Profession(professionID, charKey)
  local scan = ownScans(charKey)[professionID]
  local name = professionName(professionID, scan)
  local rank, max = ownSkill(name, scan, charKey)
  local prof = { pid = professionID, name = name, scan = scan, rank = rank, max = max }
  local skill = skillData(professionID)
  if skill then
    prof.skill, prof.data = skill, skill.recipes
    return prof
  end
  local data = ns.DataBySkillLine and ns.DataBySkillLine[professionID]
  if not data then return nil, "nodata", prof end
  if not scan then return nil, "noscan", prof end
  prof.data = data
  return prof
end

-- All crafting professions for a choice: { pid, name, icon, rank, max, own, hasData }...,
-- own professions first (highest skill first), then by name.
function Costs.AllProfessions()
  local ids, own = {}, ownScans()
  for pid in pairs(ns.RecipeData or {}) do ids[pid] = true end
  for pid in pairs(ns.SkillData or {}) do ids[pid] = true end
  local list = {}
  for pid in pairs(ids) do
    local name = professionName(pid, own[pid])
    if name then
      local rank, max = ownSkill(name, own[pid])
      local recipeData = ns.RecipeData and ns.RecipeData[pid]
      table.insert(list, { pid = pid, name = name, icon = recipeData and recipeData.icon,
        rank = rank, max = max, own = rank ~= nil,
        hasData = skillData(pid) ~= nil or (own[pid] ~= nil and ns.DataBySkillLine ~= nil
          and ns.DataBySkillLine[pid] ~= nil) })
    end
  end
  table.sort(list, function(a, b)
    if a.own ~= b.own then return a.own end
    if a.own and a.rank ~= b.rank then return a.rank > b.rank end
    return a.name < b.name
  end)
  return list
end

-- Candidate recipes of a profession (Planner.Candidates): from ns.SkillData when there is
-- an entry, else from the own scan with the old color/learn data.
--   way   true: every recipe (profit views); "standard" (default) or "dynamic" (see
--         Planner.WAYS); with ns.RecipeSources for the profession the way decides which
--         patterns count, without it only learned and trainer recipes do
--   buy   copper per reagent unit (default Costs.Buy)
function Costs.Candidates(prof, way, buy)
  local opts = way == true or {
    way = way or "standard",
    sources = ns.RecipeSources and ns.RecipeSources[prof.pid],
    ctx = prof.ctx or Costs.Context(),
    patternPrice = Costs.PatternPrice,
    rank = prof.rank,
  }
  buy = buy or Costs.Buy
  if prof.skill then
    return ns.Planner.Candidates(ns.Planner.SkillRecipes(prof.skill, prof.scan), prof.skill.recipes,
      buy, Costs.VendorSell, Costs.AuctionSell, opts)
  end
  return ns.Planner.Candidates(prof.scan.recipes, prof.data,
    buy, Costs.VendorSell, Costs.AuctionSell, opts)
end

-- Skill path of a profession in one way, with the material supply at the auction house
-- taken into account: a reagent needed in larger numbers than offered gets the price of
-- buying that many (Costs.BuyMany), and the path is planned again (up to PLAN_ROUNDS).
-- Returns { segments, total, reached, skipped, need, made, scarce = { [itemID] = true },
--           missing (Planner.Missing at the end of the way) }.
-- Material the household already has (bags and bank of every character, ns.ShoppingList.Holdings)
-- costs what selling it would bring (decided 20 Nov 2026: stock is used up first, but is not
-- free); what is needed beyond the stock is bought. The first round assumes the stock covers
-- it, later rounds mix both by the counts of the plan.
Costs.PLAN_ROUNDS = 4
local function stockValue(itemID, buyPrice)
  local sell = ns.Item and ns.Item.SellNet and ns.Item.SellNet(ns.Item(itemID)) or 0
  if not buyPrice then return sell end
  return math.min(sell, buyPrice)
end
local function holdings(itemID)
  local H = ns.ShoppingList and ns.ShoppingList.Holdings
  return H and (H(itemID)) or 0
end

function Costs.Plan(prof, from, to, ahCap, way)
  local prices, scarce = {}, {}
  local function buy(itemID)
    if prices[itemID] then return prices[itemID] end
    local base = Costs.Buy(itemID)
    if holdings(itemID) > 0 then return stockValue(itemID, base) end
    return base
  end
  local result
  for _ = 1, Costs.PLAN_ROUNDS do
    local candidates, skipped = Costs.Candidates(prof, way, buy)
    local segments, total, reached = ns.Planner.Path(candidates, from, to, ahCap)
    local need, made = {}, {}
    if segments then need, made = ns.Planner.Shopping(segments) end
    result = { segments = segments, total = total, reached = reached or from, skipped = skipped,
      need = need, made = made, scarce = scarce }
    local changed = false
    for itemID, count in pairs(need) do
      local have = math.min(holdings(itemID), count)
      local rest = count - have
      local unit, short = Costs.BuyMany(itemID, math.max(1, rest))
      if short and rest > 0 then scarce[itemID] = true end
      local current = buy(itemID)
      local price = unit
      if have > 0 then
        -- stock at its sale value, the rest at the price of buying that many
        local stock = stockValue(itemID, Costs.Buy(itemID))
        price = (have * stock + rest * (unit or stock)) / count
      end
      if price and current and math.abs(price - current) > current * 0.02 + 1 then
        prices[itemID] = price
        changed = true
      end
    end
    if not changed then break end
  end
  local srcs = ns.RecipeSources and ns.RecipeSources[prof.pid]
  if srcs and result.reached < to then
    local recipes = prof.skill and ns.Planner.SkillRecipes(prof.skill, prof.scan) or prof.scan.recipes
    result.missing = ns.Planner.Missing(recipes, prof.skill and prof.skill.recipes or prof.data, srcs,
      prof.ctx or Costs.Context(), result.reached, way or "standard", Costs.PatternPrice)
  end
  result.prices = prices
  return result
end
