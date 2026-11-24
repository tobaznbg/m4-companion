-- AuctionScan: our own full scan of the auction house, no other addon needed.
-- Supports the classic auction API (QueryAuctionItems getAll) and the modern one
-- (C_AuctionHouse.ReplicateItems); which one the client has is detected at runtime.
--
-- Stored per auction house (Allianz / Neutral / Horde, see AuctionHouse.lua) in
-- M4CompanionDB.ah.houses[house]:
--   last     { t, npc, items = { [itemID] = { fingerprint, ... } } }  previous scan, for the diff
--   current  { [itemID] = { min, mv, qty, n, sellers } }              latest scan summary
--   days     { [dayKey] = { [itemID] = day row } }                    see AuctionStats.AddToDay
--   currentT, npc (auctioneer of the latest scan), lastScanT, scans, api, log (one line per scan)
-- A scan belongs to the house it was started at, also when it finishes after a switch.
local ADDON, ns = ...

local Scan = {}
ns.AuctionScan = Scan

local THROTTLE = 15 * 60       -- the server allows a full scan every 15 minutes
local BATCH = 200              -- listings read per frame
local ITEM_BATCH = 300         -- items processed per frame when saving
local MAX_DIFF_AGE = 24 * 3600 -- older previous scans say nothing about sales
local PREFIX = "|cffffd100M4:|r "

local state -- running scan: { api, started, house, npc, listings = { [itemID] = { ... } }, count }
local button

-- The data of a house (default: the current one).
local function db(house)
  return ns.AuctionHouse.Data(house)
end

-- The data of the current house without creating it.
local function peek()
  return ns.db and ns.AuctionHouse.Peek()
end

local function hasModern()
  return C_AuctionHouse and type(C_AuctionHouse.ReplicateItems) == "function"
end

local function hasLegacy()
  return type(QueryAuctionItems) == "function" and type(GetAuctionItemInfo) == "function"
end

local function detectApi()
  if AuctionHouseFrame and hasModern() then return "modern" end
  if AuctionFrame and hasLegacy() then return "legacy" end
  if hasModern() then return "modern" end
  if hasLegacy() then return "legacy" end
  return nil
end

-- Seconds since the last finished scan, or nil.
function Scan.Age()
  local h = peek()
  local t = h and h.currentT
  return t and (time() - t) or nil
end

function Scan.Running()
  return state ~= nil
end

-- Live prices for the auction house tabs -------------------------------------------
Scan.LIVE_MAX = 60 * 60   -- a scan counts as live for an hour
local LIVE_EVERY = 15 * 60

-- Starts a full scan when the last one is older than 15 minutes and the server
-- allows one. Must run inside a click (hardware event).
function Scan.EnsureFresh()
  if not state and (Scan.Age() or math.huge) > LIVE_EVERY and Scan.Wait() == 0 then Scan.Start() end
end

-- Short status text for a tab toolbar.
function Scan.LiveInfo()
  if state then return "|cffffb547Live-Preise werden geholt …|r" end
  local age = Scan.Age()
  if age and age <= Scan.LIVE_MAX then return string.format("Live-Preise, %d min alt", math.floor(age / 60)) end
  return "|cffffb547Keine Live-Preise – Daten vom Server|r"
end

-- Called after every finished scan.
local doneListeners = {}
function Scan.OnDone(fn) table.insert(doneListeners, fn) end

function Scan.HasData()
  local h = peek()
  return h ~= nil and h.lastScanT ~= nil
end

-- Seconds until the next full scan is allowed (0 = now). The server's limit counts every
-- scan, whichever house it was at.
function Scan.Wait()
  local last = ns.db.ah and ns.db.ah.lastScanT
  if not last then return 0 end
  return math.max(0, THROTTLE - (time() - last))
end

local function canScan(api)
  if api == "legacy" and CanSendAuctionQuery then
    local _, canAll = CanSendAuctionQuery()
    return canAll and true or false
  end
  return Scan.Wait() == 0
end

local function addListing(itemID, count, buyout, seller, timeLeft)
  if not itemID or itemID == 0 or not buyout or buyout <= 0 then return end
  count = math.max(1, count or 1)
  local list = state.listings[itemID]
  if not list then
    list = {}
    state.listings[itemID] = list
  end
  table.insert(list, {
    unit = math.floor(buyout / count + 0.5),
    count = count,
    -- Seller names may still be loading; such listings are kept anyway.
    seller = (seller and seller ~= "") and seller or "?",
    tl = timeLeft or 4,
  })
  state.count = state.count + 1
end

-- Reading -------------------------------------------------------------------

-- GetAuctionItemInfo / GetReplicateItemInfo share the return layout:
-- 3 count, 10 buyout, 14 owner, 17 itemID, 18 hasAllInfo
local function readLegacy(index)
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = GetAuctionItemInfo("list", index)
  local timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("list", index)
  addListing(itemID, count, buyout, owner, timeLeft)
end

local function readModern(index)
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(index)
  local timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft and C_AuctionHouse.GetReplicateItemTimeLeft(index)
  -- The modern enum is 0..3; store it as the classic 1..4.
  addListing(itemID, count, buyout, owner, timeLeft and (timeLeft + 1))
end

local finish

local function readBatches(first, last, read)
  local index = first
  local function step()
    if not state then return end
    local stop = math.min(last, index + BATCH - 1)
    for i = index, stop do read(i) end
    index = stop + 1
    if index <= last then
      C_Timer.After(0, function() ns.Safe(step) end)
    else
      finish()
    end
  end
  step()
end

-- Saving ----------------------------------------------------------------------

local function toKeys(listings)
  local keys = {}
  for i, l in ipairs(listings) do keys[i] = ns.AuctionStats.Key(l) end
  return keys
end

local function fromKeys(keys)
  local list = {}
  for _, key in ipairs(keys or {}) do
    local l = ns.AuctionStats.ParseKey(key)
    if l then table.insert(list, l) end
  end
  return list
end

finish = function()
  local scanState = state
  local ah = db(scanState.house)
  local now = time()
  local previous = ah.last
  local elapsed = previous and (now - previous.t) or nil
  local diff = elapsed and elapsed <= MAX_DIFF_AGE
  local dayKey = ns.AuctionStats.DayKey(now)
  ah.days[dayKey] = ah.days[dayKey] or {}
  local day = ah.days[dayKey]

  -- Every item that is listed now or was listed in the previous scan.
  local itemIDs, seen = {}, {}
  for itemID in pairs(scanState.listings) do
    table.insert(itemIDs, itemID); seen[itemID] = true
  end
  if diff then
    for itemID in pairs(previous.items) do
      if not seen[itemID] then table.insert(itemIDs, itemID) end
    end
  end

  local current, lastItems = {}, {}
  local soldTotal = 0
  -- the scan as an observation for the cloud (Observations.lua), written in the same batches
  local obsItems = scanState.obsID and ns.Obs and ns.Obs.Items(scanState.obsID)
  local index = 1
  local function step()
    local stop = math.min(#itemIDs, index + ITEM_BATCH - 1)
    for i = index, stop do
      local itemID = itemIDs[i]
      local listings = scanState.listings[itemID] or {}
      local summary
      if #listings > 0 then
        summary = ns.AuctionStats.Summarize(listings)
        current[itemID] = { summary.min, summary.mv, summary.qty, summary.n, summary.sellers }
        lastItems[itemID] = toKeys(listings)
        if obsItems then ns.Obs.Put(obsItems, itemID, now, listings, ns.Obs.SCAN) end
      end
      local soldUnits, soldValue, soldN, endedN
      if diff and previous.items[itemID] then
        soldUnits, soldValue, soldN, endedN =
          ns.AuctionStats.Diff(fromKeys(previous.items[itemID]), listings, elapsed)
        soldTotal = soldTotal + soldN
      end
      day[itemID] = ns.AuctionStats.AddToDay(day[itemID], summary, soldUnits, soldValue, soldN, endedN)
    end
    index = stop + 1
    if index <= #itemIDs then
      C_Timer.After(0, function() ns.Safe(step) end)
      return
    end
    ah.last = { t = now, npc = scanState.npc, items = lastItems }
    ah.current = current
    ah.currentT = now
    ah.npc = scanState.npc
    ah.scans = (ah.scans or 0) + 1
    ah.api = scanState.api
    ns.AuctionHouse.LogScan(scanState.house, { t = now, npc = scanState.npc, name = scanState.npcName,
      offers = scanState.count, items = #itemIDs })
    ns.AuctionStats.Prune(ah.days, now)
    print(string.format("%sScan fertig (%s): %d Angebote, %d Items, %d Sekunden.%s", PREFIX,
      ns.AuctionHouse.Label(scanState.house, scanState.npc), scanState.count, #itemIDs, now - scanState.started,
      diff and string.format(" Seit dem letzten Scan vermutlich %d Angebote verkauft.", soldTotal) or ""))
    if ns.PlannerUI and ns.PlannerUI.Refresh then ns.Safe(ns.PlannerUI.Refresh) end
    for _, fn in ipairs(doneListeners) do ns.Safe(fn) end
  end
  state = nil
  step()
end

-- Starting ------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local silenced = {}

-- Blizzard's browse frame would redraw on every list update of a getAll query;
-- it is silenced while we read and restored afterwards.
local function silenceOthers(event)
  silenced = {}
  if not GetFramesRegisteredForEvent then return end
  for _, f in ipairs({ GetFramesRegisteredForEvent(event) }) do
    if f ~= eventFrame then
      f:UnregisterEvent(event)
      table.insert(silenced, { f, event })
    end
  end
end

local function restoreOthers()
  for _, entry in ipairs(silenced) do entry[1]:RegisterEvent(entry[2]) end
  silenced = {}
end

eventFrame:SetScript("OnEvent", function(self, event)
  self:UnregisterEvent(event)
  restoreOthers()
  if not state then return end
  ns.Safe(function()
    if event == "AUCTION_ITEM_LIST_UPDATE" then
      -- With getAll every listing is on the one "page".
      local count = GetNumAuctionItems("list")
      readBatches(1, count or 0, readLegacy)
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
      readBatches(0, C_AuctionHouse.GetNumReplicateItems() - 1, readModern)
    end
  end)
end)

function Scan.Start()
  if state then
    print(PREFIX .. "Scan läuft bereits.")
    return
  end
  local api = detectApi()
  if not api then
    print(PREFIX .. "Dieser Client bietet keine bekannte Auktionshaus-Schnittstelle.")
    return
  end
  if not canScan(api) then
    local wait = Scan.Wait()
    if wait > 0 then
      print(string.format("%sVollscan erst wieder in %d:%02d Minuten möglich.", PREFIX,
        math.floor(wait / 60), wait % 60))
    else
      print(PREFIX .. "Der Server erlaubt gerade keinen Vollscan, bitte etwas später erneut.")
    end
    return
  end

  local open = ns.AuctionHouse.Open()
  -- obsID: the cloud house id the scan is recorded under as an observation - only at an
  -- auctioneer, fixed now (the scan belongs to the house it was started at)
  state = { api = api, started = time(), listings = {}, count = 0, house = ns.AuctionHouse.Auto(),
    npc = open and open.npc, npcName = open and open.name, obsID = ns.Obs and ns.Obs.OpenHouseID() }
  db(state.house).lastScanT = time()
  ns.db.ah.lastScanT = time()
  if ns.Selling then C_Timer.After(1, function() ns.Safe(ns.Selling.Refresh) end) end
  print(PREFIX .. "Vollscan gestartet – das Spiel kann kurz hängen.")
  if api == "legacy" then
    silenceOthers("AUCTION_ITEM_LIST_UPDATE")
    eventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  else
    eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    C_AuctionHouse.ReplicateItems()
  end
end

local function abort()
  if state then
    state = nil
    eventFrame:UnregisterAllEvents()
    restoreOthers()
    print(PREFIX .. "Scan abgebrochen (Auktionshaus geschlossen).")
  end
end

-- Tab "AH-Scan" under the auction house ----------------------------------------------------
-- After Blizzard's tabs (Kaufen / Verkaufen / Auktionen), in their look. A click starts the full
-- scan (it also starts by itself when the auction house opens, every 15 min at most); the
-- tooltip says how old the last scan is and when the next one is possible. While a scan
-- runs the tab reads "Scannt …".
Scan.BUTTON = true

local function ago(seconds)
  if seconds < 90 then return "gerade eben" end
  if seconds < 5400 then return string.format("vor %d min", math.floor(seconds / 60 + 0.5)) end
  return string.format("vor %d h", math.floor(seconds / 3600 + 0.5))
end

local function setTabText()
  if not button then return end
  button:SetText(state and "Scannt …" or "AH-Scan")
  if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, button, 20, nil, 70) end
end

local function createButton()
  if not Scan.BUTTON then return end
  local parent = AuctionHouseFrame
  if not parent or button then return end
  -- Blizzard's last tab, read before creating ours: the template adds the new tab to
  -- parent.Tabs itself, and anchoring it to itself fails
  local tabs = rawget(parent, "Tabs")
  local last = type(tabs) == "table" and tabs[#tabs]
  local ok, t = pcall(CreateFrame, "Button", "M4CompanionScanTab", parent, "AuctionHouseFrameDisplayModeTabTemplate")
  if not ok or not t then ok, t = pcall(CreateFrame, "Button", "M4CompanionScanTab", parent, "UIPanelButtonTemplate") end
  if not ok or not t then return end
  button = t
  if last and last ~= t then
    t:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
  else
    t:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", 300, 2)
  end
  setTabText()
  if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, t) end
  t:SetScript("OnClick", function()
    ns.Safe(Scan.Start)
    setTabText()
    if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, t) end
  end)
  t:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("AH-Scan")
    GameTooltip:AddLine("Auktionshaus: " .. ns.AuctionHouse.Label(), 1, 1, 1)
    local age = Scan.Age()
    GameTooltip:AddLine(age and ("Letzter Scan " .. ago(age)) or "Noch kein Scan", 1, 1, 1)
    if state then
      GameTooltip:AddLine("Läuft gerade …", 0.37, 0.83, 0.55)
    else
      local wait = Scan.Wait()
      if wait > 0 then
        GameTooltip:AddLine(string.format("Wieder möglich in %d:%02d", math.floor(wait / 60), wait % 60), 1, 0.71, 0.28)
      else
        GameTooltip:AddLine("Klick: alle Angebote lesen (alle 15 Minuten möglich)", 0.6, 0.6, 0.6)
      end
    end
    GameTooltip:Show()
  end)
  t:SetScript("OnLeave", function() GameTooltip:Hide() end)
  Scan.OnDone(function() C_Timer.After(0, setTabText) end)
  -- next to it: "Einkaufsliste" opens the shopping list (ShoppingList.lua) beside the auction house
  local okL, list = pcall(CreateFrame, "Button", "M4CompanionShoppingTab", parent, "AuctionHouseFrameDisplayModeTabTemplate")
  if not okL or not list then okL, list = pcall(CreateFrame, "Button", "M4CompanionShoppingTab", parent, "UIPanelButtonTemplate") end
  if okL and list then
    list:SetPoint("TOPLEFT", t, "TOPRIGHT", 3, 0)
    list:SetText("Einkaufsliste")
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, list, 20, nil, 70) end
    if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, list) end
    list:SetScript("OnClick", function()
      if ns.ShoppingList and ns.ShoppingList.Toggle then ns.Safe(ns.ShoppingList.Toggle) end
      if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, list) end
    end)
    list:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Einkaufsliste")
      GameTooltip:AddLine("Was für deine geplanten Crafts noch fehlt und was es kostet.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    list:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- and "Tageshandel": the daily-rhythm pool of this house (DayTrade.lua)
    local okD, trade = pcall(CreateFrame, "Button", "M4CompanionDayTradeTab", parent, "AuctionHouseFrameDisplayModeTabTemplate")
    if not okD or not trade then okD, trade = pcall(CreateFrame, "Button", "M4CompanionDayTradeTab", parent, "UIPanelButtonTemplate") end
    if okD and trade then
      trade:SetPoint("TOPLEFT", list, "TOPRIGHT", 3, 0)
      trade:SetText("Tageshandel")
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, trade, 20, nil, 70) end
      if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, trade) end
      trade:SetScript("OnClick", function()
        if ns.DayTrade and ns.DayTrade.Toggle then ns.Safe(ns.DayTrade.Toggle) end
        if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, trade) end
      end)
      trade:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Tageshandel")
        GameTooltip:AddLine("Items mit Tagesrhythmus: wann kaufen, bis zu welchem Preis, wann zu welchem Preis einstellen.", 1, 1, 1, true)
        GameTooltip:Show()
      end)
      trade:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
  end
end

-- Opening the auction house starts the full scan by itself (every 15 min at most).
-- If the game demands a click for it (ADDON_ACTION_BLOCKED), auto scans stop for the
-- session and the tabs start the scan on their click instead (EnsureFresh).
local autoBlocked = false
ns.On("ADDON_ACTION_BLOCKED", function(_, addon, fn)
  if addon == ADDON and type(fn) == "string" and fn:find("ReplicateItems") then
    autoBlocked = true
    if state then abort() end
  end
end)

ns.On("AUCTION_HOUSE_SHOW", function()
  -- The auction UI is load-on-demand; its frame exists only from now on.
  C_Timer.After(0, function()
    ns.Safe(createButton)
    if button then button:Show() end
  end)
  C_Timer.After(1, function()
    local off = ns.db.settings and ns.db.settings.autoScan == false
    if not autoBlocked and not off then ns.Safe(Scan.EnsureFresh) end
  end)
end)
ns.On("AUCTION_HOUSE_CLOSED", function() abort(); setTabText() end)
hooksecurefunc(Scan, "Start", function() setTabText() end)
