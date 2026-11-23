-- SourceLog: where recipes come from in WoW Forever, as the game shows it while playing (it only
-- listens; nothing is clicked or bought). It checks the recipe sources (Data_RecipeSources.lua,
-- partly Classic data marked c = 1) against the real game:
--   merchant  a merchant window: every recipe item it sells, its price, whether stock is limited
--   trainer   a trainer window: every service shown (name, skill needed, cost)
--   loot      a recipe item looted: from which creature (or object)
-- ns.db.sourceLog = { v = 1,
--   merchant = { [npcID] = { name, zone, map, x, y, t, items = { [itemID] = { p = copper, lim = 1|nil, n = units
--                there now (limited stock), t } }, visits = { { t, s = { [itemID] = units } }… } } },
--              visits: the stock of its limited recipes per visit (0 = a limited recipe seen before is
--              gone: sold out), the last 50 - when it restocks
--   trainer  = { [npcID] = { name, zone, map, x, y, t, skill = profession, s = { [service name] =
--                { req = skill needed, c = copper, t } } } },
--   loot     = { [itemID] = { [source] = { n = times, t = last } } } }   source: npc id, or "o<id>" for an object
-- /m4 quellen prints what is recorded.
local ADDON, ns = ...

local Log = {}
ns.SourceLog = Log

local RECIPE_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9

local function isRecipe(itemID)
  local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not (info and itemID) then return false end
  local ok, _, _, _, _, _, classID = pcall(info, itemID)
  return ok and classID == RECIPE_CLASS
end

-- npc id from a GUID ("Creature-0-…-<npcID>-…"); objects as "o<id>".
local function sourceOf(guid)
  if type(guid) ~= "string" then return nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  id = tonumber(id)
  if not id then return nil end
  if kind == "Creature" or kind == "Vehicle" then return id end
  if kind == "GameObject" then return "o" .. id end
  return nil
end

local function root()
  local db = ns.db
  db.sourceLog = db.sourceLog or { v = 1 }
  local log = db.sourceLog
  log.merchant, log.trainer, log.loot = log.merchant or {}, log.trainer or {}, log.loot or {}
  return log
end

-- The NPC in front of the player with name and place: an entry of a log part (created once).
local function npcEntry(part)
  local id = sourceOf(UnitGUID and UnitGUID("npc"))
  if type(id) ~= "number" then return nil end
  local e = part[id] or {}
  part[id] = e
  e.name = (UnitName and UnitName("npc")) or e.name
  local map, x, y
  if ns.PlayerPosition then map, x, y = ns.PlayerPosition() end
  e.zone = (GetZoneText and GetZoneText()) or e.zone
  if map then e.map, e.x, e.y = map, x and math.floor(x * 1000 + 0.5) / 10, y and math.floor(y * 1000 + 0.5) / 10 end
  e.t = time()
  return e
end

local function recordMerchant()
  if not (ns.db and GetMerchantNumItems) then return end
  local items = {}
  for i = 1, GetMerchantNumItems() or 0 do
    local id = GetMerchantItemID and GetMerchantItemID(i)
    if not id and GetMerchantItemLink then
      local link = GetMerchantItemLink(i)
      id = link and tonumber(link:match("item:(%d+)"))
    end
    if id and isRecipe(id) then
      -- price and stock: the classic function, else the modern C_MerchantFrame.GetItemInfo (table)
      local ok, price, numAvailable = false, nil, nil
      if GetMerchantItemInfo then
        local _
        ok, _, _, price, _, numAvailable = pcall(GetMerchantItemInfo, i)
      elseif C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local okI, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if okI and type(info) == "table" then ok, price, numAvailable = true, info.price, info.numAvailable end
      end
      local limited = ok and numAvailable and numAvailable >= 0
      items[id] = { p = ok and price or nil, lim = limited and 1 or nil, n = limited and numAvailable or nil, t = time() }
    end
  end
  if not next(items) then return end -- only merchants with recipes are kept
  local e = npcEntry(root().merchant)
  if not e then return end
  e.items = e.items or {}
  -- stock of the limited recipes this visit; one seen limited before and missing now: sold out
  local stock = {}
  for id, v in pairs(e.items) do if v.lim and not items[id] then stock[id] = 0 end end
  for id, v in pairs(items) do
    if v.lim then stock[id] = v.n or 0 end
    e.items[id] = v
  end
  if next(stock) then
    e.visits = e.visits or {}
    local last = e.visits[#e.visits]
    -- one entry per visit (MERCHANT_UPDATE fires several times while the window is open)
    if last and time() - last.t < 120 then last.s = stock else table.insert(e.visits, { t = time(), s = stock }) end
    while #e.visits > 50 do table.remove(e.visits, 1) end
  end
end

local function recordTrainer()
  if not (ns.db and GetNumTrainerServices) then return end
  local e = npcEntry(root().trainer)
  if not e then return end
  e.s = e.s or {}
  for i = 1, GetNumTrainerServices() or 0 do
    local name, _, category = GetTrainerServiceInfo(i)
    if name and category ~= "header" then
      local skill, rank = nil, nil
      if GetTrainerServiceSkillReq then skill, rank = GetTrainerServiceSkillReq(i) end
      local cost = GetTrainerServiceCost and GetTrainerServiceCost(i)
      e.s[name] = { req = rank, c = cost, t = time() }
      if skill and skill ~= "" then e.skill = skill end
    end
  end
end

local function recordLoot()
  if not (ns.db and GetNumLootItems and GetLootSlotLink) then return end
  for slot = 1, GetNumLootItems() or 0 do
    local link = GetLootSlotLink(slot)
    local id = link and tonumber(link:match("item:(%d+)"))
    if id and isRecipe(id) then
      local src = GetLootSourceInfo and sourceOf((GetLootSourceInfo(slot)))
      if src then
        local loot = root().loot
        loot[id] = loot[id] or {}
        local s = loot[id][src] or { n = 0 }
        s.n, s.t = s.n + 1, time()
        loot[id][src] = s
      end
    end
  end
end

if ns.On then
  ns.On("MERCHANT_SHOW", function() ns.Safe(recordMerchant) end)
  ns.On("MERCHANT_UPDATE", function() ns.Safe(recordMerchant) end) -- items arriving late
  ns.On("TRAINER_SHOW", function() ns.Safe(recordTrainer) end)
  ns.On("TRAINER_UPDATE", function() ns.Safe(recordTrainer) end)
  ns.On("LOOT_OPENED", function() ns.Safe(recordLoot) end)
end

-- "/m4 quellen": what is recorded so far.
function Log.Summary()
  local log = root()
  local m, mi, t, ts, l = 0, 0, 0, 0, 0
  for _, e in pairs(log.merchant) do m = m + 1; for _ in pairs(e.items or {}) do mi = mi + 1 end end
  for _, e in pairs(log.trainer) do t = t + 1; for _ in pairs(e.s or {}) do ts = ts + 1 end end
  for _ in pairs(log.loot) do l = l + 1 end
  print(string.format("|cffffd100M4:|r Quellen mitgeschrieben: %d Händler (%d Rezepte), %d Lehrer (%d Einträge), %d Rezepte gelootet.",
    m, mi, t, ts, l))
end
