-- Item: the one place for an item's market data. Every module takes its numbers from
-- here; nothing else reads price sources (collector export, own scans, searches).
--
-- ns.Item(itemID) -> {
--   now        "AH jetzt" in every view: the price it can be bought for right now, i.e. the
--              cheapest offer (copper per unit), nil if not on offer; from the newest of
--              collector snapshot, own full scan, own searches and other players'
--              observations (ns.AHObs, Data_Obs<house>.lua; live: ns.Live, LiveChannel.lua)
--   offers, quantity   auctions / units listed at that time
--   dataT      time() of the source "now" comes from
--   dataSource "cloud" (snapshot), "scan" (own full scan), "search" (own search), "players"
--              (other players' observations via the cloud) or "live" (other players' observations
--              over the addon channel this session): where now / offers / quantity are from
--   levels     the cheapest unit prices of that source as "price:units;..." (at most 8, see
--              Item.PriceLevels), nil when the source has none (snapshot; scans and searches
--              not recorded as observations, e.g. of a house without cloud id)
--   medToday, medTodayHours  median of the hourly cheapest offers today (Berlin calendar
--                      day, 0:00-23:59 German time) so far, and the hours behind it (internal,
--                      not shown)
--   medYesterday       the same median over the whole previous Berlin day
--   med7, med7Days     the same median over today plus the 6 full days before, days behind it
--   ref, refSource     R, THE reference price everywhere (selling, sniper, recipes, views):
--                      med7 once it rests on 3 days, else medYesterday, else med7, else medToday; refSource "yesterday" /
--                      "week" / "today" (Item.RefLabel). Same rule as the cloud (price_ref).
--   demand     units bought per day, counted by the cloud itself over 7 days (commodities:
--              estimated sales; items: only auctions that were the cheapest offer). Shown as a
--              level: Item.DemandText (DEMAND_LEVELS)
--   saturation share bought of the offers up to 5 % above the cheapest (cloud, 7 days), nil
--              without enough: Item.SaturationText (unterversorgt / ausgeglichen / übersättigt)
--   certain    units certainly bought per day (partial purchases of commodities, a lower
--              bound; nil for items that are not commodities)
--   change     now / medYesterday - 1 ("zu Median gestern")
--   trend      PPO of the daily prices, EMA 3 days / EMA 14 days - 1 (cloud)
--   direction  1 rising, -1 falling, 0 sideways (EMA 3 / 7 / 14 in order or not)
--   vendorSell what a merchant pays, vendorBuy what a merchant charges (nil if unknown)
--   guildSale  what guild members really sold it for: { median, sales, units, days } -
--              median unit price (before the cut) over the last days, from the members'
--              ledgers without names (m4d, Data_GuildSales.lua; only from 3 sales on), nil
--              without. Shown only (Item.GuildSaleText); not part of R or any formula yet.
-- }
-- Derived (the only formulas for these):
--   Item.SellNet(e)  selling one unit: the lower of (cheapest offer - 1 copper) and R,
--                    minus the 5 % cut; a merchant if he pays more (same rule as the
--                    cloud's ahprofessions)
--   Item.BuyCost(e)  buying one unit: merchant, else cheapest offer, else R
--   Item.MaterialCost(list)  buying a reagent list { itemID, count, ... } via BuyCost
--   Item.Value(e)    what one unit is worth to the player (= SellNet)
-- Producers report live observations with Item.Observe (single item searches).
-- Pure Lua apart from guarded game calls, so tools/ can load it too.
local ADDON, ns = ...

local CUT = 0.05

-- Classic merchant prices of common reagents, until a merchant visit records the real one.
local VENDOR_ESTIMATE = {
  [2320] = 10, [2321] = 100, [4291] = 500, [8343] = 2000, [14341] = 5000,
  [4289] = 50, [4340] = 350, [2324] = 25, [2604] = 50, [2605] = 100,
  [6260] = 50, [6261] = 1000, [2325] = 1000,
}

local Item = {}
local observed = {}   -- itemID -> { now, t } from single item searches (this session)

-- The cloud data of the current auction house (ns.AuctionHouse.CloudData), nil without; and
-- the cloud house id.
local function collector(itemID)
  local house, id = ns.AuctionHouse.CloudData()
  return house and house.items[itemID], house, id
end

-- Observations of the item in the current house (cloud id): the own ones (ns.db.obs, recorded by
-- Observations.lua from full scans and searches, kept across sessions) and the other players'
-- (ns.AHObs from the data addon: { t, m, q, n, confirmations, d }, only those newer than the
-- house's snapshot).
local function ownObs(id, itemID)
  local h = id and ns.db and ns.db.obs and ns.db.obs[id]
  local o = h and h[itemID]
  return type(o) == "table" and type(o.t) == "number" and o or nil
end

local function playersObs(id, itemID)
  local h = id and ns.AHObs and ns.AHObs[id]
  local r = type(h) == "table" and type(h.items) == "table" and h.items[itemID]
  return type(r) == "table" and type(r[1]) == "number" and type(r[2]) == "number" and r or nil
end

-- UTC "2026-11-17T09:18:56Z" -> epoch seconds (cached).
local epochCache = {}
local function epoch(iso)
  if not iso or not time then return nil end
  if epochCache[iso] == nil then
    local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
    local t = false
    if y then
      -- time() reads the table as local time; shift by the local UTC offset.
      local now = time()
      local offset = now - time(date("!*t", now))
      -- nil for a date the client cannot represent locally (m4d's empty shell carries 1970-01-01)
      local local_ = time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
        min = tonumber(mi), sec = tonumber(s), isdst = false })
      t = local_ and local_ + offset or false
    end
    epochCache[iso] = t
  end
  return epochCache[iso] or nil
end
Item.Epoch = epoch

-- Guild sales prices from the data addon (M4CompanionData.GuildSales, kept current by the
-- companion app): { updated, days, houses = { [house] = { [itemID] = { median, sales, units } } } }.
-- Looked up per call: the data addon loads after this one.
local function guildSale(itemID)
  local live = rawget(_G, "M4CompanionData")
  local gs = type(live) == "table" and live.GuildSales
  local id = ns.AuctionHouse.CloudID()
  if type(gs) ~= "table" or not id then return nil end
  local items
  if type(gs.houses) == "table" then items = gs.houses[id]
  elseif id == ns.AuctionHouse.PRIMARY_CLOUD then items = gs.items end
  local row = type(items) == "table" and items[itemID]
  if type(row) ~= "table" or type(row[1]) ~= "number" or row[1] <= 0 then return nil end
  return { median = row[1], sales = row[2] or 0, units = row[3] or 0, days = gs.days or 7 }
end

local function clientVendorSell(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local price = getInfo and select(11, getInfo(itemID))
  if type(price) == "number" then return price end
  local known = ns.db and ns.db.vendorSell and ns.db.vendorSell[itemID]
  return known
end

function Item.Get(itemID)
  local row, house, id = collector(itemID)
  local e = { itemID = itemID }
  -- now / offers / quantity / levels: the newest source wins (on a tie the earlier one here, so
  -- an own observation with price levels beats the same scan's summary).
  local bestT = -1
  if row then
    bestT = epoch(house.updated) or 0
    e.now, e.offers, e.quantity, e.dataSource = row[1], row[7], row[8], "cloud"
  end
  local own = ownObs(id, itemID)
  if own and own.t > bestT then
    e.now, e.quantity, e.offers, e.levels = own.m, own.q, own.n, own.d
    e.dataSource = own.s == 1 and "scan" or "search"
    bestT = own.t
  end
  local ah = ns.AuctionHouse.Peek() -- the own scan of the current auction house
  if ah and ah.currentT and ah.currentT > bestT then
    local live = ah.current and ah.current[itemID]
    -- own scan row: { min, marketValue, quantity, offers, sellers }
    e.now = live and live[1] and live[1] > 0 and live[1] or nil
    e.quantity, e.offers, e.levels, e.dataSource = live and live[3] or 0, live and live[4] or 0, nil, "scan"
    bestT = ah.currentT
  end
  local o = observed[itemID]
  -- single searches belong to the automatic house: not while another house is viewed. They
  -- also know "nothing on offer", which the observations cannot hold.
  if o and o.t > bestT and ns.AuctionHouse.Current() == ns.AuctionHouse.Auto() then
    e.now, e.levels, e.dataSource = o.now, nil, "search"
    if not o.now then e.quantity, e.offers = 0, 0 end
    bestT = o.t
  end
  local p = playersObs(id, itemID)
  if p and p[1] > bestT then
    e.now, e.quantity, e.offers, e.levels, e.dataSource = p[2], p[3], p[4], p[6], "players"
    bestT = p[1]
  end
  -- other players' observations heard over the addon channel (LiveChannel.lua, loaded later)
  local l = ns.Live and ns.Live.Get(id, itemID)
  if l and l.t > bestT then
    e.now, e.quantity, e.offers, e.levels, e.dataSource = l.m, l.q, l.n, l.d, "live"
    bestT = l.t
  end
  e.dataT = bestT > 0 and bestT or nil
  if row then
    -- demand: units bought per day, own count of the cloud (field 25 since 24 Nov 2026); an
    -- older collector file has only the old scale (field 18, a tenth of it)
    e.demand = row[25] or (row[18] and row[18] * 10)
    e.certain = row[19]
    e.saturation = row[26]
    e.trend, e.direction = row[16], row[17]
    e.medToday, e.medTodayHours, e.medYesterday, e.med7, e.med7Days = row[20], row[21], row[22], row[23], row[24]
    -- A collector file from before the medians (fields 20-24 missing): its daily price of
    -- the previous UTC day (field 15, the same median, other day boundary) stands in.
    if row[21] == nil and row[24] == nil and row[15] then e.medYesterday = row[15] end
  end
  e.ref, e.refSource = Item.Reference(e)
  if e.now and e.medYesterday and e.medYesterday > 0 then e.change = e.now / e.medYesterday - 1 end
  local vs = clientVendorSell(itemID)
  e.vendorSell = vs and vs > 0 and vs or nil
  e.vendorBuy = (ns.db and ns.db.vendorBuy and ns.db.vendorBuy[itemID]) or VENDOR_ESTIMATE[itemID]
  e.guildSale = guildSale(itemID)
  return e
end

-- All offers of the item in the own full scan, cheapest first: { { unit, count }... }, and
-- the scan time; nil without a scan. (The only place that reads the scan's listings.)
function Item.Listings(itemID)
  local h = ns.AuctionHouse.Peek()
  local last = h and h.last
  local keys = last and last.items and last.items[itemID]
  if not keys then return nil, last and last.t end
  local list = {}
  for _, key in ipairs(keys) do
    local unit, count = key:match("^(%d+):(%d+):")
    if unit then table.insert(list, { unit = tonumber(unit), count = tonumber(count) }) end
  end
  table.sort(list, function(x, y) return x.unit < y.unit end)
  return list, last.t
end

-- Price history from the collector (Data_History.lua, every listed item, compact format; the
-- older table format is read too): { start = epoch of the first slot, step = seconds per slot,
--   prices = { cheapest offer per slot, 0 = not listed, false = no snapshot }, qty = {...},
--   hourly = true for the 1-hour slots } or nil.
-- Item.History(id)        the last 7 days in 2-hour slots
-- Item.History(id, true)  the last 48 hours in 1-hour slots (ns.History.hours); a file without
--                         them (older collector) gives its 2-hour slots instead
-- The live copy from the data addon (m4-companion_Data, kept current by the companion app,
-- global M4CompanionData) wins over the one shipped with this addon.
-- Looked up per call: the data addon loads after this one.
-- Per house id: ns.HistoryAH[id] of the data addon; the collector's main house also has it as
-- ns.History (older data addons only that one, and the copy shipped with this addon).
local function historyTable(id)
  local live = rawget(_G, "M4CompanionData")
  local per = type(live) == "table" and type(live.HistoryAH) == "table" and live.HistoryAH[id]
  if type(per) == "table" then return per end
  if id ~= ns.AuctionHouse.PRIMARY_CLOUD then return nil end
  if type(live) == "table" and type(live.History) == "table" then return live.History end
  return ns.History
end

-- One compact list "350,,,-,0,725": empty = same as before, "-" = no snapshot (false).
local function decodeSlots(text, n)
  local out, prev, i = {}, false, 0
  for tok in (text .. ","):gmatch("([^,]*),") do
    i = i + 1
    if tok == "-" then prev = false
    elseif tok ~= "" then prev = tonumber(tok) or false end
    out[i] = prev
  end
  for k = i + 1, n or i do out[k] = false end
  return out
end

local decoded = setmetatable({}, { __mode = "k" }) -- history table -> key -> result

-- "prices;qty" of one item -> history, false if unreadable.
local function decodeLine(text, start, step, n)
  if type(text) ~= "string" then return false end
  local p, q = text:match("^([^;]*);(.*)$")
  if not p then return false end
  return { start = start, step = step, prices = decodeSlots(p, n), qty = decodeSlots(q, n) }
end

local function historyFrom(history, itemID, hourly)
  if not history then return nil end
  if type(history.items) == "table" then
    -- Compact format (all listed items): ns.History = { start, step, n, items = { [id] = "p;q" },
    -- hourStart, hourStep, hourN, hours = { [id] = "p;q" } }
    local cache = decoded[history]
    if not cache then cache = {}; decoded[history] = cache end
    local key = hourly and ("h" .. itemID) or itemID
    if cache[key] ~= nil then return cache[key] or nil end
    local result = false
    if hourly and type(history.hours) == "table" and history.hours[itemID] then
      result = decodeLine(history.hours[itemID], history.hourStart, history.hourStep or 3600, history.hourN)
      if result then result.hourly = true end
    end
    if not result then
      result = decodeLine(history.items[itemID], history.start, history.step or 3600, history.n)
    end
    cache[key] = result
    return result or nil
  end
  local h = history[itemID]
  if type(h) ~= "table" then return nil end
  return { start = h[1], step = h.step or 3600, prices = h.prices or {}, qty = h.qty or {} }
end

-- The app's live copy first; an item it does not know (older or smaller file) from the copy
-- shipped with the addon.
function Item.History(itemID, hourly)
  local id = ns.AuctionHouse.CloudID() -- the history of the current house's cloud data
  if not id then return nil end
  local live = historyTable(id)
  return historyFrom(live, itemID, hourly)
    or (id == ns.AuctionHouse.PRIMARY_CLOUD and live ~= ns.History and historyFrom(ns.History, itemID, hourly)) or nil
end

-- Price levels "460:120;465:80" (Item.Get's levels) -> { { unit, count }... } cheapest first;
-- empty for nil or "".
function Item.PriceLevels(text)
  local list = {}
  for unit, count in tostring(text or ""):gmatch("(%d+):(%d+)") do
    list[#list + 1] = { unit = tonumber(unit), count = tonumber(count) }
  end
  return list
end

-- Items in the own full scan (itemID -> true).
function Item.ScannedItems()
  local h = ns.AuctionHouse.Peek()
  local last = h and h.last
  return last and last.items or {}
end

-- A single item search saw this cheapest offer (nil = none on offer) right now.
function Item.Observe(itemID, cheapest, t)
  observed[itemID] = { now = cheapest, t = t or (time and time()) or 0 }
end

-- What single searches saw belongs to the house they were made at: forgotten on a switch.
ns.AuctionHouse.OnChange(function() observed = {} end)

-- R and its source from the medians of an item table (see the head of this file).
-- R: the median of the 7 days (one odd day moves it little) once it rests on at least 3 days,
-- else of yesterday, else of the 7 days, else of today. Same rule as the cloud
-- (ahmetrics.price_ref_source, WEEK_MIN_DAYS).
Item.WEEK_MIN_DAYS = 3
function Item.Reference(e)
  if e.med7 and e.med7 > 0 and (e.med7Days or 0) >= Item.WEEK_MIN_DAYS then return e.med7, "week" end
  if e.medYesterday and e.medYesterday > 0 then return e.medYesterday, "yesterday" end
  if e.med7 and e.med7 > 0 then return e.med7, "week" end
  if e.medToday and e.medToday > 0 then return e.medToday, "today" end
  return nil, nil
end

Item.REF_LABELS = { yesterday = "Marktwert gestern", week = "Marktwert 7 Tage", today = "Marktwert heute" }

-- "Median gestern" etc.: what R of the item is; nil without R.
function Item.RefLabel(e)
  return e.refSource and Item.REF_LABELS[e.refSource] or nil
end

-- "-10 % zu Median gestern" (price against R), nil without R.
function Item.RefCompare(price, e)
  if not price or not e.ref or e.ref <= 0 then return nil end
  local d = price / e.ref - 1
  local pct = math.floor(math.abs(d) * 100 + 0.5) * (d < 0 and -1 or 1)
  return string.format("%+d %% zu %s", pct, Item.RefLabel(e))
end

-- "Median heute 15g · gestern 23g · 7 Tage 23g": the three medians, the ones we have; nil
-- without any. short = copper left out (tooltips).
function Item.MedianText(e, short)
  local fmt = ns.FormatMoney or function(c) return tostring(c) end
  local parts = {}
  if e.medToday then table.insert(parts, "heute " .. fmt(e.medToday, short)) end
  if e.medYesterday then table.insert(parts, "gestern " .. fmt(e.medYesterday, short)) end
  if e.med7 then table.insert(parts, "7 Tage " .. fmt(e.med7, short)) end
  if #parts == 0 then return nil end
  return "Marktwert " .. table.concat(parts, " · ")
end

-- "15g 20s (23×, 7 Tage)": what guild members sold it for (median unit price, number of
-- sales, days); nil without. short = copper left out (tooltips).
function Item.GuildSaleText(e, short)
  local g = e and e.guildSale
  if not g then return nil end
  local fmt = ns.FormatMoney or function(c) return tostring(c) end
  return string.format("%s (%d\195\151, %d Tage)", fmt(g.median, short), g.sales, g.days)
end

function Item.SellNet(e)
  -- The current price: undercut the cheapest offer now (it carries every trend). Only an offer
  -- more than 50 % above R (median, see Item.Reference) is no market (one seller asking far
  -- too much, shown as "unsicher"): then R. Without an offer now: R.
  local base = e.now and (e.now - 1) or e.ref
  if base and e.ref and e.now and e.now > e.ref * 1.5 then base = e.ref end
  local ah = base and base > 0 and math.floor(base * (1 - CUT)) or 0
  local vendor = e.vendorSell or 0
  if ah > 0 and ah >= vendor then return ah, true end
  return vendor, false
end

function Item.BuyCost(e)
  if e.vendorBuy then return e.vendorBuy, true end
  return e.now or e.ref, false
end

-- Copper for a reagent list { itemID, count, ... } (recipe format), each unit via BuyCost.
-- nil and the first item without a price when one is missing. The only formula for
-- material costs (crafting tab, tooltip, recipe items).
function Item.MaterialCost(list)
  local cost = 0
  for i = 1, #(list or {}), 2 do
    local unit = Item.BuyCost(Item.Get(list[i]))
    if not unit then return nil, list[i] end
    cost = cost + unit * (list[i + 1] or 1)
  end
  return cost
end

-- The current price is far from R (more than 50 % above or below): a single offer that
-- may not be the market. Views mark such prices as "unsicher".
function Item.Unsure(e)
  return e.now ~= nil and e.ref ~= nil and e.ref > 0 and (e.now > e.ref * 1.5 or e.now < e.ref * 0.5)
end

function Item.Value(e)
  return (Item.SellNet(e))
end

-- "+49 % steigt" for views; nil without data. The word follows the number (3-day vs 14-day
-- average): from +3 % "steigt", from -3 % "fällt", in between "seitwärts" - so a -1 % item is
-- not called falling.
function Item.TrendText(e)
  if not e.trend then return nil end
  local word = e.trend >= 0.03 and "steigt" or (e.trend <= -0.03 and "fällt" or "seitwärts")
  local pct = math.floor(math.abs(e.trend) * 100 + 0.5) * (e.trend < 0 and -1 or 1)
  return string.format("%+d %% %s", pct, word)
end

-- Demand levels, units bought per day.
Item.DEMAND_LEVELS = { { 200, "sehr hoch" }, { 50, "hoch" }, { 10, "mittel" }, { 1, "niedrig" } }

-- The demand level in its color: hoch / sehr hoch green, mittel white, niedrig / kaum red.
function Item.DemandColored(e)
  local text = Item.DemandText(e)
  if not text then return nil end
  local color = (text == "hoch" or text == "sehr hoch") and "|cff5fd38d" or (text == "mittel" and "|cffffffff" or "|cffff6b6b")
  return color .. text .. "|r"
end

-- Saturation: are offers above the cheapest bought too? >= 50 %: unterversorgt, < 20 %:
-- übersättigt (only the cheapest sells), between: ausgeglichen. Returns text, color; nil without.
function Item.SaturationText(e)
  local s = e and e.saturation
  if not s then return nil end
  local pct = math.floor(s * 100 + 0.5)
  if s >= 0.5 then return "unterversorgt", pct, "|cff5fd38d" end
  if s < 0.2 then return "übersättigt", pct, "|cffff6b6b" end
  return "ausgeglichen", pct, "|cffffb547"
end

-- "hoch" etc. for views; nil without data.
function Item.DemandText(e)
  if e.demand == nil then return nil end
  for _, level in ipairs(Item.DEMAND_LEVELS) do
    if e.demand >= level[1] then return level[2] end
  end
  return "kaum"
end

-- The demand level as a symbol, for the auction house list (own textures, one flat style, made
-- by tools/demand_icons.py): red arrow down (niedrig, kaum), orange bar (mittel), green arrow up
-- (hoch), flame (sehr hoch); nil without data.
local function icon(name) return "|TInterface\\AddOns\\m4-companion\\media\\" .. name .. ":14:14|t" end
local DEMAND_ICONS = {
  ["sehr hoch"] = icon("demand_top"),
  ["hoch"] = icon("demand_high"),
  ["mittel"] = icon("demand_mid"),
  ["niedrig"] = icon("demand_low"),
}
DEMAND_ICONS["kaum"] = DEMAND_ICONS["niedrig"]
function Item.DemandIcon(e)
  local text = Item.DemandText(e)
  return text and (DEMAND_ICONS[text] or text) or nil
end

Item.CUT = CUT
ns.Item = setmetatable(Item, { __call = function(_, itemID) return Item.Get(itemID) end })
