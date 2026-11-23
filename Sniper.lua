-- Sniper: while the auction house is open and the sniper runs, it searches the
-- items of a watch list one after another (like TSM's sniper with groups, which
-- also issues single item searches), compares the offers with the reference value
-- (Deals.Reference) and lists the hits.
-- No bulk request: SearchForItemKeys with 400 keys got the character disconnected
-- (16 Nov 2026). Searches are paced to at most one per SEARCH_SPACING seconds.
-- Watch list = items of our own auction house (ns.Item) with demand >= watchMinDemand, where the discount is worth minProfit and that
-- we can afford; the watchMax best by expected profit (all values: Deals.Settings, editable in the main window). Without the collector data
-- or the API it falls back to browsing the whole auction house (slow). A hit is an offer at or below Deals.MAX_SHARE of the reference, for an
-- item that sells well, with at least Deals.MIN_PROFIT after the cut. In the watch list's detail check
-- the price stair (Deals.Staircase) decides what to buy and at which price to sell it again.
-- Buying is always a click of the player: items one auction per click,
-- commodities "Kaufen" (the game quotes the final price) and then "Bestätigen".
-- If the game blocks automatic searches, every search round needs a click too.
-- Every hit and purchase is logged in db.sniper, so the yield can be measured.
-- Recipes (ns.RecipeWatch, Data_RecipeWatch.lua): the tradeable recipes worth having are
-- watched in their own category on top of the watch list (not counted against watchMax).
-- A recipe hit is an offer at or below its R (Sniper.RecipeUsual) * recipeMax (no R known:
-- every offer); it is marked "Rezept" in the list and plays its own sound.
local ADDON, ns = ...

local Sniper = {}
ns.Sniper = Sniper

local api = C_AuctionHouse or {}
local PAUSE = 3            -- seconds between two browse rounds
local SEARCH_TIMEOUT = 6   -- give up on a detail search after this
local BROWSE_TIMEOUT = 25
local MAX_PAGES = 80
local PRICE_TOLERANCE = 1.02 -- commodity quote may be 2 % above the listed cost
local LOG_MAX = 2000
local SEARCH_SPACING = 1.0   -- seconds between two searches (TSM allows itself 100 a minute)
local FULL_PAUSE = 30        -- pause between two whole-AH browses (as TSM)

local running, manual = false, false
local phase = "idle"        -- idle, browse, detail, wait
local token = 0             -- invalidates timers of an earlier round
local pages, browseStarted = 0, nil
local candidates = {}
local detailing = nil
local hits = {}             -- key -> hit
local checked = {}          -- key -> min price at which the detail found no deal
local pending = nil         -- commodity quote waiting for "Bestätigen"
local buying = nil          -- item auction bought, waiting for the result
local note = nil            -- last message for the status line
local round = { items = 0, candidates = 0, seconds = 0 }
local timeouts = 0          -- detail searches without an answer (this run)
local watch = nil           -- { keys = {itemKey...}, set = {itemID = true} } or nil (whole AH)
local seen = {}             -- key -> { price = cheapest offer or false (none), limit = buy-up-to, t = time() }
local roundNo = 0           -- watch list rounds of this run
local levels = {}           -- itemID -> { list = price levels of the last search, t = time() }
local priority = {}         -- items asked for elsewhere (ns.AHSearch), searched before the watch list
local recipeSoundAt = -1000 -- GetTime() of the last recipe hit sound

local function changed()
  if ns.Selling and ns.Selling.Refresh then ns.Safe(ns.Selling.Refresh) end
end

local function store()
  ns.db.sniper = ns.db.sniper or { log = {} }
  return ns.db.sniper
end

local function session()
  local s = store()
  if not s.session or s.session.closed then
    s.session = { start = time(), rounds = 0, hits = 0, hitProfit = 0, bought = 0, spent = 0,
      expected = 0, gone = 0, goneSeconds = 0 }
  end
  return s.session
end

local function log(kind, hit, extra)
  local s = store()
  local e = { t = time(), k = kind, i = hit.itemID, u = hit.units, p = math.floor(hit.profit), c = hit.cost }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  ns.AuctionHouse.Tag(e) -- ah, npc: the house and auctioneer of the hit
  table.insert(s.log, e)
  while #s.log > LOG_MAX do table.remove(s.log, 1) end
end

-- Item level is left out: search results may carry the real level while the
-- browse result says 0, and in this game an item id has one level anyway.
local function keyOf(itemKey)
  return table.concat({ itemKey.itemID, itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0 }, ":")
end

-- Reference price of this item in our auction house (ns.Item R, median of yesterday).
local function houseValue(itemID)
  return ns.Item(itemID).ref
end

-- Same item variant as the reference prices (random suffixes and pets differ in value).
local function plainKey(itemKey)
  return (itemKey.itemSuffix or 0) == 0 and (itemKey.battlePetSpeciesID or 0) == 0
end

local function ready()
  return not api.IsThrottledMessageSystemReady or api.IsThrottledMessageSystemReady()
end

-- Watch list candidates from the items of our own auction house (ns.Item), best first:
-- { { itemID, score, ref, demand }... } limited to watchMax (Deals.Settings). Also used
-- by the main window to show what the sniper watches.
function Sniper.WatchCandidates()
  local house = ns.AuctionHouse.CloudData()
  if not house then return {} end
  local set = ns.Deals.Settings()
  local money, list = GetMoney(), {}
  local discount = 1 - set.maxShare - ns.Deals.CUT
  for itemID in pairs(house.items) do
    local item = ns.Item(itemID)
    local ref, demand = ns.Deals.Reference(itemID, nil), item.demand
    local candidateLimit = ref and ref * set.maxShare
    if candidateLimit and set.maxPrice > 0 then candidateLimit = math.min(candidateLimit, set.maxPrice) end
    -- Maximalpreis also limits the watch list: no items whose R is above it.
    local tooExpensive = ref and set.maxPrice > 0 and ref > set.maxPrice
    local falling = ns.Deals.Falling(itemID)
    if ref and not tooExpensive and not falling and demand and demand >= set.watchMinDemand and candidateLimit <= money then
      local stack = math.max(1, math.min(20, (item.quantity or 1) / math.max(1, item.offers or 1)))
      if discount * ref * stack >= set.minProfit then
        table.insert(list, { itemID = itemID, score = ref * math.min(demand, 20), ref = ref, demand = demand })
      end
    end
  end
  table.sort(list, function(a, b) return a.score > b.score end)
  for i = #list, set.watchMax + 1, -1 do list[i] = nil end
  return list
end

-- Watched recipe of the item ({ profession, skill, product, usual }) while recipes are watched.
function Sniper.RecipeInfo(itemID)
  local r = ns.RecipeWatch and ns.RecipeWatch[itemID]
  if not r or not ns.Deals.Settings().recipeWatch or ns.Deals.Falling(itemID) then return nil end
  return r
end

-- Comparison price of a watched recipe: R of the recipe item (ns.Item: median of yesterday,
-- else of 7 days, else of today), else the list's value. Returns price, label ("Median
-- gestern", ..., "Listenwert") and a short label for narrow cells ("gestern", "7 Tage",
-- "heute", "Liste"); nil without any. Same rule as the cloud (ahnotify.recipes_at).
local SHORT = { yesterday = "gestern", week = "7 Tage", today = "heute" }
function Sniper.RecipeUsual(itemID)
  local e = ns.Item(itemID)
  if e.ref then return e.ref, ns.Item.RefLabel(e), SHORT[e.refSource] end
  local r = ns.RecipeWatch and ns.RecipeWatch[itemID]
  if r and r.usual then return r.usual, "Listenwert", "Liste" end
  return nil
end

-- Highest price a recipe hit may cost (nil = every offer, no R and no global cap).
function Sniper.RecipeLimit(itemID)
  local usual = Sniper.RecipeUsual(itemID)
  local set = ns.Deals.Settings()
  local limit = usual and math.floor(usual * set.recipeMax + 0.5) or nil
  if set.maxPrice > 0 and (not limit or set.maxPrice < limit) then return set.maxPrice end
  return limit
end

-- Watched recipes, sorted by item id: { itemID... } (empty while switched off).
function Sniper.RecipeItems()
  local list = {}
  if not ns.RecipeWatch or not ns.Deals.Settings().recipeWatch then return list end
  -- Falling recipes (Deals.Falling, same setting as the items) stay off the list as well.
  for itemID in pairs(ns.RecipeWatch) do
    if not ns.Deals.Falling(itemID) then table.insert(list, itemID) end
  end
  table.sort(list)
  return list
end

local function buildWatchlist()
  if not api.SendSearchQuery or not api.MakeItemKey then return nil end
  local w = { keys = {}, set = {}, recipeSet = {} }
  for _, c in ipairs(Sniper.WatchCandidates()) do
    local itemKey = api.MakeItemKey(c.itemID)
    table.insert(w.keys, { itemKey = itemKey, itemID = c.itemID, key = keyOf(itemKey), normal = true })
    w.set[c.itemID] = true
  end
  -- Without the collector data the whole AH is browsed (recipes included, see quickCheck).
  if #w.keys == 0 then return nil end
  for _, itemID in ipairs(Sniper.RecipeItems()) do
    w.recipeSet[itemID] = true
    local found = false
    for _, k in ipairs(w.keys) do
      if k.itemID == itemID then k.recipe, found = true, true end
    end
    if not found then
      local itemKey = api.MakeItemKey(itemID)
      table.insert(w.keys, { itemKey = itemKey, itemID = itemID, key = keyOf(itemKey), recipe = true })
      w.set[itemID] = true
    end
  end
  return w
end

local lastSearch = 0
-- Diagnostics: answered searches, summed answer time, throttle waits, late answers.
local diag = { answered = 0, seconds = 0, waits = 0, late = 0, sent = 0 }
local sentAt = {}
-- The spacing is shared with ns.AHSearch, and no search while its own one waits for an answer.
local function searchAllowed()
  local shared = ns.AHSearch
  if shared and (shared.Busy() or shared.Since() < SEARCH_SPACING) then return false end
  return GetTime() - lastSearch >= SEARCH_SPACING
end

local function browseFilters()
  local filters = {}
  if Enum and Enum.AuctionHouseFilter then
    for name, value in pairs(Enum.AuctionHouseFilter) do
      if type(name) == "string" and name:find("Quality$") then table.insert(filters, value) end
    end
  end
  return filters
end

local function priceSort()
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  return { { sortOrder = order, reverseSort = false } }
end

local nextStep

local function later(seconds, fn)
  local my = token
  C_Timer.After(seconds, function()
    if running and my == token then ns.Safe(fn) end
  end)
end

-- Browse ---------------------------------------------------------------------------

local function sendBrowse()
  if not ready() then return later(0.5, sendBrowse) end
  pages, browseStarted = 0, GetTime()
  candidates = {}
  if watch then
    -- one round = every watched item searched once
    for _, w in ipairs(watch.keys) do table.insert(candidates, w) end
    phase = "detail"
    session().rounds = session().rounds + 1
    roundNo = roundNo + 1
    round.items = #candidates
    changed()
    return nextStep()
  end
  phase = "browse"
  api.SendBrowseQuery({ searchString = "", sorts = priceSort(), filters = browseFilters(),
    itemClassFilters = {} })
  local my = token
  later(BROWSE_TIMEOUT, function()
    if phase == "browse" and my == token then Sniper.BrowseDone() end
  end)
end

local function quickCheck(r)
  if r.containsOwnerItem or not r.minPrice or r.minPrice <= 0 then return false end
  if not plainKey(r.itemKey) then return false end
  local itemID = r.itemKey.itemID
  if not watch and Sniper.RecipeInfo(itemID) then
    local limit = Sniper.RecipeLimit(itemID)
    if not limit or r.minPrice <= limit then return true, true end
  end
  if watch then
    if not watch.set[itemID] then return false end -- sells in our house: checked by the list
  elseif not ns.Deals.Liquid(itemID) then
    return false
  end
  local ref = ns.Deals.Reference(itemID, houseValue(itemID))
  return ref and r.minPrice <= ref * ns.Deals.MaxShare()
end

function Sniper.BrowseDone()
  if phase ~= "browse" then return end
  local results = api.GetBrowseResults and api.GetBrowseResults() or {}
  local seen = {}
  for _, r in ipairs(results) do
    local key = keyOf(r.itemKey)
    seen[key] = r.minPrice
    local ok, recipe = quickCheck(r)
    if ok and checked[key] ~= r.minPrice then
      table.insert(candidates, { itemKey = r.itemKey, itemID = r.itemKey.itemID, key = key, minPrice = r.minPrice,
        recipe = recipe, normal = not recipe })
    end
  end
  -- Hits whose cheapest offer is gone were bought by someone else (or cancelled).
  local s = session()
  for key, hit in pairs(hits) do
    if hit ~= (pending and pending.hit) and (not seen[key] or seen[key] > hit.best) then
      s.gone, s.goneSeconds = s.gone + 1, s.goneSeconds + (time() - hit.firstSeen)
      log("gone", hit, { a = time() - hit.firstSeen })
      hits[key] = nil
    end
  end
  round.items, round.candidates = #results, #candidates
  round.seconds = GetTime() - (browseStarted or GetTime())
  s.rounds = s.rounds + 1
  phase = "detail"
  changed()
  nextStep()
end

-- Detail ---------------------------------------------------------------------------

-- Offers of the last search grouped by unit price, cheapest first: { { unit, count, own }... }.
local LEVELS_MAX = 25
local function priceLevels(listings)
  local by, list = {}, {}
  for _, l in ipairs(listings) do
    local e = by[l.unit]
    if not e then
      e = { unit = l.unit, count = 0 }
      by[l.unit] = e
      table.insert(list, e)
    end
    e.count = e.count + (l.count or 1)
    if l.own then e.own = true end
    if l.ownCount then e.ownCount = (e.ownCount or 0) + l.ownCount end
  end
  table.sort(list, function(a, b) return a.unit < b.unit end)
  for i = #list, LEVELS_MAX + 1, -1 do list[i] = nil end
  return list
end

-- Recipe hit: the foreign offers at or below the recipe limit, cheapest first. profit =
-- what stays below R (Sniper.RecipeUsual, 0 without one); sellAt = R.
local function recipeHit(c, listings, commodity)
  local limit = Sniper.RecipeLimit(c.itemID)
  local usual, usualLabel, usualShort = Sniper.RecipeUsual(c.itemID)
  local buy = {}
  for _, l in ipairs(listings) do
    if not l.own and l.unit and l.unit > 0 and (not limit or l.unit <= limit) then table.insert(buy, l) end
  end
  if #buy == 0 then return nil end
  table.sort(buy, function(a, b) return a.unit < b.unit end)
  local units, cost = 0, 0
  for _, l in ipairs(buy) do units, cost = units + (l.count or 1), cost + l.unit * (l.count or 1) end
  local best = buy[1].unit
  local info = ns.RecipeWatch and ns.RecipeWatch[c.itemID] or {}
  return { key = c.key, itemKey = c.itemKey, itemID = c.itemID, commodity = commodity, recipe = true,
    profession = info.profession, skill = info.skill, product = info.product, usual = usual,
    usualLabel = usualLabel, usualShort = usualShort,
    ref = usual or best, cap = usual, level = best, sellAt = usual or best, sellSource = usualLabel or "Angebot",
    buyUpTo = limit or best, limit = limit or best, units = units, cost = cost,
    profit = usual and math.max(0, usual - best) or 0, best = best, auctions = buy }
end

local function evaluate(c, listings, commodity)
  local plain, cheapest = {}, nil
  for _, l in ipairs(listings) do
    table.insert(plain, { unit = l.unit, count = l.count })
    if not cheapest or l.unit < cheapest then cheapest = l.unit end
  end
  ns.Item.Observe(c.itemID, cheapest)
  levels[c.itemID] = { list = priceLevels(listings), t = time() }
  -- the shared "last search" store; answers whoever waits for this item (ns.AHSearch)
  if ns.AHSearch then ns.AHSearch.Store(c.itemID, levels[c.itemID].list) end
  local house = #plain > 0 and ns.Deals.HousePrice(plain, 0.25) or nil
  local ref, source = ns.Deals.Reference(c.itemID, house)
  local set = ns.Deals.Settings()
  local limit = ref and ref * set.maxShare
  if limit and set.maxPrice > 0 then limit = math.min(limit, set.maxPrice) end
  seen[c.key] = { price = cheapest or false, limit = limit, t = time() }
  -- Watched recipe: its own rule; the price stair only when it is on the normal list too.
  if Sniper.RecipeInfo(c.itemID) then
    seen[c.key].limit = Sniper.RecipeLimit(c.itemID) or seen[c.key].limit
    local hit = recipeHit(c, listings, commodity)
    if hit or not c.normal then return hit end
  end
  -- Price stair (Deals.Staircase): what to buy, where to sell it again.
  local item = ns.Item(c.itemID)
  local cap, capLabel = item.ref or ref, item.ref and ns.Item.RefLabel(item) or source
  -- The demand figure is on TSM's EU-wide scale, not units on this realm: without counted
  -- sales assume at most one unit a day.
  local perDay, perDaySource = item.demand and math.min(item.demand, 1), "vorsichtig geschätzt"
  if item.certain and item.certain > 0 then perDay, perDaySource = item.certain, "sicher verkauft" end
  -- Falling price: no hit (the resale price would not hold).
  if ns.Deals.Falling(c.itemID) then return nil end
  local stair = ns.Deals.Staircase(listings, cap, perDay, set)
  if not stair or stair.profit < ns.Deals.MinProfit() then return nil end
  local hit = { key = c.key, itemKey = c.itemKey, itemID = c.itemID, commodity = commodity, ref = ref,
    source = source, cap = cap, capLabel = capLabel, level = stair.level, sellAt = stair.sellAt, sellSource = stair.sellSource,
    buyUpTo = stair.buyUpTo, limit = stair.buyUpTo, units = stair.units, cost = stair.cost,
    profit = stair.profit, best = stair.best, auctions = stair.auctions,
    perDay = perDay, perDaySource = perDaySource, days = perDay and perDay > 0 and stair.units / perDay or nil }
  return hit
end

local function answered(itemID)
  local t = sentAt[itemID]
  if not t then return end
  sentAt[itemID] = nil
  if detailing and detailing.itemID == itemID then
    diag.answered, diag.seconds = diag.answered + 1, diag.seconds + (GetTime() - t)
  else
    diag.late = diag.late + 1
  end
  ns.db.sniper.diag = diag
end

local function finishDetail(c, listings, commodity)
  if detailing ~= c then return end
  detailing = nil
  local hit = evaluate(c, listings, commodity)
  local old = hits[c.key]
  if hit then
    hit.firstSeen = old and old.firstSeen or time()
    hit.seen = time()
    hits[c.key] = hit
    if not old then
      local s = session()
      s.hits, s.hitProfit = s.hits + 1, s.hitProfit + hit.profit
      log("hit", hit, { b = hit.best, r = math.floor(hit.ref), rc = hit.recipe or nil })
      if PlaySound then
        if hit.recipe then
          -- own sound, at most once a minute (many recipes may hit in the same round)
          if GetTime() - recipeSoundAt >= 60 then
            recipeSoundAt = GetTime()
            pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
          end
        else
          pcall(PlaySound, SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_OPEN or 5274)
        end
      end
    end
  else
    if old then
      local s = session()
      s.gone, s.goneSeconds = s.gone + 1, s.goneSeconds + (time() - old.firstSeen)
      log("gone", old, { a = time() - old.firstSeen })
    end
    hits[c.key] = nil
    if c.minPrice then checked[c.key] = c.minPrice end
  end
  changed()
  later(0.1, nextStep)
end

local function sendDetail(c)
  if not ready() then diag.waits = diag.waits + 1 end
  if not ready() or not searchAllowed() then return later(0.25, function() sendDetail(c) end) end
  lastSearch = GetTime()
  if ns.AHSearch then ns.AHSearch.Stamp() end
  diag.sent = diag.sent + 1
  sentAt[c.itemID] = GetTime()
  detailing = c
  api.SendSearchQuery(c.itemKey, priceSort(), true)
  later(SEARCH_TIMEOUT, function()
    if detailing == c then
      detailing, timeouts = nil, timeouts + 1
      if c.minPrice then checked[c.key] = c.minPrice end
      if ns.AHSearch then ns.AHSearch.Failed(c.itemID) end
      nextStep()
    end
  end)
end

local frame = CreateFrame("Frame")
local function listen(event)
  pcall(frame.RegisterEvent, frame, event)
end

local handlers = {}

handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function()
  if phase ~= "browse" then return end
  if api.HasFullBrowseResults and not api.HasFullBrowseResults() and pages < MAX_PAGES then
    pages = pages + 1
    if ready() then api.RequestMoreBrowseResults() else later(0.5, function() api.RequestMoreBrowseResults() end) end
    return
  end
  Sniper.BrowseDone()
end
handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED = handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED

handlers.COMMODITY_SEARCH_RESULTS_UPDATED = function(itemID)
  answered(itemID)
  local c = detailing
  if not c or c.itemID ~= itemID then return end
  local listings = {}
  for i = 1, (api.GetNumCommoditySearchResults(itemID) or 0) do
    local r = api.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice then
      table.insert(listings, { unit = r.unitPrice, count = r.quantity, auctionID = r.auctionID,
        own = r.containsOwnerItem, ownCount = r.containsOwnerItem and r.numOwnerItems or nil })
    end
  end
  finishDetail(c, listings, true)
end

handlers.ITEM_SEARCH_RESULTS_UPDATED = function(itemKey)
  if itemKey then answered(itemKey.itemID) end
  local c = detailing
  if not c or not itemKey or keyOf(itemKey) ~= c.key then return end
  local listings = {}
  for i = 1, (api.GetNumItemSearchResults(itemKey) or 0) do
    local r = api.GetItemSearchResultInfo(itemKey, i)
    -- One result = r.quantity auctions of one item each at buyoutAmount (as TSM reads it:
    -- quantity is the number of auctions, not a stack size).
    if r and r.buyoutAmount and r.buyoutAmount > 0 then
      table.insert(listings, { unit = r.buyoutAmount, count = r.quantity or 1, buyout = r.buyoutAmount,
        auctionID = r.auctionID, own = r.containsOwnerItem })
    end
  end
  finishDetail(c, listings, false)
end

-- Loop -----------------------------------------------------------------------------

nextStep = function()
  if not running or pending or buying then return end
  if phase == "detail" then
    local c = table.remove(priority, 1) or table.remove(candidates, 1)
    if c then return sendDetail(c) end
    phase = "wait"
    round.seconds = GetTime() - (browseStarted or GetTime())
    changed()
    if manual then return end -- the next round needs a click
    return later(watch and PAUSE or FULL_PAUSE, sendBrowse)
  end
end

local function stopAll(text)
  running, phase, detailing, candidates = false, "idle", nil, {}
  priority = {} -- ns.AHSearch takes these back and searches them itself
  token = token + 1
  if pending and api.CancelCommoditiesPurchase then pcall(api.CancelCommoditiesPurchase) end
  pending, buying = nil, nil
  if text then note = text end
  local s = ns.db and ns.db.sniper and ns.db.sniper.session
  if s and not s.closed then s.closed, s.stop = true, time() end
  changed()
end

-- Buying ---------------------------------------------------------------------------

local function affordable(hit)
  local money, units, cost = GetMoney(), 0, 0
  local maxPrice = ns.Deals.Settings().maxPrice
  local priceBlocked = false
  for _, a in ipairs(hit.auctions) do
    if maxPrice > 0 and a.unit > maxPrice then priceBlocked = true; break end
    local n = math.min(a.count, math.floor((money - cost) / a.unit))
    if n <= 0 then break end
    units, cost = units + n, cost + n * a.unit
    if n < a.count then break end
  end
  return units, cost, priceBlocked
end

function Sniper.Buy(hit)
  if not hit then return end
  if pending and pending.hit == hit then
    -- second click: confirm the quoted commodity purchase
    local maxPrice = ns.Deals.Settings().maxPrice
    if maxPrice > 0 and (pending.maxPrice == 0 or maxPrice < pending.maxPrice) then
      pcall(api.CancelCommoditiesPurchase)
      note = "Maximalpreis geändert – Kauf bitte neu anfragen."
      pending = nil
      return changed()
    end
    api.ConfirmCommoditiesPurchase(hit.itemID, pending.units)
    pending.confirmed = true
    note = "Kauf bestätigt …"
    return changed()
  end
  if pending or buying then note = "Erst den laufenden Kauf abschließen."; return changed() end
  if hit.commodity then
    local units, cost, priceBlocked = affordable(hit)
    if units == 0 then
      note = priceBlocked and "Kein Angebot unter dem Maximalpreis." or "Nicht genug Gold."
      return changed()
    end
    pending = { hit = hit, units = units, cost = cost, maxPrice = ns.Deals.Settings().maxPrice }
    api.StartCommoditiesPurchase(hit.itemID, units)
    note = "Preis wird beim Server angefragt …"
  else
    local a = hit.auctions[1]
    if not a then return end
    local maxPrice = ns.Deals.Settings().maxPrice
    if maxPrice > 0 and a.buyout > maxPrice then
      note = "Der Preis liegt über dem Maximalpreis."
      return changed()
    end
    if a.buyout > GetMoney() then note = "Nicht genug Gold."; return changed() end
    buying = { hit = hit, auction = a }
    api.PlaceBid(a.auctionID, a.buyout)
    note = "Kaufe …"
    local my = buying
    C_Timer.After(8, function() if buying == my then buying = nil; nextStep() end end)
  end
  changed()
end

local function bought(hit, units, cost)
  local s = session()
  local profit = ((hit.sellAt or hit.ref) * (1 - ns.Deals.CUT)) * units - cost
  s.bought, s.spent, s.expected = s.bought + units, s.spent + cost, s.expected + profit
  log("buy", hit, { u = units, c = cost, p = math.floor(profit) })
end

handlers.COMMODITY_PRICE_UPDATED = function(unitPrice, totalPrice)
  if not pending or pending.quoted then return end
  pending.quoted, pending.total = true, totalPrice
  local maxPrice = ns.Deals.Settings().maxPrice
  local effectiveLimit = maxPrice
  if pending.maxPrice > 0 and (effectiveLimit == 0 or pending.maxPrice < effectiveLimit) then
    effectiveLimit = pending.maxPrice
  end
  local overLimit = effectiveLimit > 0 and unitPrice > effectiveLimit
  local limitChanged = maxPrice > 0 and (pending.maxPrice == 0 or maxPrice < pending.maxPrice)
  if totalPrice > pending.cost * PRICE_TOLERANCE or overLimit or limitChanged then
    pcall(api.CancelCommoditiesPurchase)
    if overLimit then
      note = "Schon weg: Preis jetzt über dem Maximalpreis."
    elseif limitChanged then
      note = "Maximalpreis geändert – Kauf bitte neu anfragen."
    else
      note = "Schon weg: Preis jetzt " .. ns.FormatMoney(unitPrice, true) .. " pro Stück."
    end
    hits[pending.hit.key] = nil
    pending = nil
    later(0.5, nextStep)
  else
    note = string.format("%dx für %s – nochmal klicken zum Bestätigen.", pending.units, ns.FormatMoney(totalPrice, true))
  end
  changed()
end

handlers.COMMODITY_PRICE_UNAVAILABLE = function()
  if not pending then return end
  note = "Preis nicht verfügbar – schon weg."
  hits[pending.hit.key] = nil
  pending = nil
  changed()
  later(0.5, nextStep)
end

handlers.COMMODITY_PURCHASE_SUCCEEDED = function()
  if not pending then return end
  bought(pending.hit, pending.units, pending.total or pending.cost)
  note = "Gekauft: " .. pending.units .. "x " .. ns.ItemName(pending.hit.itemID)
  hits[pending.hit.key] = nil
  pending = nil
  changed()
  later(0.5, nextStep)
end

handlers.COMMODITY_PURCHASE_FAILED = function()
  if not pending then return end
  note = "Kauf fehlgeschlagen."
  pending = nil
  changed()
  later(0.5, nextStep)
end

handlers.AUCTION_HOUSE_PURCHASE_COMPLETED = function(auctionID)
  if not buying or buying.auction.auctionID ~= auctionID then return end
  local hit, a = buying.hit, buying.auction
  bought(hit, 1, a.buyout)
  note = "Gekauft: " .. ns.ItemName(hit.itemID) .. " für " .. ns.FormatMoney(a.buyout, true)
  -- The group's auction id is used up; search the item again right away for fresh ids.
  hits[hit.key] = nil
  local again = { itemKey = hit.itemKey, itemID = hit.itemID, key = hit.key, recipe = hit.recipe }
  again.normal = not hit.recipe
  if watch then
    for _, w in ipairs(watch.keys) do
      if w.key == hit.key then again.recipe, again.normal = w.recipe, w.normal end
    end
  end
  table.insert(candidates, 1, again)
  buying = nil
  changed()
  later(0.5, nextStep)
end

handlers.AUCTION_HOUSE_SHOW_ERROR = function()
  if buying then
    note = "Kauf ging nicht – schon weg."
    hits[buying.hit.key] = nil
    buying = nil
    changed()
    later(0.5, nextStep)
  end
end

handlers.ADDON_ACTION_BLOCKED = function(addon, fn)
  if addon ~= ADDON or not running then return end
  if not manual then
    manual = true
    note = "Das Spiel verlangt pro Suchrunde einen Klick (" .. tostring(fn) .. ")."
    changed()
  end
end
handlers.ADDON_ACTION_FORBIDDEN = handlers.ADDON_ACTION_BLOCKED

handlers.AUCTION_HOUSE_CLOSED = function()
  if running then stopAll() end
end

for event in pairs(handlers) do listen(event) end
frame:SetScript("OnEvent", function(_, event, ...)
  local fn = handlers[event]
  if fn then ns.Safe(fn, ...) end
end)

-- Control --------------------------------------------------------------------------

function Sniper.IsRunning() return running end

-- An item asked for elsewhere (ns.AHSearch, e.g. the detail window): searched next, before
-- the rest of the watch list, like the re-search after a purchase. Its result goes to
-- ns.AHSearch.Store. front: ahead of the other asked items (a click beats a list check).
-- Returns false when the sniper does not run (search it yourself then).
function Sniper.Prioritize(itemID, front)
  if not running or not itemID or not api.MakeItemKey then return false end
  if detailing and detailing.itemID == itemID then return true end
  for i, c in ipairs(priority) do
    if c.itemID == itemID then
      if front and i > 1 then table.insert(priority, 1, table.remove(priority, i)) end
      return true
    end
  end
  local itemKey = api.MakeItemKey(itemID)
  table.insert(priority, front and 1 or #priority + 1, { itemKey = itemKey, itemID = itemID, key = keyOf(itemKey) })
  if phase == "wait" and not pending and not buying then
    -- between two rounds: search it now; the round pause starts again afterwards
    token = token + 1
    phase = "detail"
    nextStep()
  end
  return true
end
function Sniper.NeedsClick() return running and manual and phase == "wait" end
function Sniper.Pending() return pending end

-- The one button: Start, Stop, or (when the game wants a click per round) Suchen.
function Sniper.Click()
  if not running then
    if not (api.SendBrowseQuery and api.GetBrowseResults) then
      note = "Dieser Client hat keine Browse-Suche."
      return changed()
    end
    running, note, hits, checked, timeouts = true, nil, {}, {}, 0
    seen, roundNo = {}, 0
    diag, sentAt = { answered = 0, seconds = 0, waits = 0, late = 0, sent = 0 }, {}
    watch = buildWatchlist()
    token = token + 1
    session()
    sendBrowse()
  elseif Sniper.NeedsClick() then
    token = token + 1
    sendBrowse()
  else
    stopAll("Gestoppt.")
  end
  changed()
end

-- Offers of the item in the sniper's last search, grouped by unit price, cheapest first:
-- { { unit, count, own }... } (at most 25 levels) and the search time; nil if not searched.
function Sniper.Listings(itemID)
  local l = levels[itemID]
  if not l then return nil end
  return l.list, l.t
end

function Sniper.Hits()
  local list = {}
  for _, hit in pairs(hits) do table.insert(list, hit) end
  -- recipes first (rare, gone fast), then by profit
  table.sort(list, function(a, b)
    if (a.recipe or false) ~= (b.recipe or false) then return a.recipe == true end
    return a.profit > b.profit
  end)
  return list
end

-- Seconds one watch list search takes right now: the search spacing, or the measured
-- answer time plus the step delay when the server is slower.
local function pace()
  local answer = diag.answered > 0 and diag.seconds / diag.answered + 0.1 or 0
  return math.max(SEARCH_SPACING, answer)
end

-- Live state for the panel at the auction house:
--   { running, phase, round, index, total, left, eta (seconds), current (key or nil),
--     rows = { { itemID, key, limit, price (copper, false = no offer, nil = not yet),
--                checked (time() or nil), current (bool), hit (or nil) }... } }
-- Rows: hits first (best profit first), then the watch list in its own order.
function Sniper.State()
  local st = { running = running, phase = phase, round = roundNo, rows = {}, total = 0, index = 0, left = 0, eta = 0 }
  local current = detailing and detailing.key
  st.current = current
  local listed = {}
  local function row(key, itemID, hit)
    local s = seen[key]
    local limit = hit and hit.limit or (s and s.limit)
    local recipe = not hit and watch and watch.recipeSet and watch.recipeSet[itemID]
    if not limit and recipe then limit = Sniper.RecipeLimit(itemID) end
    if not limit then
      local ref = ns.Deals.Reference(itemID, nil)
      limit = ref and ref * ns.Deals.MaxShare()
    end
    listed[key] = true
    table.insert(st.rows, { itemID = itemID, key = key, limit = limit, price = s and s.price,
      checked = s and s.t, current = key == current, hit = hit, recipe = (hit and hit.recipe) or recipe or nil })
  end
  for _, hit in ipairs(Sniper.Hits()) do row(hit.key, hit.itemID, hit) end
  if watch then
    for _, w in ipairs(watch.keys) do
      if not listed[w.key] then row(w.key, w.itemID, nil) end
    end
    st.total = #watch.keys
    if running and phase == "detail" then
      st.left = math.min(st.total, #candidates + (detailing and 1 or 0))
    end
    st.index = st.total - st.left
    st.eta = st.left * pace()
  end
  return st
end

-- Status block for the panel: up to four short lines.
--   1 state (white), 2 progress of this session, 3 server answers, 4 last message (orange)
function Sniper.StatusLines()
  local s = ns.db and ns.db.sniper and ns.db.sniper.session
  local lines = {}
  if not running then
    lines[1] = "Gestoppt"
  elseif phase == "browse" then
    lines[1] = "Durchsucht das ganze AH …" .. (pages > 0 and (" Seite " .. pages) or "")
  elseif phase == "detail" and watch then
    local left = #candidates + (detailing and 1 or 0)
    lines[1] = string.format("Scannt: %d von %d Items", #watch.keys - left, #watch.keys)
  elseif phase == "detail" then
    lines[1] = string.format("Prüft %d Kandidaten …", #candidates + (detailing and 1 or 0))
  else
    lines[1] = string.format("Pause – Runde fertig (%d Items in %.0f s)", round.items, round.seconds)
  end
  if s then
    local minutes = math.max(1, math.floor(((s.stop or time()) - s.start) / 60))
    local text = string.format("%d Runden  ·  %d Treffer  ·  %d min", s.rounds, s.hits, minutes)
    if s.bought > 0 then
      text = text .. "  ·  gekauft " .. ns.FormatMoney(s.spent, true) .. ", erwartet +" .. ns.FormatMoney(s.expected, true)
    end
    lines[2] = text
  end
  if running and diag.sent > 0 then
    lines[3] = string.format("Server antwortet in Ø %.1f s%s", diag.answered > 0 and diag.seconds / diag.answered or 0,
      timeouts > 0 and string.format("  ·  %d ohne Antwort", timeouts) or "")
  end
  if note then lines[4] = note end
  if not running and not s then
    lines[2] = "Start: sucht laufend Angebote weit unter Wert."
    lines[3] = "Jeder Kauf ist ein Klick von dir."
  end
  return lines
end

function Sniper.Status()
  local lines, out = Sniper.StatusLines(), {}
  for i = 1, 4 do if lines[i] then table.insert(out, lines[i]) end end
  return table.concat(out, "  ·  ")
end
