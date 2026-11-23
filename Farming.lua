-- Farming: rates every gatherable item by what it brings in your auction house
-- and whether you can get it. Pure logic plus thin data accessors.
--
-- Prices and sales come from ns.Item.
local ADDON, ns = ...

local Farming = {}
ns.Farming = Farming

local CUT = 0.05
local MIN_HOURS = 48       -- collector hours before sales figures are trusted
Farming.MIN_VALUE = 200    -- below 2 silver per unit an item is not worth farming for
Farming.MIN_DEMAND = 2     -- ns.Item demand (cloud scale, "mittel" and up)
local LEVEL_REACH = 3      -- mobs up to this many levels above you are fine

-- Skill needed to skin a mob of the given level (classic rule).
function Farming.SkinSkill(level)
  if level >= 20 then return level * 5 end
  return math.max(1, (level - 10) * 10)
end

-- The character's skill in a profession: from its profession scan (the profession window, see
-- Recipes.lua) - the character snapshot's list stays empty on Forever -, else the snapshot.
local function professionSkill(name)
  if name == "" then return math.huge end
  local scan = ns.db and ns.db.recipes and ns.db.recipes[ns.CharKey() .. ":" .. name]
  if scan and scan.rank then return scan.rank end
  local char = ns.db and ns.db.chars and ns.db.chars[ns.CharKey()]
  for _, prof in ipairs(char and char.professions or {}) do
    if prof.name == name then return prof.rank or 0 end
  end
  return nil
end
Farming.ProfessionSkill = professionSkill

-- Whether the player can gather the item now: ok, reason text.
local function access(group, entry, level)
  local skill = professionSkill(group.source)
  if group.kind == "fish" then
    -- the fishing water decides the skill, not the fish
    if not skill then return false, group.label .. " fehlt" end
    return true, "Angeln"
  end
  if group.kind == "skill" then
    if not skill then return false, group.label .. " fehlt" end
    if skill < entry[2] then return false, string.format("ab Skill %d", entry[2]) end
    return true, string.format("Skill %d", entry[2])
  end
  local lo, hi = entry[2], entry[3]
  local range = string.format("Stufe %d-%d", lo, hi)
  if group.source ~= "" then
    if not skill then return false, group.label .. " fehlt" end
    if skill < Farming.SkinSkill(lo) then
      return false, string.format("%s, Skill %d", range, Farming.SkinSkill(lo))
    end
  end
  if level + LEVEL_REACH < lo then return false, range .. ", zu hoch" end
  return true, range
end

-- Signal for one item from its market data.
-- Buyers take the cheapest offer first, so a farmer who undercuts by one copper
-- sells next: revenue is (current minimum - 1 copper) after the cut, and speed is
-- the daily demand. The size of the stock behind does not matter.
function Farming.Signal(m)
  local value = ns.Item.SellNet(m)
  if value < Farming.MIN_VALUE then return "wenig wert", "grey", value end
  if not m.demand then return "Absatz offen", "grey", value end
  if m.demand >= Farming.MIN_DEMAND then return "lohnt", "green", value end
  if m.demand > 0.05 then return "wenig Nachfrage", "yellow", value end
  return "kein Absatz", "orange", value
end

-- All groups with rated items, reachable items first, then by value.
function Farming.Evaluate()
  local level = UnitLevel and UnitLevel("player") or 1
  local result = {}
  for _, group in ipairs(ns.Gathering) do
    local rows = {}
    for _, entry in ipairs(group.items) do
      local itemID = entry[1]
      local m = ns.Item(itemID)
      if not (m.now or m.ref) then m = nil end
      local ok, reason = access(group, entry, level)
      local row = { itemID = itemID, market = m, reachable = ok, access = reason }
      if m then
        row.signal, row.color, row.value, row.days = Farming.Signal(m)
      else
        row.signal, row.color, row.value = "nicht im AH", "grey", 0
      end
      table.insert(rows, row)
    end
    table.sort(rows, function(a, b)
      if a.reachable ~= b.reachable then return a.reachable end
      return a.value > b.value
    end)
    table.insert(result, { label = group.label, rows = rows })
  end
  return result
end

function Farming.DataInfo()
  local house = ns.AuctionHouse.CloudData()
  local scan = ns.AuctionHouse.Peek()
  return house and house.updated, house and house.hours or 0, scan and scan.currentT, MIN_HOURS
end

-- Farm spots ---------------------------------------------------------------
-- Value per kill = sum over loot: chance x quantity x revenue per unit
--                + (if you can skin it) sum over skinning results, same way.
-- Revenue per unit = current minimum - 1 copper after the auction cut, or the
-- vendor price when the item is not on the auction house. Coins are not in the
-- wowhead data; the session measures them.

local ZONE_FALLBACK = {
  [3] = "Ödland", [4] = "Verwüstete Lande", [8] = "Sümpfe des Elends", [10] = "Dämmerwald",
  [11] = "Sumpfland", [15] = "Marschen von Dustwallow", [16] = "Azshara", [17] = "Brachland",
  [28] = "Westliche Pestländer", [33] = "Schlingendorntal", [36] = "Alteracgebirge",
  [45] = "Arathihochland", [46] = "Brennende Steppe", [47] = "Hinterland", [51] = "Sengende Schlucht",
  [85] = "Tirisfal", [130] = "Silberwald", [139] = "Östliche Pestländer", [148] = "Dunkelküste",
  [267] = "Vorgebirge des Hügellands", [331] = "Eschental", [357] = "Feralas", [361] = "Teufelswald",
  [400] = "Tausend Nadeln", [405] = "Desolace", [406] = "Steinkrallengebirge", [440] = "Tanaris",
  [490] = "Krater von Un'Goro", [618] = "Winterquell", [1377] = "Silithus",
  -- dungeons
  [491] = "Kral der Klingenhauer (Dungeon)", [718] = "Höhlen des Wehklagens (Dungeon)",
  [719] = "Tiefschwarze Grotte (Dungeon)", [722] = "Hügel der Klingenhauer (Dungeon)",
  [796] = "Scharlachrotes Kloster (Dungeon)", [1176] = "Zul'Farrak (Dungeon)",
  [1337] = "Uldaman (Dungeon)", [2100] = "Maraudon (Dungeon)",
}

local function zoneName(areaID)
  if C_Map and C_Map.GetAreaInfo then
    local name = C_Map.GetAreaInfo(areaID)
    if name and name ~= "" then return name end
  end
  return ZONE_FALLBACK[areaID] or ("Gebiet " .. areaID)
end

local function parseDrops(text)
  local list = {}
  for item, pct, qty in (text or ""):gmatch("(%d+):(%d+)x?([%d%.]*)") do
    table.insert(list, { tonumber(item), tonumber(pct) / 100, tonumber(qty) or 1 })
  end
  return list
end
Farming.ParseDrops = parseDrops
Farming.ZoneName = zoneName

-- Revenue for one unit, cached per evaluation.
local function unitRevenue(itemID, cache)
  local v = cache[itemID]
  if v then return v end
  v = ns.Item.Value(ns.Item(itemID))
  cache[itemID] = v
  return v
end

-- Measured results per creature over all sessions of this character.
local function measured(npcID)
  local kills, value, seconds = 0, 0, 0
  for _, session in ipairs(ns.db and ns.db.sessions or {}) do
    local stats = session.npcs and session.npcs[npcID]
    if session.char == ns.CharKey() and stats and stats.kills > 0 then
      local total = 0
      for _, s in pairs(session.npcs) do total = total + s.kills end
      local duration = ns.Tracker.Duration(session)
      kills = kills + stats.kills
      value = value + stats.value + stats.money
      seconds = seconds + duration * stats.kills / total -- time share of this creature
    end
  end
  if kills == 0 or seconds < 60 then return nil end
  return { kills = kills, killsPerHour = kills * 3600 / seconds, goldPerHour = value * 3600 / seconds }
end

function Farming.Spots()
  local level = UnitLevel and UnitLevel("player") or 1
  local skin = professionSkill("Kürschnerei")
  local cache, rows = {}, {}
  for _, spot in ipairs(ns.FarmSpots or {}) do
    local npcID, name, lo, hi, zones, skinText, lootText = unpack(spot)
    local row = { npcID = npcID, name = name, lo = lo, hi = hi, value = 0, parts = {} }
    row.reachable = level + LEVEL_REACH >= lo
    local skinNeed = Farming.SkinSkill(hi)
    row.canSkin = skinText ~= "" and skin ~= nil and skin >= skinNeed
    if skinText ~= "" and not row.canSkin then
      row.note = skin and string.format("Häuten ab Skill %d", skinNeed) or "ohne Kürschnerei"
    end
    local function add(list)
      for _, d in ipairs(list) do
        local v = d[2] * d[3] * unitRevenue(d[1], cache)
        row.value = row.value + v
        row.parts[d[1]] = (row.parts[d[1]] or 0) + v
      end
    end
    add(parseDrops(lootText))
    if row.canSkin then add(parseDrops(skinText)) end
    local zoneList = {}
    for z in zones:gmatch("(-?%d+)") do
      local id = tonumber(z)
      if id > 0 then table.insert(zoneList, zoneName(id)) end
    end
    row.zone = table.concat(zoneList, ", ")
    row.measured = measured(npcID)
    if row.value > 0 then table.insert(rows, row) end
  end
  table.sort(rows, function(a, b)
    if a.reachable ~= b.reachable then return a.reachable end
    return a.value > b.value
  end)
  return rows
end

-- The biggest contributors of a spot's value, as "name 60 %, name 25 %".
function Farming.Breakdown(row, count)
  local list = {}
  for itemID, v in pairs(row.parts) do table.insert(list, { itemID, v }) end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local parts = {}
  for i = 1, math.min(count or 2, #list) do
    table.insert(parts, string.format("%s %d %%", ns.ItemName(list[i][1]),
      math.floor(list[i][2] / row.value * 100 + 0.5)))
  end
  return table.concat(parts, ", ")
end
