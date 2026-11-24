-- TradeBook: the ledger ("Handelsbuch") in Blizzard's own look (ns.NativeWindow): side tabs
-- Übersicht / Handelsbuch / Bestand / Auktionen / Gold. Opens on the overview, period "Alles",
-- all characters of the household. Opened with the minimap button (left click) or /m4 buch.
-- All pages with the real figures (ns.Profit, ns.MyAuctions, ns.Ledger).
local ADDON, ns = ...

local TradeBook = {}
ns.TradeBook = TradeBook

local NAME = "M4CompanionTradeBook"
local ICON = "Interface\\Icons\\INV_Misc_Coin_02" -- a pile of gold coins
local PERIODS = { { key = "today", label = "Heute" }, { key = "week", label = "7 Tage" }, { key = "all", label = "Alles" } }

local window
local period = "all"
local charSel = nil -- nil: all characters of the household, else one character key
local choices = {} -- the choice row under the title (buildChoices)

-- The auction house the pages show: the choice (AuctionHouse.Chooser), else the automatic one.
local function shownHouse()
  return choices.house and choices.house.Selected() or ns.AuctionHouse.Auto()
end

-- Whether a record (ledger event, stored auction) belongs to the shown house; records of no
-- house or of an unknown one belong to the home house (AuctionHouse.ShownUnder).
local function inHouse(e)
  return ns.AuctionHouse.ShownUnder(e) == shownHouse()
end

-- Runs fn(...) on the shown house: scan data and prices of that house (AuctionHouse.WithView),
-- the profit figures filtered to its trades (Profit.SetHouseFilter), reset afterwards.
local function withHouse(fn, ...)
  local house = shownHouse()
  local P = ns.Profit
  local before = P and P.HouseFilter and P.HouseFilter()
  if P and P.SetHouseFilter then P.SetHouseFilter(house) end
  local result = { pcall(ns.AuctionHouse.WithView, house, fn, ...) }
  if P and P.SetHouseFilter then P.SetHouseFilter(before) end
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2)
end

-- A tab's build function on the shown house; the page's Refresh too, every time.
local function viewed(build)
  return function(page, ...)
    withHouse(build, page, ...)
    local refresh = page.Refresh
    if refresh and not page.m4Viewed then
      page.m4Viewed = true
      page.Refresh = function(...) return withHouse(refresh, ...) end
    end
  end
end

-- The characters the pages show: the chosen one or the whole household (same realm and faction).
local function household()
  return ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or { ns.CharKey and ns.CharKey() }
end
local function shownKeys() return charSel and { charSel } or household() end

-- A character's gold and since when it is known: live for the one playing, else the last stored
-- value (snapshot, kept on every change of money). Snapshots without moneyT are from before the
-- logout fix (the client answers 0 at logout): then the gold seen at the auction house counts.
local function goldOf(key)
  if key == (ns.CharKey and ns.CharKey()) and GetMoney then return GetMoney(), time() end
  local c = ns.db and ns.db.chars and ns.db.chars[key]
  if c and c.moneyT then return c.money or 0, c.moneyT end
  local owned = ns.db and ns.db.owned and ns.db.owned[key]
  if owned and owned.g then return owned.g, owned.t end
  return c and c.money or 0, c and c.updated
end

-- First and last name as the player frame shows it ("Lokm Bank"), else the first name. The
-- realm is left out: the household is one realm anyway.
local function fullName(key)
  local c = key and ns.db and ns.db.chars and ns.db.chars[key]
  return (c and (c.fullName or c.name)) or (key and key:match("^([^-]+)")) or "?"
end

function TradeBook.Gold()
  local sum = 0
  for _, key in ipairs(shownKeys()) do sum = sum + (goldOf(key)) end
  return sum
end


-- Overview, built from Blizzard's "Berufe" overview parts: on top two cards side by side
-- (profit and loss with the period choice, stock), below running auctions and recent trades.
local CARD_W, TOP_H = 331, 142
local TOP = -62 -- the overview's cards start under the window's choice row (character, period)

local function card(page, w, x, y, width, height, title)
  local c = CreateFrame("Frame", nil, page)
  c:SetSize(width, height)
  c:SetPoint("TOPLEFT", w.frame, "TOPLEFT", x, y)
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetAtlas("Profession-overview-Card")
  c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  c.Title:SetPoint("TOPLEFT", 20, -16)
  c.Title:SetText(title)
  return c
end

-- A table in a card: column heads, a gold rule and a scroll list of rows (Blizzard's scroll box
-- and minimal scroll bar). Returns setRows(rows, heads), rows = { { icon = …, itemID = …, text1, … } },
-- heads = other column heads for these rows (nil: the ones given here).
local function scrollTable(c, cols, top)
  local heads = {}
  for i, col in ipairs(cols) do
    local h = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if col[3] == "LEFT" then h:SetPoint("TOPLEFT", col[2], top) else h:SetPoint("TOPRIGHT", c, "TOPLEFT", col[2], top) end
    h:SetText(col[1])
    heads[i] = h
  end
  local rule = c:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(1, 0.82, 0, 0.25)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 20, top - 14)
  rule:SetPoint("TOPRIGHT", -24, top - 14)
  local empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  empty:SetPoint("TOPLEFT", 22, top - 24)
  local okB, box = pcall(CreateFrame, "Frame", nil, c, "WowScrollBoxList")
  local okS, bar = pcall(CreateFrame, "EventFrame", nil, c, "MinimalScrollBar")
  if not (okB and okS and CreateScrollBoxListLinearView and ScrollUtil) then
    return function(rows) empty:SetText(#rows .. " Einträge") end
  end
  box:SetPoint("TOPLEFT", 16, top - 18)
  box:SetPoint("BOTTOMRIGHT", -30, 14)
  bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, 0)
  bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 0)
  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(20)
  view:SetElementInitializer("BackdropTemplate", function(row, r)
    if not row.m4 then
      row.m4 = {}
      row.m4.icon = row:CreateTexture(nil, "ARTWORK")
      row.m4.icon:SetSize(16, 16)
      row.m4.icon:SetPoint("LEFT", 4, 0)
      for k, col in ipairs(cols) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        if col[3] == "LEFT" then
          fs:SetPoint("LEFT", row, "LEFT", k == 1 and 26 or (col[2] - 16), 0)
          -- ends before the next (right-aligned) column with room for its text; longer is cut "…"
          local nextCol = cols[k + 1]
          local room = nextCol and nextCol[3] ~= "LEFT" and (nextCol[2] - 16) - (k == 1 and 26 or (col[2] - 16)) - 38
          fs:SetWidth(room and math.min(col[4] or 200, room) or (col[4] or 200))
          fs:SetJustifyH("LEFT")
        else
          fs:SetPoint("RIGHT", row, "LEFT", col[2] - 16, 0)
          fs:SetJustifyH("RIGHT")
        end
        row.m4[k] = fs
      end
      row:EnableMouse(true)
      row:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
          if self.itemID and self.ownUseMenu then ns.Safe(TradeBook.OwnUseMenu, self, self.itemID) end
          return
        end
        if button ~= "LeftButton" then return end
        if self.itemID and ns.NativeWindow.AltClick(self.itemID, self) then return end
        if self.onClick then ns.Safe(self.onClick) end
      end)
    end
    row.itemID = r.itemID
    row.onClick = r.onClick
    row.ownUseMenu = r.ownUseMenu
    row.m4.icon:SetTexture(r.icon)
    for k = 1, #cols do row.m4[k]:SetText(r[k] or "") end
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  return function(rows, texts)
    for i, h in ipairs(heads) do h:SetText(texts and texts[i] or cols[i][1]) end
    empty:SetText(#rows == 0 and "Keine Einträge" or "")
    box:SetDataProvider(CreateDataProvider(rows))
  end
end

-- Real data ------------------------------------------------------------------------------------

local GREEN, RED, MUTED = "|cff5fd38d", "|cffff6b6b", "|cff999999"
-- areas in the list gold, their parts white; parts where no money moved (handed over, stock) grey
local GOLD, WHITE, GREY = { 1, 0.82, 0 }, { 1, 1, 1 }, { 0.6, 0.6, 0.6 }
-- an amount in grey with its sign (bookings without money moving)
local function greyed(c)
  c = math.floor((c or 0) + 0.5)
  return MUTED .. (c < 0 and "-" or "+") .. ns.FormatMoney(math.abs(c), true) .. "|r"
end
local function money(c) return ns.FormatMoney(math.floor((c or 0) + 0.5), true) end
local function signed(c)
  c = math.floor((c or 0) + 0.5)
  return c >= 0 and (GREEN .. "+" .. money(c) .. "|r") or (RED .. "-" .. money(-c) .. "|r")
end
local function iconOf(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end

local function since()
  if period == "today" then
    local d = date("*t")
    return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
  elseif period == "week" then
    return time() - 7 * 86400
  end
  return nil
end

-- Running auctions of the shown characters (built with the "Auktionen" tab's collection).
local function auctionRows() return TradeBook.AuctionRows() end

local KINDS = { buy = "Kauf", sale = "Verkauf", vendor = "Händler", post = "Eingestellt", expired = "Abgelaufen",
  cancelled = "Abgebrochen", craft = "Hergestellt", trade = "Handel" }

-- The last 20 trades (all of them: the "Handelsbuch" tab).
local function tradeRows()
  local out = {}
  local L = ns.Ledger
  local events = L and L.HouseholdEvents and L.HouseholdEvents() or {}
  local me, many = ns.CharKey and ns.CharKey(), not charSel and #household() > 1
  local recent = {}
  for i = #events, 1, -1 do
    local e = events[i]
    local who = L.CharOf and L.CharOf(e)
    if (not charSel or who == charSel) and inHouse(e) then recent[#recent + 1] = { e = e, who = who } end
    if #recent >= 20 then break end
  end
  for _, x in ipairs(recent) do
    local e = x.e
    local amount = ""
    if e.k == "buy" then amount = RED .. "-" .. money(e.c) .. "|r"
    elseif e.k == "sale" then amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
    elseif e.k == "vendor" then amount = GREEN .. "+" .. money(e.c) .. "|r"
    elseif e.k == "post" and e.p then amount = MUTED .. money(e.p * (e.u or 1)) .. "|r" end
    local name = e.n or (e.i and ns.ItemName(e.i)) or "?"
    local units = tostring(e.u or 1)
    if e.k == "trade" then
      -- the trade window: with whom, what went each way; gold as the amount
      name = "Handel mit " .. (e.with or "?") .. (e.own and (MUTED .. " (eigener Char)|r") or "")
      local parts = {}
      for _, it in ipairs(e.give or {}) do parts[#parts + 1] = RED .. "-" .. it.n .. "× " .. (ns.ItemName(it.i) or "?") .. "|r" end
      for _, it in ipairs(e.get or {}) do parts[#parts + 1] = GREEN .. "+" .. it.n .. "× " .. (ns.ItemName(it.i) or "?") .. "|r" end
      if #parts > 0 then name = name .. "  " .. table.concat(parts, ", ") end
      local net = (e.gr or 0) - (e.gg or 0)
      amount = net > 0 and (GREEN .. "+" .. money(net) .. "|r") or (net < 0 and (RED .. "-" .. money(-net) .. "|r") or (MUTED .. "Tausch|r"))
      units = MUTED .. "–|r"
    elseif e.src == "trade" and e.with then
      name = name .. MUTED .. "  · Handel mit " .. e.with .. "|r"
    end
    local whoText = (many and x.who and x.who ~= me) and (MUTED .. "  · " .. (x.who:match("^([^-]+)") or x.who) .. "|r") or ""
    out[#out + 1] = { itemID = e.i, icon = e.k == "trade" and "Interface\\Icons\\INV_Misc_Coin_01" or iconOf(e.i),
      name .. whoText,
      MUTED .. date("%d.%m. %H:%M", e.t or 0) .. "|r  " .. (KINDS[e.k] or tostring(e.k)),
      units, amount }
  end
  return out
end

local function buildOverview(page, w)
  local NW = ns.NativeWindow

  -- 1. profit and loss (left) with the period choice
  local pnl = card(page, w, 5, TOP, CARD_W, TOP_H, "Gewinn und Verlust")
  local pnlSlot = NW.Slot(pnl, "Interface\\Icons\\INV_Misc_Coin_02", "Gewinn", "")
  pnlSlot:SetPoint("TOPLEFT", 16, -40)
  local pnlFig = NW.Figures(pnl, pnlSlot, { "Umsatz", "Wareneinsatz", "Gebühren" }, { line = false, gap = 8, step = 14 })
  pnlFig.labels[1]:ClearAllPoints()
  pnlFig.labels[1]:SetPoint("TOPLEFT", pnlSlot, "BOTTOMLEFT", 2, -8)
  pnlFig.SetWidth(CARD_W - 40)

  -- 2. stock (right)
  local stock = card(page, w, 5 + CARD_W + 2, TOP, CARD_W, TOP_H, "Bestand und Gold")
  local stockSlot = NW.Slot(stock, "Interface\\Icons\\INV_Box_02", "Buchgewinn", "")
  stockSlot:SetPoint("TOPLEFT", 16, -40)
  local stockFig = NW.Figures(stock, stockSlot, { "Einkauf", "Erlös", "Gold" }, { line = false, gap = 8, step = 14 })
  stockFig.labels[1]:ClearAllPoints()
  stockFig.labels[1]:SetPoint("TOPLEFT", stockSlot, "BOTTOMLEFT", 2, -8)
  stockFig.SetWidth(CARD_W - 40)

  -- 3. running auctions (full width): 9 whole rows (scroll box = card height - 74, rows of 20)
  local AH = 254
  local auc = card(page, w, 5, TOP - TOP_H + 4, 664, AH, "Laufende Auktionen")
  local aucInfo = auc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  aucInfo:SetPoint("TOPRIGHT", -20, -18)
  local setAuctions = scrollTable(auc, { { "Gegenstand", 20, "LEFT", 330 }, { "Preis", 450, "RIGHT" },
    { "Status", 565, "RIGHT" }, { "Zeit", 612, "RIGHT" } }, -42)

  -- 4. recent trades (full width), scrollable: 3 whole rows in the rest of the window
  local trTop = TOP - TOP_H + 4 - AH + 4
  local tr = card(page, w, 5, trTop, 664, 594 + trTop - 10, "Letzte Vorgänge")
  local setTrades = scrollTable(tr, { { "Item", 20, "LEFT", 270 }, { "Wann · Art", 320, "LEFT", 170 },
    { "Menge", 520, "RIGHT" }, { "Betrag", 612, "RIGHT" } }, -42)

  function page.Refresh()
    -- profit and loss of the period, stock now (ns.Profit, one replay)
    local report = ns.Profit and ns.Profit.Report and ns.Profit.Report(since())
    local t = report and report.totals or {}
    local sales = 0
    for _, g in ipairs(report and report.groups or {}) do sales = sales + (g.sold or 0) end
    pnlSlot.Sub:SetText(signed(t.profit) .. MUTED .. "  ·  " .. sales .. " verkauft|r")
    pnlFig.values[1]:SetText(money(t.revenue)); pnlFig.values[2]:SetText(money(t.cost)); pnlFig.values[3]:SetText(money(t.fees))
    local st = report and report.stockTotals or {}
    stockSlot.Sub:SetText(signed(st.gain))
    stockFig.values[1]:SetText(money(st.cost)); stockFig.values[2]:SetText(money(st.sell))
    stockSlot.Name:SetText(string.format("Buchgewinn  |cff999999%d Items · %d Stück|r", report and #(report.stock or {}) or 0, st.units or 0))
    stockFig.values[3]:SetText(money(TradeBook.Gold()))
    local rows, under = auctionRows()
    setAuctions(rows)
    aucInfo:SetText(#rows .. " Auktionen" .. (under > 0 and ("  ·  " .. RED .. under .. " unterboten|r") or ""))
    setTrades(tradeRows())
  end
  page.Refresh()
end

-- Sub pages: Blizzard's recipe list left, the card right ---------------------------------------

-- The card's icon as a button: item tooltip on hover, Alt+click opens the market data window.
-- d.itemID is set by whoever shows an item on the card.
local function iconButton(parent, d)
  local b = CreateFrame("Button", nil, parent)
  b:SetAllPoints(d.Icon)
  b:SetScript("OnEnter", function(self)
    if not d.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(d.itemID)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function()
    if d.itemID then ns.NativeWindow.AltClick(d.itemID, parent) end
  end)
  return b
end

-- Card head (icon in a ring, name) and figure rows, built once per card for its labels.
local function cardFrame(card, labels)
  if card.m4 then return card.m4 end
  local d = {}
  d.Icon = card:CreateTexture(nil, "ARTWORK")
  d.Icon:SetSize(44, 44)
  d.Icon:SetPoint("TOPLEFT", 22, -22)
  local okMask, mask = pcall(card.CreateMaskTexture, card)
  if okMask and mask then
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(d.Icon)
    d.Icon:AddMaskTexture(mask)
  end
  local ring = card:CreateTexture(nil, "OVERLAY")
  ring:SetSize(60, 60)
  ring:SetPoint("CENTER", d.Icon, "CENTER", 0, 0)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetTexCoord(0, 0.6, 0, 0.6)
  d.Ring = ring
  d.Name = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  d.Name:SetPoint("LEFT", d.Icon, "RIGHT", 14, 6)
  d.Name:SetPoint("RIGHT", card, "RIGHT", -20, 0)
  d.Name:SetJustifyH("LEFT")
  d.Sub = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.Sub:SetPoint("TOPLEFT", d.Name, "BOTTOMLEFT", 0, -3)
  d.Head = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  d.Head:SetPoint("TOPLEFT", d.Icon, "BOTTOMLEFT", 0, -20)
  d.Head:SetText("Kennzahlen:")
  iconButton(card, d)
  d.Figures = ns.NativeWindow.Figures(card, d.Head, labels)
  d.Figures.SetWidth(math.max(100, (card:GetWidth() or 340) - 46))
  card:HookScript("OnSizeChanged", function(c) d.Figures.SetWidth(math.max(100, (c:GetWidth() or 340) - 46)) end)
  card.m4 = d
  return d
end

local function showCard(card, d, entry, values, sub)
  local parts = { d.Icon, d.Ring, d.Name, d.Sub, d.Head }
  for _, p in ipairs(parts) do p:SetShown(entry ~= nil) end
  for i, v in ipairs(d.Figures.values) do
    v:SetShown(entry ~= nil)
    d.Figures.labels[i]:SetShown(entry ~= nil)
  end
  if d.Figures.line then d.Figures.line:SetShown(entry ~= nil) end
  if not entry then return end
  d.Icon:SetTexture(entry.icon)
  d.itemID = entry.itemID
  d.Name:SetText(entry.name)
  d.Sub:SetText(sub or "")
  for i, v in ipairs(d.Figures.values) do v:SetText(values[i] or "–") end
end

local function shortGroup(name)
  if ns.Profit and name == ns.Profit.TRADE then return "Handel" end
  if ns.Profit and name == ns.Profit.FARMED then return "Beute" end
  if ns.Profit and name == ns.Profit.OWN then return "Eigenbedarf" end
  return name
end

-- "Handelsbuch": how economic each activity is. Left the areas as plain rows (trade, loot, each
-- profession) with their profit; right the area's figures and its items (scrollable, by
-- contribution); an item opens in place (its profit and loss and trades, "‹ Zurück" to the
-- area). The search box searches all items.
local AREA_ROWS = 7

-- Figures of one area: { labels, values, top = { { name, value }… }, sub }.
local function areaFigures(g, items)
  local P = ns.Profit
  local function pct(a, b) return (b and b ~= 0) and string.format("%d %%", math.floor(a / b * 100 + 0.5)) or "–" end
  local top = {}
  local sorted = {}
  for _, r in ipairs(items or {}) do sorted[#sorted + 1] = r end
  if P.IsFarmed(g.name) then
    table.sort(sorted, function(a, b) return (a.revenue or 0) > (b.revenue or 0) end)
    for i = 1, math.min(5, #sorted) do top[i] = { sorted[i].name or ns.ItemName(sorted[i].itemId) or "?", money(sorted[i].revenue) } end
    local sub = g.name == P.FARMED and "Beute – was du gelootet und verkauft hast"
      or (g.name .. " – gesammelt und verkauft (kein Einkauf)")
    return { sub = sub, topTitle = "Brachte am meisten:",
      labels = { "Erlös", "Gebühren", "Verlorene Einstellgebühren", "Verkauft", "Gewinn" },
      values = { money(g.revenue), money(g.fees), money(g.depositsLost), (g.sold or 0) .. " Stück", signed(g.profit) }, top = top }
  end
  table.sort(sorted, function(a, b) return (a.profit or 0) > (b.profit or 0) end)
  for i = 1, math.min(5, #sorted) do top[i] = { sorted[i].name or ns.ItemName(sorted[i].itemId) or "?", signed(sorted[i].profit) } end
  if g.name == P.OWN then
    table.sort(sorted, function(a, b) return (a.spent or 0) > (b.spent or 0) end)
    top = {}
    for i = 1, math.min(5, #sorted) do top[i] = { sorted[i].name or ns.ItemName(sorted[i].itemId) or "?", RED .. "-" .. money(sorted[i].spent) .. "|r" } end
    return { sub = "Eigenbedarf – für dich gekauft (Taschen, Werkzeuge, Verbrauchtes): Ausgaben, kein Handel",
      topTitle = "Größte Ausgaben:", labels = { "Ausgaben", "Gekauft", "Ergebnis" },
      values = { money(g.spent), (g.bought or 0) .. " Stück", signed(g.profit) }, top = top }
  end
  if g.name == P.TRADE then
    return { sub = "Handel – im AH oder beim Händler gekauft und wieder verkauft", topTitle = "Größter Beitrag:",
      labels = { "Einkauf", "Verkauf", "Gebühren", "Marge", "Noch im Bestand", "Abgelaufen", "Gewinn" },
      values = { money((g.spent or 0) + (g.pre or 0)), money(g.revenue), money(g.fees), pct(g.profit or 0, g.revenue), money(g.stockValue),
        string.format("%d×  " .. RED .. "-%s|r", (g.expired or 0) + (g.cancelled or 0), money(g.depositsLost)), signed(g.profit) },
      top = top }
  end
  return { sub = "Beruf – Material gekauft, hergestellt und verkauft", topTitle = "Größter Beitrag:",
    labels = { "Wareneinsatz", "Erlös", "Gebühren", "Marge", "Hergestellt / verkauft", "Unverkauft (Material)", "Gewinn" },
    values = { money(g.cost), money(g.revenue), money(g.fees), pct(g.profit or 0, g.revenue),
      string.format("%d / %d Stück", g.crafted or 0, g.sold or 0),
      string.format("%d Stück · %s", g.stockUnits or 0, money(g.stockValue)), signed(g.profit) }, top = top }
end

-- A crafting profession with bought material, the whole: what came in, what went out for
-- material, how much of it is still there (stock change at cost) and the profit. Gewinn =
-- Erlös - Materialeinkauf + Bestandsveränderung - Gebühren (Bestandsveränderung = Einkauf -
-- Wareneinsatz: what of the purchases is not sold yet, as raw material or in products).
local function overviewFigures(g, m, e)
  local delta = (g.spent or 0) + (g.pre or 0) + (g.tin or 0) - (g.cost or 0) - (g.tout or 0)
  if math.abs(delta) < 10 then delta = 0 end
  return { sub = "Beruf – Material eingekauft, verkauft", topTitle = "",
    labels = { "Erlös", "Einkauf", "Erhalten", "Von anderen Berufen verarbeitet", "Bestandsveränderung", "Gebühren", "Gewinn" },
    values = { money(g.revenue), RED .. "-" .. money((m.spent or 0) + (m.pre or 0) + (e.spent or 0)) .. "|r",
      (g.tin or 0) > 0 and (RED .. "-" .. money(g.tin) .. "|r") or "–", (g.tout or 0) > 0 and signed(g.tout) or "–",
      signed(delta), money(g.fees), signed(g.profit) } }
end

-- The parts of a profession with bought material; they add up to its profit:
-- Einkauf (bought, and material handed over by another profession at cost) + Verarbeitet (own
-- material another profession used, at cost) + Verkauf netto (all sales after fees) + Bestand
-- (what of it is still there, at cost: material left and products in stock) = Gewinn.
local function buyFigures(g, m, trade, e)
  e = e or {}
  return { sub = trade and "Einkauf – Ware, im AH oder beim Händler gekauft" or "Einkauf – Material, Rezepte und Werkzeuge, im AH oder beim Händler gekauft", topTitle = "",
    labels = { "Einkauf", trade and "Gekauft" or "Material", trade and "Einstand eingetragen (vor der Aufzeichnung)" or "Rezepte und Werkzeuge",
      "Davon verarbeitet", trade and "Wieder verkauft" or "Roh wieder verkauft", "Bestand jetzt (alles)" },
    values = { RED .. "-" .. money((m.spent or 0) + (m.pre or 0) + (e.spent or 0)) .. "|r",
      string.format("%d Stück · %s", m.bought or 0, money(m.spent)),
      trade and ((m.pre or 0) > 0 and string.format("%d Stück · %s", m.preN or 0, money(m.pre)) or "–")
        or ((e.spent or 0) > 0 and string.format("%d Stück · %s", e.bought or 0, money(e.spent)) or "–"),
      string.format("%d Stück · %s", m.used or 0, money(m.usedValue)),
      string.format("%d Stück", m.sold or 0), string.format("%d Stück · %s", m.stockUnits or 0, money(m.stockValue)) } }
end

local function sellFigures(g, m, pr, trade)
  if trade then
    return { sub = "Verkauf – nach Gebühren", topTitle = "",
      labels = { "Erlös", "Gebühren", "Verkauft", "Verkauf netto" },
      values = { money(g.revenue), RED .. "-" .. money(g.fees) .. "|r", string.format("%d Stück", g.sold or 0),
        signed((g.revenue or 0) - (g.fees or 0)) } }
  end
  return { sub = "Verkauf – Produkte und roh verkauftes Material, nach Gebühren", topTitle = "",
    labels = { "Erlös Produkte / Beute", "Erlös Material (roh)", "Gebühren", "Verkauft", "Verkauf netto" },
    values = { money(pr.revenue), money(m.revenue), RED .. "-" .. money(g.fees) .. "|r",
      string.format("%d Stück", (pr.sold or 0) + (m.sold or 0)), signed((g.revenue or 0) - (g.fees or 0)) } }
end

-- (a few copper of rounding between the per-item values are no stock)
local function stockValueOf(g)
  local v = (g.spent or 0) + (g.pre or 0) + (g.tin or 0) - (g.cost or 0) - (g.tout or 0)
  return math.abs(v) < 10 and 0 or v
end

local function stockFigures(g, m, pr, trade)
  return { sub = "Bestand – was vom Einkauf noch da ist (zum Einkaufspreis)", topTitle = "",
    labels = { trade and "Ware übrig" or "Material übrig", "Produkte auf Lager", "Nicht mehr da (abgeschrieben)", "Bestand" },
    values = { string.format("%d Stück · %s", m.stockUnits or 0, money(m.stockValue)),
      string.format("%d Stück · %s", pr.stockUnits or 0, money(pr.stockValue)),
      string.format("%d Stück · %s", (m.gone or 0) + (pr.gone or 0), money((m.goneValue or 0) + (pr.goneValue or 0))),
      signed(stockValueOf(g)) } }
end

-- Material another profession of the household gathered and this one used (at cost).
local function receivedFigures(g, list)
  local labels, values, by, order = {}, {}, {}, {}
  for _, x in ipairs(list) do
    if not by[x.from] then by[x.from] = 0; order[#order + 1] = x.from end
    by[x.from] = by[x.from] + x.v
  end
  for _, from in ipairs(order) do
    labels[#labels + 1] = "Von " .. from; values[#values + 1] = RED .. "-" .. money(by[from]) .. "|r"
  end
  labels[#labels + 1] = "Erhalten"; values[#values + 1] = RED .. "-" .. money(g.tin or 0) .. "|r"
  return { sub = "Erhalten – Material aus einem Sammelberuf, zum Einkaufspreis übernommen", topTitle = "",
    labels = labels, values = values }
end

local function handoverFigures(g, list)
  local labels, values, by, order = {}, {}, {}, {}
  for _, x in ipairs(list) do
    if not by[x.to] then by[x.to] = 0; order[#order + 1] = x.to end
    by[x.to] = by[x.to] + x.v
  end
  for _, to in ipairs(order) do
    labels[#labels + 1] = "Von " .. to; values[#values + 1] = signed(by[to])
  end
  labels[#labels + 1] = "Verarbeitet"; values[#values + 1] = signed(g.tout or 0)
  return { sub = "Verarbeitet – eigenes Material, das ein anderer Beruf verarbeitet hat (zum Einkaufspreis)", topTitle = "",
    labels = labels, values = values }
end

local AREA_ICONS = { trade = "Interface\\Icons\\INV_Misc_Coin_02", farmed = "Interface\\Icons\\INV_Misc_Bag_10",
  own = "Interface\\Icons\\INV_Misc_Bag_08" }
local PROFESSION_ICONS = {
  ["Lederverarbeitung"] = "Interface\\Icons\\Trade_LeatherWorking", ["Schneiderei"] = "Interface\\Icons\\Trade_Tailoring",
  ["Schmiedekunst"] = "Interface\\Icons\\Trade_BlackSmithing", ["Alchimie"] = "Interface\\Icons\\Trade_Alchemy",
  ["Alchemie"] = "Interface\\Icons\\Trade_Alchemy", ["Ingenieurskunst"] = "Interface\\Icons\\Trade_Engineering",
  ["Verzauberkunst"] = "Interface\\Icons\\Trade_Engraving", ["Kochkunst"] = "Interface\\Icons\\INV_Misc_Food_15",
  ["Erste Hilfe"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", ["Bergbau"] = "Interface\\Icons\\Trade_Mining",
  ["Kürschnerei"] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01", ["Kräuterkunde"] = "Interface\\Icons\\Trade_Herbalism",
}

-- Card head: icon in a ring, name, a line below (shared by the area and the item view).
local function head(layer) return ns.NativeWindow.CardHead(layer) end

-- An item's result in the lists: the profit once something was sold (or lost on expiry); an item
-- bought and not sold yet is no loss but stock: what it cost, grey ("Bestand 12g 50s").
local function resultText(r)
  if ns.Profit and r.prof == ns.Profit.OWN and (r.sold or 0) == 0 then
    return RED .. "-" .. money(r.spent) .. "|r"
  end
  local active = (r.sold or 0) > 0 or (r.expired or 0) > 0 or (r.cancelled or 0) > 0 or (r.profit or 0) ~= 0
  if not active and (r.stockUnits or 0) > 0 then
    return MUTED .. "Bestand " .. money(r.stockValue) .. "|r"
  end
  return signed(r.profit)
end

local function buildLedger(page)
  local NW = ns.NativeWindow
  local ITEM_LABELS = { "Hergestellt / gekauft", "Verkauft", "Ø Verkaufspreis", "Umsatz", "Wareneinsatz", "Gebühren", "Gewinn" }
  local card, area, item, allItems, currentArea
  local showItem -- forward

  local function layers(c)
    if area then return end
    card = c
    -- area view
    local al = CreateFrame("Frame", nil, c)
    al:SetAllPoints(c)
    area = head(al)
    area.layer = al
    local labels = {}
    for i = 1, AREA_ROWS do labels[i] = "" end
    area.Figures = NW.Figures(al, area.Head, labels)
    area.SetItems = scrollTable(al, { { "Item", 20, "LEFT", 190 }, { "Stück", 245, "RIGHT" }, { "Gewinn", 315, "RIGHT" } }, -232)
    -- item view
    local il = CreateFrame("Frame", nil, c)
    il:SetAllPoints(c)
    item = head(il)
    item.layer = il
    item.Figures = NW.Figures(il, item.Head, ITEM_LABELS)
    item.SetEvents = scrollTable(il, { { "Wann · Art", 20, "LEFT", 160 }, { "Menge", 225, "RIGHT" }, { "Betrag", 300, "RIGHT" } }, -250)
    local okB, back = pcall(CreateFrame, "Button", nil, il, "UIPanelButtonTemplate")
    if not okB then back = CreateFrame("Button", nil, il) end
    back:SetSize(76, 22)
    back:SetPoint("TOPRIGHT", il, "TOPRIGHT", -16, -27) -- on the name's line (icon 44 px at -22)
    back:SetText("‹ Zurück")
    -- the name and the line below end before the button
    item.Name:ClearAllPoints()
    item.Name:SetPoint("LEFT", item.Icon, "RIGHT", 14, 6)
    item.Name:SetPoint("RIGHT", back, "LEFT", -8, 0)
    back:SetScript("OnClick", function()
      if currentArea then il:Hide(); al:Show() end
    end)
    item.Back = back
    il:Hide()
    local function widths(fr)
      local w = math.max(100, (fr:GetWidth() or 340) - 46)
      area.Figures.SetWidth(w)
      item.Figures.SetWidth(w)
    end
    widths(c)
    c:HookScript("OnSizeChanged", widths)
  end

  local function eventRows(itemID)
    local rows = {}
    for _, e in ipairs(withHouse(ns.Profit.ItemEvents, itemID, since()) or {}) do
      local amount = ""
      if e.k == "buy" then amount = RED .. "-" .. money(e.c) .. "|r"
      elseif e.k == "sale" then amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
      elseif e.k == "vendor" then amount = GREEN .. "+" .. money(e.c) .. "|r"
      elseif (e.k == "expired" or e.k == "cancelled") and e.lost then amount = RED .. "-" .. money(e.lost) .. "|r"
      elseif e.k == "post" and e.p then amount = MUTED .. money(e.p * (e.u or 1)) .. "|r" end
      rows[#rows + 1] = { MUTED .. date("%d.%m. %H:%M", e.t or 0) .. "|r  " .. (KINDS[e.k] or tostring(e.k)),
        tostring(e.u or 1), amount }
    end
    return rows
  end

  showItem = function(r, fromArea)
    item.layer:Show()
    area.layer:Hide()
    item.Back:SetShown(fromArea and true or false)
    item.Icon:SetTexture(iconOf(r.itemId))
    item.itemID = r.itemId
    item.Name:SetText(r.name or ns.ItemName(r.itemId) or ("#" .. r.itemId))
    item.Sub:SetText(shortGroup(r.prof) .. (r.kind == "material" and " · Material" or ""))
    local v = { string.format("%d / %d", r.crafted or 0, r.bought or 0), tostring(r.sold or 0),
      r.avgPrice and money(r.avgPrice) or "–", money(r.revenue), money(r.cost), money(r.fees), signed(r.profit) }
    for i, fs in ipairs(item.Figures.values) do fs:SetText(v[i] or "–") end
    item.SetEvents(eventRows(r.itemId))
  end

  local function showArea(entry)
    currentArea = entry
    area.layer:Show()
    item.layer:Hide()
    local f = entry.figures
    area.Icon:SetTexture(entry.icon)
    area.itemID = nil
    area.Name:SetText(entry.title or entry.name)
    area.Sub:SetText("Zusammenfassung")
    for i = 1, AREA_ROWS do
      local has = f.labels[i] ~= nil
      area.Figures.labels[i]:SetShown(has)
      area.Figures.values[i]:SetShown(has)
      area.Figures.labels[i]:SetText(f.labels[i] or "")
      area.Figures.values[i]:SetText(f.values[i] or "")
    end
    if area.Figures.line then
      area.Figures.line:ClearAllPoints()
      area.Figures.line:SetPoint("BOTTOMLEFT", area.Figures.labels[#f.labels], "TOPLEFT", 0, 4)
    end
    local rows = {}
    for _, x in ipairs(entry.items) do
      if x.deposits then
        -- the lost deposits of auctions that came back (no sale): one line, not per item
        rows[#rows + 1] = { icon = "Interface\\Icons\\INV_Misc_Coin_04", "Verlorene Einstellgebühren",
          tostring(x.n) .. "×", RED .. "-" .. money(x.v) .. "|r" }
      else
        local r = x.r or x
        local value = entry.isLoot and money(r.revenue) or resultText(r)
        local units = (r.sold or 0) > 0 and tostring(r.sold) or (MUTED .. "–|r")
        local mode = entry.listMode
        local label
        if r.kind == "loot" and not entry.isLoot then
          label = (r.name or ns.ItemName(r.itemId) or "?") .. MUTED .. " (Beute)|r"
        end
        if mode == "buy" then
          units, value = tostring(x.n or 0), RED .. "-" .. money(x.v) .. "|r"
          if x.pre then label = (r.name or ns.ItemName(r.itemId) or "?") .. MUTED .. " (Einstand)|r" end
        elseif mode == "out" then
          units, value = tostring(x.n or 0), signed(x.v)
        elseif mode == "sell" then
          units, value = tostring(r.sold or 0), signed((r.revenue or 0) - (r.cut or 0))
        elseif mode == "stock" then
          units, value = tostring(r.stockUnits or 0), money(r.stockValue)
        end
        rows[#rows + 1] = { itemID = r.itemId, icon = iconOf(r.itemId), label or r.name or ns.ItemName(r.itemId) or "?",
          units, value, onClick = function() showItem(r, true) end,
          ownUseMenu = r.prof == ns.Profit.TRADE or r.prof == ns.Profit.OWN }
      end
    end
    area.SetItems(rows, entry.heads)
  end

  local split = NW.Split(page, {
    footer = 104,
    onSelect = function(entry, c)
      layers(c)
      if entry and entry.areaEntry then showArea(entry)
      elseif entry and entry.row then showItem(entry.row, false) end
    end,
    -- the search box searches every item of every area
    search = function(query)
      local out = { { key = "search", header = "Suchergebnisse" } }
      for _, r in ipairs(allItems or {}) do
        local name = (r.name or ns.ItemName(r.itemId) or ""):lower()
        if name:find(query, 1, true) then
          out[#out + 1] = { key = "i:" .. r.prof .. ":" .. (r.kind or "") .. ":" .. r.itemId, name = r.name or ns.ItemName(r.itemId),
            icon = iconOf(r.itemId), value = resultText(r), row = r }
        end
      end
      return out
    end,
  })

  -- Balance under the areas: all areas of the period together.
  local balance
  if split.footer then
    local title = split.footer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 6, -8)
    title:SetText("Bilanz")
    balance = NW.Figures(split.footer, title, { "Wareneinsatz", "Erlöse", "Gebühren", "Gewinn" }, { gap = 6, step = 15 })
    balance.SetWidth(math.max(100, (split.footer:GetWidth() or 280) - 14))
    split.footer:HookScript("OnSizeChanged", function(f) balance.SetWidth(math.max(100, (f:GetWidth() or 280) - 14)) end)
  end

  function page.Refresh()
    local P = ns.Profit
    local report = P and P.Report and P.Report(since()) or { groups = {}, items = {} }
    if balance then
      local t = report.totals or {}
      balance.values[1]:SetText(money(t.cost))
      balance.values[2]:SetText(money(t.revenue))
      balance.values[3]:SetText(money(t.fees))
      balance.values[4]:SetText(signed(t.profit))
    end
    -- three main categories: the game (loot, trade, own use), main and secondary professions;
    -- within a profession category the gathering ones first
    local SECONDARY = { ["Angeln"] = true, ["Kochkunst"] = true, ["Erste Hilfe"] = true }
    local byName = {}
    for _, g in ipairs(report.groups) do byName[g.name] = g end
    local ordered = {}
    local function add(g) if g then ordered[#ordered + 1] = g end end
    local function profs(secondary)
      local list = {}
      for _, g in ipairs(report.groups) do
        if g.name ~= P.TRADE and g.name ~= P.OWN and g.name ~= P.FARMED and (SECONDARY[g.name] or false) == secondary then
          list[#list + 1] = g
        end
      end
      table.sort(list, function(a, b)
        local fa, fb = P.IsFarmed(a.name), P.IsFarmed(b.name)
        if fa ~= fb then return fa end
        return a.name < b.name
      end)
      return list
    end
    ordered[#ordered + 1] = { header = "Spiel", key = "cat:game" }
    add(byName[P.FARMED]); add(byName[P.TRADE]); add(byName[P.OWN])
    local main, side = profs(false), profs(true)
    if #main > 0 then ordered[#ordered + 1] = { header = "Hauptberufe", key = "cat:main" } end
    for _, g in ipairs(main) do add(g) end
    if #side > 0 then ordered[#ordered + 1] = { header = "Nebenberufe", key = "cat:side" } end
    for _, g in ipairs(side) do add(g) end
    local entries = {}
    allItems = {}
    local allMaterial = {}
    for _, list in pairs(report.items) do
      for _, r in ipairs(list) do if r.kind == "material" then allMaterial[#allMaterial + 1] = r end end
    end
    for _, g in ipairs(ordered) do
      if g.header then
        entries[#entries + 1] = { key = g.key, header = g.header }
      else
        local items = {}
        for _, r in ipairs(report.items[g.name] or {}) do items[#items + 1] = r; allItems[#allItems + 1] = r end
        local isLoot = P.IsFarmed(g.name)
        table.sort(items, function(a, b)
          if isLoot then return (a.revenue or 0) > (b.revenue or 0) end
          return (a.profit or 0) > (b.profit or 0)
        end)
        local icon = g.name == P.TRADE and AREA_ICONS.trade or (g.name == P.OWN and AREA_ICONS.own) or (isLoot and AREA_ICONS.farmed)
          or PROFESSION_ICONS[g.name] or "Interface\\Icons\\INV_Misc_QuestionMark"
        local mats, prods, exps = {}, {}, {}
        local trade = g.name == P.TRADE
        for _, r in ipairs(items) do
          if r.kind == "material" or trade then mats[#mats + 1] = r
          elseif r.kind == "expense" then exps[#exps + 1] = r
          else prods[#prods + 1] = r end
        end
        -- material handed over between professions (leather from Kürschnerei to Lederverarbeitung)
        local tin, tout, inRows, outRows = 0, 0, {}, {}
        for _, r in ipairs(allMaterial) do
          for prof, v in pairs(r.usedBy or {}) do
            if prof ~= r.prof and v > 0 then
              if prof == g.name then
              tin = tin + v
              inRows[#inRows + 1] = { r = r, v = v, from = r.prof, n = r.usedByN and r.usedByN[prof] or nil }
            end
              if r.prof == g.name then
              tout = tout + v
              outRows[#outRows + 1] = { r = r, v = v, to = prof, n = r.usedByN and r.usedByN[prof] or nil }
            end
            end
          end
        end
        g.tin, g.tout = math.floor(tin + 0.5), math.floor(tout + 0.5)
        if #mats > 0 or tin > 0 or #exps > 0 then
          -- an area with purchases: the whole, then its parts (they add up to the profit)
          local m, pr, ex = P.Sum(mats, g.name), P.Sum(prods, g.name), P.Sum(exps, g.name)
          local all = {}
          for _, r in ipairs(prods) do all[#all + 1] = r end
          for _, r in ipairs(mats) do all[#all + 1] = r end
          for _, r in ipairs(exps) do all[#all + 1] = r end
          entries[#entries + 1] = { key = g.name, areaEntry = true, name = shortGroup(g.name), icon = icon, color = GOLD,
            value = signed(g.profit), figures = trade and areaFigures(g, items) or overviewFigures(g, m, ex), items = all }
          local buys, sells, stock = {}, {}, {}
          for _, r in ipairs(all) do
            if (r.kind == "material" or r.kind == "expense" or trade) and (r.bought or 0) > 0 then buys[#buys + 1] = { r = r, v = r.spent, n = r.bought } end
            if (r.sold or 0) > 0 then sells[#sells + 1] = r end
            if (r.preN or 0) > 0 then buys[#buys + 1] = { r = r, v = r.pre, n = r.preN, pre = true } end
            if (r.stockUnits or 0) > 0 then stock[#stock + 1] = r end
          end
          local got = {}
          for _, x in ipairs(inRows) do got[#got + 1] = { r = x.r, v = x.v, n = x.n } end
          table.sort(got, function(a, b) return a.v > b.v end)
          table.sort(buys, function(a, b) return (a.v or 0) > (b.v or 0) end)
          table.sort(sells, function(a, b) return (a.revenue - a.cut) > (b.revenue - b.cut) end)
          local lostN, lost = 0, 0
          for _, r in ipairs(all) do
            lostN, lost = lostN + (r.expired or 0) + (r.cancelled or 0), lost + (r.depositsLost or 0)
          end
          if lost > 0 then sells[#sells + 1] = { deposits = true, n = lostN, v = lost } end
          table.sort(stock, function(a, b) return (a.stockValue or 0) > (b.stockValue or 0) end)
          if #buys > 0 then
            entries[#entries + 1] = { key = g.name .. ":buy", areaEntry = true, indent = 14, color = WHITE, name = "Einkauf",
              title = shortGroup(g.name) .. " – Einkauf", icon = icon, value = RED .. "-" .. money(m.spent + m.pre + ex.spent) .. "|r",
              figures = buyFigures(g, m, trade, ex), items = buys, listMode = "buy", heads = { "Item", "Stück", "Einkauf" } }
          end
          if g.tin > 0 then
            entries[#entries + 1] = { key = g.name .. ":in", areaEntry = true, indent = 14, color = GREY, name = "Erhalten",
              title = g.name .. " – Erhalten", icon = icon, value = greyed(-g.tin),
              figures = receivedFigures(g, inRows), items = got, listMode = "buy", heads = { "Item", "Stück", "Wert" } }
          end
          if g.tout > 0 then
            table.sort(outRows, function(a, b) return a.v > b.v end)
            entries[#entries + 1] = { key = g.name .. ":out", areaEntry = true, indent = 14, color = GREY, name = "Verarbeitet",
              title = g.name .. " – Verarbeitet", icon = icon, value = greyed(g.tout),
              figures = handoverFigures(g, outRows), items = outRows, listMode = "out", heads = { "Item", "Stück", "Wert" } }
          end
          entries[#entries + 1] = { key = g.name .. ":sell", areaEntry = true, indent = 14, color = WHITE, name = "Verkauf",
            title = shortGroup(g.name) .. " – Verkauf", icon = icon, value = signed((g.revenue or 0) - (g.fees or 0)),
            figures = sellFigures(g, m, pr, trade), items = sells, listMode = "sell", heads = { "Item", "Stück", "Netto" } }
          entries[#entries + 1] = { key = g.name .. ":stock", areaEntry = true, indent = 14, color = GREY, name = since() and "Bestandsänderung" or "Bestand",
            title = shortGroup(g.name) .. " – Bestand", icon = icon, value = greyed(stockValueOf(g)),
            figures = stockFigures(g, m, pr, trade), items = stock, listMode = "stock", heads = { "Item", "Stück", "Wert" } }
        else
          entries[#entries + 1] = { key = g.name, areaEntry = true, name = shortGroup(g.name), icon = icon, color = GOLD,
            value = signed(g.profit), figures = areaFigures(g, items), items = items, isLoot = isLoot }
        end
      end
    end
    split.SetEntries(entries)
  end
end

-- Grouped pages (Bestand, Auktionen), built like the ledger page: left the groups as rows with a
-- value and a balance under them, right the group's summary with its items (scrollable), an item
-- opens in place with "‹ Zurück".
--   spec.groupLabels      labels of the group summary (values per group: g.values)
--   spec.itemLabels       labels of the item view (values per item: it.values)
--   spec.listCols         columns of the item list (it.cols, the first one is the name)
--   spec.balanceLabels    labels of the balance (values: data.balance)
--   spec.collect()        -> { groups = { { key, name, icon, value, values, items = { { itemID, name,
--                            icon, sub, cols, values } } } }, balance = { … } }
-- Labels and values into a figures block (rows without a label hidden).
local function setFigures(fig, labels, values)
  for i, fs in ipairs(fig.values) do
    local has = labels[i] ~= nil
    fig.labels[i]:SetShown(has); fs:SetShown(has)
    fig.labels[i]:SetText(labels[i] or ""); fs:SetText(values[i] or "–")
  end
end

local function buildGrouped(page, spec)
  local NW = ns.NativeWindow
  local area, item, current
  local function layers(c)
    if area then return end
    local al = CreateFrame("Frame", nil, c)
    al:SetAllPoints(c)
    area = head(al)
    area.layer = al
    area.Figures = NW.Figures(al, area.Head, spec.groupLabels)
    area.SetItems = scrollTable(al, spec.listCols, -86 - 10 - #spec.groupLabels * 16 - 30)
    local il = CreateFrame("Frame", nil, c)
    il:SetAllPoints(c)
    item = head(il)
    item.layer = il
    item.Figures = NW.Figures(il, item.Head, spec.itemLabels)
    local okB, back = pcall(CreateFrame, "Button", nil, il, "UIPanelButtonTemplate")
    if not okB then back = CreateFrame("Button", nil, il) end
    back:SetSize(76, 22)
    back:SetPoint("TOPRIGHT", il, "TOPRIGHT", -16, -27)
    back:SetText("‹ Zurück")
    back:SetScript("OnClick", function() il:Hide(); al:Show() end)
    item.Name:ClearAllPoints()
    item.Name:SetPoint("LEFT", item.Icon, "RIGHT", 14, 6)
    item.Name:SetPoint("RIGHT", back, "LEFT", -8, 0)
    il:Hide()
    local function widths(fr)
      local w = math.max(100, (fr:GetWidth() or 340) - 46)
      area.Figures.SetWidth(w)
      item.Figures.SetWidth(w)
    end
    widths(c)
    c:HookScript("OnSizeChanged", widths)
  end
  local function showItem(it)
    item.layer:Show()
    area.layer:Hide()
    item.Icon:SetTexture(it.icon)
    item.itemID = it.itemID
    item.Name:SetText(it.name)
    item.Sub:SetText(it.sub or "")
    setFigures(item.Figures, it.labels or spec.itemLabels, it.values)
  end
  local function showGroup(g)
    current = g
    area.layer:Show()
    item.layer:Hide()
    area.Icon:SetTexture(g.icon)
    area.itemID = nil
    area.Name:SetText(g.name)
    area.Sub:SetText("Zusammenfassung")
    setFigures(area.Figures, g.labels or spec.groupLabels, g.values)
    local rows = {}
    for _, it in ipairs(g.items) do
      local row = { itemID = it.itemID, icon = it.icon, onClick = function() showItem(it) end }
      for k, v in ipairs(it.cols) do row[k] = v end
      rows[#rows + 1] = row
    end
    area.SetItems(rows)
  end
  local all = {}
  local split = NW.Split(page, {
    footer = 22 + #spec.balanceLabels * 15 + 16,
    onSelect = function(entry, c)
      layers(c)
      if entry and entry.group then showGroup(entry.group)
      elseif entry and entry.it then showItem(entry.it) end
    end,
    search = function(query)
      local out = { { key = "search", header = "Suchergebnisse" } }
      for _, it in ipairs(all) do
        if (it.name or ""):lower():find(query, 1, true) then
          out[#out + 1] = { key = "i:" .. tostring(it.key or it.itemID), name = it.name, icon = it.icon, itemID = it.itemID,
            value = it.cols[#it.cols], it = it }
        end
      end
      return out
    end,
  })
  local balance
  if split.footer then
    local title = split.footer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 6, -8)
    title:SetText("Bilanz")
    balance = NW.Figures(split.footer, title, spec.balanceLabels, { gap = 6, step = 15 })
    balance.SetWidth(math.max(100, (split.footer:GetWidth() or 280) - 14))
    split.footer:HookScript("OnSizeChanged", function(f) balance.SetWidth(math.max(100, (f:GetWidth() or 280) - 14)) end)
  end
  function page.Refresh()
    local data = spec.collect()
    if balance then
      for i, fs in ipairs(balance.values) do fs:SetText(data.balance[i] or "–") end
    end
    local entries = { { key = "groups", header = spec.title } }
    all = {}
    for _, g in ipairs(data.groups) do
      entries[#entries + 1] = { key = g.key, name = g.name, icon = g.icon, value = g.value, group = g }
      for _, it in ipairs(g.items) do all[#all + 1] = it end
    end
    split.SetEntries(entries)
  end
end

-- "bei Lok 3 · bei Lokbank 12": who of the household holds the item (bags, bank, auctions).
local function heldBy(itemID)
  local parts = {}
  for _, key in ipairs(ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or {}) do
    local n = 0
    local inv = ns.db.inventory and ns.db.inventory[key]
    for _, part in ipairs({ inv and inv.bags or {}, inv and inv.bank or {} }) do
      local e = part[itemID]
      if e then n = n + (e.n or 0) end
    end
    local owned = ns.db.owned and ns.db.owned[key]
    for _, a in ipairs(owned and owned.list or {}) do
      if a.i == itemID and not a.s then n = n + (a.q or 1) end
    end
    if n > 0 then parts[#parts + 1] = "bei " .. (key:match("^([^-]+)") or key) .. " " .. n end
  end
  return table.concat(parts, " · ")
end

local function charName(key) return key and key:match("^([^-]+)") or "?" end

local function pctText(gain, cost)
  if not (gain and cost and cost > 0) then return "–" end
  return string.format("%+d %%", math.floor(gain / cost * 100 + 0.5))
end

-- "Bestand": what the character holds, by where it comes from (trade, each profession), and the
-- gold of every character of the household (cash is stock too).
local collectGold -- below, next to its helpers
local function collectStock()
  local P = ns.Profit
  local report = P and P.Report and P.Report(nil) or { stock = {} }
  local groups, order = {}, {}
  local total = { cost = 0, sell = 0, gain = 0, units = 0 }
  -- where the units are: running auctions of the household ("Im AH", at the listed
  -- price after the cut), sold with the mail still to come ("Unterwegs", Profit.Transit), the
  -- rest by origin (a profession, Hergestellt, Handel)
  local listed = {}
  for _, key in ipairs(ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or {}) do
    local owned = ns.db.owned and ns.db.owned[key]
    for _, a in ipairs(owned and owned.list or {}) do
      if a.i and not a.s then
        local l = listed[a.i] or { n = 0, value = 0 }
        local q = a.q or 1
        l.n = l.n + q
        l.value = l.value + math.floor(((a.u and a.u * q) or a.b or 0) * 0.95 + 0.5)
        listed[a.i] = l
      end
    end
  end
  local transit = P and P.Transit and P.Transit() or {}
  local function group(key, name, icon)
    local g = groups[key]
    if not g then
      g = { key = key, name = name or key, items = {}, units = 0, cost = 0, sell = 0, gain = 0, icon = icon }
      groups[key] = g
      order[#order + 1] = g
    end
    return g
  end
  -- n units of stock entry s into group g; sell = what they bring (nil: unknown)
  local function put(g, s, n, sell, sub)
    if n <= 0 then return end
    local cost = s.units > 0 and s.cost * n / s.units or 0
    local gain = sell and (sell - cost) or nil
    local name = s.name or ns.ItemName(s.itemId) or ("#" .. s.itemId)
    g.items[#g.items + 1] = { key = g.key .. ":" .. s.itemId, itemID = s.itemId, icon = iconOf(s.itemId), name = name,
      sub = sub, gain = gain or -1e12,
      cols = { name, tostring(n), gain and signed(gain) or "–" },
      values = { tostring(n), money(s.unitCost), money(cost), sell and money(sell / n) or "–",
        sell and money(sell) or "–", pctText(gain, cost), gain and signed(gain) or "–" } }
    g.units, g.cost = g.units + n, g.cost + cost
    if sell then g.sell, g.gain = g.sell + sell, g.gain + gain end
    -- sold (AH Transit) is gold on its way, not goods: counted apart in the balance
    if g.key == "transit" then
      total.transit = (total.transit or 0) + (sell or 0)
    else
      total.units, total.cost = total.units + n, total.cost + cost
      if sell then total.sell, total.gain = total.sell + sell, total.gain + gain end
    end
  end
  for _, s in ipairs(report.stock or {}) do
    local left = s.units
    local l, t = listed[s.itemId], transit[s.itemId]
    local nT = t and math.min(left, t.n) or 0
    put(group("transit", "AH Transit", "Interface\\Icons\\INV_Letter_15"), s, nT,
      nT > 0 and t.value * nT / t.n or nil, "verkauft – das Gold kommt mit der Post")
    left = left - nT
    local nA = l and math.min(left, l.n) or 0
    put(group("auction", "Im AH", "Interface\\Icons\\INV_Hammer_15"), s, nA,
      nA > 0 and l.value * nA / l.n or nil, "eingestellt – zum eigenen Preis nach Gebühr")
    if l and nA > 0 then l.placed = (l.placed or 0) + nA end
    left = left - nA
    if left > 0 then
      local maker = (s.source or ""):find("hergestellt") and ns.CraftedBy and ns.CraftedBy(s.itemId)
      local key = maker or ((s.source or ""):find("hergestellt") and "Hergestellt" or "Handel")
      local g = group(key, key, key == "Handel" and AREA_ICONS.trade or PROFESSION_ICONS[key] or "Interface\\Icons\\INV_Box_02")
      put(g, s, left, s.sellUnit and s.sellUnit * left or nil,
        heldBy(s.itemId) ~= "" and heldBy(s.itemId) or (key .. " · " .. (s.source or "")))
    end
  end
  -- every other running auction (loot, or bought before the ledger: no known cost) belongs in
  -- "Im AH" too, at cost 0 - the group shows all the own auctions
  for id, l in pairs(listed) do
    local rest = l.n - (l.placed or 0)
    if rest > 0 then
      put(group("auction", "Im AH", "Interface\\Icons\\INV_Hammer_15"),
        { itemId = id, units = rest, cost = 0, unitCost = 0, name = ns.ItemName and ns.ItemName(id) or nil },
        rest, l.value * rest / l.n, "eingestellt – Beute oder ohne bekannten Einkauf")
    end
  end
  -- empty location groups out
  local kept = {}
  for _, g in ipairs(order) do if #g.items > 0 then kept[#kept + 1] = g end end
  order = kept
  -- where it is first (in the mail, in the auction house), then the origins by book gain
  local RANK = { transit = 1, auction = 2 }
  table.sort(order, function(a, b)
    local ra, rb = RANK[a.key] or 9, RANK[b.key] or 9
    if ra ~= rb then return ra < rb end
    return a.gain > b.gain
  end)
  for _, g in ipairs(order) do
    table.sort(g.items, function(a, b) return a.gain > b.gain end)
    -- AH Transit: the whole gold that comes with the mail, else the book gain
    g.value = g.key == "transit" and money(g.sell) or signed(g.gain)
    g.values = { string.format("%d Items · %d Stück", #g.items, g.units), money(g.cost), money(g.sell),
      pctText(g.gain, g.cost), signed(g.gain) }
  end
  local gold = collectGold and collectGold()
  if gold then table.insert(order, 1, gold) end
  local cash = gold and gold.total or 0
  local transit = total.transit or 0
  return { groups = order, balance = { money(cash), money(transit), money(total.cost), money(cash + transit + total.cost),
    signed(total.gain) } }
end

local function buildStock(page)
  buildGrouped(page, {
    title = "Herkunft",
    groupLabels = { "Bestand", "Einkauf", "Erlös (nach Gebühr)", "Marge", "Buchgewinn" },
    itemLabels = { "Stück", "Einkauf / Stk.", "Einkauf", "Erlös / Stk.", "Erlös", "Marge", "Buchgewinn" },
    listCols = { { "Item", 20, "LEFT", 190 }, { "Stück", 245, "RIGHT" }, { "Buchgewinn", 315, "RIGHT" } },
    balanceLabels = { "Gold", "AH Transit", "Ware (Einkauf)", "Zusammen", "Buchgewinn Ware" },
    collect = collectStock,
  })
end

-- "Auktionen": the running auctions by status (undercut first), with value, cost and profit.
local function collectAuctions()
  local My = ns.MyAuctions
  local defs = {
    { key = "under", name = "Unterboten", icon = "Interface\\Icons\\INV_Misc_QuestionMark" },
    { key = "best", name = "Bester Preis", icon = "Interface\\Icons\\INV_Misc_Coin_02" },
    { key = "other", name = "Nicht geprüft", icon = "Interface\\Icons\\INV_Hammer_15" },
  }
  local groups = {}
  for _, d in ipairs(defs) do groups[d.key] = { key = d.key, name = d.name, icon = d.icon, items = {}, worth = 0, net = 0, profit = 0, units = 0 } end
  local total = { worth = 0, profit = 0, count = 0 }
  local function add(bucket, r, status, who)
    local g = groups[bucket]
    local qty = r.quantity or 1
    local cost, source = ns.Profit.UnitCost(r.itemID)
    local net = r.unit and math.floor(r.unit * 0.95 * qty) or 0
    local profit = cost and r.unit and math.floor((r.unit * 0.95 - cost) * qty) or nil
    local name = ns.ItemName(r.itemID) or ("#" .. tostring(r.itemID))
    g.items[#g.items + 1] = { key = bucket .. ":" .. tostring(r.itemID) .. ":" .. (#g.items + 1), itemID = r.itemID, icon = iconOf(r.itemID),
      name = name, sub = status, profit = profit or -1e12, worth = (r.unit or 0) * qty, under = bucket == "under",
      qty = qty, unit = r.unit, timeLeft = r.timeLeft, who = who, short = (r.st == "under" and (RED .. "unterboten " .. money(r.diff) .. "|r"))
        or (r.st == "best" and (GREEN .. "bester Preis|r")) or (r.st == "alone" and (MUTED .. "allein im AH|r"))
        or (r.st == "bid" and (MUTED .. "nur Gebot|r")) or (MUTED .. "nicht geprüft|r"),
      cols = { name, r.unit and money(r.unit) or "–", profit and signed(profit) or "–" },
      values = { tostring(qty), r.unit and money(r.unit) or "–", r.foreign and money(r.foreign) or "–", status,
        r.timeLeft and string.format("%d h", math.ceil(r.timeLeft / 3600)) or "–",
        cost and (source == "Beute" and "Beute" or money(cost)) or "–", profit and signed(profit) or "–" } }
    g.worth, g.net, g.units = g.worth + (r.unit or 0) * qty, g.net + net, g.units + qty
    if profit then g.profit = g.profit + profit; total.profit = total.profit + profit end
    total.worth, total.count = total.worth + (r.unit or 0) * qty, total.count + 1
  end
  local me = ns.CharKey and ns.CharKey()
  local keys = shownKeys()
  local mine = false
  for _, key in ipairs(keys) do if key == me then mine = true end end
  -- the live list is the automatic house's: only when that one is shown
  if shownHouse() ~= ns.AuctionHouse.Auto() then mine = false end
  local rows = mine and My and My.Rows and My.Rows() or {}
  local any = false
  for _, r in ipairs(rows) do
    if (r.active or 0) > 0 then
      r.st = r.status
      any = true
      if r.status == "under" then add("under", r, RED .. "unterboten um " .. money(r.diff) .. "|r")
      elseif r.status == "best" then add("best", r, GREEN .. "bester Preis|r")
      else add("other", r, r.status == "alone" and "allein im AH" or "nicht geprüft") end
    end
  end
  -- the other characters: their stored auctions (and this one's without the AH)
  for _, key in ipairs(keys) do
    if key ~= me or not any then
    local saved = key and ns.db and ns.db.owned and ns.db.owned[key]
    local who = key ~= me and ("  " .. MUTED .. "· " .. charName(key) .. "|r") or ""
    -- the stored auctions with the result of their last check (time left counted down)
    local age = saved and saved.t and math.max(0, time() - saved.t) or 0
    local function ago(t)
      local d = math.max(0, time() - (t or 0))
      return d < 3600 and string.format("vor %d min", math.floor(d / 60 + 0.5)) or string.format("vor %d h", math.floor(d / 3600 + 0.5))
    end
    for _, a in ipairs(saved and saved.list or {}) do
      if not a.s and inHouse(a) then
        local r = { itemID = a.i, unit = a.u, quantity = a.q, foreign = a.f, diff = a.df, st = a.st,
          timeLeft = a.tl and math.max(0, a.tl - age) or nil }
        local when = (a.ck and ("  " .. MUTED .. "· geprüft " .. ago(a.ck) .. "|r") or "") .. who
        if a.st == "under" then add("under", r, RED .. "unterboten um " .. money(a.df) .. "|r" .. when, key)
        elseif a.st == "best" then add("best", r, GREEN .. "bester Preis|r" .. when, key)
        elseif a.st == "alone" then add("other", r, "allein im AH" .. when, key)
        else add("other", r, "nicht geprüft (Auktionshaus öffnen)" .. who, key) end
      end
    end
    end
  end
  local out = {}
  for _, d in ipairs(defs) do
    local g = groups[d.key]
    if #g.items > 0 then
      table.sort(g.items, function(a, b) return a.profit > b.profit end)
      g.value = MUTED .. #g.items .. "|r"
      g.values = { string.format("%d Auktionen · %d Stück", #g.items, g.units), money(g.worth), money(g.net), signed(g.profit) }
      out[#out + 1] = g
    end
  end
  return { groups = out, balance = { tostring(total.count), money(total.worth), signed(total.profit) } }
end

-- The overview's auction rows: undercut first, then the dearest; the character after the name
-- when all characters are shown.
function TradeBook.AuctionRows()
  local data = collectAuctions()
  local me, many = ns.CharKey and ns.CharKey(), not charSel and #household() > 1
  local items, under = {}, 0
  for _, g in ipairs(data.groups) do
    for _, it in ipairs(g.items) do
      items[#items + 1] = it
      if it.under then under = under + 1 end
    end
  end
  table.sort(items, function(x, y)
    if x.under ~= y.under then return x.under end
    return (x.worth or 0) > (y.worth or 0)
  end)
  local out = {}
  for _, it in ipairs(items) do
    local who = (many and it.who and it.who ~= me) and (MUTED .. "  · " .. charName(it.who) .. "|r") or ""
    out[#out + 1] = { itemID = it.itemID, icon = it.icon,
      it.name .. ((it.qty or 1) > 1 and (MUTED .. "  " .. it.qty .. "×|r") or "") .. who,
      it.unit and money(it.unit) or "–", it.short,
      MUTED .. (it.timeLeft and string.format("%d h", math.ceil(it.timeLeft / 3600)) or "–") .. "|r" }
  end
  return out, under
end

-- Auctions: left every running auction as a row, dearest first (price right), right its details;
-- the balance under the list.
local function buildAuctions(page)
  local NW = ns.NativeWindow
  local LABELS = { "Stück", "Mein Preis", "Billigst fremd", "Status", "Restzeit", "Einkauf / Stk.", "Gewinn" }
  local view
  local split = NW.Split(page, {
    footer = 22 + 3 * 15 + 16,
    onSelect = function(entry, c)
      if not view then
        view = head(c)
        view.Figures = NW.Figures(c, view.Head, LABELS)
        local function widths(fr) view.Figures.SetWidth(math.max(100, (fr:GetWidth() or 340) - 46)) end
        widths(c)
        c:HookScript("OnSizeChanged", widths)
      end
      local it = entry and entry.it
      for _, part in ipairs({ view.Icon, view.Name, view.Sub, view.Head }) do part:SetShown(it ~= nil) end
      for i, fs in ipairs(view.Figures.values) do fs:SetShown(it ~= nil); view.Figures.labels[i]:SetShown(it ~= nil) end
      if view.Figures.line then view.Figures.line:SetShown(it ~= nil) end
      if not it then return end
      view.Icon:SetTexture(it.icon)
      view.itemID = it.itemID
      view.Name:SetText(it.name)
      view.Sub:SetText(it.sub)
      for i, fs in ipairs(view.Figures.values) do fs:SetText(it.values[i] or "–") end
    end,
  })
  local balance
  if split.footer then
    local title = split.footer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 6, -8)
    title:SetText("Bilanz")
    balance = NW.Figures(split.footer, title, { "Auktionen", "Wert", "Gewinn" }, { gap = 6, step = 15 })
    balance.SetWidth(math.max(100, (split.footer:GetWidth() or 280) - 14))
    split.footer:HookScript("OnSizeChanged", function(f) balance.SetWidth(math.max(100, (f:GetWidth() or 280) - 14)) end)
  end
  function page.Refresh()
    local data = collectAuctions()
    local items = {}
    for _, g in ipairs(data.groups) do
      for _, it in ipairs(g.items) do items[#items + 1] = it end
    end
    table.sort(items, function(x, y) return (x.worth or 0) > (y.worth or 0) end)
    local entries = { { key = "auctions", header = "Laufende Auktionen" } }
    for _, it in ipairs(items) do
      entries[#entries + 1] = { key = it.key, name = it.name, icon = it.icon, itemID = it.itemID, value = it.cols[2], it = it,
        marker = it.under and "down" or nil }
    end
    split.SetEntries(entries)
    if balance then for i, fs in ipairs(balance.values) do fs:SetText(data.balance[i] or "–") end end
  end
end

-- "Gold": every character of the household with its gold (and the gold bound in its running
-- auctions), the total under the list. Always all characters, whatever is chosen above.
local CLASS_ICON = "Interface\\Icons\\ClassIcon_"
local function ago(t)
  if not t then return "unbekannt" end
  local d = math.max(0, time() - t)
  if d < 120 then return "gerade eben" end
  if d < 7200 then return string.format("vor %d min", math.floor(d / 60 + 0.5)) end
  if d < 172800 then return string.format("vor %d h", math.floor(d / 3600 + 0.5)) end
  return string.format("vor %d Tagen", math.floor(d / 86400 + 0.5))
end
local function auctionWorth(key)
  local saved = ns.db and ns.db.owned and ns.db.owned[key]
  local sum, n = 0, 0
  for _, a in ipairs(saved and saved.list or {}) do
    if not a.s and a.u then sum, n = sum + a.u * (a.q or 1), n + 1 end
  end
  return sum, n
end

-- The gold group of the stock page: every character with its gold and the gold bound in its
-- running auctions.
collectGold = function()
  local me = ns.CharKey and ns.CharKey()
  local list, total, bound = {}, 0, 0
  for _, key in ipairs(household()) do
    local gold, goldT = goldOf(key)
    local worth, n = auctionWorth(key)
    total, bound = total + gold, bound + worth
    list[#list + 1] = { key = key, gold = gold, goldT = goldT, worth = worth, n = n, c = ns.db and ns.db.chars and ns.db.chars[key] or {} }
  end
  table.sort(list, function(x, y) return x.gold > y.gold end)
  local items = {}
  for _, x in ipairs(list) do
    local c = x.c
    local icon = c.class and (CLASS_ICON .. c.class:sub(1, 1) .. c.class:sub(2):lower()) or ICON
    local name = fullName(x.key)
    items[#items + 1] = { key = "gold:" .. x.key, icon = icon, name = name,
      sub = string.format("Stufe %s %s", tostring(c.level or "?"), c.className or ""),
      cols = { name, "", money(x.gold) },
      labels = { "Gold", "Anteil", "In Auktionen", "Zusammen", "Stand" },
      values = { money(x.gold), total > 0 and string.format("%d %%", math.floor(x.gold / total * 100 + 0.5)) or "–",
        x.n > 0 and string.format("%s  " .. MUTED .. "(%d)|r", money(x.worth), x.n) or "–", money(x.gold + x.worth),
        x.key == me and "jetzt (spielt)" or ago(x.goldT) } }
  end
  return { key = "gold", name = "Gold", icon = "Interface\\Icons\\INV_Misc_Coin_01", items = items, total = total,
    value = money(total),
    labels = { "Gold (bar)", "In Auktionen gebunden", "Zusammen", "Charaktere" },
    values = { money(total), money(bound), money(total + bound), tostring(#items) } }
end

-- "Marktsuche" (magnifier tab): one search line like a search engine over every item the addon
-- knows (shipped names, collector data, own scans). Empty: the line sits in the middle of the
-- page; typing moves it up and the hits show below with their market figures (ns.Item). A
-- click on a hit (or Enter: the first one) opens the full market data window (ns.ItemDetail)
-- docked at the ledger. Accepts names, item ids and item links (Shift+click into the line).
local SEARCH_TAB_ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
local SEARCH_MAX = 200
local searchPage -- the built page (TradeBook.ShowSearch fills its line)

-- string.lower leaves UTF-8 umlauts alone: Ä Ö Ü by hand.
local function lowerDE(s)
  return (s or ""):lower():gsub("\195\132", "\195\164"):gsub("\195\150", "\195\182"):gsub("\195\156", "\195\188")
end

-- Every searchable item once: { id, name, low, data = has collector or scan data }.
local function buildIndex()
  local seen, list = {}, {}
  -- the cloud data of the viewed house (AuctionHouse.CloudData)
  local house = ns.AuctionHouse.CloudData()
  local market = house and house.items or {}
  local scanned = ns.Item and ns.Item.ScannedItems and ns.Item.ScannedItems() or {}
  local scan = ns.AuctionHouse.Peek()
  local current = scan and scan.current or {}
  local cached = C_Item and C_Item.GetItemNameByID
  local function add(id)
    if type(id) ~= "number" or seen[id] then return end
    seen[id] = true
    local name = (ns.ItemNames and ns.ItemNames[id]) or (cached and cached(id))
    if not name then return end
    list[#list + 1] = { id = id, name = name, low = lowerDE(name),
      data = market[id] ~= nil or scanned[id] ~= nil or current[id] ~= nil }
  end
  for id in pairs(market) do add(id) end
  for id in pairs(scanned) do add(id) end
  for id in pairs(current) do add(id) end
  for id in pairs(ns.ItemNames or {}) do add(id) end
  local withData = 0
  for _, x in ipairs(list) do if x.data then withData = withData + 1 end end
  return list, withData
end

local function trendColored(e)
  local text = ns.Item.TrendText(e)
  if not text then return MUTED .. "–|r" end
  if e.trend >= 0.03 then return GREEN .. text .. "|r" end
  if e.trend <= -0.03 then return RED .. text .. "|r" end
  return text
end

local function searchItems(index, query)
  query = lowerDE(query):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return {} end
  local hits = {}
  -- an item link or a bare item id: that item first
  local linked = tonumber(query:match("item:(%d+)") or query:match("^#?(%d+)$") or "")
  if linked then
    hits[1] = { id = linked, name = ns.ItemName(linked), rank = -1, data = true }
    if query:find("|h%[") then query = lowerDE(query:match("|h%[(.-)%]|h") or "") end
  end
  if query ~= "" and not query:match("^#?%d+$") then
    local words = {}
    for w in query:gmatch("%S+") do words[#words + 1] = w end
    for _, x in ipairs(index) do
      if x.id ~= linked then
        local all = true
        for _, w in ipairs(words) do
          if not x.low:find(w, 1, true) then all = false break end
        end
        if all then
          local rank = (x.low == query and 0) or (x.low:sub(1, #query) == query and 1)
            or (x.low:find(" " .. words[1], 1, true) and 2) or 3
          hits[#hits + 1] = { id = x.id, name = x.name, rank = rank, data = x.data }
        end
      end
    end
  end
  table.sort(hits, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.data ~= b.data then return a.data end
    if #a.name ~= #b.name then return #a.name < #b.name end
    return a.name < b.name
  end)
  return hits
end

local function buildSearch(page, w)
  searchPage = page
  local index, withData
  local hits = {}

  -- landing: magnifier, title, hint (shown while the line is empty)
  local landing = CreateFrame("Frame", nil, page)
  landing:SetAllPoints(page)
  local glass = landing:CreateTexture(nil, "ARTWORK")
  -- the tab's icon (64 px, sharp) in a round ring like the cards' heads; the search box's
  -- 16 px magnifier glyph blurs when scaled up
  glass:SetSize(56, 56)
  glass:SetPoint("CENTER", page, "CENTER", 0, 110)
  glass:SetTexture(SEARCH_TAB_ICON)
  local okMask, mask = pcall(landing.CreateMaskTexture, landing)
  if okMask and mask then
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(glass)
    glass:AddMaskTexture(mask)
  end
  local ring = landing:CreateTexture(nil, "OVERLAY")
  ring:SetSize(76, 76)
  ring:SetPoint("CENTER", glass, "CENTER", 0, 0)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetTexCoord(0, 0.6, 0, 0.6)
  local title = landing:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  title:SetPoint("TOP", glass, "BOTTOM", 0, -10)
  title:SetText("Marktdaten durchsuchen")
  local hint = landing:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOP", title, "BOTTOM", 0, -64)
  hint:SetWidth(460)
  hint:SetText("Name (auch Teile davon, z. B. „leder dick“), Item-ID oder Item-Link (Shift+Klick).\n"
    .. "Enter öffnet den ersten Treffer, ein Klick zeigt alle Marktdaten mit Preisverlauf\n"
    .. "und – wo bekannt – wer das Item droppt (mit Wegpunkt auf der Karte).")
  local stats = landing:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  stats:SetPoint("TOP", hint, "BOTTOM", 0, -14)

  -- hits: a card under the line with the market figures per item
  local results = card(page, w, 5, -62, 664, 594 - 62 - 6, "Treffer")
  -- the card art is stretched to the full page height, its top border grows with it: title,
  -- count and table start lower than on the overview's short cards
  results.Title:ClearAllPoints()
  results.Title:SetPoint("TOPLEFT", 24, -30)
  local count = results:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  count:SetPoint("RIGHT", results, "TOPRIGHT", -28, -37)
  local setRows = scrollTable(results, { { "Gegenstand", 24, "LEFT", 270 }, { "AH jetzt", 380, "RIGHT" },
    { "Marktwert", 465, "RIGHT" }, { "Trend", 545, "RIGHT" }, { "Nachfrage", 612, "RIGHT" } }, -56)
  results:Hide()

  local okBox, box = pcall(CreateFrame, "EditBox", nil, page, "SearchBoxTemplate")
  if not okBox then
    box = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  end
  box:SetAutoFocus(false)
  box:SetHeight(28)
  local instructions = rawget(box, "Instructions")
  if type(instructions) == "table" then instructions:SetText("Gegenstand suchen …") end
  page.Box = box

  local function openDetail(id)
    -- on the house the search shows (the ledger's choice)
    if id and ns.ItemDetail then ns.Safe(ns.ItemDetail.Show, id, { anchor = w.frame, house = shownHouse() }) end
  end

  local function place(active)
    box:ClearAllPoints()
    if active then
      box:SetWidth(330) -- leaves room for the house choice at the right edge
      -- (centred: 171..501 of 673; the choice starts at about 505 with its label)
      box:SetPoint("TOP", w.frame, "TOP", 0, -30)
    else
      box:SetWidth(440)
      box:SetPoint("TOP", title, "BOTTOM", 0, -18)
    end
    landing:SetShown(not active)
    results:SetShown(active)
  end

  local function run()
    local text = box:GetText() or ""
    if text:gsub("%s", "") == "" then
      hits = {}
      place(false)
      return
    end
    if not index then index, withData = buildIndex() end
    hits = searchItems(index, text)
    place(true)
    local rows = {}
    for i = 1, math.min(SEARCH_MAX, #hits) do
      local h = hits[i]
      local e = ns.Item(h.id)
      local ref = e.ref and money(e.ref) or (MUTED .. "–|r")
      local now = e.now and money(e.now) or (MUTED .. (e.dataT and "nicht im AH" or "–") .. "|r")
      local id = h.id
      -- "· Drop" after the name: the detail window knows who drops it (ns.ItemDrops)
      local drop = ns.HasDrops and ns.HasDrops(id) and ("  " .. MUTED .. "· Drop|r") or ""
      rows[#rows + 1] = { itemID = id, icon = iconOf(id), h.name .. drop, now, ref, trendColored(e),
        ns.Item.DemandText(e) or (MUTED .. "–|r"), onClick = function() openDetail(id) end }
    end
    setRows(rows)
    count:SetText(#hits > SEARCH_MAX and string.format("%d Treffer (die ersten %d)", #hits, SEARCH_MAX)
      or (#hits == 1 and "1 Treffer" or (#hits .. " Treffer")))
  end

  -- typing: search a moment after the last key (thousands of names per pass)
  local token = 0
  box:HookScript("OnTextChanged", function(_, user)
    token = token + 1
    local mine = token
    if C_Timer and C_Timer.After then
      C_Timer.After(0.15, function() if mine == token then ns.Safe(withHouse, run) end end)
    else
      ns.Safe(withHouse, run)
    end
  end)
  box:HookScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if hits[1] then openDetail(hits[1].id) end
  end)
  box:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)

  function page.Refresh()
    index, withData = buildIndex() -- new scans, names the client has loaded since
    stats:SetText(string.format("%s Gegenstände in der Datenbank  ·  %s davon mit Marktdaten",
      BreakUpLargeNumbers and BreakUpLargeNumbers(#index) or #index,
      BreakUpLargeNumbers and BreakUpLargeNumbers(withData) or withData))
    run()
  end
  place(false)
end

-- Shift+click on an item while the search line has the focus: the link goes into the line.
if hooksecurefunc and rawget(_G, "ChatEdit_InsertLink") then
  hooksecurefunc("ChatEdit_InsertLink", function(link)
    local box = searchPage and searchPage.Box
    if box and box:IsVisible() and box:HasFocus() and type(link) == "string" then
      box:SetText(link:match("|h%[(.-)%]|h") or link)
    end
  end)
end

local function refreshPage(page) if page.Refresh then page.Refresh() end end

-- The window's choice row under the title: character (all or one) left, auction house in the
-- middle, period right (the table `choices` is declared at the top: shownHouse reads it). The
-- period only where it counts (overview, ledger); the gold tab shows every character anyway.
local function chooser(parent, width, options, get, set)
  local ok, d = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and d and d.SetupMenu then
    d:SetWidth(width)
    d:SetupMenu(function(_, root)
      for _, o in ipairs(options()) do
        root:CreateRadio(o.label, function() return get() == o.key end, function() set(o.key) end)
      end
    end)
    function d.Update()
      for _, o in ipairs(options()) do if o.key == get() then d:SetText(o.label) end end
      if d.GenerateMenu then pcall(d.GenerateMenu, d) end
    end
    return d
  end
  local okB, bt = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
  d = okB and bt or CreateFrame("Button", nil, parent)
  d:SetSize(width, 22)
  d:SetScript("OnClick", function()
    local opts = options()
    for i, o in ipairs(opts) do
      if o.key == get() then set(opts[i % #opts + 1].key) break end
    end
  end)
  function d.Update()
    for _, o in ipairs(options()) do if o.key == get() and d.SetText then d:SetText(o.label) end end
  end
  return d
end

local function refreshCurrent()
  local tab = window and window.current and window.tabs[window.current]
  if tab and tab.page and tab.page.Refresh then ns.Safe(tab.page.Refresh) end
  for _, d in pairs(choices) do if d.Update then d.Update() end end
end

-- the house chosen in another window (market data, Alle Produkte): the ledger follows
if ns.AuctionHouse and ns.AuctionHouse.OnViewChange then
  ns.AuctionHouse.OnViewChange(function()
    if window and window.frame:IsShown() then ns.Safe(refreshCurrent) end
  end)
end

local function buildChoices(w)
  local f = w.frame
  local charLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  charLabel:SetPoint("TOPLEFT", 66, -36)
  charLabel:SetText("Charakter")
  choices.char = chooser(f, 180, function()
    local opts = { { key = "all", label = "Alle Charaktere" } }
    for _, key in ipairs(household()) do opts[#opts + 1] = { key = key, label = fullName(key) } end
    return opts
  end, function() return charSel or "all" end, function(key)
    charSel = key ~= "all" and key or nil
    if ns.Profit and ns.Profit.SetCharFilter then ns.Profit.SetCharFilter(charSel) end
    refreshCurrent()
  end)
  choices.char:SetPoint("LEFT", charLabel, "RIGHT", 8, 0)
  choices.charLabel = charLabel
  -- the auction house: the automatic one (open AH, else the last used) or another one
  local houseLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  houseLabel:SetPoint("LEFT", choices.char, "RIGHT", 18, 0)
  houseLabel:SetText("AH")
  choices.house = ns.AuctionHouse.Chooser(f, 130, function() refreshCurrent() end)
  choices.house:SetPoint("LEFT", houseLabel, "RIGHT", 8, 0)
  choices.houseLabel = houseLabel
  choices.period = chooser(f, 100, function() return PERIODS end, function() return period end, function(key)
    period = key
    refreshCurrent()
  end)
  choices.period:SetPoint("TOPRIGHT", -12, -30)
  local periodLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  periodLabel:SetPoint("RIGHT", choices.period, "LEFT", -8, 0)
  periodLabel:SetText("Zeitraum")
  choices.periodLabel = periodLabel
  for _, d in pairs(choices) do if d.Update then d.Update() end end
end

local function showChoices(key)
  local withChar, withPeriod = key ~= "gold" and key ~= "search" and key ~= "boxenstopp", key == "overview" or key == "ledger"
  local withHouseChoice = key ~= "gold" and key ~= "boxenstopp"
  choices.char:SetShown(withChar); choices.charLabel:SetShown(withChar)
  choices.house:SetShown(withHouseChoice); choices.houseLabel:SetShown(withHouseChoice)
  -- the search line sits in the choice row: the house choice moves to the right edge there
  choices.house:ClearAllPoints()
  if key == "search" then
    choices.house:SetPoint("TOPRIGHT", -12, -30)
    choices.houseLabel:ClearAllPoints()
    choices.houseLabel:SetPoint("RIGHT", choices.house, "LEFT", -8, 0)
  else
    choices.houseLabel:ClearAllPoints()
    choices.houseLabel:SetPoint("LEFT", choices.char, "RIGHT", 18, 0)
    choices.house:SetPoint("LEFT", choices.houseLabel, "RIGHT", 8, 0)
  end
  choices.period:SetShown(withPeriod); choices.periodLabel:SetShown(withPeriod)
  for _, d in pairs(choices) do if d.Update then d.Update() end end
end
local function onTab(key, fn)
  return function(page)
    showChoices(key)
    if fn then fn(page) else refreshPage(page) end
  end
end

local function create()
  window = ns.NativeWindow.New({ name = NAME, title = "Handelsbuch", icon = ICON })
  buildChoices(window)
  window:AddTab({ key = "overview", title = "Übersicht", icon = "Interface\\Icons\\INV_Misc_Coin_02", overview = true,
    build = viewed(buildOverview), onShow = onTab("overview", function(page)
      if page.Refresh then page.Refresh() end
      ns.Safe(TradeBook.CheckAuctions)
    end) })
  window:AddTab({ key = "ledger", title = "Handelsbuch", icon = "Interface\\Icons\\INV_Misc_Note_01",
    build = viewed(buildLedger), onShow = onTab("ledger") })
  window:AddTab({ key = "stock", title = "Bestand", icon = "Interface\\Icons\\INV_Box_02",
    build = viewed(buildStock), onShow = onTab("stock") })
  window:AddTab({ key = "auctions", title = "Auktionen", icon = "Interface\\Icons\\INV_Hammer_15",
    build = viewed(buildAuctions), onShow = onTab("auctions", function(page) refreshPage(page); ns.Safe(TradeBook.CheckAuctions) end) })
  window:AddTab({ key = "search", title = "Marktsuche", icon = SEARCH_TAB_ICON, overview = true,
    build = viewed(buildSearch), onShow = onTab("search") })
  -- under the search: Dr. Porzellan's toilet break planner, only with "Min-Max-Optimierung" (Boxenstopp.lua)
  if ns.Boxenstopp then
    window:AddTab({ key = "boxenstopp", title = "Boxenstopp-Planer", icon = ns.Boxenstopp.ICON, overview = true,
      visible = ns.Boxenstopp.Enabled, build = ns.Boxenstopp.Build, onShow = onTab("boxenstopp") })
  end
end

-- Right click on a trade / own use item: own use by hand, back to trade, or the automatic rule
-- (Profit.SetOwnUse; the marks travel with the settings sync).
function TradeBook.OwnUseMenu(owner, itemID)
  local P = ns.Profit
  local mark = P.OwnUseMark(itemID)
  local function set(v)
    P.SetOwnUse(itemID, v)
    local tab = window and window.current and window.tabs[window.current]
    if tab and tab.page and tab.page.Refresh then ns.Safe(tab.page.Refresh) end
  end
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(owner, function(_, root)
      root:CreateTitle(ns.ItemName(itemID) or "Item")
      root:CreateRadio("Eigenbedarf (Ausgabe)", function() return mark == true end, function() set(true) end)
      root:CreateRadio("Handel (zum Weiterverkauf)", function() return mark == false end, function() set(false) end)
      root:CreateRadio("Automatisch einordnen", function() return mark == nil end, function() set(nil) end)
    end)
  else
    -- no menu API: toggle own use / trade
    set(not (mark == true))
    print("|cff33ccffm4:|r " .. (ns.ItemName(itemID) or "Item") .. ": " .. (mark == true and "Handel" or "Eigenbedarf"))
  end
end

function TradeBook.Show()
  -- the playing character's last name (the player frame is filled by now)
  local c = ns.db and ns.db.chars and ns.CharKey and ns.db.chars[ns.CharKey()]
  local T = ns.Tracker
  if c and T and T.FullName then
    local ok, n = pcall(T.FullName)
    if ok and n then c.fullName = n end
  end
  if not window then create() end
  window:UpdateTabs() -- the settings sync may have switched the planner since
  window:Show()
  window:SelectTab("overview")
end

-- The switch "Min-Max-Optimierung" changed: the planner's tab follows.
function TradeBook.UpdateTabs()
  if window then window:UpdateTabs() end
end

-- The ledger on the toilet break planner (when switched on).
function TradeBook.ShowBoxenstopp()
  if not (ns.Boxenstopp and ns.Boxenstopp.Enabled()) then return false end
  TradeBook.Show()
  window:SelectTab("boxenstopp")
  return true
end

-- The ledger on its market search; text (optional) goes into the search line.
function TradeBook.ShowSearch(text)
  TradeBook.Show()
  window:SelectTab("search")
  local box = searchPage and searchPage.Box
  if not box then return end
  if text and text ~= "" then box:SetText(text) else box:SetFocus() end
end

function TradeBook.Toggle()
  if window and window.frame:IsShown() then window.frame:Hide() else TradeBook.Show() end
end

function TradeBook.Frame() return window and window.frame end

-- The playing character's gold in its snapshot on every change, so the other characters see it.
ns.On("PLAYER_MONEY", function()
  local c = ns.db and ns.db.chars and ns.CharKey and ns.db.chars[ns.CharKey()]
  if c and GetMoney then c.money, c.moneyT = GetMoney(), time() end
  if window and window.frame:IsShown() and (window.current == "stock" or window.current == "overview") then refreshCurrent() end
end)

-- Another auction house opened: the automatic choice moved (frame and page follow).
ns.AuctionHouse.OnChange(function()
  if window and window.frame:IsShown() then refreshCurrent() end
end)

-- Own auctions changed (MyAuctions: list or a search result): the shown page follows.
function TradeBook.OnAuctionsChanged()
  if not (window and window.frame:IsShown() and window.current) then return end
  local tab = window.tabs[window.current]
  if tab and tab.page and tab.page.Refresh and (window.current == "auctions" or window.current == "overview") then
    tab.page.Refresh()
  end
end

-- At the auction house the auctions are checked (own list, then one search per item): when the
-- auctions or the overview page shows, at most once a minute.
local lastCheck = 0
local function checkAuctions()
  local My = ns.MyAuctions
  if not (My and My.Check and ns.AHSearch and ns.AHSearch.IsOpen and ns.AHSearch.IsOpen()) then return end
  if time() - lastCheck < 60 then return end
  lastCheck = time()
  My.Check()
end
TradeBook.CheckAuctions = checkAuctions
if ns.On then
  -- the auction house opens while the window shows: check right away
  ns.On("AUCTION_HOUSE_SHOW", function()
    if window and window.frame:IsShown() and C_Timer then
      C_Timer.After(1, function() ns.Safe(checkAuctions) end)
    end
  end)
end

-- Probe (one step, removed later): what the profession window is made of in this client, so
-- the ledger window can use the very same templates, atlases and side tabs.
local function regionsOf(f, depth)
  local out = {}
  if type(f) ~= "table" or not f.GetRegions then return out end
  for _, r in ipairs({ f:GetRegions() }) do
    if r.GetObjectType and r:GetObjectType() == "Texture" then
      local atlas = r.GetAtlas and r:GetAtlas()
      local tex = r.GetTexture and r:GetTexture()
      local layer, sub = r:GetDrawLayer()
      local p, rel, rp, x, y = r:GetPoint(1)
      out[#out + 1] = string.format("%s|%s|%s/%s|%s %s %s %.0f %.0f|%.0fx%.0f|shown=%s", tostring(r:GetName() or "-"),
        tostring(atlas or tex), tostring(layer), tostring(sub), tostring(p),
        rel == f and "parent" or tostring(rel and rel.GetName and rel:GetName() or (rel and "other") or "nil"),
        tostring(rp), x or 0, y or 0, r:GetWidth() or 0, r:GetHeight() or 0, tostring(r:IsShown()))
    end
  end
  return out
end

local function keysOf(t)
  local k = {}
  for key, v in pairs(t) do
    if type(v) == "table" and v.GetObjectType then k[#k + 1] = tostring(key) .. ":" .. v:GetObjectType() end
  end
  table.sort(k)
  return table.concat(k, ",")
end

function TradeBook.Probe()
  if not ns.db then return end
  if not rawget(_G, "ProfessionsFrame") then
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then pcall(load, "Blizzard_Professions") end
  end
  local out = { t = time() }
  local pf = rawget(_G, "ProfessionsFrame")
  out.pf = type(pf)
  if type(pf) == "table" then
    out.pfKeys = keysOf(pf)
    out.pfRegions = table.concat(regionsOf(pf), " ;; ")
    local page = rawget(pf, "CraftingPage")
    if type(page) == "table" then
      out.pageKeys = keysOf(page)
      out.pageRegions = table.concat(regionsOf(page), " ;; ")
      local list = rawget(page, "RecipeList")
      if type(list) == "table" then
        out.listKeys = keysOf(list)
        out.listRegions = table.concat(regionsOf(list), " ;; ")
        local sb = rawget(list, "SearchBox")
        if type(sb) == "table" then
          local p, rel, rp, x, y = sb:GetPoint(1)
          out.searchPoint = string.format("%s %s %.0f %.0f %.0fx%.0f", tostring(p), tostring(rp), x or 0, y or 0, sb:GetWidth(), sb:GetHeight())
        end
        local fb = rawget(list, "FilterButton") or rawget(list, "FilterDropdown")
        if type(fb) == "table" then
          local p, rel, rp, x, y = fb:GetPoint(1)
          out.filterPoint = string.format("%s %s %.0f %.0f %.0fx%.0f %s", tostring(p), tostring(rp), x or 0, y or 0, fb:GetWidth(), fb:GetHeight(), fb:GetObjectType())
        end
        local box = rawget(list, "ScrollBox")
        if type(box) == "table" and box.ForEachFrame then
          local rows = {}
          box:ForEachFrame(function(row)
            if #rows < 3 then
              rows[#rows + 1] = keysOf(row) .. " => " .. table.concat(regionsOf(row), " ;; ")
            end
          end)
          out.rows = table.concat(rows, " || ")
        end
      end
      local form = rawget(page, "SchematicForm")
      if type(form) == "table" then
        out.formKeys = keysOf(form)
        out.formRegions = table.concat(regionsOf(form), " ;; ")
        local bg = rawget(form, "Background")
        if type(bg) == "table" then out.formBackground = tostring(bg.GetAtlas and bg:GetAtlas() or bg:GetTexture()) end
      end
    end
    -- side tabs: children of the window at its right edge
    local tabs = {}
    for _, child in ipairs({ pf:GetChildren() }) do
      local l, r = child:GetLeft(), pf:GetRight()
      if l and r and l > r - 10 then
        tabs[#tabs + 1] = tostring(child:GetName() or "-") .. ":" .. child:GetObjectType() .. " " .. keysOf(child)
          .. " => " .. table.concat(regionsOf(child), " ;; ")
      end
    end
    out.sideTabs = table.concat(tabs, " || ")
  end
  local info = C_XMLUtil and C_XMLUtil.GetTemplateInfo
  local names = {}
  for _, n in ipairs({ "ProfessionsRecipeListCategoryTemplate", "ProfessionsRecipeListRecipeTemplate",
      "ProfessionsRecipeListTemplate", "ProfessionsFrameTabTemplate", "SpellBookSkillLineTabTemplate",
      "ProfessionsSideTabTemplate", "LargeSideTabButtonTemplate", "SideTabTemplate", "SearchBoxTemplate",
      "WowStyle1FilterDropdownTemplate", "UIMenuButtonStretchTemplate", "ProfessionsSchematicFormTemplate" }) do
    local ok, ti = pcall(function() return info and info(n) end)
    names[#names + 1] = n .. "=" .. tostring(ok and ti ~= nil)
  end
  out.templates = table.concat(names, ",")
  ns.db.tradeBookProbe = out
end

if ns.On then
  ns.On("TRADE_SKILL_SHOW", function()
    if C_Timer then C_Timer.After(0.5, function() ns.Safe(TradeBook.Probe) end) end
  end)
end

-- Probe 2: the profession overview page ("Berufe", ProfessionsFrame.BookPage), two levels deep.
local function describe(f, depth, out, prefix)
  if type(f) ~= "table" or not f.GetObjectType then return end
  local w, h = f:GetWidth() or 0, f:GetHeight() or 0
  local p, rel, rp, x, y = f:GetPoint(1)
  out[#out + 1] = string.format("%s%s %s %.0fx%.0f @%s %s %.0f %.0f", prefix, f:GetObjectType(), tostring(f:GetName() or "-"),
    w, h, tostring(p), tostring(rp), x or 0, y or 0)
  if f.GetRegions then
    for _, r in ipairs({ f:GetRegions() }) do
      local t = r:GetObjectType()
      if t == "Texture" then
        local layer, sub = r:GetDrawLayer()
        local rp1, _, rrp, rx, ry = r:GetPoint(1)
        out[#out + 1] = string.format("%s  tex %s %s/%s %.0fx%.0f @%s %s %.0f %.0f", prefix,
          tostring((r.GetAtlas and r:GetAtlas()) or r:GetTexture()), tostring(layer), tostring(sub),
          r:GetWidth() or 0, r:GetHeight() or 0, tostring(rp1), tostring(rrp), rx or 0, ry or 0)
      elseif t == "FontString" then
        local fo = r:GetFontObject()
        out[#out + 1] = string.format("%s  text %q font=%s", prefix, tostring(r:GetText()), tostring(fo and fo:GetName()))
      end
    end
  end
  if depth > 0 and f.GetChildren then
    for _, c in ipairs({ f:GetChildren() }) do describe(c, depth - 1, out, prefix .. "    ") end
  end
end

-- The shown window whose title is "Berufe" (whatever its name in this client).
local function findBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if type(book) == "table" and book:IsShown() then return book end
  if not EnumerateFrames then return nil end
  local f = EnumerateFrames()
  while f do
    if f:IsShown() and f.GetParent and f:GetParent() == UIParent then
      local container = rawget(f, "TitleContainer")
      local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
      if type(title) == "table" and title.GetText and title:GetText() == "Berufe" then return f end
    end
    f = EnumerateFrames(f)
  end
end

function TradeBook.ProbeBook()
  local book = findBook()
  if type(book) ~= "table" or not ns.db then return false end
  local out = {}
  describe(book, 4, out, "")
  ns.db.tradeBookProbe2 = { t = time(), name = tostring(book:GetName()), lines = out }
  return true
end

-- look for it every 2 s until found once (probe only)
if C_Timer and C_Timer.NewTicker then
  local ticker
  ticker = C_Timer.NewTicker(2, function()
    local ok, found = pcall(TradeBook.ProbeBook)
    if ok and found and ticker then ticker:Cancel() end
  end)
end

-- The professions book ("Berufe", K) loads on demand: hook its OnShow once it exists.
local bookHooked = false
local function hookBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if bookHooked or type(book) ~= "table" then return end
  bookHooked = true
  book:HookScript("OnShow", function()
    if C_Timer then C_Timer.After(0.5, function() ns.Safe(TradeBook.ProbeBook) end) end
  end)
  if book:IsShown() then ns.Safe(TradeBook.ProbeBook) end
end
if ns.On then
  ns.On("ADDON_LOADED", function(_, name) if name == "Blizzard_ProfessionsBook" then ns.Safe(hookBook) end end)
  ns.On("PLAYER_LOGIN", function() ns.Safe(hookBook) end)
end
