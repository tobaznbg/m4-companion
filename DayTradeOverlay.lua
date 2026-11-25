-- DayTradeOverlay: a small movable box on the screen (like LayerSwap's) for checking the day
-- trading on the go: how fresh the data is, what to buy now (with the expected profit for a
-- fixed capital, 25g) and what to post now. A click on a line opens the ledger's "Tageshandel"
-- tab on that item (and searches it when the auction house is open); right click hides the box,
-- "/m4 overlay" brings it back. The numbers come from DayTrade.lua (Trade.States), so the box and
-- the tab never disagree.
-- Under it the watch list ("Beobachtet", ns.Watch): items put there with the market data window's
-- "Beobachten" button, each with its price now and against yesterday's median; a click opens the
-- big price chart (ItemDetail's Big), a right click takes the item off the list.
local ADDON, ns = ...

local Overlay = {}
ns.DayTradeOverlay = Overlay

local MAX_LINES = 5
local MIN_PROFIT = 30000 -- copper: a buy suggestion under 3g expected profit is not worth the trip
local WIDTH = 290
local GREEN, RED, MUTED, GOLD = "|cff5fd38d", "|cffff6b6b", "|cff999999", "|cffffd100" -- luacheck: ignore RED

local frame, rows, title, fresh
local function money(c) return ns.FormatMoney(math.floor((c or 0) + 0.5), true) end

local function settings()
  ns.db.ui = ns.db.ui or {}
  return ns.db.ui
end

-- The watch list: item ids in the order they were added (ns.db.watch).
local Watch = {}
ns.Watch = Watch
local function watched()
  ns.db.watch = ns.db.watch or {}
  return ns.db.watch
end
function Watch.List() return watched() end
function Watch.Has(id)
  for _, x in ipairs(watched()) do if x == id then return true end end
  return false
end
-- Adds the item (and shows the box) or takes it off; returns whether it is watched now.
function Watch.Toggle(id)
  local list = watched()
  for i, x in ipairs(list) do
    if x == id then
      table.remove(list, i)
      Overlay.Refresh()
      return false
    end
  end
  list[#list + 1] = id
  if frame and frame:IsShown() then Overlay.Refresh() else Overlay.Show() end
  return true
end

-- "Cloud 34m · Scan 21m · Spieler 3m": the age of each source, colored by it. "Spieler" is the
-- newest of the players' observations via the cloud and those heard live (LiveChannel.lua).
local function freshness()
  local function part(label, t)
    if not t then return MUTED .. label .. " –|r" end
    local age = time() - t
    local c = age < 1200 and GREEN or age < 4200 and GOLD or RED
    -- the age, short: "jetzt", "10m", "1h", "2d"
    local text = age < 60 and "jetzt" or age < 3600 and string.format("%dm", math.floor(age / 60))
      or age < 86400 and string.format("%dh", math.floor(age / 3600)) or string.format("%dd", math.floor(age / 86400))
    return c .. label .. " " .. text .. "|r"
  end
  local AH = ns.AuctionHouse
  local data, id = AH.CloudData()
  local cloudT = data and ns.Item.Epoch and ns.Item.Epoch(data.updated)
  local own = AH.Peek()
  local scanT = own and own.currentT
  local players = id and ns.AHObs and ns.AHObs[id]
  local playersT = players and ns.Item.Epoch and ns.Item.Epoch(players.updated)
  if playersT and playersT <= 0 then playersT = nil end -- an empty shell of m4d (1970)
  local liveT = ns.Live and ns.Live.NewestT(id)
  if liveT and (not playersT or liveT > playersT) then playersT = liveT end
  return part("Cloud", cloudT) .. MUTED .. " · |r" .. part("Scan", scanT) .. MUTED .. " · |r" .. part("Spieler", playersT)
end

local function row(i)
  if rows[i] then return rows[i] end
  local b = CreateFrame("Button", nil, frame)
  b:SetHeight(14)
  b:SetPoint("LEFT", frame, "LEFT", 10, 0)
  b:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.left:SetPoint("LEFT", 0, 0)
  b.left:SetJustifyH("LEFT")
  -- one line each: long names end in "…" instead of wrapping
  b.left:SetWordWrap(false)
  if b.left.SetMaxLines then b.left:SetMaxLines(1) end
  b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.right:SetPoint("RIGHT", 0, 0)
  b.right:SetJustifyH("RIGHT")
  b.right:SetWordWrap(false)
  b.left:SetPoint("RIGHT", b.right, "LEFT", -6, 0)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  b:SetScript("OnClick", function(self, button)
    if self.watch and self.itemID then
      -- watch list: left the big chart, right off the list
      if button == "RightButton" then return Watch.Toggle(self.itemID) end
      local Big = ns.ItemDetail and ns.ItemDetail.Big
      if Big and Big.Show then ns.Safe(Big.Show, self.itemID) end
      return
    end
    if button == "RightButton" then return Overlay.Hide() end
    if not self.itemID then return end
    ns.Safe(ns.DayTrade.Show, self.itemID)
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() and ns.Deals and ns.Deals.Search then
      if AuctionHouseFrameDisplayMode then AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
      local id = self.itemID
      C_Timer.After(0.1, function() ns.Safe(ns.Deals.Search, id) end)
    end
  end)
  b:SetScript("OnEnter", function(self)
    if not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemID)
    if self.tip then GameTooltip:AddLine(self.tip, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- drags move the whole box, also when started on a line
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function() frame:StartMoving() end)
  b:SetScript("OnDragStop", function() Overlay.StopMoving() end)
  rows[i] = b
  return b
end

local function refresh()
  if not (frame and frame:IsShown()) then return end
  title:SetText(GOLD .. "Tageshandel|r  " .. MUTED .. ns.AuctionHouse.Name() .. "|r")
  fresh:SetText(freshness())
  local states = ns.DayTrade.States()
  local lines = {}
  local function add(l) lines[#lines + 1] = l end
  if #states == 0 then
    add({ text = MUTED .. "keine Daten für dieses AH|r" })
  else
    -- buy now: everything in its buy window under the limit, best expected profit first
    local buys = {}
    for _, s in ipairs(states) do
      if s.phase == "buy" and s.offer.cheapest and s.offer.cheapest <= s.limit then
        local qty, cost, profit, approx = ns.DayTrade.Plan(s)
        if qty > 0 and profit >= MIN_PROFIT then buys[#buys + 1] = { s = s, qty = qty, cost = cost, profit = profit, approx = approx } end
      end
    end
    table.sort(buys, function(a, b) return a.profit > b.profit end)
    add({ head = string.format("Kaufen %s%dg|r", MUTED, math.floor(ns.DayTrade.CAPITAL / 10000)) })
    if #buys == 0 then add({ text = MUTED .. "–|r" }) end
    for i = 1, math.min(#buys, MAX_LINES) do
      local b = buys[i]
      add({ itemID = b.s.itemID, text = ns.ItemName(b.s.itemID) or ("Item " .. b.s.itemID),
        right = string.format("%s+%s|r", GREEN, money(b.profit)),
        tip = string.format("Kaufen: %d Stück für %s (Grenze %s je Stück).\nEinstellen %s zu %s je Stück: erwartet +%s nach Gebühr und Einstellgebühr.",
          b.qty, money(b.cost), money(b.s.limit), ns.DayTrade.NextWindowText(b.s.sellHour),
          money(b.s.ask), money(b.profit)) })
    end
    -- post now: what the household holds in its sell window
    local sells = {}
    for _, s in ipairs(states) do
      -- only what makes sense now: held, in its sell window and not undercut below the floor
      if s.phase == "sell" and s.held > 0 and s.post then sells[#sells + 1] = s end
    end
    table.sort(sells, function(a, b) return a.post * a.held > b.post * b.held end)
    add({ head = "Einstellen", gap = true })
    if #sells == 0 then add({ text = MUTED .. "–|r" }) end
    for i = 1, math.min(#sells, MAX_LINES) do
      local s = sells[i]
      add({ itemID = s.itemID, text = ns.ItemName(s.itemID) or ("Item " .. s.itemID),
        right = string.format("%d× %s%s|r", s.held, s.post >= s.ask and GREEN or GOLD, money(s.post))
          .. ((s.gain(s.post) or 0) > 0 and string.format("  %s+%s|r", GREEN, money(s.gain(s.post))) or ""),
        tip = s.post >= s.ask and "2 h einstellen, mindestens zum Zielpreis."
          or "2 h einstellen, 1 Kupfer unter dem Günstigsten (der liegt unter dem Zielpreis)." })
    end
  end
  -- the watch list: price now and against yesterday's median
  local watch = watched()
  if #watch > 0 then
    add({ head = "Beobachtet", gap = true })
    for _, id in ipairs(watch) do
      local e = ns.Item.Get(id)
      local now, ch = e and e.now, e and e.change
      add({ itemID = id, watch = true, text = ns.ItemName(id) or ("Item " .. id),
        right = now and (money(now) .. (ch and string.format("  %s%+d %%|r", ch >= 0 and GREEN or RED,
          math.floor(ch * 100 + 0.5)) or "")) or (MUTED .. "nicht im AH|r"),
        tip = "Klick: großes Diagramm.\nRechtsklick: nicht mehr beobachten.\nProzent: jetzt zu Median gestern." })
    end
  end
  local y = -40
  for i, l in ipairs(lines) do
    local r = row(i)
    if l.gap then y = y - 6 end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, y)
    r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, y)
    r.itemID, r.tip, r.watch = l.itemID, l.tip, l.watch
    r.left:SetFontObject(l.head and "GameFontNormalSmall" or "GameFontHighlightSmall")
    r.left:SetText(l.head or ((l.itemID and "  " or "") .. (l.text or "")))
    r.right:SetText(l.right or "")
    r:EnableMouse(l.itemID ~= nil)
    r:Show()
    y = y - 15
  end
  for i = #lines + 1, #rows do rows[i]:Hide() end
  frame:SetHeight(-y + 8)
end
Overlay.Refresh = function() ns.Safe(refresh) end

function Overlay.StopMoving()
  frame:StopMovingOrSizing()
  local point, _, rel, x, y = frame:GetPoint()
  settings().tradeOverlayPos = { point, rel, x, y }
end

local function create()
  frame = CreateFrame("Frame", "M4CompanionTradeOverlay", UIParent, "BackdropTemplate")
  frame:SetWidth(WIDTH)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", Overlay.StopMoving)
  frame:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then Overlay.Hide() end end)
  if frame.SetBackdrop then
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    frame:SetBackdropColor(0, 0, 0, 0.65)
    frame:SetBackdropBorderColor(1, 1, 1, 0.15)
  end
  local pos = settings().tradeOverlayPos
  if type(pos) == "table" and pos[1] then
    frame:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
  else
    frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
  title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -8)
  title:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  fresh = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fresh:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  fresh:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  fresh:SetJustifyH("LEFT")
  fresh:SetWordWrap(false)
  rows = {}
  frame:SetScript("OnShow", refresh)
  -- prices age and the hour moves items between buy, sell and wait: redraw regularly
  C_Timer.NewTicker(15, Overlay.Refresh)
end

function Overlay.Show()
  if not frame then create() end
  settings().tradeOverlay = true
  frame:Show()
  refresh()
end

function Overlay.Hide()
  if frame then frame:Hide() end
  settings().tradeOverlay = false
  print("|cffffd100M4:|r Tageshandel-Overlay aus – mit /m4 overlay wieder an.")
end

function Overlay.Toggle()
  if frame and frame:IsShown() then Overlay.Hide() else Overlay.Show() end
end

-- On by default; a hidden box stays hidden across sessions.
ns.OnReady(function()
  if settings().tradeOverlay ~= false then ns.Safe(Overlay.Show) end
  if ns.Obs and ns.Obs.OnRecord then ns.Obs.OnRecord(function() C_Timer.After(0, Overlay.Refresh) end) end
  if ns.AuctionScan and ns.AuctionScan.OnDone then ns.AuctionScan.OnDone(Overlay.Refresh) end
  ns.AuctionHouse.OnChange(Overlay.Refresh)
  -- other players' prices arrive up to once a second: the box follows every LIVE_EVERY seconds
  if ns.Live then
    local LIVE_EVERY = 5
    local lastLive, livePending = -LIVE_EVERY, false
    ns.Live.OnUpdate(function()
      if livePending then return end
      livePending = true
      C_Timer.After(math.max(0, lastLive + LIVE_EVERY - GetTime()), function()
        livePending, lastLive = false, GetTime()
        Overlay.Refresh()
      end)
    end)
  end
end)
