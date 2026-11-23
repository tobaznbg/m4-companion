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
