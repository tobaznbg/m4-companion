-- DayTrade: "Tageshandel" - items whose price follows a daily rhythm (cheap and dear hours),
-- bought in the cheap window and posted (2 h) in the dear one.
--
-- The pool comes from the cloud (collector ahrhythm.py, hourly with the house data):
--   ns.AHData[house].rhythm = { [itemID] = { buyHour, sellHour, buyLimit, ask, maxQty, profitDay } }
-- windows are 3 hours from buyHour / sellHour (Berlin time = the PC's clock), buyLimit and ask in
-- copper per unit. The cloud only sets these parameters; what is on offer right now is the
-- newest observation Item.Get knows, updated at once on an own search or scan:
--   * own search or full scan (Observations.lua), other players' observations (cloud): the 8
--     cheapest price levels - units at or under the limit counted from them, a lower bound ("≥")
--     when all 8 are at or under it; the own full scan of that time counts its every listing,
--   * else the cloud snapshot (cheapest only).
-- The addon never buys or posts by itself; it only tells what the windows say now.
local ADDON, ns = ...

local Trade = {}
ns.DayTrade = Trade

local WINDOW_HOURS = 3
local CUT = 0.05
local DEPOSIT_2H = 0.05
local GREEN, RED, MUTED, GOLD = "|cff5fd38d", "|cffff6b6b", "|cff999999", "|cffffd100"

local page, split, selected
local SOURCES = { cloud = "Cloud", scan = "Vollscan", search = "Suche", players = "Spieler" }

local function money(c) return c and ns.FormatMoney(math.floor(c + 0.5), true) or "–" end

function Trade.Pool()
  local data = ns.AuctionHouse.CloudData()
  return data and type(data.rhythm) == "table" and data.rhythm or nil, data
end

-- Whether hour h lies in the window starting at from (wraps over midnight).
local function inWindow(h, from) return (h - from) % 24 < WINDOW_HOURS end
local function windowText(from)
  return string.format("%d–%d Uhr", from, (from + WINDOW_HOURS) % 24)
end
-- Hours until the window starting at from opens (0 = open now).
local function hoursUntil(h, from) return inWindow(h, from) and 0 or (from - h) % 24 end

-- What is on offer now: cheapest per unit, units at or under the limit (nil = unknown; atLeast:
-- a lower bound), source, time - all from the one newest source of Item.Get.
local function offer(itemID, limit)
  local e = ns.Item.Get(itemID)
  if not (e and e.dataT) then return {} end
  local o = { cheapest = e.now, t = e.dataT, source = SOURCES[e.dataSource] or "Cloud" }
  local levels, capped
  if e.dataSource == "scan" then
    -- the own full scan of that very time has every listing: an exact count
    local list, t = ns.Item.Listings(itemID)
    if t == e.dataT then levels = list or {} end
  end
  if not levels and e.levels then
    levels = ns.Item.PriceLevels(e.levels)
    capped = #levels >= (ns.Obs and ns.Obs.LEVELS or 8)
  end
  if not levels and not e.now and e.dataSource ~= "cloud" then levels = {} end -- seen: nothing on offer
  if levels then
    local units, all = 0, true
    for _, l in ipairs(levels) do
      if l.unit <= limit then units = units + l.count else all = false end
    end
    -- only the cheapest levels are known: with all of them under the limit more may follow
    o.units, o.atLeast = units, capped and all or nil
  end
  return o
end

local function ago(t)
  local s = math.max(0, time() - t)
  if s < 90 then return "gerade eben" end
  if s < 5400 then return string.format("vor %d min", math.floor(s / 60 + 0.5)) end
  return string.format("vor %d h", math.floor(s / 3600 + 0.5))
end

-- The state of one pool item now: { phase = "buy"|"sell"|"wait", text, color, … }.
local function state(itemID, r)
  local buyHour, sellHour, limit, ask, maxQty, profitDay = r[1], r[2], r[3], r[4], r[5], r[6]
  local h = tonumber(date("%H"))
  local o = offer(itemID, limit)
  local held = ns.ShoppingList and ns.ShoppingList.Holdings and ns.ShoppingList.Holdings(itemID) or 0
  local e = ns.Item.Get(itemID)
  local dep = (e and e.vendorSell or 0) * DEPOSIT_2H
  -- the lowest price that still returns the buy limit after cut and deposit
  local floor = math.ceil((limit + dep) / (1 - CUT))
  local s = { itemID = itemID, buyHour = buyHour, sellHour = sellHour, limit = limit, ask = ask, maxQty = maxQty,
    profitDay = profitDay, offer = o, held = held, dep = dep, floor = floor }
  if inWindow(h, buyHour) then
    s.phase = "buy"
    if o.cheapest and o.cheapest <= limit then
      s.text, s.color = o.units and o.units > 0 and string.format("kaufen (%d)", math.min(o.units, maxQty)) or "kaufen", GREEN
    elseif o.cheapest then
      s.text, s.color = "zu teuer", RED
    else
      s.text, s.color = "Kaufzeit", GOLD
    end
  elseif inWindow(h, sellHour) then
    s.phase = "sell"
    if held > 0 then
      if not o.cheapest or o.cheapest >= ask then
        s.text, s.color, s.post = "einstellen", GREEN, ask
      elseif o.cheapest - 1 >= floor then
        s.text, s.color, s.post = "einstellen", GOLD, o.cheapest - 1
      else
        s.text, s.color = "unterboten", RED
      end
    else
      s.text, s.color = "Verkaufszeit", MUTED
    end
  else
    local wait = hoursUntil(h, buyHour)
    s.phase = "wait"
    s.wait = wait
    s.text, s.color = string.format("Kauf %d Uhr", buyHour), MUTED
  end
  return s
end

-- Card -------------------------------------------------------------------------------------

local LABELS = { "Kaufzeit", "Kaufgrenze", "Einstellzeit", "Zielpreis (2 h)", "Untergrenze", "Höchstens / Tag",
  "Erwartet / Tag", "Günstigster jetzt", "Stück ≤ Grenze", "Im Haushalt" }

local function card(c)
  local NW = ns.NativeWindow
  local v = NW.CardHead(c)
  v.Head:SetText("Tageshandel:")
  v.fig = NW.Figures(c, v.Head, LABELS, { line = false })
  v.fig.SetWidth(300)
  v.Advice = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  v.Advice:SetPoint("TOPLEFT", v.fig.labels[#LABELS], "BOTTOMLEFT", 0, -16)
  v.Advice:SetWidth(300)
  v.Advice:SetJustifyH("LEFT")
  v.Note = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  v.Note:SetPoint("TOPLEFT", v.Advice, "BOTTOMLEFT", 0, -10)
  v.Note:SetWidth(300)
  v.Note:SetJustifyH("LEFT")
  local ok, b = pcall(CreateFrame, "Button", nil, c, "UIPanelButtonTemplate")
  if ok and b then
    b:SetSize(120, 22)
    b:SetPoint("BOTTOMLEFT", 22, 18)
    b:SetText("Im AH suchen")
    b:SetScript("OnClick", function()
      local id = selected and selected.itemID
      if not id or not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
      if AuctionHouseFrameDisplayMode then AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
      C_Timer.After(0.1, function() if ns.Deals and ns.Deals.Search then ns.Safe(ns.Deals.Search, id) end end)
    end)
    v.Search = b
  end
  return v
end

local function show(entry, c)
  if not rawget(c, "m4Trade") then c.m4Trade = card(c) end
  local v = c.m4Trade
  selected = entry
  local s = entry and entry.state
  local shown = s ~= nil
  for _, part in ipairs({ v.Icon, v.Ring, v.Name, v.Sub, v.Head, v.Advice, v.Note }) do part:SetShown(shown) end
  for i = 1, #LABELS do v.fig.labels[i]:SetShown(shown); v.fig.values[i]:SetShown(shown) end
  if v.Search then v.Search:SetShown(shown and AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown()) end
  if not shown then return end
  v.itemID = s.itemID
  v.Icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(s.itemID)) or 134400)
  v.Name:SetText(ns.ItemName(s.itemID) or ("Item " .. s.itemID))
  v.Sub:SetText(ns.AuctionHouse.Name())
  local o = s.offer
  local values = {
    windowText(s.buyHour),
    money(s.limit),
    windowText(s.sellHour),
    money(s.ask),
    money(s.floor),
    tostring(s.maxQty),
    money(s.profitDay),
    o.cheapest and (money(o.cheapest) .. MUTED .. "  " .. o.source .. ", " .. ago(o.t) .. "|r") or "–",
    o.units and ((o.atLeast and "≥ " or "") .. o.units) or (MUTED .. "unbekannt|r"),
    tostring(s.held),
  }
  for i, text in ipairs(values) do v.fig.values[i]:SetText(text) end
  local advice
  if s.phase == "buy" then
    if o.cheapest and o.cheapest <= s.limit then
      advice = GREEN .. string.format("Jetzt kaufen: bis %s je Stück, höchstens %d Stück.|r", money(s.limit), s.maxQty)
    elseif o.cheapest then
      advice = RED .. "Gerade zu teuer – nichts über der Kaufgrenze kaufen.|r"
    else
      advice = GOLD .. "Kaufzeit – erst suchen, dann kaufen.|r"
    end
  elseif s.phase == "sell" then
    if s.post then
      advice = (s.post == s.ask and GREEN or GOLD)
        .. string.format("Jetzt für 2 h einstellen zu %s je Stück.|r", money(s.post))
    elseif s.held > 0 then
      advice = RED .. string.format("Unterboten unter die Untergrenze %s – nicht einstellen.|r", money(s.floor))
    else
      advice = MUTED .. "Verkaufszeit, aber nichts im Haushalt.|r"
    end
  else
    advice = MUTED .. string.format("Nächster Kauf in %d h (%s).|r", s.wait, windowText(s.buyHour))
  end
  v.Advice:SetText(advice)
  v.Note:SetText("Fenster und Preise aus der Cloud (stündlich). Günstigster und Stückzahl aus der neuesten "
    .. "Beobachtung: eigene Suche, eigener Vollscan, andere Spieler oder Cloud-Stand. "
    .. "Gebühr 5 %, Einstellgebühr 2 h " .. money(s.dep) .. " je Stück.")
end

-- List -------------------------------------------------------------------------------------

local GROUPS = { { "buy", "Jetzt kaufen" }, { "sell", "Jetzt einstellen" }, { "wait", "Später" } }

local function entries()
  local pool = Trade.Pool()
  if not pool then return {} end
  local byPhase = { buy = {}, sell = {}, wait = {} }
  for itemID, r in pairs(pool) do
    local ok, s = pcall(state, itemID, r)
    if ok and s then table.insert(byPhase[s.phase], s) end
  end
  local out = {}
  for _, g in ipairs(GROUPS) do
    local list = byPhase[g[1]]
    if #list > 0 then
      table.sort(list, function(a, b)
        if (a.wait or 0) ~= (b.wait or 0) then return (a.wait or 0) < (b.wait or 0) end
        return a.profitDay > b.profitDay
      end)
      out[#out + 1] = { header = g[2], key = g[1] }
      for _, s in ipairs(list) do
        out[#out + 1] = { key = s.itemID, itemID = s.itemID, state = s, name = ns.ItemName(s.itemID) or ("Item " .. s.itemID),
          value = s.color .. s.text .. "|r" }
      end
    end
  end
  return out
end

local function refresh()
  if not (page and page:IsVisible() and split) then return end
  local list = entries()
  split.SetEntries(list)
  if page.empty then page.empty:SetShown(#list == 0) end
end
Trade.Refresh = function() ns.Safe(refresh) end

-- The page of the ledger's side tab "Tageshandel" (TradeBook.lua, under "Marktsuche").
function Trade.Build(p)
  page = p
  split = ns.NativeWindow.Split(p, { onSelect = show, listWidth = 300 })
  local empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("TOPLEFT", 20, -60)
  empty:SetWidth(260)
  empty:SetJustifyH("LEFT")
  empty:SetText("Für dieses Auktionshaus liegen noch keine Tageshandel-Daten aus der Cloud vor "
    .. "(Datenpaket über die Companion-App aktualisieren und /reload).")
  p.empty = empty
  -- the hour moves items between the groups: check once a minute while shown
  local acc = 0
  p:HookScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc >= 60 then acc = 0; refresh() end
  end)
end

-- Shown on the page's onShow (TradeBook.lua).
function Trade.OnShow() refresh() end

function Trade.Show()
  if ns.TradeBook and ns.TradeBook.ShowDayTrade then ns.TradeBook.ShowDayTrade() end
end

-- The auction house button: opens the ledger on this tab, closes it when it already shows it.
function Trade.Toggle()
  local TB = ns.TradeBook
  if TB and TB.Frame and TB.Frame() and TB.Frame():IsShown() and TB.Current and TB.Current() == "daytrade" then
    TB.Frame():Hide()
  else
    Trade.Show()
  end
end

-- Live: a search of a pool item redraws at once (Item.Get has it as the newest source). One
-- frame later: the "nothing on offer" of an empty search reaches Item.Observe in another handler.
if ns.Obs then
  ns.Obs.OnRecord(function(itemID)
    local pool = Trade.Pool()
    if pool and pool[itemID] then C_Timer.After(0, Trade.Refresh) end
  end)
end
ns.AuctionHouse.OnChange(function() refresh() end)
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then ns.AuctionScan.OnDone(refresh) end
end)
