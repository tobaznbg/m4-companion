-- AuctionHouse: which of the three auction houses the player is at, and from which auctioneer
-- (NPC) the data comes. Alliance, Horde and the neutral houses (Gadgetzan, Booty Bay, Everlook)
-- each have their own offers, so everything read at the auction house is kept per house.
--   house keys: "A" Allianz, "N" Neutral, "H" Horde
-- Detection on AUCTION_HOUSE_SHOW from the auctioneer: UnitFactionGroup("npc") (Alliance / Horde
-- auctioneers belong to their faction, the goblins of the neutral houses to none), else the
-- town (neutral towns below), else the player's faction (marked as a guess). Every auctioneer is
-- remembered in ns.db.ah.npcs; "/m4 ah A|N|H" fixes the house of the auctioneer in front of you.
--
-- M4CompanionDB.ah (v = 3; data of before the split is Horde, see migrate):
--   houses   { A = house, N = house, H = house }, house = what AuctionScan keeps per house:
--            { days, current, currentT, last = { t, items, npc }, lastScanT, scans, api,
--              npc = id of the auctioneer of the newest scan, log = { { t, npc, offers, items }... } }
--   npcs     { [npcID] = { name, house, fac, zone, sub, map, first, seen, visits, guess, fixed } }
--   lastScanT newest scan start of any house (the server's 15-minute limit is not per house)
--   splitT   time of the split: auction house records without a house older than this are Horde
--            (also those another PC syncs in later, see AH.Of)
local ADDON, ns = ...

local AH = {}
ns.AuctionHouse = AH

AH.KEYS = { "A", "N", "H" }
AH.NAMES = { A = "Allianz", N = "Neutral", H = "Horde" }
AH.COLORS = { A = "|cff4a9eff", N = "|cffd8b04a", H = "|cffe04848" }
local SCAN_LOG_MAX = 50
-- All data of before the split (addon up to 0.17.3) was read at the Horde auction house.
local LEGACY_HOUSE = "H"
-- The collector's cloud data comes per house id: Data_AH<id>, its history, guild sales. Which
-- ids belong to the player's houses the data addon says (m4d, ns.HouseGroups: the Allianz,
-- Horde and neutral house of the realm's group); without it (older data addon) only the Horde
-- house has cloud data, the collector's main house.
AH.PRIMARY_CLOUD = 113
-- ledger kinds that happen at the auction house (buy / sale only without src: src marks a
-- merchant or trade window deal)
local AH_KINDS = { buy = true, sale = true, post = true, expired = true, cancelled = true }

-- Towns with a neutral auction house (sub zone or zone text, German and English).
local NEUTRAL_TOWNS = {
  ["Gadgetzan"] = true, ["Beutebucht"] = true, ["Booty Bay"] = true,
  ["Ewige Warte"] = true, ["Everlook"] = true, ["Area 52"] = true,
}

local open = nil      -- { house, npc = id, name, guess } while the auction house is open
local listeners = {}

local function factionKey(f)
  if f == "Alliance" then return "A" end
  if f == "Horde" then return "H" end
  return nil
end

local function playerHouse()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  local key = factionKey(f)
  if key then return key end
  local c = ns.db and ns.db.chars and ns.CharKey and ns.db.chars[ns.CharKey()]
  return factionKey(c and c.faction) or "H"
end

local function root()
  local db = ns.db
  db.ah = db.ah or {}
  local ah = db.ah
  ah.houses = ah.houses or {}
  ah.npcs = ah.npcs or {}
  ah.lastHouse = nil -- no longer used: away from the auctioneer it is always the home house
  return ah
end

-- The data of one house (created on first use).
function AH.Data(house)
  local houses = root().houses
  house = house or AH.Current()
  local h = houses[house]
  if not h then
    h = { days = {}, current = {}, scans = 0, log = {} }
    houses[house] = h
  end
  h.days, h.current, h.log = h.days or {}, h.current or {}, h.log or {}
  return h
end

-- The data of one house without creating it (nil when nothing was read there yet).
function AH.Peek(house)
  local ah = ns.db and ns.db.ah
  return ah and ah.houses and ah.houses[house or AH.Current()]
end

-- The automatic house: the open one while the player stands at an auctioneer, else always the
-- home house (the player's faction) - prices for crafting, planner and shopping list must not
-- follow the house visited last.
function AH.Auto()
  if open then return open.house end
  return playerHouse()
end

-- A view of another house (the ledger's choice), only while AH.WithView runs.
local view = nil

-- The house the data is for: the viewed one while a view runs, else the automatic one.
function AH.Current()
  return view or AH.Auto()
end

-- Runs fn(...) with every reader (scan data, item prices) on `house`; returns fn's results.
-- house nil: the automatic one.
function AH.WithView(house, fn, ...)
  local before = view
  view = house
  local result = { pcall(fn, ...) }
  view = before
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2)
end

function AH.IsOpen() return open ~= nil end

-- The cloud house id of an auction house key (default: the current one), nil if the cloud has
-- no data for it. Looked up per call: the data addon loads after this one.
function AH.CloudID(house)
  house = house or AH.Current()
  local live = rawget(_G, "M4CompanionData")
  local groups = type(live) == "table" and type(live.HouseGroups) == "table" and live.HouseGroups
  if groups then
    local key = ns.CharKey and ns.CharKey()
    local realm = key and key:match("^[^-]*%-(.+)$")
    local base = realm and type(live.CloudRealms) == "table" and live.CloudRealms[realm]
    if not base and type(live.Houses) == "table" then base = live.Houses[1] end
    local g = base and groups[base]
    if type(g) == "table" then return g[house] end
  end
  return house == "H" and AH.PRIMARY_CLOUD or nil
end

-- The cloud data (ns.AHData[id]) of an auction house key (default: the current one) and its
-- id; nil if there is none.
function AH.CloudData(house)
  local id = AH.CloudID(house)
  local data = id and ns.AHData and ns.AHData[id]
  if type(data) ~= "table" or type(data.items) ~= "table" then return nil, id end
  return data, id
end

-- Whether the cloud has data for the house (default: the current one).
function AH.HasCloud(house)
  return AH.CloudData(house) ~= nil
end

-- The home house: the one of the player's faction. Records of no house (crafts, merchant,
-- trade window, mails of an unknown sender) belong to it.
function AH.Home() return playerHouse() end

-- The auctioneer in front of the player: { house, npc, name, guess } or nil.
function AH.Open() return open end

function AH.Name(house) return AH.NAMES[house or AH.Current()] or "?" end

-- "Neutral (Auktionator Grizzlin)" in the house's color.
function AH.Label(house, npcID)
  house = house or AH.Current()
  local text = (AH.COLORS[house] or "") .. AH.Name(house) .. "|r"
  local n = npcID and ns.db and ns.db.ah and ns.db.ah.npcs and ns.db.ah.npcs[npcID]
  if n and n.name then text = text .. " (" .. n.name .. ")" end
  return text
end

-- Marks a record with the house and auctioneer it comes from (ah, npc); returns it.
function AH.Tag(t)
  if type(t) ~= "table" then return t end
  t.ah = t.ah or AH.Auto()
  if open and open.npc and t.npc == nil then t.npc = open.npc end
  return t
end

-- fn(house, previous) runs when the automatic house changes: an auction house of another house
-- opens, or it closes and the home house applies again.
function AH.OnChange(fn) table.insert(listeners, fn) end

-- House of an auction house mail from its sender ("… Auktionshaus der Horde", "Neutral …").
function AH.FromSender(sender)
  if type(sender) ~= "string" or sender == "" then return nil end
  local s = sender:lower()
  if s:find("neutral") then return "N" end
  if s:find("horde") then return "H" end
  if s:find("allianz") or s:find("alliance") then return "A" end
  return nil
end

-- The auctioneer of the "npc" unit: id, name.
local function npcOf()
  local guid = UnitGUID and UnitGUID("npc")
  local id
  if type(guid) == "string" then
    local kind, _, _, _, _, npcID = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then id = tonumber(npcID) end
  end
  return id, UnitName and UnitName("npc") or nil
end

local function detect()
  local id, name = npcOf()
  local ah = root()
  local known = id and ah.npcs[id]
  local fac = UnitFactionGroup and UnitFactionGroup("npc")
  local zone = GetZoneText and GetZoneText() or nil
  local sub = GetSubZoneText and GetSubZoneText() or nil
  local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
  local house, guess
  if known and known.fixed then
    house = known.house
  elseif factionKey(fac) then
    house = factionKey(fac)
  elseif NEUTRAL_TOWNS[sub or ""] or NEUTRAL_TOWNS[zone or ""] then
    house = "N"
  elseif id and fac == nil and UnitExists and UnitExists("npc") then
    -- an auctioneer of no faction outside the known towns: a neutral house
    house = "N"
  else
    house, guess = playerHouse(), true
  end
  if id then
    local n = known or { first = time(), visits = 0 }
    n.name = name or n.name
    n.house, n.fac, n.guess = house, fac, guess or nil
    n.zone, n.sub, n.map = zone, (sub ~= "" and sub or nil), map
    n.seen, n.visits = time(), (n.visits or 0) + 1
    ah.npcs[id] = n
  end
  return house, id, name, guess
end

ns.On("AUCTION_HOUSE_SHOW", function()
  if not ns.db then return end
  local previous = AH.Auto()
  local house, id, name, guess = detect()
  open = { house = house, npc = id, name = name, guess = guess }
  if house ~= previous then
    for _, fn in ipairs(listeners) do ns.Safe(fn, house, previous) end
  end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  if not open then return end
  local previous = open.house
  open = nil
  local house = AH.Auto()
  if house ~= previous then
    for _, fn in ipairs(listeners) do ns.Safe(fn, house, previous) end
  end
end)

-- Data of before the split (one table for every house): it was all read at the Horde auction
-- house, so it is moved once into houses.H (marked legacy, no auctioneer known), and the
-- auction house records of the ledger, the sniper log and the own auctions get ah = "H".
local function migrate()
  local ah = ns.db.ah
  if type(ah) ~= "table" then ah = {}; ns.db.ah = ah end
  if (ah.v or 0) >= 3 then return end
  ah.houses = ah.houses or {}
  -- Everything read before the split comes from the Horde auction house (no auctioneer known).
  if ah.v ~= 2 then
    local old = {}
    for _, k in ipairs({ "days", "current", "currentT", "last", "lastScanT", "scans", "api" }) do
      old[k], ah[k] = ah[k], nil
    end
    if old.current or old.last or old.days then
      local h = AH.Data(LEGACY_HOUSE)
      for k, v in pairs(old) do h[k] = v end
      h.migrated = time()
      ah.lastScanT = old.lastScanT
    end
  else
    -- a first version (v 2) put the old data into the player's faction: to the Horde
    local from
    for key, h in pairs(ah.houses) do
      if key ~= LEGACY_HOUSE and h.migrated then from = key end
    end
    if from and not ah.houses[LEGACY_HOUSE] then
      ah.houses[LEGACY_HOUSE], ah.houses[from] = ah.houses[from], nil
    end
  end
  if ah.houses[LEGACY_HOUSE] and ah.houses[LEGACY_HOUSE].migrated then
    ah.houses[LEGACY_HOUSE].legacy = "Horde-Auktionshaus, vor der Trennung nach Häusern (Auktionator unbekannt)"
  end
  -- the records of before the split: auction house trades of the ledger, sniper log, own auctions
  local db = ns.db
  for _, b in pairs(db.ledger or {}) do
    for _, e in ipairs(type(b) == "table" and b.events or {}) do
      if e.ah == nil and AH_KINDS[e.k] and e.src == nil then e.ah = LEGACY_HOUSE end
    end
  end
  for _, e in ipairs(db.sniper and db.sniper.log or {}) do
    if e.ah == nil then e.ah = LEGACY_HOUSE end
  end
  for _, o in pairs(db.owned or {}) do
    for _, e in ipairs(type(o) == "table" and o.list or {}) do
      if e.ah == nil then e.ah = LEGACY_HOUSE end
    end
  end
  ah.splitT = ah.splitT or time() -- auction house records without a house before this: Horde
  ah.v = 3
end

-- The house a record is shown under: its own (AH.Of), else the home house (crafts, merchant,
-- trade window and trades of an unknown house).
function AH.ShownUnder(e)
  return AH.Of(e) or AH.Home()
end

-- House of a record (ledger event, sniper log line, own auction): its own, else Horde for a
-- record of before the split; nil when unknown.
function AH.Of(e)
  if type(e) ~= "table" then return nil end
  if e.ah then return e.ah end
  local split = ns.db and ns.db.ah and ns.db.ah.splitT
  if split and (e.t or 0) < split and AH_KINDS[e.k] and e.src == nil then return LEGACY_HOUSE end
  return nil
end

-- on login: the player's faction is known for sure by then
ns.On("PLAYER_LOGIN", function() if ns.db then migrate() end end)

-- Scan log of a house: who the data came from.
function AH.LogScan(house, entry)
  local h = AH.Data(house)
  table.insert(h.log, entry)
  while #h.log > SCAN_LOG_MAX do table.remove(h.log, 1) end
end

-- /m4 ah [A|N|H]: shows the house and auctioneer; with a letter the auctioneer in front of you
-- is fixed to that house (and its data from now on goes there).
function AH.Command(arg)
  local P = "|cffffd100M4:|r "
  arg = (arg or ""):upper()
  if arg == "A" or arg == "N" or arg == "H" then
    if not open or not open.npc then
      print(P .. "Erst ein Auktionshaus öffnen, dann /m4 ah " .. arg .. ".")
      return
    end
    local n = root().npcs[open.npc]
    n.house, n.fixed, n.guess = arg, true, nil
    local previous = open.house
    open.house = arg
    print(P .. (n.name or "Auktionator") .. " gehört jetzt zu " .. AH.Label(arg) .. ".")
    if arg ~= previous then
      for _, fn in ipairs(listeners) do ns.Safe(fn, arg, previous) end
    end
    return
  end
  if open then
    print(P .. "Auktionshaus " .. AH.Label(open.house) .. ", Auktionator " .. tostring(open.name or "?")
      .. " (NPC " .. tostring(open.npc or "?") .. ")" .. (open.guess and " – geraten, mit /m4 ah A|N|H festlegen" or ""))
  else
    print(P .. "Daten für " .. AH.Label() .. " (zuletzt benutztes Auktionshaus).")
  end
  for _, key in ipairs(AH.KEYS) do
    local h = AH.Peek(key)
    local t = h and h.currentT
    print(string.format("  %s: %s%s", AH.Label(key, h and h.npc),
      t and ("Scan " .. date("%d.%m. %H:%M", t) .. ", " .. (h.scans or 0) .. " Scans") or "kein Scan",
      h and h.legacy and ("  |cff999999(Altdaten: " .. h.legacy .. ")|r") or ""))
  end
end

-- Choice of the house a window shows -------------------------------------------------------
-- AH.Chooser(parent, width, onChange): a dropdown Allianz / Neutral / Horde. Preselected is the
-- automatic house (marked "(auto)", green frame); another choice gets a red, pulsing frame. A
-- choice that becomes the automatic house (the player goes there) is automatic again.
--   d.Selected()  the house to show ("A"/"N"/"H")
--   d.IsAuto()    true while the automatic house is shown
--   d.Update()    text and frame (also after the automatic house moved)
--   d.Select(h)   sets the choice (nil: automatic), without onChange
-- onChange(house) runs after the player picked one.

-- The frame around the choice: green and still, or red and pulsing. f.Set(auto)
local function choiceFrame(target)
  local f = CreateFrame("Frame", nil, target)
  f:SetPoint("TOPLEFT", target, "TOPLEFT", -4, 3)
  f:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 4, -3)
  f:SetFrameLevel((target:GetFrameLevel() or 1) + 5)
  local edges = {}
  local function edge(p1, p2, horizontal)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetPoint(p1); t:SetPoint(p2)
    if horizontal then t:SetHeight(2) else t:SetWidth(2) end
    edges[#edges + 1] = t
  end
  edge("TOPLEFT", "TOPRIGHT", true); edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
  edge("TOPLEFT", "BOTTOMLEFT", false); edge("TOPRIGHT", "BOTTOMRIGHT", false)
  local pulse = f:CreateAnimationGroup()
  pulse:SetLooping("BOUNCE")
  local fade = pulse:CreateAnimation("Alpha")
  fade:SetFromAlpha(1); fade:SetToAlpha(0.2); fade:SetDuration(0.6)
  if fade.SetSmoothing then fade:SetSmoothing("IN_OUT") end
  function f.Set(auto)
    for _, t in ipairs(edges) do
      if auto then t:SetColorTexture(0.37, 0.83, 0.55, 0.95) else t:SetColorTexture(1, 0.25, 0.25, 1) end
    end
    if auto then
      pulse:Stop(); f:SetAlpha(1)
    elseif not pulse:IsPlaying() then
      pulse:Play()
    end
  end
  return f
end

function AH.Chooser(parent, width, onChange)
  local sel = nil -- nil: the automatic house
  local d
  local function selected() return sel or AH.Auto() end
  local function options()
    local auto, opts = AH.Auto(), {}
    for _, key in ipairs(AH.KEYS) do
      opts[#opts + 1] = { key = key, label = AH.NAMES[key] .. (key == auto and " (auto)" or "") }
    end
    return opts
  end
  local function choose(key)
    sel = key ~= AH.Auto() and key or nil
    d.Update()
    if onChange then ns.Safe(onChange, selected()) end
  end
  local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and dd and dd.SetupMenu then
    d = dd
    d:SetWidth(width)
    d:SetupMenu(function(_, rootMenu)
      for _, o in ipairs(options()) do
        rootMenu:CreateRadio(o.label, function() return selected() == o.key end, function() choose(o.key) end)
      end
    end)
  else
    -- no menu API: a button that steps through the houses
    local okB, bt = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    d = okB and bt or CreateFrame("Button", nil, parent)
    d:SetSize(width, 22)
    d:SetScript("OnClick", function()
      local opts = options()
      for i, o in ipairs(opts) do
        if o.key == selected() then choose(opts[i % #opts + 1].key) break end
      end
    end)
  end
  local border = choiceFrame(d)
  function d.Update()
    if sel == AH.Auto() then sel = nil end
    for _, o in ipairs(options()) do
      if o.key == selected() and d.SetText then d:SetText(o.label) end
    end
    if d.GenerateMenu then pcall(d.GenerateMenu, d) end
    border.Set(sel == nil)
  end
  d.Selected = selected
  function d.IsAuto() return sel == nil end
  -- sets the choice from outside (nil: the automatic house); no onChange
  function d.Select(house)
    sel = (house and house ~= AH.Auto()) and house or nil
    d.Update()
  end
  AH.OnChange(function() d.Update() end)
  d.Update()
  return d
end
