-- Ledger: every auction house trade of this character, whichever window it came from.
--   buy        purchase succeeded (hooks on C_AuctionHouse: PlaceBid, commodity purchase)
--   post       auction created (hooks on PostItem / PostCommodity)
--   sale       "sold" mail with invoice: price and the auction house cut
--   expired    "expired" mail, cancelled: "cancelled" mail
--   craft      the player made an item (see "Crafting" below)
--   vendor     sold to a merchant (c: what the merchant paid, no cut); a buyback removes it
--   buy with src = "vendor": bought from a merchant (BuyMerchantItem; c what was paid)
--   trade      a completed trade window: with (the other player), gg / gr gold given / received,
--              give / get = { { i, n }… } items given / received, own = 1 between household
--              characters. Items for gold also become buy / sale entries with src = "trade"
--              (the gold split by the items' market value), so they count in the profit.
-- Mails stay in the inbox until taken, so every scan sees them again. A mail counts
-- once: same kind, item, amount and count and a receive time within MAIL_SLACK of
-- an entry already logged is the same mail.
-- db.ledger[charKey] = { events = { { t, k, i, n, u, c, cut, p, d }... } }
--   t time, k kind, i itemID (nil if only the name is known), n item name,
--   u units, c copper (buy: paid, sale: price before cut), cut, p unit price (post), d duration,
--   dep deposit paid for the post (copper, all units; nil when the client could not tell)
--   craft only: prof profession name, pid profession id, rid recipe (spell) id, x casts,
--   r reagents used { { i, n }... }, src "cast" or "loot" (how it was detected)
local ADDON, ns = ...

local Ledger = {}
ns.Ledger = Ledger

local api = C_AuctionHouse or {}
local MAIL_SLACK = 900   -- seconds; receive time derived from daysLeft drifts a little
local MAIL_DAYS = 30     -- auction house mails are kept 30 days
local KEEP = 3000
Ledger.KEEP = KEEP   -- also the limit when Sync.lua merges another PC's events

local function book()
  ns.db.ledger = ns.db.ledger or {}
  local key = ns.CharKey()
  ns.db.ledger[key] = ns.db.ledger[key] or { events = {} }
  return ns.db.ledger[key]
end

local function nameOf(itemID)
  return itemID and ns.ItemName(itemID) or nil
end

local function add(e)
  e.t = e.t or time()
  e.n = e.n or nameOf(e.i)
  local events = book().events
  table.insert(events, e)
  while #events > KEEP do table.remove(events, 1) end
  if ns.PlannerUI and ns.PlannerUI.Refresh then ns.Safe(ns.PlannerUI.Refresh) end
end

-- Item id for a name from the mails: game cache first, then our own entries.
local function idForName(name)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local link = getInfo and select(2, getInfo(name))
  local id = link and tonumber(link:match("item:(%d+)"))
  if id then return id end
  local events = book().events
  for i = #events, 1, -1 do
    if events[i].n == name and events[i].i then return events[i].i end
  end
end

-- Purchases -------------------------------------------------------------------------

local auctionItem = {}   -- auctionID -> itemID, from any item search (ours or Blizzard's)
local bids = {}          -- auctionID -> { itemID, amount }
local commodity = nil    -- { itemID, units, total, confirmed }

ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
  if not (itemKey and api.GetNumItemSearchResults) then return end
  for i = 1, (api.GetNumItemSearchResults(itemKey) or 0) do
    local r = api.GetItemSearchResultInfo(itemKey, i)
    if r and r.auctionID then auctionItem[r.auctionID] = itemKey.itemID end
  end
end)

local function hook(name, fn)
  if type(api[name]) == "function" then hooksecurefunc(api, name, function(...) ns.Safe(fn, ...) end) end
end

hook("PlaceBid", function(auctionID, amount)
  bids[auctionID] = { itemID = auctionItem[auctionID], amount = amount }
end)

hook("StartCommoditiesPurchase", function(itemID, units)
  commodity = { itemID = itemID, units = units }
end)

hook("ConfirmCommoditiesPurchase", function(itemID, units)
  if commodity and commodity.itemID == itemID then
    commodity.units, commodity.confirmed = units, true
  end
end)

ns.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, total)
  if commodity then commodity.total = total end
end)

ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
  local c = commodity
  commodity = nil
  if not c or not c.total then return end
  add({ k = "buy", i = c.itemID, u = c.units, c = c.total })
end)

ns.On("COMMODITY_PURCHASE_FAILED", function() commodity = nil end)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
  local b = bids[auctionID]
  bids[auctionID] = nil
  if not b then return end
  add({ k = "buy", i = b.itemID, u = 1, c = b.amount })
end)

-- Posts -----------------------------------------------------------------------------

local posting = {}  -- posts sent, confirmed by AUCTION_HOUSE_AUCTION_CREATED in order

local function itemAt(location)
  local ok, id = pcall(C_Item.GetItemID, location)
  return ok and id or nil
end

-- Deposit the post costs; lost when the auction expires or is cancelled. The hooks run
-- right after the post call, while the item is still in the bag.
local function deposit(fn, ...)
  if type(api[fn]) ~= "function" then return nil end
  local ok, dep = pcall(api[fn], ...)
  return ok and type(dep) == "number" and dep or nil
end

hook("PostItem", function(location, duration, quantity, bid, buyout)
  table.insert(posting, { k = "post", i = itemAt(location), u = quantity or 1, p = buyout, d = duration,
    dep = deposit("CalculateItemDeposit", location, duration, quantity or 1) })
end)

hook("PostCommodity", function(location, duration, quantity, unitPrice)
  local itemID = itemAt(location)
  table.insert(posting, { k = "post", i = itemID, u = quantity, p = unitPrice, d = duration,
    dep = itemID and deposit("CalculateCommodityDeposit", itemID, duration, quantity) })
end)

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function()
  local e = table.remove(posting, 1)
  if e then add(e) end
end)

ns.On("AUCTION_HOUSE_CLOSED", function() posting, bids, commodity = {}, {}, nil end)

-- Mails -----------------------------------------------------------------------------

-- "Auktion abgelaufen: %s" -> pattern with the item name captured.
local function subjectPattern(fmt)
  if not fmt then return nil end
  return "^" .. fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
end

local EXPIRED = subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
local CANCELLED = subjectPattern(AUCTION_REMOVED_MAIL_SUBJECT)

-- Whether a mail with this signature and receive time is already in the ledger.
local function known(sig, t, used)
  local events = book().events
  for idx = #events, 1, -1 do
    local e = events[idx]
    if e.m == sig and not used[idx] and math.abs(e.t - t) <= MAIL_SLACK then
      used[idx] = true
      return true
    end
  end
  return false
end

-- A purchase the hooks logged (same item and amount, no mail signature yet, within
-- BUY_SLACK of the mail): tag it with the mail's signature; true if found.
local BUY_SLACK = 2 * 3600
local function tagLoggedBuy(e, t, used)
  local events = book().events
  for idx = #events, 1, -1 do
    local x = events[idx]
    if x.k == "buy" and not x.m and not used[idx] and x.c == e.c and (x.u or 1) == e.u
        and (x.i == e.i or (e.i == nil and x.n == e.n)) and math.abs((x.t or 0) - t) <= BUY_SLACK then
      x.m, used[idx] = e.m, true
      return true
    end
  end
  return false
end

local function scanInbox()
  if not GetInboxNumItems then return end
  local used = {}
  for i = 1, GetInboxNumItems() do
    local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
    local received = time() - math.floor(((MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400))
    local invoiceType, itemName, _, bid, _, _, cut, _, _, _, count = nil, nil
    if GetInboxInvoiceInfo then
      invoiceType, itemName, _, bid, _, _, cut, _, _, _, count = GetInboxInvoiceInfo(i)
    end
    local e
    if invoiceType == "seller" and itemName and bid then
      e = { k = "sale", n = itemName, u = count or 1, c = bid, cut = cut or 0 }
    elseif invoiceType == "buyer" and itemName and bid then
      -- A won auction: the purchase, also when the click was not seen (bought before the
      -- addon ran, or a way of buying the hooks miss). A buy the hooks logged already is
      -- only tagged with this mail's signature (no second purchase).
      e = { k = "buy", n = itemName, u = count or 1, c = bid }
    elseif subject then
      local name = EXPIRED and subject:match(EXPIRED)
      local kind = name and "expired"
      if not name and CANCELLED then
        name = subject:match(CANCELLED)
        kind = name and "cancelled"
      end
      if name then
        local _, itemID, _, n = GetInboxItem(i, 1)
        e = { k = kind, n = name, i = itemID, u = n or 1 }
      end
    end
    if e then
      e.i = e.i or idForName(e.n)
      e.m = table.concat({ e.k, e.n, e.c or 0, e.u }, "|")
      local seen = known(e.m, received, used)
      if not seen and e.k == "buy" and tagLoggedBuy(e, received, used) then
        -- logged by the purchase hooks already, now tagged with this mail
      elseif not seen then
        e.t = received
        add(e)
        used[#book().events] = true
      end
    end
  end
end

ns.On("MAIL_INBOX_UPDATE", function() ns.Safe(scanInbox) end)

-- Crafting --------------------------------------------------------------------------
-- How a craft is recognised (only what is certain):
--   1. UNIT_SPELLCAST_SUCCEEDED for "player" whose spellID is a recipe of this character's
--      own profession scan (ns.db.recipes, Recipes.lua; recipe ids are the craft spells).
--      Recipes without an output item (enchantments) are ignored. Reagents and the expected
--      units per cast come from that scan.
--   2. The loot line "Ihr stellt her: <item>" (LOOT_ITEM_CREATED_SELF[_MULTIPLE], read from
--      the client's format strings) corrects the units of a cast seen within LOOT_WINDOW.
--      Without such a cast (no scan of that profession yet) the line alone counts as a craft
--      only when the item is a product in ns.RecipeData; reagents then come from there.
--      Conjured food and other created items are no recipe products and stay out.
--   3. Made with a profession's tool (an item whose tooltip says "Benötigt <Beruf> (n)", e.g.
--      the salt shaker): the loot line within TOOL_WINDOW of using that item counts as a craft
--      of that profession; the reagents are what left the bags meanwhile (bag counts before
--      the use against after the next bag update).
--   Repeated casts of the same recipe within MERGE seconds go into one event (x casts),
--   so batch crafting does not push older trades out of the ledger.

local LOOT_WINDOW = 5
local MERGE = 60
local state = nil  -- last craft: { e, t, open = casts awaiting their loot line, q, loot }

-- "Ihr stellt her: %sx%d." -> pattern capturing link and (optional) count.
local function lootPattern(fmt)
  if type(fmt) ~= "string" then return nil end
  local p = fmt:gsub("%%%d%$", "%%")          -- positional "%1$s" -> "%s"
  p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
  return "^" .. p .. "$"
end

local CREATED_MULTI = lootPattern(LOOT_ITEM_CREATED_SELF_MULTIPLE)
local CREATED = lootPattern(LOOT_ITEM_CREATED_SELF)

-- The player's recipe for a spell id from the own profession scans.
local function ownRecipe(spellID)
  local prefix = ns.CharKey() .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    local r = key:sub(1, #prefix) == prefix and scan.recipes and scan.recipes[spellID]
    if r then return r, scan end
  end
end

-- Profession and reagents of a product from the shipped recipe data.
local function shippedRecipe(itemID)
  for pid, data in pairs(ns.RecipeData or {}) do
    for rid, rec in pairs(data.recipes or {}) do
      if rec[2] == itemID then
        local reagents, list = {}, rec[4] or {}
        for i = 1, #list, 2 do table.insert(reagents, { i = list[i], n = list[i + 1] }) end
        return { pid = pid, prof = data.name, rid = rid, q = rec[3] or 1, r = reagents }
      end
    end
  end
end

local function addReagents(e, reagents)
  e.r = e.r or {}
  for _, g in ipairs(reagents or {}) do
    if g.i and g.n then
      local found
      for _, have in ipairs(e.r) do
        if have.i == g.i then found = have break end
      end
      if found then found.n = found.n + g.n else table.insert(e.r, { i = g.i, n = g.n }) end
    end
  end
end

local function onCast(spellID)
  local recipe, scan = ownRecipe(spellID)
  if not (recipe and recipe.out) then return end
  local now = time()
  local q = recipe.qmin or 1
  local s = state
  if s and s.e.i == recipe.out and now - s.t <= MERGE then
    s.t = now
    if s.loot > 0 and s.e.src == "loot" then
      -- The loot line came first and already counted this cast.
      s.loot = s.loot - 1
      return
    end
    s.e.x, s.e.u = (s.e.x or 1) + 1, s.e.u + q
    addReagents(s.e, recipe.r)
    s.open = s.open + 1
    return
  end
  local e = { k = "craft", i = recipe.out, u = q, x = 1, rid = spellID, src = "cast",
    prof = scan.profession, pid = scan.professionID }
  addReagents(e, recipe.r)
  add(e)
  state = { e = e, t = now, open = 1, q = q, loot = 0 }
end

-- Profession tools ------------------------------------------------------------------------
local TOOL_WINDOW = 10
local PROFESSIONS = { ["Lederverarbeitung"] = true, ["Schneiderei"] = true, ["Schmiedekunst"] = true,
  ["Alchemie"] = true, ["Alchimie"] = true, ["Ingenieurskunst"] = true, ["Verzauberkunst"] = true,
  ["Kochkunst"] = true, ["Erste Hilfe"] = true, ["Bergbau"] = true, ["Kürschnerei"] = true,
  ["Kräuterkunde"] = true, ["Angeln"] = true }
local lastUse   -- { itemID, t, before = bag counts } (used from the bags)
local lastSpell -- { spellID, t, before = bag counts } (any cast, e.g. a tool on the action bar)
local pendingTool -- a tool craft waiting for the bags to show what was used up

local function bagCounts()
  local counts = {}
  local info = C_Container and C_Container.GetContainerItemInfo
  local slots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  if not (info and slots and ns.CarriedBags) then return counts end
  for _, bag in ipairs(ns.CarriedBags()) do
    for slot = 1, (slots(bag) or 0) do
      local it = info(bag, slot)
      if it and it.itemID then counts[it.itemID] = (counts[it.itemID] or 0) + (it.stackCount or 1) end
    end
  end
  return counts
end

-- The profession an item asks for ("Benötigt Lederverarbeitung (250)"), nil if none.
local function toolProfession(itemID)
  local get = C_TooltipInfo and C_TooltipInfo.GetItemByID
  if not (itemID and get) then return nil end
  local ok, data = pcall(get, itemID)
  for _, line in ipairs(ok and data and data.lines or {}) do
    local name = type(line.leftText) == "string" and line.leftText:match("^Benötigt (.-) %(%d+%)")
    if name and PROFESSIONS[name] then return name end
  end
end

Ledger.ToolProfession = toolProfession

function Ledger.OnItemUse(bag, slot)
  local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
  if not (info and info.itemID) then return end
  lastUse = { itemID = info.itemID, t = time(), before = bagCounts() }
end

-- A tool used from the action bar or by a macro never passes UseContainerItem: the cast is
-- recorded too, and the tool is the carried item whose use spell it was.
ns.On("UNIT_SPELLCAST_SENT", function(_, unit, _, _, spellID)
  if unit == "player" and spellID then lastSpell = { spellID = spellID, t = time(), before = bagCounts() } end
end)

local function itemSpellID(itemID)
  local get = (C_Item and C_Item.GetItemSpell) or GetItemSpell
  if not get then return nil end
  local ok, _, sid = pcall(get, itemID)
  return ok and sid or nil
end

-- The tool behind a loot line at time now: { itemID, prof, before } or nil.
local function recentTool(now)
  local use = lastUse
  local prof = use and now - use.t <= TOOL_WINDOW and toolProfession(use.itemID)
  if prof then return use.itemID, prof, use.before end
  local cast = lastSpell
  if not (cast and now - cast.t <= TOOL_WINDOW) then return nil end
  for id in pairs(cast.before) do
    if itemSpellID(id) == cast.spellID then
      prof = toolProfession(id)
      if prof then return id, prof, cast.before end
    end
  end
end

local function finishToolCraft()
  local p = pendingTool
  pendingTool = nil
  if not p then return end
  local after = bagCounts()
  local reagents = {}
  for id, n in pairs(p.before) do
    local gone = n - (after[id] or 0)
    if gone > 0 and id ~= p.itemID and id ~= p.tool then table.insert(reagents, { i = id, n = gone }) end
  end
  -- tool: the item used (Profit counts it as own use, not as stock to sell)
  local e = { k = "craft", i = p.itemID, u = p.count, x = 1, src = "tool", prof = p.prof, tool = p.tool }
  addReagents(e, reagents)
  add(e)
end
ns.On("BAG_UPDATE_DELAYED", function() if pendingTool then ns.Safe(finishToolCraft) end end)

local function onCreated(itemID, count)
  local now = time()
  local s = state
  if s and s.e.i == itemID and s.open > 0 and now - s.t <= LOOT_WINDOW then
    s.e.u = s.e.u + count - s.q
    s.open = s.open - 1
    return
  end
  local shipped = shippedRecipe(itemID)
  if not shipped then
    -- made with a profession's tool used just before
    local tool, prof, before = recentTool(now)
    if tool then
      pendingTool = { itemID = itemID, count = count, prof = prof, tool = tool, before = before }
      lastUse, lastSpell = nil, nil
      if C_Timer then C_Timer.After(2, function() if pendingTool then ns.Safe(finishToolCraft) end end) end
    end
    return
  end
  if s and s.e.i == itemID and s.e.src == "loot" and now - s.t <= MERGE then
    s.e.x, s.e.u = (s.e.x or 1) + 1, s.e.u + count
    addReagents(s.e, shipped.r)
    s.t, s.loot = now, s.loot + 1
    return
  end
  local e = { k = "craft", i = itemID, u = count, x = 1, rid = shipped.rid, src = "loot",
    prof = shipped.prof, pid = shipped.pid }
  addReagents(e, shipped.r)
  add(e)
  state = { e = e, t = now, open = 0, q = shipped.q, loot = 1 }
end

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if unit == "player" and spellID then onCast(spellID) end
end)

ns.On("CHAT_MSG_LOOT", function(_, text)
  if type(text) ~= "string" then return end
  local link, count = nil, nil
  if CREATED_MULTI then link, count = text:match(CREATED_MULTI) end
  if not link and CREATED then link = text:match(CREATED) end
  local itemID = link and tonumber(link:match("item:(%d+)"))
  if itemID then onCreated(itemID, tonumber(count) or 1) end
end)

-- Report ----------------------------------------------------------------------------

-- Per item: bought/sold/posted units and money, plus totals.
-- One trade event into the per-item summary (crafts are reported by Profit.lua).
local function summarize(items, e)
  local key = e.i or e.n or "?"
  local it = items[key]
  if not it then
    it = { itemID = e.i, name = e.n, bought = 0, spent = 0, posted = 0, sold = 0, net = 0,
      expired = 0, cancelled = 0, last = 0 }
    items[key] = it
  end
  it.itemID = it.itemID or e.i
  it.last = math.max(it.last, e.t or 0)
  if e.k == "buy" then
    it.bought, it.spent = it.bought + (e.u or 0), it.spent + (e.c or 0)
  elseif e.k == "post" then
    it.posted = it.posted + (e.u or 0)
  elseif e.k == "sale" then
    it.sold, it.net = it.sold + (e.u or 0), it.net + (e.c or 0) - (e.cut or 0)
  elseif e.k == "expired" then
    it.expired = it.expired + (e.u or 0)
  elseif e.k == "cancelled" then
    it.cancelled = it.cancelled + (e.u or 0)
  end
end

function Ledger.Summary()
  local items, total = {}, { bought = 0, spent = 0, sold = 0, net = 0, ownNet = 0, profit = 0, held = 0 }
  for _, e in ipairs(book().events) do
    if e.k ~= "craft" then summarize(items, e) end
  end
  local list = {}
  for _, it in pairs(items) do
    -- Profit only on traded units (bought and sold again), at the average purchase price.
    local avgCost = it.bought > 0 and it.spent / it.bought or 0
    local traded = math.min(it.sold, it.bought)
    local netPer = it.sold > 0 and it.net / it.sold or 0
    it.profit = traded * (netPer - avgCost)
    it.open = math.max(0, it.bought - it.sold)
    it.openCost = it.open * avgCost
    total.bought, total.spent = total.bought + it.bought, total.spent + it.spent
    total.sold, total.net = total.sold + it.sold, total.net + it.net
    total.ownNet = total.ownNet + (it.sold - traded) * netPer
    total.profit = total.profit + it.profit
    total.held = total.held + it.openCost
    table.insert(list, it)
  end
  table.sort(list, function(a, b) return a.last > b.last end)
  return list, total
end

-- Merchant sales ---------------------------------------------------------------------
-- A right click on a bag item with the merchant window open sells it. The hook runs after
-- the call while the slot still holds the (locked) item. A buyback in the same visit takes
-- the newest matching sale out again.

local merchantOpen = false
local visitSales = {}   -- events logged during this merchant visit, newest last

local function sellPriceOf(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local price = select(11, getInfo(itemID))
  return type(price) == "number" and price or nil
end

function Ledger.OnContainerUse(bag, slot)
  if not merchantOpen then return end
  if MerchantFrame and MerchantFrame.IsShown and not MerchantFrame:IsShown() then return end
  local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
  if not (info and info.itemID) or info.hasNoValue then return end
  local price = sellPriceOf(info.itemID)
  if not price or price <= 0 then return end
  local u = info.stackCount or 1
  local e = { k = "vendor", i = info.itemID, u = u, c = price * u }
  add(e)
  table.insert(visitSales, e)
end

function Ledger.OnBuyback(index)
  local link = GetBuybackItemLink and GetBuybackItemLink(index)
  local id = link and tonumber(link:match("item:(%d+)"))
  if not id then return end
  local events = book().events
  for v = #visitSales, 1, -1 do
    local e = visitSales[v]
    if e.i == id then
      table.remove(visitSales, v)
      for i = #events, 1, -1 do
        if events[i] == e then table.remove(events, i) break end
      end
      return
    end
  end
end

-- A purchase from a merchant: price per unit from the merchant list (its price is for a stack of
-- `perStack` units), quantity as asked for (nil: one stack). Items for other currencies only
-- (price 0) are left out.
function Ledger.OnMerchantBuy(index, quantity)
  if not (merchantOpen and GetMerchantItemInfo) then return end
  local _, _, price, perStack = GetMerchantItemInfo(index)
  local link = GetMerchantItemLink and GetMerchantItemLink(index)
  local id = link and tonumber(link:match("item:(%d+)"))
  if not (id and price and price > 0) then return end
  perStack = (perStack and perStack > 0) and perStack or 1
  local units = (quantity and quantity > 0) and quantity or perStack
  add({ k = "buy", i = id, u = units, c = math.floor(price / perStack * units + 0.5), src = "vendor" })
end

if hooksecurefunc then
  if BuyMerchantItem then
    hooksecurefunc("BuyMerchantItem", function(index, quantity) ns.Safe(Ledger.OnMerchantBuy, index, quantity) end)
  end
  if C_Container and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
      ns.Safe(Ledger.OnContainerUse, bag, slot)
      ns.Safe(Ledger.OnItemUse, bag, slot)
    end)
  elseif UseContainerItem then
    hooksecurefunc("UseContainerItem", function(bag, slot) ns.Safe(Ledger.OnContainerUse, bag, slot) end)
  end
  if BuybackItem then
    hooksecurefunc("BuybackItem", function(index) ns.Safe(Ledger.OnBuyback, index) end)
  end
end
if ns.On then
  ns.On("MERCHANT_SHOW", function() merchantOpen, visitSales = true, {} end)
  ns.On("MERCHANT_CLOSED", function() merchantOpen, visitSales = false, {} end)
end

-- Trade window ------------------------------------------------------------------------------
-- The last state of the trade window is kept on every change; when the game reports the trade
-- complete it is logged (see "trade" above). The window can close before or after that message.
local trade

local function tradeItems(linkOf, infoOf)
  local list = {}
  for slot = 1, 6 do -- slot 7: "will not be traded"
    local link = linkOf and linkOf(slot)
    local id = link and tonumber(link:match("item:(%d+)"))
    if id then
      local _, _, count = infoOf(slot)
      list[#list + 1] = { i = id, n = count or 1 }
    end
  end
  return list
end

local function snapshotTrade()
  if not trade then return end
  trade.give = tradeItems(GetTradePlayerItemLink, GetTradePlayerItemInfo)
  trade.get = tradeItems(GetTradeTargetItemLink, GetTradeTargetItemInfo)
  trade.gg = GetPlayerTradeMoney and GetPlayerTradeMoney() or 0
  trade.gr = GetTargetTradeMoney and GetTargetTradeMoney() or 0
end

-- Market value of items, for splitting a trade's gold among them.
local function worth(list)
  local total, each = 0, {}
  for k, it in ipairs(list) do
    local m = ns.Item and ns.Item(it.i) or {}
    local v = (m.ref or m.now or m.vendorSell or 1) * it.n
    each[k], total = v, total + v
  end
  return each, total
end

local function recordTrade(s)
  if #s.give == 0 and #s.get == 0 and s.gg == 0 and s.gr == 0 then return end
  local own
  for _, key in ipairs(Ledger.Household and Ledger.Household() or {}) do
    if key:match("^([^-]+)") == s.with then own = 1 end
  end
  add({ k = "trade", with = s.with, gg = s.gg, gr = s.gr, give = s.give, get = s.get, own = own })
  if own then return end
  -- items for gold: purchases or sales at that gold
  local net = s.gr - s.gg
  if #s.get > 0 and #s.give == 0 and net < 0 then
    local each, total = worth(s.get)
    for k, it in ipairs(s.get) do
      add({ k = "buy", i = it.i, u = it.n, c = math.floor(-net * each[k] / total + 0.5), src = "trade", with = s.with })
    end
  elseif #s.give > 0 and #s.get == 0 and net > 0 then
    local each, total = worth(s.give)
    for k, it in ipairs(s.give) do
      add({ k = "sale", i = it.i, u = it.n, c = math.floor(net * each[k] / total + 0.5), cut = 0, src = "trade", with = s.with })
    end
  end
end

if ns.On then
  ns.On("TRADE_SHOW", function() trade = { with = UnitName and UnitName("NPC") or "?" }; ns.Safe(snapshotTrade) end)
  for _, ev in ipairs({ "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE" }) do
    ns.On(ev, function() ns.Safe(snapshotTrade) end)
  end
  ns.On("UI_INFO_MESSAGE", function(_, _, message)
    if trade and message == ERR_TRADE_COMPLETE then
      local s = trade
      trade = nil
      ns.Safe(recordTrade, s)
    end
  end)
  ns.On("TRADE_CLOSED", function()
    local s = trade
    if C_Timer then C_Timer.After(2, function() if trade == s then trade = nil end end) end
  end)
end

-- All events of this character, oldest first (read only; Profit.lua replays them).
function Ledger.Events()
  return book().events
end

-- Household: every character of this WoW account on the same realm and faction (one auction
-- house). Faction from the character snapshot (Tracker.lua, db.chars); a character whose faction
-- is not known yet (never logged in on this PC) is left out until it is.
function Ledger.Household()
  local me = ns.CharKey()
  local realm = me:match("^[^-]+%-(.+)$")
  local mine = ns.db.chars and ns.db.chars[me]
  -- the own faction live from the game (a new character's snapshot may not be written yet)
  local faction = (UnitFactionGroup and UnitFactionGroup("player")) or (mine and mine.faction)
  local keys, seen = { me }, { [me] = true }
  local function consider(key)
    if seen[key] or type(key) ~= "string" then return end
    seen[key] = true
    local r = key:match("^[^-]+%-(.+)$")
    local c = ns.db.chars and ns.db.chars[key]
    if r == realm and faction and c and c.faction == faction then keys[#keys + 1] = key end
  end
  for key in pairs(ns.db.ledger or {}) do consider(key) end
  for key in pairs(ns.db.chars or {}) do consider(key) end
  table.sort(keys)
  return keys
end

-- The household's events in time order (the profit report replays them together, so goods
-- made by one character and sold by another carry their cost). Not copied: the events stay the
-- stored ones; Ledger.CharOf(e) tells whose event it is. Rebuilt when a book grew.
local merged, mergedKey, charOf = nil, nil, setmetatable({}, { __mode = "k" })
function Ledger.HouseholdEvents()
  local keys = Ledger.Household()
  local sig = {}
  for _, key in ipairs(keys) do
    local b = ns.db.ledger and ns.db.ledger[key]
    local events = b and b.events or {}
    sig[#sig + 1] = key .. "=" .. #events .. ":" .. tostring(events[#events])
  end
  local k = table.concat(sig, ",")
  if merged and k == mergedKey then return merged end
  local out = {}
  for _, key in ipairs(keys) do
    local b = ns.db.ledger and ns.db.ledger[key]
    for _, e in ipairs(b and b.events or {}) do
      out[#out + 1] = e
      charOf[e] = key
    end
  end
  table.sort(out, function(x, y) return (x.t or 0) < (y.t or 0) end)
  merged, mergedKey = out, k
  return out
end

function Ledger.CharOf(e) return charOf[e] end

function Ledger.Recent(n)
  local events, out = Ledger.HouseholdEvents(), {}
  for i = #events, math.max(1, #events - n + 1), -1 do table.insert(out, events[i]) end
  return out
end

-- One-time data fix (20 Nov 2026): Raffiniertes Tiefsteinsalz posted before the tool crafts were
-- recognised was made with the salt shaker (Lederverarbeitung): a craft just before its first
-- post. Same time on every PC, so the sync keeps one copy.
ns.OnReady(function()
  local b = book()
  if b.toolFix1 then return end
  b.toolFix1 = true
  local events, crafted, firstPost = b.events, false, nil
  for _, e in ipairs(events) do
    if e.i == 15409 and e.k == "craft" then crafted = true end
    if e.i == 15409 and e.k == "post" and not firstPost then firstPost = e end
  end
  if crafted or not firstPost then return end
  local e = { t = (firstPost.t or time()) - 60, k = "craft", i = 15409, n = nameOf(15409), u = 1, x = 1,
    src = "tool", prof = "Lederverarbeitung", r = { { i = 8150, n = 1 } } }
  table.insert(events, e)
  table.sort(events, function(x, y) return (x.t or 0) < (y.t or 0) end)
end)

-- One-time data fix (23 Nov 2026): the salt shaker used from the action bar was not recognised
-- (only uses from the bags were). Every post of Raffiniertes Tiefsteinsalz without enough salt
-- crafted or bought before gets the missing craft a minute before it (Deeprock salt per unit).
-- Deterministic times, so the sync keeps one copy.
ns.OnReady(function()
  for _, b in pairs(ns.db.ledger or {}) do
    if type(b) == "table" and type(b.events) == "table" and not b.toolFix2 then
      b.toolFix2 = true
      local have, missing = 0, {}
      for _, e in ipairs(b.events) do
        if e.i == 15409 then
          local u = e.u or 1
          if e.k == "craft" or e.k == "buy" or e.k == "cancelled" or e.k == "expired" then have = have + u
          elseif e.k == "post" then
            if have < u then table.insert(missing, { t = (e.t or time()) - 60, u = u - have }); have = u end
            have = have - u
          end
        end
      end
      for _, m in ipairs(missing) do
        table.insert(b.events, { t = m.t, k = "craft", i = 15409, n = nameOf(15409), u = m.u, x = m.u,
          src = "tool", prof = "Lederverarbeitung", tool = 15846, r = { { i = 8150, n = m.u } } })
      end
      if #missing > 0 then table.sort(b.events, function(x, y) return (x.t or 0) < (y.t or 0) end) end
    end
  end
end)

-- One-time import of purchases the sniper logged before the ledger existed (16 Nov 2026), once
-- per account: the log is the account's, its purchases were the first character's. (Until
-- 20 Nov 2026 every new character imported them again; those copies are removed below.)
ns.OnReady(function()
  local b = book()
  if b.imported then return end
  b.imported = true
  local anyImported = false
  for key, other in pairs(ns.db.ledger or {}) do
    if key ~= ns.CharKey() and type(other) == "table" and other.imported then anyImported = true end
  end
  if anyImported then return end
  local log = ns.db.sniper and ns.db.sniper.log or {}
  for _, e in ipairs(log) do
    if e.k == "buy" and e.c then
      table.insert(b.events, { t = e.t, k = "buy", i = e.i, n = nameOf(e.i), u = 1, c = e.c })
    end
  end
  table.sort(b.events, function(x, y) return x.t < y.t end)
end)

-- Clean-up (20 Nov 2026): the sniper log's purchases copied into later characters. A purchase of
-- the log stays only in the book that has the most events (the character that really bought
-- them). Runs every session, also after the cloud sync merged its copies back in.
local function removeSniperCopies()
  local log = ns.db.sniper and ns.db.sniper.log or {}
  local fromLog = {}
  for _, e in ipairs(log) do
    if e.k == "buy" and e.c then fromLog[tostring(e.t) .. ":" .. tostring(e.i) .. ":" .. tostring(e.c)] = true end
  end
  if not next(fromLog) then return end
  local owner, most = nil, -1
  for key, b in pairs(ns.db.ledger or {}) do
    if type(b) == "table" and #(b.events or {}) > most then owner, most = key, #(b.events or {}) end
  end
  for key, b in pairs(ns.db.ledger or {}) do
    if key ~= owner and type(b) == "table" and b.events then
      local keep = {}
      for _, e in ipairs(b.events) do
        local k = tostring(e.t) .. ":" .. tostring(e.i) .. ":" .. tostring(e.c)
        if not (e.k == "buy" and fromLog[k] and not e.m) then keep[#keep + 1] = e end
      end
      b.events = keep
    end
  end
end
ns.OnReady(function() ns.Safe(removeSniperCopies) end)
ns.On("PLAYER_LOGIN", function() ns.Safe(removeSniperCopies) end)
