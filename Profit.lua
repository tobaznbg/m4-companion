-- Profit: profit and loss per profession from the trading ledger (Ledger.lua).
--
-- The ledger is replayed oldest first with a moving average cost per item (not FIFO):
-- auction house goods are interchangeable, stacks merge in the bags and the ledger does not
-- see every unit (farmed material, crafts before the ledger existed), so single lots cannot
-- be followed anyway; an average is robust against such gaps and needs no lot bookkeeping.
--
-- Two pools per item:
--   bought   units bought at the auction house, at their average purchase price
--   crafted  units the player made, at their average cost (external + internal material)
-- A craft takes each reagent from the crafted pool first (own intermediate, e.g. a bolt of
-- cloth: its cost moves into the product, it is no new material), then from the bought pool
-- (material at purchase price), the rest is farmed / not bought and costs 0 (Tobias' rule).
-- A sale takes units from the crafted pool first (they count for the profession), then
-- from the bought pool (group TRADE: bought and sold again, their purchase price is the cost),
-- the rest was made with a learned recipe before crafts were logged (its profession, material
-- 0 like farmed) or farmed / looted (group FARMED, cost 0). Revenue and cut pro rata.
-- Sales logged before item ids were recorded carry only the name; it is looked up.
-- Expired and cancelled auctions of an item lose the deposit of its posts (average
-- deposit per unit of the item's posts; posts before deposits were logged count 0).
--
-- Figures (copper):
--   revenue       sale price before the cut (gross)
--   fees          auction house cut + lost deposits (cut and depositsLost also separate)
--   materials     bought reagents used by crafts (farmed = 0); for TRADE the purchase price
--   cost          what the sold units cost (soldCost; Eigenbedarf: what was spent)
--   profit        revenue - cost - fees: unsold units (crafted or bought) are stock, no loss
--   stock         units not sold or used yet x their average cost (now, not "since"):
--                 crafted units in their profession, bought units in TRADE
-- Per item also (in the period): bought / spent (units and copper bought at the auction
-- house, TRADE rows), soldCost (cost of the sold units taken from the pools: crafted at
-- their average cost, bought at the purchase price, farmed 0), expired / cancelled (how
-- many auctions came back: number of mails, not units).
-- Per sold unit (nil without sales): avgPrice (revenue / sold, gross), soldUnitCost
-- (soldCost / sold), unitProfit ((revenue - cut - soldCost) / sold; lost deposits are not
-- in it, they are per auction, not per unit sold).
-- Note: materials are booked when crafting, soldCost when selling. For a crafted item the
-- period's profit therefore counts the material of all units made, soldCost only that of
-- the units sold (the rest is stock).
-- "since" (epoch, nil = all) filters the figures by event time; the pools always replay the
-- whole ledger, so costs stay right.
--
-- ns.Profit.Professions(since) -> { { name, revenue, materials, fees, cut, depositsLost,
--   profit, stockUnits, stockValue, crafted, sold, bought, spent, soldCost, expired,
--   cancelled }... } sorted by profit
-- ns.Profit.Items(professionName, since) -> { { itemId, name, crafted, sold, revenue,
--   materials, fees, cut, depositsLost, profit, stockUnits, stockValue, unitCost, bought,
--   spent, soldCost, expired, cancelled, avgPrice, soldUnitCost, unitProfit }... } sorted by
--   profit
-- ns.Profit.Totals(since) -> { revenue, materials, fees, cut, depositsLost, profit,
--   stockUnits, stockValue }
-- ns.Profit.Report(since) -> { groups = Professions, items = { [group] = Items },
--   totals = Totals, stock, stockTotals = Stock() } from one replay (the ledger page)
-- ns.Profit.Stock() -> list, totals: per item units left (crafted + bought pool), cost
--   (Einstand), market value now (ns.Item(id).now x units, nil without a price) and the
--   difference; sellUnit / sell (Item.SellNet per unit / x units: selling after the cut),
--   gain (Buchgewinn = sell - cost) and gainPct (sellUnit / unitCost - 1, nil at cost 0);
--   totals { units, cost, market, pricedCost, diff, unpriced, sell, sellCost, gain, capped }
--   (market and diff over the items with a price only, unpriced = items without one; sell
--   and gain over the items with a selling price; capped = held counts known)
-- ns.Profit.Snapshot() / WriteSnapshot(): stock snapshot for the server (see there)
-- ns.Profit.ItemEvents(itemID, since) -> the item's events, newest first, as
--   { t, k, u, c, cut, p, dep, lost } (lost: deposit lost by an expired/cancelled auction)
local ADDON, ns = ...

local cached, cachedKey, cachedAt = nil, nil, 0 -- whole-ledger replay cache, see replayAll
local heldCache, heldAt = nil, 0 -- what the character holds, for UnitCost (refreshed every 2 s)

local Profit = ns.Profit or {}
ns.Profit = Profit

local UNKNOWN = "Unbekannt"
local TRADE = "Handel (gekauft, verkauft)"
local FARMED = "Gesammelt (Farm, Beute)"
-- Own use ("Eigenbedarf", decided 20 Nov 2026): bought for oneself, not to resell - an
-- expense, not trade. An item counts as own use when
--   1. marked by hand (ns.db.settings.ownUse[itemID] = true; false = always trade), else
--   2. it was the tool of a craft (craft events with tool = itemID), else
--   3. it was bought, never posted, sold or brought to a vendor, and no household character
--      holds it any more (bags, bank, auctions): used up, equipped, eaten; only when every
--      bank is known (heldCounts).
local OWN = "Eigenbedarf"
Profit.TRADE, Profit.FARMED, Profit.OWN = TRADE, FARMED, OWN

local function ownMarks()
  local s = ns.db and ns.db.settings
  return s and s.ownUse or {}
end

-- Marks an item as own use (true), trade (false) or back to the automatic rules (nil); the
-- settings travel with the state sync.
function Profit.SetOwnUse(itemID, value)
  if not (ns.db and itemID) then return end
  ns.db.settings = ns.db.settings or {}
  ns.db.settings.ownUse = ns.db.settings.ownUse or {}
  ns.db.settings.ownUse[itemID] = value
  if Profit.Invalidate then Profit.Invalidate() end
end
function Profit.OwnUseMark(itemID) return ownMarks()[itemID] end

-- Character filter (the ledger window's choice): the figures count only this character's events;
-- the pools (cost of goods) still run over the whole household. nil = every character.
local charFilter = nil
function Profit.SetCharFilter(key) charFilter = key end
function Profit.CharFilter() return charFilter end
local function charOK(e)
  return not charFilter or not (ns.Ledger and ns.Ledger.CharOf) or ns.Ledger.CharOf(e) == charFilter
end

-- Gathered goods count for their gathering profession, not as loot: leather, hides and scales
-- for skinning, ore, stone and gems for mining, herbs for herbalism (ns.Gathering).
local gatherOf
local function farmGroup(itemID)
  if not gatherOf then
    gatherOf = {}
    for _, g in ipairs(ns.Gathering or {}) do
      if g.source and g.source ~= "" then
        for _, it in ipairs(g.items or {}) do
          if it[1] and not gatherOf[it[1]] then gatherOf[it[1]] = g.source end
        end
      end
    end
  end
  return gatherOf[itemID] or FARMED
end
Profit.FarmGroup = farmGroup

-- The areas without a purchase price (loot and the gathering professions).
function Profit.IsFarmed(group)
  if group == FARMED then return true end
  for _, g in ipairs(ns.Gathering or {}) do
    if g.source ~= "" and g.source == group then return true end
  end
  return false
end

-- itemID of a ledger event: its id, else looked up by name (older events).
local byName
local function idOf(e)
  if e.i then return e.i end
  if not e.n then return nil end
  if not byName then
    byName = {}
    for id, name in pairs(ns.ItemNames or {}) do byName[name] = id end
  end
  return byName[e.n]
end

local function pool(pools, itemID)
  local p = pools[itemID]
  if not p then
    p = { q = 0, v = 0 }
    pools[itemID] = p
  end
  return p
end

-- Takes up to n units from a pool at its average cost: units taken, their value.
local function take(p, n)
  if not p or p.q <= 0 or n <= 0 then return 0, 0 end
  local k = math.min(n, p.q)
  local v = p.v * k / p.q
  p.q, p.v = p.q - k, p.v - v
  if p.q <= 0 then p.q, p.v = 0, 0 end
  return k, v
end

local function newFigures()
  return { revenue = 0, materials = 0, fees = 0, cut = 0, depositsLost = 0, crafted = 0, sold = 0,
    bought = 0, spent = 0, soldCost = 0, expired = 0, cancelled = 0, used = 0, usedValue = 0, usedBy = {}, usedByN = {} }
end

-- Replays the ledger: per item figures in the period and the pools at the end.
-- lost: event -> deposit lost (expired / cancelled with a known deposit).
-- Cost per unit the player entered by hand (ItemDetail "Einstand eintragen"), for items whose
-- purchase the ledger never saw (bought before the addon ran). Kept in the settings, so the
-- sync between PCs carries it.
local function manualCost(itemID)
  local m = ns.db and ns.db.settings and ns.db.settings.manualCost
  local v = m and (m[itemID] or m[tostring(itemID)])
  return type(v) == "number" and v > 0 and v or nil
end
Profit.ManualCost = manualCost

function Profit.SetManualCost(itemID, copper)
  ns.db.settings = ns.db.settings or {}
  ns.db.settings.manualCost = ns.db.settings.manualCost or {}
  ns.db.settings.manualCost[itemID] = copper and copper > 0 and math.floor(copper + 0.5) or nil
  ns.db.settings.manualCost[tostring(itemID)] = nil
  cached = nil
end

-- "65g 20s", "65g", "20s 5c", "65" (gold), "65,5" (gold) -> copper, or nil.
function Profit.ParseMoney(text)
  if type(text) ~= "string" then return nil end
  local t = text:lower():gsub("%s+", "")
  if t == "" then return nil end
  local plain = t:gsub(",", ".")
  if plain:match("^%d+%.?%d*$") then return math.floor(tonumber(plain) * 10000 + 0.5) end
  local total, any = 0, false
  for digits, unit in t:gmatch("(%d+)([gsck])") do
    any = true
    local v = tonumber(digits)
    if unit == "g" then total = total + v * 10000
    elseif unit == "s" then total = total + v * 100
    else total = total + v end
  end
  local rest = t:gsub("%d+[gsck]", "")
  if not any or rest ~= "" then return nil end
  return total
end

local function replay(since)
  local events = ns.Ledger and (ns.Ledger.HouseholdEvents or ns.Ledger.Events) and (ns.Ledger.HouseholdEvents or ns.Ledger.Events)() or {}
  local bought, crafted = {}, {}
  local profOf = {}     -- itemID -> profession name (last craft)
  local depo = {}       -- itemID -> { u, dep } of posts with a known deposit
  local items = {}      -- itemID -> figures (crafted items, grouped by profession later)
  local other = {}      -- TRADE / FARMED -> itemID -> figures
  local everBought = {} -- itemID -> true
  local lost = {}
  local traded = {}     -- itemID -> true: posted, sold, vendored, expired or cancelled once
  local tools = {}      -- itemID -> true: the tool of a craft
  local usedBy = {}     -- itemID -> { [profession] = units of the bought pool used in its crafts }
  local craftProfs = {} -- profession -> true: crafted with in this household
  local function figures(itemID, group)
    local t = items
    if group then
      other[group] = other[group] or {}
      t = other[group]
    end
    local f = t[itemID]
    if not f then
      f = newFigures()
      t[itemID] = f
    end
    return f
  end

  for _, e in ipairs(events) do
    local inPeriod = (not since or (e.t or 0) >= since) and charOK(e)
    local id, u = idOf(e), e.u or 0
    if id and e.k == "buy" then
      everBought[id] = true
      local p = pool(bought, id)
      p.q, p.v = p.q + u, p.v + (e.c or 0)
      if inPeriod then
        local f = figures(id, TRADE)
        f.bought, f.spent = f.bought + u, f.spent + (e.c or 0)
      end
    elseif id and e.k == "craft" and u > 0 then
      if e.tool then tools[e.tool] = true end
      local external, internal = 0, 0
      for _, g in ipairs(e.r or {}) do
        if g.i and g.n then
          local k, v = take(crafted[g.i], g.n)
          internal = internal + v
          local kb, bv = take(bought[g.i], g.n - k)
          external = external + bv
          if kb > 0 then
            local by = usedBy[g.i] or {}
            usedBy[g.i] = by
            by[e.prof or UNKNOWN] = (by[e.prof or UNKNOWN] or 0) + kb
            if inPeriod then
              local f = figures(g.i, TRADE)
              f.used, f.usedValue = f.used + kb, f.usedValue + bv
              f.usedBy[e.prof or UNKNOWN] = (f.usedBy[e.prof or UNKNOWN] or 0) + bv
              f.usedByN[e.prof or UNKNOWN] = (f.usedByN[e.prof or UNKNOWN] or 0) + kb
            end
          end
        end
      end
      local p = pool(crafted, id)
      p.q, p.v = p.q + u, p.v + external + internal
      profOf[id] = e.prof or profOf[id] or UNKNOWN
      if e.prof then craftProfs[e.prof] = true end
      if inPeriod then
        local f = figures(id)
        f.crafted, f.materials = f.crafted + u, f.materials + external
      end
    elseif id and e.k == "post" then
      traded[id] = true
      if e.dep and u > 0 then
        local d = depo[id] or { u = 0, dep = 0 }
        d.u, d.dep = d.u + u, d.dep + e.dep
        depo[id] = d
      end
    elseif id and (e.k == "sale" or e.k == "vendor") and u > 0 then
      traded[id] = true
      local k, cv = take(crafted[id], u)
      local kb, bv = take(bought[id], u - k)
      local function book(n, group, cost, value)
        if n <= 0 or not inPeriod then return end
        local f = figures(id, group)
        local share = n / u
        local cut = (e.cut or 0) * share
        f.sold = f.sold + n
        f.revenue = f.revenue + (e.c or 0) * share
        f.cut, f.fees = f.cut + cut, f.fees + cut
        f.materials = f.materials + (cost or 0)
        f.soldCost = f.soldCost + (value or 0)
      end
      book(k, nil, 0, cv)
      book(kb, TRADE, bv, bv)
      -- Not crafted per the log and not bought: made with a learned recipe before crafts were
      -- logged (material counts 0 like farmed), else farmed or looted.
      local rest = u - k - kb
      local manual = manualCost(id)
      if manual then
        -- Bought before the ledger ran, cost entered by hand: a trade at that cost.
        book(rest, TRADE, manual * rest, manual * rest)
      else
        local maker = ns.CraftedBy and ns.CraftedBy(id)
        if maker and not profOf[id] then profOf[id] = maker end
        book(rest, not maker and farmGroup(id) or nil, 0, 0)
      end
    elseif id and (e.k == "expired" or e.k == "cancelled") then
      traded[id] = true
      local d = depo[id]
      local amount = d and d.u > 0 and d.dep / d.u * u or 0
      if amount > 0 then lost[e] = amount end
      if inPeriod then
        -- Same area as its sales: an item of a learned recipe belongs to that profession.
        local maker = not profOf[id] and ns.CraftedBy and ns.CraftedBy(id)
        if maker then profOf[id] = maker end
        local group = not profOf[id] and ((everBought[id] or manualCost(id)) and TRADE or farmGroup(id)) or nil
        local f = figures(id, group)
        f[e.k] = f[e.k] + 1
        f.depositsLost, f.fees = f.depositsLost + amount, f.fees + amount
      end
    end
  end
  return items, crafted, profOf, other, bought, lost, { traded = traded, tools = tools, everBought = everBought, usedBy = usedBy, craftProfs = craftProfs }
end

-- The profession a bought item is material of, from the item itself: a reagent of that
-- profession's recipes (ns.RecipeData). Used in several professions: the one whose crafts used
-- most of it in this household, else the one with the most recipes needing it. nil: no reagent.
local reagentIndex
local function reagentProfessions(id)
  if not reagentIndex then
    reagentIndex = {}
    for _, data in pairs(ns.RecipeData or {}) do
      for _, rec in pairs(data.recipes or {}) do
        local list = rec[4] or {}
        for i = 1, #list, 2 do
          local r = list[i]
          if r then
            local by = reagentIndex[r] or {}
            reagentIndex[r] = by
            by[data.name] = (by[data.name] or 0) + 1
          end
        end
      end
    end
  end
  return reagentIndex[id]
end

-- Professions of the household: scanned by one of its characters or crafted with (ledger).
local function ownProfessions(act)
  local own = {}
  for prof in pairs(act and act.craftProfs or {}) do own[prof] = true end
  local chars = {}
  for _, key in ipairs(ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or {}) do chars[key] = true end
  for key, scan in pairs(ns.db and ns.db.recipes or {}) do
    local char = type(key) == "string" and key:match("^(.-):")
    if type(scan) == "table" and scan.profession and (chars[char] or not next(chars)) then own[scan.profession] = true end
  end
  return own
end

-- Only professions of the household count: a reagent of none of them stays in TRADE. What a
-- gathering profession of the household yields (leather: Kürschnerei, fish: Angeln) belongs to
-- it, also when bought; a crafting profession using it gets it handed over at cost (usedBy).
local function materialOf(id, act, own)
  own = own or ownProfessions(act)
  local gather = farmGroup(id)
  if gather ~= FARMED and own[gather] then return gather end
  local recipes = reagentProfessions(id)
  if not recipes then return nil end
  local best, n = nil, 0
  for prof, units in pairs(act and act.usedBy[id] or {}) do
    if recipes[prof] and own[prof] and units > n then best, n = prof, units end
  end
  if best then return best end
  for prof, count in pairs(recipes) do
    if own[prof] and (count > n or (count == n and best and prof < best)) then best, n = prof, count end
  end
  return best
end
Profit.MaterialOf = function(id) return materialOf(id, nil) end
Profit.OwnProfessions = ownProfessions

-- Whether a bought item is own use (see OWN); pool = its bought pool (units neither sold nor
-- used in crafts), held = heldCounts(true) or nil.
local function isOwnUse(id, act, held, pool)
  local mark = ownMarks()[id]
  if mark ~= nil then return mark end
  if act and act.tools[id] then return true end
  if act and act.everBought[id] and not act.traded[id] and pool and pool.q > 0
      and held and (held[id] or 0) == 0 then
    return true
  end
  return false
end
Profit.IsOwnUse = isOwnUse

local function round(x) return math.floor(x + 0.5) end

-- p: the pool (units left); left = units the household still holds of it (nil: not known).
-- Units of the pool no longer held (vendored before that was logged, used, destroyed) are gone:
-- their cost is booked as a write-off (in cost and profit), the stock is what is still there.
local function row(id, group, f, p, kind, left)
  local gone, goneValue = 0, 0
  if left and p.q > left then
    gone = p.q - left
    goneValue = p.v * gone / p.q
    p = { q = left, v = p.v - goneValue }
  end
  local cost = (group == OWN and round(f.materials) or round(f.soldCost)) + round(goneValue)
  return {
    gone = gone, goneValue = round(goneValue), usedBy = f.usedBy, usedByN = f.usedByN,
    itemId = id, prof = group, kind = kind, name = ns.ItemName and ns.ItemName(id) or nil,
    used = f.used, usedValue = round(f.usedValue),
    crafted = f.crafted, sold = f.sold, bought = f.bought, spent = round(f.spent),
    revenue = round(f.revenue), materials = round(f.materials), fees = round(f.fees),
    cut = round(f.cut), depositsLost = round(f.depositsLost),
    cost = cost,
    profit = round(f.revenue) - cost - round(f.fees),
    soldCost = round(f.soldCost), expired = f.expired, cancelled = f.cancelled,
    stockUnits = p.q, stockValue = round(p.v),
    unitCost = p.q > 0 and round(p.v / p.q) or nil,
    avgPrice = f.sold > 0 and round(f.revenue / f.sold) or nil,
    soldUnitCost = f.sold > 0 and round(f.soldCost / f.sold) or nil,
    unitProfit = f.sold > 0 and round((f.revenue - f.cut - f.soldCost) / f.sold) or nil,
  }
end

local NONE = { q = 0, v = 0 }

-- The whole-ledger replay for the read-only lookups (UnitCost, Stock, ItemEvents), kept while
-- the ledger is unchanged: the auction tab asks for every row once a second. Key: event count
-- and newest event; in-place changes (a craft growing, a buy getting its mail) are picked up
-- after CACHE_TTL at the latest; a hand-entered cost clears it (Profit.Invalidate).
local CACHE_TTL = 5
local function clock() return (GetTime and GetTime()) or os.clock() end
local function replayAll()
  local events = ns.Ledger and (ns.Ledger.HouseholdEvents or ns.Ledger.Events) and (ns.Ledger.HouseholdEvents or ns.Ledger.Events)() or {}
  local last = events[#events]
  local key = tostring(#events) .. ":" .. tostring(last) .. ":" .. tostring(charFilter)
  local now = clock()
  if not cached or key ~= cachedKey or now - cachedAt > CACHE_TTL then
    cached, cachedKey, cachedAt = { replay(nil) }, key, now
  end
  return unpack(cached)
end

function Profit.Invalidate() cached = nil end

-- Per item rows: crafted items under their profession (stock = crafted pool), TRADE rows
-- for bought items that were sold, came back or are still there (stock = bought pool, also
-- when nothing happened in the period), FARMED rows without stock.
local function itemRows(since, replayed)
  local items, crafted, profOf, other, bought, _, act = unpack(replayed or { replay(since) })
  local rows = {}
  local held = Profit.HeldCounts and Profit.HeldCounts(true) -- defined further down
  local own = ownProfessions(act)
  -- what the household still holds, shared by the crafted pool first, then the bought one
  local leftCrafted, leftBought = {}, {}
  if held then
    for id, p in pairs(crafted) do leftCrafted[id] = math.min(p.q, held[id] or 0) end
    for id in pairs(bought) do
      leftBought[id] = math.max(0, (held[id] or 0) - (leftCrafted[id] or 0))
    end
  end
  local trade = other[TRADE] or {}
  for id, p in pairs(bought) do
    if p.q > 0 and not trade[id] then trade[id] = newFigures() end
  end
  other[TRADE] = next(trade) and trade or nil
  for area, list in pairs(other) do
    for id, f in pairs(list) do
      local group = area
      -- gathered by a profession nobody in the household has (looted ore, herbs): loot
      if area ~= FARMED and area ~= TRADE and area ~= OWN and Profit.IsFarmed(area) and not own[area] then group = FARMED end
      -- loot that is material of a household profession (wolf meat: Kochkunst) is that
      -- profession's loot
      local lootOf = group == FARMED and materialOf(id, act, own)
      if lootOf then
        table.insert(rows, row(id, lootOf, f, NONE, "loot"))
        group = nil
      end
      local p = group == TRADE and bought[id] or NONE
      local material = group == TRADE and ownMarks()[id] ~= true and materialOf(id, act, own)
      if material then
        -- a reagent: material of its profession (bought, used in crafts, rest sold or kept)
        if f.bought > 0 or f.used > 0 or f.sold > 0 or f.expired > 0 or f.cancelled > 0 or p.q > 0 then
          table.insert(rows, row(id, material, f, p, "material", held and leftBought[id] or nil))
        end
        group = nil
      elseif group == TRADE and isOwnUse(id, act, held, bought[id]) then
        -- own use: the purchase is an expense, no stock
        f.materials = f.spent
        group, p = OWN, NONE
      end
      -- Bought material that went into crafts (none left, nothing sold) is no trade; own use
      -- only in the period it was bought.
      local show = group and (group ~= TRADE or p.q > 0 or f.sold > 0 or f.expired > 0 or f.cancelled > 0)
      if group == OWN and (f.spent or 0) == 0 and f.sold == 0 then show = false end
      if show then
        -- gathered by a household profession (skinned leather): that profession's loot
        local kind = group ~= TRADE and group ~= OWN and Profit.IsFarmed(group) and "loot" or nil
        table.insert(rows, row(id, group, f, p, kind, held and group == TRADE and leftBought[id] or nil))
      end
    end
  end
  for id, prof in pairs(profOf) do
    local f = items[id] or newFigures()
    local p = crafted[id] or NONE
    if f.crafted > 0 or f.sold > 0 or f.fees > 0 or f.expired > 0 or f.cancelled > 0 or p.q > 0 then
      table.insert(rows, row(id, prof, f, p, "product", held and leftCrafted[id] or nil))
    end
  end
  return rows
end

local function byProfit(a, b)
  if a.profit ~= b.profit then return a.profit > b.profit end
  return (a.name or tostring(a.itemId)) < (b.name or tostring(b.itemId))
end

local SUM_KEYS = { "gone", "goneValue", "used", "usedValue", "revenue", "materials", "cost", "fees", "cut", "depositsLost", "profit", "stockUnits",
  "stockValue", "crafted", "sold", "bought", "spent", "soldCost", "expired", "cancelled" }

Profit.SUM_KEYS = SUM_KEYS

-- Sum of rows (same keys as a group), e.g. the materials or the products of a profession.
function Profit.Sum(rows, name)
  local s = { name = name }
  for _, key in ipairs(SUM_KEYS) do s[key] = 0 end
  for _, r in ipairs(rows or {}) do
    for _, key in ipairs(SUM_KEYS) do s[key] = s[key] + (r[key] or 0) end
  end
  return s
end

local function professions(rows)
  local by, list = {}, {}
  for _, r in ipairs(rows) do
    local s = by[r.prof]
    if not s then
      s = { name = r.prof }
      for _, key in ipairs(SUM_KEYS) do s[key] = 0 end
      by[r.prof] = s
      table.insert(list, s)
    end
    for _, key in ipairs(SUM_KEYS) do s[key] = s[key] + r[key] end
  end
  table.sort(list, byProfit)
  return list
end

local function totals(groups)
  local t = { revenue = 0, materials = 0, cost = 0, fees = 0, cut = 0, depositsLost = 0, profit = 0,
    stockUnits = 0, stockValue = 0 }
  for _, s in ipairs(groups) do
    for key in pairs(t) do t[key] = t[key] + s[key] end
  end
  return t
end

function Profit.Professions(since)
  return professions(itemRows(since))
end

function Profit.Items(professionName, since)
  local list = {}
  for _, r in ipairs(itemRows(since)) do
    if r.prof == professionName then table.insert(list, r) end
  end
  table.sort(list, byProfit)
  return list
end

function Profit.Totals(since)
  return totals(Profit.Professions(since))
end

-- What the character really holds of an item: bags, bank (once seen) and own running
-- auctions. nil when the bank was never opened (then nothing is capped).
local function heldCounts(household)
  -- bags, bank (once seen) and running auctions of every character of the household; nil when a
  -- character's bank was never opened (then nothing is capped)
  local keys = ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or { ns.CharKey and ns.CharKey() }
  -- one chosen character: only what is known of it (bags, bank once seen, auctions), never the
  -- uncapped household pools
  local single = charFilter and not household
  if single then keys = { charFilter } end
  local held = {}
  for _, key in ipairs(keys) do
    local inv = key and ns.db and ns.db.inventory and ns.db.inventory[key]
    if inv then
      if not (inv.bagsT and inv.bankT) and not single then return nil end
      for _, part in ipairs({ inv.bags or {}, inv.bank or {} }) do
        for id, entry in pairs(part) do held[id] = (held[id] or 0) + (entry.n or 0) end
      end
    end
    local owned = ns.db.owned and ns.db.owned[key]
    for _, a in ipairs(owned and owned.list or {}) do
      if a.i and not a.s then held[a.i] = (held[a.i] or 0) + (a.q or 1) end
    end
  end
  if single then return held end
  local me = ns.CharKey and ns.CharKey()
  local inv = me and ns.db.inventory and ns.db.inventory[me]
  if not (inv and inv.bagsT and inv.bankT) then return nil end
  return held
end
Profit.HeldCounts = heldCounts

-- Stock now from the pools: crafted and bought units of an item together, at most what the
-- character holds (items used, equipped, destroyed or given away leave the stock).
local function stock(crafted, bought, act)
  local by, list = {}, {}
  local households = act and heldCounts(true)
  local function add(id, p, source)
    if not p or p.q <= 0 then return end
    -- own use (tools, marked, used up) is no stock
    if source == "gekauft" and act and isOwnUse(id, act, households, p) then return end
    local s = by[id]
    if not s then
      s = { itemId = id, name = ns.ItemName and ns.ItemName(id) or nil, units = 0, cost = 0 }
      by[id] = s
      table.insert(list, s)
    end
    s.units, s.cost = s.units + p.q, s.cost + p.v
    s.source = s.source and (s.source .. ", " .. source) or source
  end
  for id, p in pairs(crafted) do add(id, p, "hergestellt") end
  for id, p in pairs(bought) do add(id, p, "gekauft") end
  local held = heldCounts()
  if held then
    for i = #list, 1, -1 do
      local s = list[i]
      local have = held[s.itemId] or 0
      if have <= 0 then
        table.remove(list, i)
      elseif have < s.units then
        s.cost, s.units = s.cost * have / s.units, have
      end
    end
  end
  local t = { units = 0, cost = 0, market = 0, pricedCost = 0, diff = 0, unpriced = 0,
    sell = 0, sellCost = 0, gain = 0, capped = held ~= nil }
  for _, s in ipairs(list) do
    s.cost = round(s.cost)
    s.unitCost = round(s.cost / s.units)
    local item = ns.Item and ns.Item(s.itemId)
    s.marketUnit = item and item.now or nil
    if s.marketUnit then
      s.market = round(s.marketUnit * s.units)
      s.diff = s.market - s.cost
      t.market, t.pricedCost = t.market + s.market, t.pricedCost + s.cost
    else
      t.unpriced = t.unpriced + 1
    end
    -- Book gain (Buchgewinn): what selling would bring after the cut (Item.SellNet, the same
    -- formula as the server's Discord message) minus the cost.
    local sellNet = type(ns.Item) == "table" and ns.Item.SellNet
    local sellUnit = item and sellNet and sellNet(item) or 0
    if sellUnit > 0 then
      s.sellUnit = sellUnit
      s.sell = round(sellUnit * s.units)
      s.gain = s.sell - s.cost
      if s.unitCost > 0 then s.gainPct = sellUnit / s.unitCost - 1 end
      t.sell, t.sellCost = t.sell + s.sell, t.sellCost + s.cost
    end
    t.units, t.cost = t.units + s.units, t.cost + s.cost
  end
  t.diff = t.market - t.pricedCost
  t.gain = t.sell - t.sellCost
  table.sort(list, function(a, b)
    local va, vb = a.sell or a.market or a.cost, b.sell or b.market or b.cost
    if va ~= vb then return va > vb end
    return (a.name or tostring(a.itemId)) < (b.name or tostring(b.itemId))
  end)
  return list, t
end

function Profit.Stock()
  local _, crafted, _, _, bought, _, act = replayAll()
  return stock(crafted, bought, act)
end

-- Stock snapshot for the server's Discord message on a strong book gain (m4d stockalert.go):
-- written on logout / reload into ns.db.owned[charKey].stk, so it travels with the own
-- auctions of the state sync (no app change). Only items with a known cost (> 0) and only
-- when the stock is capped by what the character holds (bank seen once), else nothing:
--   stk = { v = 1, t = time(), l = { { i = itemID, u = units, c = cost per unit }... } }
-- (at most SNAPSHOT_MAX items, the most valuable first). The server computes the selling
-- price itself (same formula as Item.SellNet), the cost is never recomputed there.
local SNAPSHOT_MAX = 300
function Profit.Snapshot()
  local list, t = Profit.Stock()
  if not t.capped then return nil end
  local out = {}
  for _, s in ipairs(list) do
    if (s.unitCost or 0) > 0 and s.units > 0 then
      table.insert(out, { i = s.itemId, u = s.units, c = s.unitCost })
    end
  end
  table.sort(out, function(a, b)
    if a.u * a.c ~= b.u * b.c then return a.u * a.c > b.u * b.c end
    return a.i < b.i
  end)
  for i = #out, SNAPSHOT_MAX + 1, -1 do out[i] = nil end
  return { v = 1, t = time and time() or 0, l = out }
end

-- Writes the snapshot into the character's own auctions entry (only when it exists: its t
-- is what the sync needs; a new entry would claim "no running auctions").
-- The snapshot holds this character's stock only (the server sums the characters' snapshots;
-- the household stock in every snapshot would count each item twice).
function Profit.WriteSnapshot()
  local key = ns.CharKey and ns.CharKey()
  local o = key and ns.db and ns.db.owned and ns.db.owned[key]
  if type(o) ~= "table" then return end
  local before = charFilter
  charFilter = key
  local ok, snap = pcall(Profit.Snapshot)
  charFilter = before
  if ok then o.stk = snap end
end

if ns.On then
  ns.On("PLAYER_LOGOUT", function()
    if ns.Safe then ns.Safe(Profit.WriteSnapshot) else Profit.WriteSnapshot() end
  end)
end

-- Everything the ledger page shows, from one replay.
function Profit.Report(since)
  local replayed = { replay(since) }
  local rows = itemRows(since, replayed)
  local groups = professions(rows)
  local items = {}
  for _, r in ipairs(rows) do
    items[r.prof] = items[r.prof] or {}
    table.insert(items[r.prof], r)
  end
  for _, list in pairs(items) do table.sort(list, byProfit) end
  local list, t = stock(replayed[2], replayed[5], replayed[7])
  return { groups = groups, items = items, totals = totals(groups), stock = list, stockTotals = t }
end

function Profit.ItemEvents(itemID, since)
  local _, _, _, _, _, lost = replayAll()
  local events = ns.Ledger and (ns.Ledger.HouseholdEvents or ns.Ledger.Events) and (ns.Ledger.HouseholdEvents or ns.Ledger.Events)() or {}
  local out = {}
  for i = #events, 1, -1 do
    local e = events[i]
    if (not since or (e.t or 0) >= since) and idOf(e) == itemID and charOK(e) then
      table.insert(out, { t = e.t, k = e.k, u = e.u, c = e.c, cut = e.cut, p = e.p, dep = e.dep,
        lost = lost[e] and round(lost[e]) or nil })
    end
  end
  return out
end

-- What one unit of the item cost the player, for pricing decisions (not for the P&L):
--   crafted pool (logged crafts, material at purchase price, farmed 0)  -> "hergestellt"
--   bought pool (bought at the auction house)                          -> "gekauft"
--   else, if the character can make it: the material at today's prices -> "Material heute"
--     (farmed material counts at its market value here: selling it would bring that much)
-- Returns copper per unit and the source text, or nil.
function Profit.UnitCost(itemID)
  local _, crafted, _, _, bought = replayAll()
  -- Holding more than the ledger's pool (e.g. 1 crate bought, 1674 looted): the extra units are
  -- loot and cost nothing, the average is spread over all units held.
  local now = clock()
  if not heldCache or now - heldAt > 2 then heldCache, heldAt = heldCounts(true) or false, now end
  local have = heldCache and heldCache[itemID] or 0
  local function average(pool, source)
    if have > pool.q then return pool.v / have, source .. " + Beute" end
    return pool.v / pool.q, source
  end
  local p = crafted[itemID]
  if p and p.q > 0 and p.v > 0 then return average(p, "hergestellt") end
  p = bought[itemID]
  if p and p.q > 0 then return average(p, "gekauft") end
  local m = manualCost(itemID)
  if m then return m, "von Hand eingetragen" end
  local c = ns.CraftingCost and ns.CraftingCost(itemID)
  if c then return c, "Material heute" end
  -- neither bought, crafted nor entered: looted (or bought before the ledger ran) - free, as
  -- in the profit report (FARMED)
  return 0, "Beute"
end

-- The lowest unit price that still covers the cost after the auction house cut.
function Profit.BreakEven(cost)
  return cost and math.ceil(cost / (1 - 0.05)) or nil
end
