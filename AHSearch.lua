-- AHSearch: the one place for single item searches outside the sniper's own rounds
-- (item detail window, live prices of the Selling panel, "Meine" auction check).
--   ns.AHSearch.Request(itemID, callback, front) queues a search; callback(offers, itemID, t)
--   gets the offers grouped by unit price, cheapest first: { { unit, count, own, ownCount }... }
--   (empty table = nothing on offer, nil = no answer or auction house closed).
-- Rules: searches only while the auction house is open, at most one per SPACING seconds
-- (shared with the sniper), and only when C_AuctionHouse.IsThrottledMessageSystemReady says so.
-- While the sniper runs, nothing is searched here: the item goes to the front of the
-- sniper's queue (ns.Sniper.Prioritize) and the callback fires when the sniper's result
-- arrives (Sniper calls AHSearch.Store). So at any time exactly one of the two waits for
-- a search answer: AHSearch (current) or the sniper (its `detailing`).
-- Every result, from here or from the sniper, ends up in one store: AHSearch.Last(itemID).
local ADDON, ns = ...

local AHSearch = {}
ns.AHSearch = AHSearch

local api = C_AuctionHouse or {}
local SPACING = 1.0        -- seconds between two searches (shared with the sniper)
local TIMEOUT = 6          -- own search without an answer
local HANDED_TIMEOUT = 45  -- item handed to the sniper and still no result
local LEVELS_MAX = 50

local open = false
local entries = {}         -- itemID -> { itemID, callbacks = {}, state = "queued"|"searching"|"sniper", since }
local queue = {}           -- itemIDs in order (state "queued")
local current = nil        -- entry of the own search that is waiting for its answer
local lastSent = -1000     -- GetTime() of the last search (own or sniper)
local last = {}            -- itemID -> { list = offers, t = time() }
local scheduled = false
local pump -- forward declared: used by schedule and Request, defined below

local function now() return GetTime and GetTime() or 0 end

local function ready()
  return not api.IsThrottledMessageSystemReady or api.IsThrottledMessageSystemReady()
end

function AHSearch.IsOpen()
  if open then return true end
  local ah = AuctionHouseFrame
  return ah ~= nil and ah.IsShown ~= nil and ah:IsShown() and true or false
end

-- Pacing shared with the sniper: time since the last search, stamp a sent search, and
-- whether an own search is waiting for its answer.
function AHSearch.Since() return now() - lastSent end
function AHSearch.Stamp() lastSent = now() end
function AHSearch.Busy() return current ~= nil end
AHSearch.SPACING = SPACING

local function sniperRunning()
  return ns.Sniper and ns.Sniper.IsRunning and ns.Sniper.IsRunning() and ns.Sniper.Prioritize and true or false
end

local function schedule(delay)
  if scheduled or not C_Timer then return end
  scheduled = true
  C_Timer.After(delay, function()
    scheduled = false
    ns.Safe(pump)
  end)
end

-- Offers grouped by unit price, cheapest first. listings: { { unit, count, own, ownCount }... }
function AHSearch.Levels(listings)
  local by, list = {}, {}
  for _, l in ipairs(listings or {}) do
    if l.unit and l.unit > 0 then
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
  end
  table.sort(list, function(a, b) return a.unit < b.unit end)
  for i = #list, LEVELS_MAX + 1, -1 do list[i] = nil end
  return list
end

-- Answers everyone waiting for the item (offers nil = no answer).
local function deliver(itemID, offers)
  local e = entries[itemID]
  if not e then return end
  entries[itemID] = nil
  for i = #queue, 1, -1 do if queue[i] == itemID then table.remove(queue, i) end end
  if current == e then current = nil end
  local t = last[itemID] and last[itemID].t or time()
  for _, cb in ipairs(e.callbacks) do ns.Safe(cb, offers, itemID, t) end
end

-- A search result for the item (from here or from the sniper): stored as the item's last
-- search and handed to everyone waiting for it. levels as AHSearch.Levels returns them.
function AHSearch.Store(itemID, levels)
  if not itemID or not levels then return end
  last[itemID] = ns.AuctionHouse.Tag({ list = levels, t = time() })
  deliver(itemID, levels)
end

-- Results belong to the house they were searched at: forgotten when another house opens.
ns.AuctionHouse.OnChange(function() last = {} end)

-- House and auctioneer of the item's last search ("A"/"N"/"H", npc id); nil if none.
function AHSearch.Source(itemID)
  local l = last[itemID]
  if not l then return nil end
  return l.ah, l.npc
end

-- The sniper's search for the item got no answer.
function AHSearch.Failed(itemID)
  local e = entries[itemID]
  if e and e.state == "sniper" then deliver(itemID, nil) end
end

-- Offers of the item's last search (grouped, cheapest first) and its time; nil if none.
function AHSearch.Last(itemID)
  local l = last[itemID]
  if not l then return nil end
  return l.list, l.t
end

-- "queued", "searching", "sniper" while a search for the item is on its way, else nil.
function AHSearch.State(itemID)
  local e = entries[itemID]
  return e and e.state
end

function AHSearch.Waiting()
  local n = 0
  for _ in pairs(entries) do n = n + 1 end
  return n
end

-- Own search ----------------------------------------------------------------------------

local function priceSort()
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  return { { sortOrder = order, reverseSort = false } }
end

local function finish(itemID, listings)
  local levels = AHSearch.Levels(listings)
  if ns.Item and ns.Item.Observe then ns.Item.Observe(itemID, levels[1] and levels[1].unit or nil) end
  AHSearch.Store(itemID, levels)
  schedule(0.1)
end

local function send(e)
  -- a full item key (random suffix such as "des Bären", item level) when the caller has one
  local itemKey = e.itemKey or (api.MakeItemKey and api.MakeItemKey(e.itemID))
  if not (itemKey and api.SendSearchQuery) then return deliver(e.itemID, nil) end
  current, e.state, e.since = e, "searching", now()
  lastSent = now()
  api.SendSearchQuery(itemKey, priceSort(), true)
  if C_Timer then
    C_Timer.After(TIMEOUT, function()
      if current == e then
        current = nil
        deliver(e.itemID, nil)
        ns.Safe(pump)
      end
    end)
  end
end

pump = function()
  if not AHSearch.IsOpen() then return end
  if current then return end -- the answer comes first
  local running = sniperRunning()
  for itemID, e in pairs(entries) do
    if e.state == "sniper" and (not running or now() - e.since > HANDED_TIMEOUT) then
      if running then
        deliver(itemID, nil) -- the sniper did not get to it
      else
        e.state = "queued"   -- the sniper stopped: search it here
        table.insert(queue, 1, itemID)
      end
    end
  end
  if running then
    -- Not in parallel to the sniper: hand everything to the front of its queue, in order.
    local keep = {}
    for _, id in ipairs(queue) do
      local e = entries[id]
      if e and ns.Sniper.Prioritize(id, e.front) then
        e.state, e.since = "sniper", now()
      elseif e then
        table.insert(keep, id)
      end
    end
    queue = keep
    if next(entries) then schedule(1) end
    return
  end
  local itemID = queue[1]
  if not itemID then return end
  if not ready() or AHSearch.Since() < SPACING then return schedule(0.25) end
  table.remove(queue, 1)
  local e = entries[itemID]
  if e then send(e) else schedule(0.1) end
end

-- Queues a search for the item. callback(offers, itemID, t) as described at the top; the same
-- callback function is not added twice for one item. front: ahead of the queued items (a
-- click on one item beats a list check). Returns false when the auction house is closed.
-- itemKey (optional): the full key of a variant (random suffix); else the plain item.
function AHSearch.Request(itemID, callback, front, itemKey)
  if not itemID or not AHSearch.IsOpen() then return false end
  -- fishing mode: only the fished item is searched
  local fish = ns.FishItem and ns.FishItem()
  if fish and itemID ~= fish then return false end
  local e = entries[itemID]
  if e and itemKey and e.state == "queued" then e.itemKey = itemKey end
  if not e then
    e = { itemID = itemID, callbacks = {}, state = "queued", since = now(), front = front, itemKey = itemKey }
    entries[itemID] = e
    if front then table.insert(queue, 1, itemID) else table.insert(queue, itemID) end
  elseif front and e.state == "queued" then
    e.front = true
    for i = #queue, 1, -1 do if queue[i] == itemID then table.remove(queue, i) end end
    table.insert(queue, 1, itemID)
  end
  if callback then
    local known = false
    for _, cb in ipairs(e.callbacks) do if cb == callback then known = true end end
    if not known then table.insert(e.callbacks, callback) end
  end
  ns.Safe(pump)
  return true
end

-- Events ----------------------------------------------------------------------------------

if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function() open = true end)
  ns.On("AUCTION_HOUSE_CLOSED", function()
    open = false
    local waiting = {}
    for itemID in pairs(entries) do table.insert(waiting, itemID) end
    current = nil
    for _, itemID in ipairs(waiting) do deliver(itemID, nil) end
    entries, queue = {}, {}
  end)
  -- An auction house error instead of the answer (measured 24 Nov: error 10 right after a
  -- failed purchase, then no answer - the next search came only after TIMEOUT, 7 s blind):
  -- the search is lost, free the slot at once.
  ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    local e = current
    if e and e.state == "searching" then
      current = nil
      deliver(e.itemID, nil)
      schedule(0.5)
    end
  end)
  ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
    if not current or current.itemID ~= itemID then return end
    local listings = {}
    for i = 1, (api.GetNumCommoditySearchResults(itemID) or 0) do
      local r = api.GetCommoditySearchResultInfo(itemID, i)
      if r and r.unitPrice then
        table.insert(listings, { unit = r.unitPrice, count = r.quantity or 1, own = r.containsOwnerItem,
          ownCount = r.containsOwnerItem and r.numOwnerItems or nil })
      end
    end
    finish(itemID, listings)
  end)
  ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
    if not current or not itemKey or current.itemID ~= itemKey.itemID then return end
    -- Gear comes in pages: ask for the rest first (the next update brings it).
    if api.HasFullItemSearchResults and not api.HasFullItemSearchResults(itemKey)
        and api.RequestMoreItemSearchResults and not current.more then
      current.more = true
      api.RequestMoreItemSearchResults(itemKey)
      return
    end
    local listings = {}
    for i = 1, (api.GetNumItemSearchResults(itemKey) or 0) do
      local r = api.GetItemSearchResultInfo(itemKey, i)
      -- One result = r.quantity auctions of one item each at buyoutAmount (as the sniper reads it).
      if r and r.buyoutAmount and r.buyoutAmount > 0 then
        table.insert(listings, { unit = r.buyoutAmount, count = r.quantity or 1, own = r.containsOwnerItem })
      end
    end
    finish(itemKey.itemID, listings)
  end)
end
