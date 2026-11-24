-- Core: namespace, saved variables, event dispatch, error capture, utilities.
local ADDON, ns = ...

ns.name = ADDON
ns.version = "0.4.0-dev"

local MAX_ERRORS = 50

-- Errors are kept in the saved variables so they can be read outside the game.
local function logError(err, stack)
  local db = M4CompanionDB
  if type(db) == "table" then
    db.errors = db.errors or {}
    table.insert(db.errors, { t = time(), e = tostring(err), s = stack })
    while #db.errors > MAX_ERRORS do
      table.remove(db.errors, 1)
    end
  end
  print("|cffff5555M4 Fehler:|r " .. tostring(err))
end

local function errorHandler(err)
  logError(err, debugstack and debugstack(2, 12, 0) or nil)
  return err
end

function ns.Safe(fn, ...)
  return xpcall(fn, errorHandler, ...)
end

-- Event dispatch: several modules may listen to the same event.
local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for _, fn in ipairs(list) do
    ns.Safe(fn, event, ...)
  end
end)

-- Callbacks run once the saved variables are available.
local readyCallbacks = {}

function ns.OnReady(fn)
  if ns.db then
    ns.Safe(fn)
  else
    table.insert(readyCallbacks, fn)
  end
end

-- The companion app keeps a data addon (m4-companion_Data, global M4CompanionData) with the
-- hourly cloud export. Its auction data replaces the copy shipped with this addon when it
-- is newer, so every reader of ns.AHData gets the fresh one. The same for the players'
-- observations since the snapshot (Data_Obs<house>.lua -> AHObs, read by Item.Get).
local function adopt(name, live)
  if type(live[name]) ~= "table" then return end
  ns[name] = ns[name] or {}
  for house, data in pairs(live[name]) do
    local own = ns[name][house]
    if type(data) == "table" and type(data.items) == "table"
        and (not own or tostring(data.updated or "") > tostring(own.updated or "")) then
      ns[name][house] = data
    end
  end
end

local function adoptLiveData()
  local live = rawget(_G, "M4CompanionData")
  if type(live) ~= "table" then return end
  adopt("AHData", live)
  adopt("AHObs", live)
end
ns.AdoptLiveData = adoptLiveData

ns.On("ADDON_LOADED", function(_, loadedName)
  if loadedName == "m4-companion_Data" then adoptLiveData() return end
  if loadedName ~= ADDON then return end
  adoptLiveData()
  M4CompanionDB = M4CompanionDB or {}
  local db = M4CompanionDB
  db.schema = 1
  db.errors = db.errors or {}
  db.chars = db.chars or {}
  db.sessions = db.sessions or {}
  db.ui = db.ui or { shown = true }
  ns.db = db
  for _, fn in ipairs(readyCallbacks) do
    ns.Safe(fn)
  end
  readyCallbacks = {}
end)

-- Utilities ----------------------------------------------------------------

-- The realm of a character key. Since the client update of 21 Nov 2026 (Forever 1.60.1)
-- GetRealmName() answers "" - the keys became "Lok-" and every per-character table split.
-- Then, in this order: the realm this character was stored under before (the newest
-- "Name-Realm" key of db.chars with that name); the realm of its server id (the number in the
-- player GUID, learned from every character whose realm is known: db.realmIds); the only realm
-- of the account's characters; the last realm the game named (db.realm). A character created
-- after the update (no key yet) is found by the server id or the account's realm. "?" is no realm.
local realmCache
local function storedRealm(name)
  local db = ns.db
  if not db then return nil end
  local best, bestT
  for key, c in pairs(db.chars or {}) do
    local n, r = key:match("^(.-)%-(.+)$")
    if n == name and r and r ~= "" and r ~= "?" then
      local t = type(c) == "table" and c.updated or 0
      if not best or t > bestT then best, bestT = r, t end
    end
  end
  return best
end

-- The server id in the player's GUID ("Player-<server>-<id>").
local function serverID()
  local guid = UnitGUID and UnitGUID("player")
  return type(guid) == "string" and guid:match("^Player%-(%d+)%-") or nil
end

-- The only realm of the account's characters, nil with none or several.
local function onlyRealm()
  local db, found = ns.db, nil
  for key in pairs(db and db.chars or {}) do
    local r = key:match("^.-%-(.+)$")
    if r and r ~= "?" then
      if found and found ~= r then return nil end
      found = r
    end
  end
  return found
end

local function realmName()
  local db = ns.db
  local sid = serverID()
  local function learned(r)
    realmCache = r
    if db and sid then db.realmIds = db.realmIds or {}; db.realmIds[sid] = r end
    return r
  end
  local r = GetRealmName and GetRealmName()
  if type(r) == "string" and r ~= "" then
    if db then db.realm = r end
    return learned(r)
  end
  if realmCache then return realmCache end
  r = storedRealm(UnitName and UnitName("player"))
  if r then return learned(r) end
  r = (db and db.realmIds and sid and db.realmIds[sid]) or onlyRealm() or (db and db.realm)
  if r then return learned(r) end
  return nil
end

function ns.CharKey()
  return (UnitName("player") or "?") .. "-" .. (realmName() or "?")
end

-- One-time repair of what was stored under "Name-" (empty realm) since that client update:
-- merged into the character's "Name-Realm" entries (ledger events without doubles, the newer
-- character snapshot, bags/bank/auctions/scans by their times), then the short keys go.
local function repairEmptyRealm()
  local db, Sync = ns.db, ns.CloudSync
  if not (db and Sync) then return end
  local me = UnitName and UnitName("player")
  local function target(short)
    local name = short:match("^(.-)%-%??$")
    local r = name and (name == me and realmName() or storedRealm(name) or onlyRealm() or db.realm)
    return r and (name .. "-" .. r) or nil
  end
  local function shortKeys(t, pattern)
    local list = {}
    for key in pairs(t or {}) do if type(key) == "string" and key:match(pattern) then list[#list + 1] = key end end
    return list
  end
  local moved = 0
  for _, key in ipairs(shortKeys(db.ledger, "^.-%-%??$")) do
    local full = target(key)
    if full then
      local src = db.ledger[key]
      db.ledger[full] = db.ledger[full] or { events = {} }
      db.ledger[full].events = db.ledger[full].events or {}
      Sync.MergeEvents(db.ledger[full].events, src.events or {}, ns.Ledger and ns.Ledger.KEEP or 3000)
      db.ledger[key] = nil
      moved = moved + 1
    end
  end
  for _, key in ipairs(shortKeys(db.chars, "^.-%-%??$")) do
    local full = target(key)
    if full then
      local merged = Sync.MergeChar(db.chars[full], db.chars[key])
      if merged then db.chars[full] = merged end
      db.chars[key] = nil
    end
  end
  for _, key in ipairs(shortKeys(db.inventory, "^.-%-%??$")) do
    local full = target(key)
    if full then
      local src, dst = db.inventory[key], db.inventory[full] or {}
      for _, part in ipairs({ "bags", "bank" }) do
        if (src[part .. "T"] or 0) > (dst[part .. "T"] or 0) then dst[part], dst[part .. "T"] = src[part], src[part .. "T"] end
      end
      db.inventory[full], db.inventory[key] = dst, nil
    end
  end
  for _, key in ipairs(shortKeys(db.owned, "^.-%-%??$")) do
    local full = target(key)
    if full then
      if not db.owned[full] or (db.owned[key].t or 0) > (db.owned[full].t or 0) then db.owned[full] = db.owned[key] end
      db.owned[key] = nil
    end
  end
  for _, key in ipairs(shortKeys(db.recipes, "^.-%-%??:.+$")) do
    local short, prof = key:match("^(.-%-%??):(.+)$")
    local full = short and target(short)
    if full then
      local fk = full .. ":" .. prof
      if not db.recipes[fk] or (db.recipes[key].t or 0) > (db.recipes[fk].t or 0) then db.recipes[fk] = db.recipes[key] end
      db.recipes[key] = nil
    end
  end
  for _, session in ipairs(db.sessions or {}) do
    if type(session.char) == "string" and session.char:match("^.-%-%??$") then session.char = target(session.char) or session.char end
  end
  if moved > 0 then
    print("|cff33ccffm4:|r Handelsbuch repariert: Einträge seit dem Spiel-Update (Realm fehlte) zusammengeführt.")
  end
end
ns.RepairEmptyRealm = repairEmptyRealm
ns.OnReady(function() ns.Safe(repairEmptyRealm) end)

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

-- Money with the game's coin icons, so gold and silver cannot be mixed up.
--   short  leave out copper once there is gold
function ns.FormatMoney(copper, short)
  copper = math.floor((copper or 0) + 0.5)
  local negative = copper < 0
  if negative then copper = -copper end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local out
  if g > 0 then
    out = g .. GOLD_ICON .. " " .. s .. SILVER_ICON
    if not short then out = out .. " " .. c .. COPPER_ICON end
  elseif s > 0 then
    out = s .. SILVER_ICON .. " " .. c .. COPPER_ICON
  else
    out = c .. COPPER_ICON
  end
  return negative and ("-" .. out) or out
end

function ns.FormatDuration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

function ns.SpellName(spellID)
  if not spellID then return nil end
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellID)
    return info and info.name
  end
  if GetSpellInfo then
    return (GetSpellInfo(spellID))
  end
  return nil
end

function ns.ItemName(itemID)
  if C_Item and C_Item.GetItemNameByID then
    local name = C_Item.GetItemNameByID(itemID)
    if name then return name end
  end
  if GetItemInfo then
    local name = GetItemInfo(itemID)
    if name then return name end
  end
  -- Not in the client's item cache yet: ask the server (GET_ITEM_INFO_RECEIVED follows
  -- and windows refresh themselves), meanwhile use a name we know.
  if C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(itemID)
  end
  local shipped = ns.ItemNames and ns.ItemNames[itemID]
  if shipped then return shipped end
  local stored = ns.db and ns.db.prices and ns.db.prices[itemID]
  if stored and stored.n then return stored.n end
  return "Item " .. tostring(itemID)
end

function ns.PlayerPosition()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return nil end
  local x, y
  local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then
    x, y = pos:GetXY()
    x = x and math.floor(x * 1000 + 0.5) / 10
    y = y and math.floor(y * 1000 + 0.5) / 10
  end
  return mapID, x, y
end

function ns.MapName(mapID)
  if mapID and C_Map and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name
  end
  return nil
end

-- Bag IDs the player carries: backpack, bags and (newer clients) the reagent bag.
function ns.CarriedBags()
  local ids = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do table.insert(ids, bag) end
  local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
  if reagent then table.insert(ids, reagent) end
  return ids
end

-- Bank container IDs: the bank itself and its bag slots.
function ns.BankBags()
  local ids = { (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or BANK_CONTAINER or -1 }
  local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0))) + 1
  for bag = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do table.insert(ids, bag) end
  return ids
end

