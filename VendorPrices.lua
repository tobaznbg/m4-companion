-- VendorPrices: records what merchants pay for every item seen in the auction
-- house, straight from the client's item data. Forever changed many vendor
-- prices, so outside data (classic values) cannot be trusted for this.
-- Result: M4CompanionDB.vendorSell[itemID] = copper (0 = cannot be sold).
local ADDON, ns = ...

local BATCH = 100      -- items per step
local STEP_DELAY = 0.2 -- seconds between steps
local MAX_PASSES = 5   -- items not yet cached are retried in later passes

local running = false

local function getInfo(itemID)
  local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  return fn and select(11, fn(itemID))
end

local function collect()
  local houses = ns.db.ah and ns.db.ah.houses
  if not houses or running then return end
  running = true
  ns.db.vendorSell = ns.db.vendorSell or {}
  local known = ns.db.vendorSell
  local todo, queued = {}, {}
  -- the items of every house's scan (merchant prices are the same everywhere)
  for _, h in pairs(houses) do
    for itemID in pairs(h.current or {}) do
      if known[itemID] == nil and not queued[itemID] then
        queued[itemID] = true
        table.insert(todo, itemID)
      end
    end
  end
  local pass, index, missing = 1, 1, {}
  local function step()
    local last = math.min(#todo, index + BATCH - 1)
    for i = index, last do
      local itemID = todo[i]
      local price = getInfo(itemID)
      if type(price) == "number" then
        known[itemID] = price
      else
        table.insert(missing, itemID)
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
      end
    end
    index = last + 1
    if index > #todo then
      if #missing == 0 or pass >= MAX_PASSES then
        running = false
        return
      end
      pass, index, todo, missing = pass + 1, 1, missing, {}
      C_Timer.After(5, function() ns.Safe(step) end)
    else
      C_Timer.After(STEP_DELAY, function() ns.Safe(step) end)
    end
  end
  step()
end

ns.VendorPrices = { Collect = collect }

ns.OnReady(function()
  C_Timer.After(20, function() ns.Safe(collect) end)
end)
