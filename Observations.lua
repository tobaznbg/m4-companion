-- Observations: what the player sees at the auction house (own full scans, searches) between
-- the hourly cloud snapshots. The companion app uploads them on logout / reload, the cloud
-- merges them with every other player's and sends them back with the data bundle
-- (Data_Obs<house>.lua -> ns.AHObs, read by Item.Get). Contract v1, seam 1:
--
-- M4CompanionDB.obs = { [cloud house id] = { [itemID] = { t, m, q, n, d, s } } }
--   t  time() of the observation      m  cheapest buyout per unit (copper, > 0)
--   q  units on offer                 n  offers (auctions of a full scan, result rows of a search)
--   d  up to 8 cheapest distinct unit prices "price:units;..." ascending ("" allowed)
--   s  source: 1 own full scan, 2 commodity search, 3 item search
-- Only the newest observation per house and item is kept, only for the house of the auctioneer
-- in front of the player (a house merely selected in a view was not seen) and only for houses
-- with a cloud id (the cloud could not place the others). Pruned on login and logout: older than
-- 48 h goes, at most 60,000 entries (oldest first) - the companion app sends only what is new.
-- A search that finds nothing is not recorded: the contract has no "not on offer" (m > 0).
local ADDON, ns = ...

local Obs = {}
ns.Obs = Obs

Obs.MAX_AGE = 48 * 3600
Obs.MAX_ENTRIES = 60000
Obs.LEVELS = 8
Obs.SCAN, Obs.COMMODITY, Obs.ITEM = 1, 2, 3

local listeners = {}
-- fn(itemID, source, recorded) runs after every search result at an auctioneer, recorded or
-- not (an empty one is not, but views showing live offers redraw on it too).
function Obs.OnRecord(fn) table.insert(listeners, fn) end

-- The cloud house id of the auctioneer in front of the player, nil away from one or without id.
function Obs.OpenHouseID()
  local open = ns.AuctionHouse.Open()
  return open and tonumber(ns.AuctionHouse.CloudID(open.house)) or nil
end

-- The observations of one cloud house (created on first use).
function Obs.Items(id)
  local db = ns.db
  db.obs = db.obs or {}
  local items = db.obs[id]
  if not items then
    items = {}
    db.obs[id] = items
  end
  return items
end

-- Records one item's offers { { unit, count }... } seen at time t into items (Obs.Items).
-- One pass, no sort: the 8 cheapest distinct prices are kept in a small sorted window, so the
-- full scan (~250k listings) costs no more than its own summary. A price pushed out of the
-- window never comes back (only cheaper ones can enter), so its units are not needed.
-- An older observation never replaces a newer one. Returns whether it was recorded.
function Obs.Put(items, itemID, t, offers, source)
  local old = items[itemID]
  if old and old.t and old.t > t then return false end
  local prices, units, k = {}, {}, 0
  local m, q, n = nil, 0, 0
  for _, l in ipairs(offers) do
    local unit, count = l.unit, l.count or 1
    if unit and unit > 0 then
      n = n + 1
      q = q + count
      if not m or unit < m then m = unit end
      if units[unit] then
        units[unit] = units[unit] + count
      elseif k < Obs.LEVELS or unit < prices[k] then
        if k == Obs.LEVELS then
          units[prices[k]] = nil
          k = k - 1
        end
        local i = k
        while i > 0 and prices[i] > unit do prices[i + 1] = prices[i]; i = i - 1 end
        prices[i + 1] = unit
        units[unit] = count
        k = k + 1
      end
    end
  end
  if not m then return false end
  for i = 1, k do prices[i] = math.floor(prices[i]) .. ":" .. math.floor(units[prices[i]]) end
  -- the table is reused: the full scan touches ~20k items at once
  local o = old or {}
  o.t, o.m, o.q, o.n, o.d, o.s = t, math.floor(m), math.floor(q), n, table.concat(prices, ";"), source
  items[itemID] = o
  return true
end

-- Searches --------------------------------------------------------------------------------
-- Every search the player sees counts, the addon's own (AHSearch, sniper) and Blizzard's.

local function recordSearch(itemID, offers, source)
  if not (itemID and ns.db and ns.AuctionHouse.Open()) then return end
  local id = Obs.OpenHouseID()
  local recorded = id and Obs.Put(Obs.Items(id), itemID, time(), offers, source) or false
  for _, fn in ipairs(listeners) do ns.Safe(fn, itemID, source, recorded) end
end

-- Trace ("/m4 spur <item>"): for a traced item every commodity search keeps its front rows with
-- price, quantity and sellers, only when they changed - to follow what one seller does (e.g. a
-- single unit far under the market, again and again). Local only: never uploaded, never sent.
-- ns.db.traceItems = { [itemID] = true }, ns.db.traceLog[itemID] = { { t, rows }... } with rows
-- "unit:qty:owner/owner(+n);...", kept TRACE_KEEP, at most TRACE_MAX entries per item.
local TRACE_ROWS, TRACE_KEEP, TRACE_MAX = 12, 48 * 3600, 20000

local function trace(itemID)
  local api = C_AuctionHouse
  local parts = {}
  for i = 1, math.min(TRACE_ROWS, api.GetNumCommoditySearchResults(itemID) or 0) do
    local r = api.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice then
      local owners = type(r.owners) == "table" and table.concat(r.owners, "/") or ""
      local more = (r.totalNumberOfOwners or 0) - (type(r.owners) == "table" and #r.owners or 0)
      parts[#parts + 1] = string.format("%d:%d:%s%s", r.unitPrice, r.quantity or 0, owners,
        more > 0 and ("(+" .. more .. ")") or "")
    end
  end
  local rows = table.concat(parts, ";")
  ns.db.traceLog = ns.db.traceLog or {}
  local log = ns.db.traceLog[itemID] or {}
  ns.db.traceLog[itemID] = log
  local last = log[#log]
  if last and last[2] == rows then return end
  log[#log + 1] = { time(), rows }
  if #log > TRACE_MAX then table.remove(log, 1) end
end

-- "/m4 spur <item>": switches the trace of an item on or off.
function Obs.ToggleTrace(itemID)
  ns.db.traceItems = ns.db.traceItems or {}
  local on = not ns.db.traceItems[itemID]
  ns.db.traceItems[itemID] = on or nil
  return on
end

local function commodityResults(_, itemID)
  local api = C_AuctionHouse
  if not (api and api.GetNumCommoditySearchResults and api.GetCommoditySearchResultInfo) then return end
  if ns.db.traceItems and ns.db.traceItems[itemID] then ns.Safe(trace, itemID) end
  local offers = {}
  -- With not all rows loaded q holds the units of the loaded ones (cheapest first) - the cheap
  -- end, which is what the price levels describe.
  for i = 1, (api.GetNumCommoditySearchResults(itemID) or 0) do
    local r = api.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.unitPrice > 0 then offers[#offers + 1] = { unit = r.unitPrice, count = r.quantity or 1 } end
  end
  recordSearch(itemID, offers, Obs.COMMODITY)
end

local function itemResults(_, itemKey)
  local api = C_AuctionHouse
  if type(itemKey) ~= "table" or not (api and api.GetNumItemSearchResults and api.GetItemSearchResultInfo) then return end
  -- Variants (random suffix "des Bären", battle pets) are other goods under the same item id;
  -- the cloud keeps one row per item id, so only plain items are recorded.
  if (itemKey.itemSuffix or 0) ~= 0 or (itemKey.battlePetSpeciesID or 0) ~= 0 then return end
  local offers = {}
  for i = 1, (api.GetNumItemSearchResults(itemKey) or 0) do
    local r = api.GetItemSearchResultInfo(itemKey, i)
    -- one result = r.quantity auctions of one item each at buyoutAmount (as AHSearch reads it)
    if r and r.buyoutAmount and r.buyoutAmount > 0 then offers[#offers + 1] = { unit = r.buyoutAmount, count = r.quantity or 1 } end
  end
  recordSearch(itemKey.itemID, offers, Obs.ITEM)
end

-- Pruning ---------------------------------------------------------------------------------

function Obs.Prune(now)
  local db = ns.db
  if not db then return end
  if type(db.obs) ~= "table" then db.obs = {} return end
  local cutoff = (now or time()) - Obs.MAX_AGE
  local total = 0
  for id, items in pairs(db.obs) do
    if type(items) ~= "table" then
      db.obs[id] = nil
    else
      for itemID, o in pairs(items) do
        if type(o) ~= "table" or type(o.t) ~= "number" or o.t < cutoff then items[itemID] = nil else total = total + 1 end
      end
      if next(items) == nil then db.obs[id] = nil end
    end
  end
  if total <= Obs.MAX_ENTRIES then return end
  local all = {}
  for id, items in pairs(db.obs) do
    for itemID, o in pairs(items) do all[#all + 1] = { o.t, id, itemID } end
  end
  table.sort(all, function(a, b) return a[1] < b[1] end)
  for i = 1, total - Obs.MAX_ENTRIES do
    local a = all[i]
    db.obs[a[2]][a[3]] = nil
  end
  for id, items in pairs(db.obs) do
    if next(items) == nil then db.obs[id] = nil end
  end
end

if ns.On then
  ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", commodityResults)
  ns.On("ITEM_SEARCH_RESULTS_UPDATED", itemResults)
  -- also on logout: a long session (several full scans) must not write more than the cap
  ns.On("PLAYER_LOGOUT", function() Obs.Prune() end)
end
if ns.OnReady then
  ns.OnReady(function()
    Obs.Prune()
    -- old trace entries go on login
    local cut = time() - TRACE_KEEP
    for id, log in pairs(ns.db.traceLog or {}) do
      local keep = {}
      for _, e in ipairs(log) do if e[1] >= cut then keep[#keep + 1] = e end end
      ns.db.traceLog[id] = #keep > 0 and keep or nil
    end
  end)
end
