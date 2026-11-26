-- Inventory: what the character holds (bags always, bank when it was opened)
-- and what to do with each item: sell on the auction house, sell to a vendor,
-- or keep.
local ADDON, ns = ...

local Inventory = {}
ns.Inventory = Inventory

local CUT = 0.05
-- The auction house is worth the effort when it beats the vendor by 20 % per unit
-- and by at least 10 silver for the whole stack.
local AH_OVER_VENDOR = 1.2
local AH_MIN_GAIN = 100     -- AH must bring at least 1 silver more than the merchant (whole stack)
local CLASS_CONSUMABLE, CLASS_QUEST = 0, 12
-- Consumables you use yourself: potion, elixir, flask, scroll, food, enhancement, bandage.
-- Other consumables (e.g. Forever's intercepted crates) are judged like goods.
local KEEP_CONSUMABLE = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }

local function containerApi()
  local c = C_Container or {}
  return c.GetContainerNumSlots or GetContainerNumSlots, c.GetContainerItemInfo
end

-- itemID -> count for the given container IDs.
local function readContainers(ids)
  local numSlots, itemInfo = containerApi()
  local result = {}
  for _, bag in ipairs(ids) do
    for slot = 1, (numSlots(bag) or 0) do
      local info = itemInfo and itemInfo(bag, slot)
      if info and info.itemID then
        local entry = result[info.itemID]
        if not entry then
          entry = { n = 0, q = info.quality, bound = info.isBound, noValue = info.hasNoValue, loot = info.hasLoot }
          result[info.itemID] = entry
        end
        entry.n = entry.n + (info.stackCount or 1)
        entry.bound = entry.bound or info.isBound
      end
    end
  end
  return result
end

local function store()
  ns.db.inventory = ns.db.inventory or {}
  local inv = ns.db.inventory[ns.CharKey()] or {}
  ns.db.inventory[ns.CharKey()] = inv
  return inv
end

function Inventory.ScanBags()
  local inv = store()
  inv.bags, inv.bagsT = readContainers(ns.CarriedBags()), time()
end

function Inventory.ScanBank()
  local inv = store()
  inv.bank, inv.bankT = readContainers(ns.BankBags()), time()
end

local function itemClass(itemID)
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not getInstant then return nil end
  local _, _, _, equipLoc, _, classID, subclassID = getInstant(itemID)
  return classID, equipLoc, subclassID
end

-- Recommendation for one stack: action, reason, revenue per unit.
function Inventory.Advise(itemID, entry)
  local item = ns.Item(itemID)
  local vendor = item.vendorSell or 0
  local net, viaAH = ns.Item.SellNet(item)
  local ah = (item.now or item.ref) and viaAH and net or nil
  local classID, equipLoc, subclassID = itemClass(itemID)

  -- Openable items (clams, chests, lockboxes): open them yourself, no sale advice.
  if entry.loot then return "behalten", "selbst öffnen", 0, vendor end
  if entry.q == 0 then return "Händler", "grau", vendor, vendor end
  -- Forever's intercepted crates are filled and turned in for Merchant's Favor.
  if itemID >= 248682 and itemID <= 248713 then return "behalten", "Kiste: füllen für Händlergunst", 0, vendor end
  if classID == CLASS_QUEST then return "behalten", "Quest", 0, vendor end
  if entry.bound then
    if vendor > 0 then return "Händler", "gebunden", vendor, vendor end
    return "behalten", "gebunden", 0, vendor
  end
  if classID == CLASS_CONSUMABLE and KEEP_CONSUMABLE[subclassID] then
    return "behalten", "Verbrauchsgut", 0, vendor
  end
  if ah and ah > vendor * AH_OVER_VENDOR and (ah - vendor) * (entry.n or 1) >= AH_MIN_GAIN then
    local reason = equipLoc and equipLoc ~= "" and "falls nicht getragen" or "AH bringt mehr"
    if item.demand and item.demand < 1 then reason = "AH, aber kaum Käufer" end
    return "AH", reason, ah, vendor
  end
  if vendor > 0 then return "Händler", ah and "AH bringt kaum mehr" or "nicht im AH", vendor, vendor end
  return "behalten", "kein Wert", 0, vendor
end

-- Rows for the window: one per item and place, sorted by value.
function Inventory.Rows()
  local inv = ns.db.inventory and ns.db.inventory[ns.CharKey()] or {}
  local rows = {}
  for _, place in ipairs({ { "bags", "Taschen" }, { "bank", "Bank" } }) do
    for itemID, entry in pairs(inv[place[1]] or {}) do
      local action, reason, unit, vendor = Inventory.Advise(itemID, entry)
      table.insert(rows, {
        itemID = itemID, count = entry.n, place = place[2], action = action, reason = reason,
        value = unit * entry.n, vendorTotal = vendor * entry.n,
      })
    end
  end
  table.sort(rows, function(a, b) return a.value > b.value end)
  return rows, inv
end

ns.On("BAG_UPDATE_DELAYED", function() ns.Safe(Inventory.ScanBags) end)
ns.On("PLAYER_ENTERING_WORLD", function() C_Timer.After(3, function() ns.Safe(Inventory.ScanBags) end) end)
ns.On("BANKFRAME_OPENED", function() C_Timer.After(0.5, function() ns.Safe(Inventory.ScanBank) end) end)
ns.On("PLAYERBANKSLOTS_CHANGED", function() ns.Safe(Inventory.ScanBank) end)
