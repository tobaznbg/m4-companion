-- AuctionProbe: records which auction house API this client offers, so the
-- listing recorder can be built on the right one. Runs on every AH visit.
local ADDON, ns = ...

local function has(fn) return type(fn) == "function" end

ns.On("AUCTION_HOUSE_SHOW", function()
  local modern = C_AuctionHouse or {}
  ns.db.ahApi = {
    t = time(),
    replicateItems = has(modern.ReplicateItems),
    getReplicateItemInfo = has(modern.GetReplicateItemInfo),
    getReplicateItemTimeLeft = has(modern.GetReplicateItemTimeLeft),
    getItemSearchResultInfo = has(modern.GetItemSearchResultInfo),
    queryAuctionItems = has(QueryAuctionItems),
    getAuctionItemInfo = has(GetAuctionItemInfo),
    getAuctionItemTimeLeft = has(GetAuctionItemTimeLeft),
    canSendAuctionQuery = has(CanSendAuctionQuery),
  }
end)

-- Search probe: every field the client gives per row of an item opened at the auction house
-- (C_AuctionHouse item / commodity search), the last few searches, to see what is known per
-- auction (sellers?). ns.db.searchProbe = { { t, itemID, kind, rows = { { field = value }… } }… }
local function plain(v, depth)
  if type(v) ~= "table" then return v end
  if (depth or 0) > 2 then return "<table>" end
  local out = {}
  for k, x in pairs(v) do out[tostring(k)] = plain(x, (depth or 0) + 1) end
  return out
end
local function probeSearch(kind, key)
  local api = C_AuctionHouse
  if not (ns.db and api) then return end
  local n, get
  if kind == "commodity" then
    n, get = api.GetNumCommoditySearchResults and api.GetNumCommoditySearchResults(key), api.GetCommoditySearchResultInfo
  else
    n, get = api.GetNumItemSearchResults and api.GetNumItemSearchResults(key), api.GetItemSearchResultInfo
  end
  if not (n and get) then return end
  local rows = {}
  for i = 1, math.min(n, 8) do
    local ok, r = pcall(get, key, i)
    if ok and type(r) == "table" then rows[#rows + 1] = plain(r) end
  end
  ns.db.searchProbe = ns.db.searchProbe or {}
  local list = ns.db.searchProbe
  table.insert(list, 1, { t = time(), kind = kind, itemID = type(key) == "table" and key.itemID or key, total = n, rows = rows })
  while #list > 5 do table.remove(list) end
end
if ns.On then
  ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey) ns.Safe(probeSearch, "item", itemKey) end)
  ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID) ns.Safe(probeSearch, "commodity", itemID) end)
end

-- Full scan probe: does the full scan (C_AuctionHouse.ReplicateItems) know the seller, and when?
-- After REPLICATE_ITEM_LIST_UPDATE every row is re-read at a few delays: how many rows have an
-- owner and hasAllInfo, plus every return value of the first rows (is there an auction id?).
-- After the 10 s pass the item data of rows still missing info is requested (as TSM does).
-- ns.db.replicateProbe = { t, passes = { { after, n, owner, allInfo }… }, sample = { … } }
local REPL_PASSES = { 0, 2, 10, 30, 90 }
local function replPass(probe, after)
  local api = C_AuctionHouse
  local n = api.GetNumReplicateItems and api.GetNumReplicateItems() or 0
  local owner, allInfo, missing = 0, 0, {}
  for i = 0, n - 1 do
    local r = { api.GetReplicateItemInfo(i) }
    if r[14] and r[14] ~= "" then owner = owner + 1 end
    if r[18] then allInfo = allInfo + 1 elseif r[17] then missing[r[17]] = true end
  end
  table.insert(probe.passes, { after = after, n = n, owner = owner, allInfo = allInfo })
  if after == 0 or after == REPL_PASSES[#REPL_PASSES] then
    for i = 0, math.min(n, 5) - 1 do
      local packed = { n = select("#", api.GetReplicateItemInfo(i)), api.GetReplicateItemInfo(i) }
      local row = { at = after, index = i, count = packed.n }
      for k = 1, packed.n do row["v" .. k] = tostring(packed[k]) end
      table.insert(probe.sample, row)
    end
  end
  if after == 10 and C_Item and C_Item.RequestLoadItemDataByID then
    local asked = 0
    for itemID in pairs(missing) do
      C_Item.RequestLoadItemDataByID(itemID); asked = asked + 1
    end
    probe.requested = asked
  end
end
-- The call itself is recorded too (called = time): if no list update follows, the server refused.
local replFrame = CreateFrame("Frame")
replFrame:SetScript("OnEvent", function(self)
  self:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  local probe = ns.db.replicateProbe
  probe.t = time()
  for _, after in ipairs(REPL_PASSES) do
    C_Timer.After(after, function() ns.Safe(replPass, probe, after) end)
  end
end)
if C_AuctionHouse and C_AuctionHouse.ReplicateItems then
  hooksecurefunc(C_AuctionHouse, "ReplicateItems", function()
    ns.db.replicateProbe = { called = time(), passes = {}, sample = {} }
    replFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  end)
end
