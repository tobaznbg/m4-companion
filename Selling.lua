-- Selling: panel next to the auction house that lists everything in the bags the
-- Bestand logic would sell on the auction house, looks up the current lowest
-- price live and posts one auction per click (the game requires a click for
-- every post).
-- Mode "Sniper": the sniper's whole watch list live (ns.Sniper.State) with progress,
-- last cheapest price and last check per item; hits on top with a buy button. A click on a
-- hit row opens the item's detail window (ItemDetail.lua) right of the panel.
-- Alt+click on any row opens the detail too (ns.ItemDetail.AltClick).
-- Mode "Auktionen": the own running auctions per item (ns.MyAuctions) with the cheapest offer of
-- somebody else and whether the own price is still the best; opening the mode or "Prüfen"
-- searches every item once (ns.AHSearch). "Abbrechen" cancels exactly one auction per click.
-- Live prices of the sell mode come from ns.AHSearch too (one search a second).
local ADDON, ns = ...

local Selling = {}
ns.Selling = Selling

local WIDTH, ROW = 410, 26
local MAX_ROWS = 18
local CRASH_SHARE = 0.7  -- warn when the live price is below 70 % of the usual one
local DURATIONS = { { 1, "2 h" }, { 2, "8 h" }, { 3, "24 h" } }

local panel, rowsFrames, durationButtons, status
local duration = 3
local mode = "sell" -- "sell", "sniper" or "mine"
local control, sniperLines, ledgerButton
local sniperView         -- watch list view of the sniper mode (createSniperView)
local createMineView, refreshMine -- forward declared: mode "Auktionen", defined below the sniper view
local SNIPER_ROW = 20
local GREEN, MUTED = "|cff5fd38d", "|cff99999e"
-- Sniper columns right of the item name: buy up to, sell at (price stair of the hit), button.
local SNIPER_COLS = { { "Kauf bis", 62 }, { "Einstellen", 74 }, { "", 58 } }
local modeTabs
local entries = {}       -- current list
local live = {}          -- itemID -> { price, own, t } from live searches
local mineView, checkButton -- mode "Auktionen" (createMineView)
local MINE_ROW = 44 -- name, status line, cost line
local RED, ORANGE = "|cffff6b6b", "|cffffb547"
-- Columns of the mode "Auktionen" right of the item: own price, cheapest of others, cancel button.
local MINE_COLS = { { "Einkauf", 60 }, { "Mein Preis", 64 }, { "Billigst fremd", 70 }, { "", 66 } }

local api = C_AuctionHouse or {}

local function money(c) return ns.FormatMoney(c, true) end

-- Items in the bags: itemID -> { location of one stack, total count, quality, bound }.
local function bagItems()
  local c = C_Container or {}
  local numSlots, info = c.GetContainerNumSlots or GetContainerNumSlots, c.GetContainerItemInfo
  local items = {}
  for _, bag in ipairs(ns.CarriedBags()) do
    for slot = 1, (numSlots(bag) or 0) do
      local i = info and info(bag, slot)
      if i and i.itemID and not i.isLocked then
        local e = items[i.itemID]
        if not e then
          e = { itemID = i.itemID, n = 0, q = i.quality, bound = i.isBound,
                location = ItemLocation:CreateFromBagAndSlot(bag, slot) }
          items[i.itemID] = e
        end
        e.n = e.n + (i.stackCount or 1)
      end
    end
  end
  return items
end

local function isCommodity(e)
  if api.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
    return api.GetItemCommodityStatus(e.location) == Enum.ItemCommodityStatus.Commodity
  end
  return false
end

-- Live price search through ns.AHSearch (one search a second, handed to the sniper while it
-- runs; ns.AHSearch also reports the price to ns.Item.Observe). -----------------------------

local function onPrice(offers, itemID)
  if not offers then return end -- no answer: asked again on the next refresh
  local best = offers[1]
  live[itemID] = { price = best and best.unit, own = best and best.own, t = GetTime() }
  ns.Safe(Selling.Refresh)
end

local function requestPrice(e)
  if live[e.itemID] or not ns.AHSearch then return end
  ns.AHSearch.Request(e.itemID, onPrice)
end

-- Price to post at, or nil with a reason.
local function askPrice(e)
  local l = live[e.itemID]
  if not l then return nil, "Preis wird abgefragt …" end
  local item = ns.Item(e.itemID)
  local vendor = item.vendorSell or 0
  local ask
  if l.price then
    -- Our own auction already leads: match it instead of undercutting ourselves.
    ask = l.own and l.price or math.max(1, l.price - 1)
  elseif item.ref then
    ask = item.ref
  else
    return nil, "kein Angebot – Preis selbst setzen"
  end
  if ask * (1 - ns.Item.CUT) <= vendor then return nil, "unter Händlerpreis" end
  -- Lowest sensible price: what it costs to make (own learned recipe) or R (median of
  -- yesterday, ns.Item), whichever is higher. Below it, better wait than join the undercutting.
  -- (the making cost plus its share of deposits already lost on cancelled / expired auctions)
  local made = ns.CraftingCost and ns.CraftingCost(e.itemID) or 0
  if made > 0 and ns.Profit and ns.Profit.LostDepositPerUnit then made = made + ns.Profit.LostDepositPerUnit(e.itemID) end
  local floor = math.max(made, item.ref or 0)
  if floor > 0 and ask < floor then
    return ask, "unter Mindestpreis " .. money(floor) .. " – besser liegen lassen", true
  end
  local warn
  if item.ref and ask < item.ref * CRASH_SHARE then
    warn = string.format("%d %% unter %s", math.floor((1 - ask / item.ref) * 100), ns.Item.RefLabel(item))
  end
  return ask, warn
end

local function post(e)
  local ask = askPrice(e)
  if not ask then return end
  if isCommodity(e) then
    api.PostCommodity(e.location, duration, e.n, ask)
  else
    api.PostItem(e.location, duration, 1, nil, ask)
  end
  live[e.itemID] = nil -- the price changed with our own auction
end

-- Sniper watch list view -----------------------------------------------------------

local function ago(t)
  local s = math.max(0, time() - t)
  if s < 60 then return string.format("vor %d s", s) end
  if s < 3600 then return string.format("vor %d min", math.floor(s / 60)) end
  return string.format("vor %d h", math.floor(s / 3600))
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Item tooltip, plus the hit figures when the row is a hit.
local function sniperTooltip(self)
  local e = self.entry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(e.itemID)
  local h = e.hit
  if h and h.recipe then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Rezept (%s %s)  ·  %dx ab %s", h.profession or "?", tostring(h.skill or "?"),
      h.units, money(h.best)), 1, 0.71, 0.28)
    GameTooltip:AddLine((h.usualLabel or "Marktwert gestern") .. " " .. (h.usual and money(h.usual) or "unbekannt"), 1, 0.71, 0.28)
    if h.best > GetMoney() then GameTooltip:AddLine("Gold reicht nicht.", 1, 0.71, 0.28) end
  elseif h then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("%dx kaufen bis %s  ·  einstellen zu %s", h.units, money(h.buyUpTo), money(h.sellAt)), 0.37, 0.83, 0.55)
    GameTooltip:AddLine(string.format("Gewinn ~%s%s", money(h.profit),
      h.days and string.format("  ·  verkauft in ~%s Tagen", ns.ItemDetail.Days(h.days)) or ""), 0.37, 0.83, 0.55)
    if h.cost > GetMoney() then GameTooltip:AddLine("Gold reicht nicht für alle.", 1, 0.71, 0.28) end
  end
  GameTooltip:AddLine("Klick: Details", 0.31, 0.76, 0.63)
  GameTooltip:Show()
end

local function sniperRow(body, i)
  local Style = ns.Style
  local r = CreateFrame("Frame", nil, body)
  r:SetHeight(SNIPER_ROW)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * SNIPER_ROW)
  r:SetPoint("RIGHT", body, "RIGHT")
  r.stripe = Style.Solid(r, Style.C.row)
  r.stripe:SetAllPoints()
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(SNIPER_ROW - 4, SNIPER_ROW - 4)
  r.icon:SetPoint("LEFT", 2, 0)
  r.cells = {}
  local x = 0
  for c = #SNIPER_COLS, 1, -1 do
    local fs = Style.Text(r, 11)
    fs:SetPoint("RIGHT", r, "RIGHT", -x - 4, 0)
    fs:SetWidth(SNIPER_COLS[c][2] - 6)
    fs:SetJustifyH("RIGHT")
    r.cells[c] = fs
    x = x + SNIPER_COLS[c][2]
  end
  r.name = Style.Text(r, 12)
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
  r.name:SetPoint("RIGHT", r, "RIGHT", -x - 4, 0)
  r.name:SetJustifyH("LEFT")
  -- Buy button over the "checked" column; same purchase path as before (one click each).
  r.button = Style.Button(r, "Kaufen", SNIPER_COLS[#SNIPER_COLS][2] - 2, SNIPER_ROW - 2, function(self)
    if self.entry then ns.Safe(ns.Sniper.Buy, self.entry) end
  end, Style.C.accent)
  r.button:SetPoint("RIGHT", -1, 0)
  r:EnableMouse(true)
  r:SetScript("OnEnter", sniperTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Click on the row (not the buy button): detail window right of the panel, again closes it.
  r:SetScript("OnMouseUp", function(self, button)
    -- Alt+click: the detail's own click watcher already opened it (a toggle would close it).
    if button ~= "RightButton" and self.entry and not ns.ItemDetail.IsAltClick() then
      ns.Safe(ns.ItemDetail.Toggle, self.entry.itemID, panel)
      ns.Safe(Selling.Refresh)
    end
  end)
  return r
end

local function createSniperView()
  local Style = ns.Style
  local v = CreateFrame("Frame", nil, panel)
  v:SetPoint("TOPLEFT", 8, -34)
  v:SetPoint("BOTTOMRIGHT", -8, 66) -- status block below
  v.progress = Style.Text(v, 12)
  v.progress:SetPoint("TOPLEFT", 2, -2)
  v.progress:SetPoint("RIGHT", v, "RIGHT", -2, 0)
  v.progress:SetJustifyH("LEFT")
  local head = CreateFrame("Frame", nil, v)
  head:SetHeight(14)
  head:SetPoint("TOPLEFT", 0, -20)
  head:SetPoint("RIGHT", v, "RIGHT", -10, 0)
  local x = 0
  for c = #SNIPER_COLS, 1, -1 do
    local fs = Style.Text(head, 10)
    fs:SetPoint("RIGHT", head, "RIGHT", -x - 4, 0)
    fs:SetWidth(SNIPER_COLS[c][2] - 6)
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(unpack(Style.C.muted))
    fs:SetText(SNIPER_COLS[c][1])
    x = x + SNIPER_COLS[c][2]
  end
  local itemHead = Style.Text(head, 10)
  itemHead:SetPoint("LEFT", 2, 0)
  itemHead:SetTextColor(unpack(Style.C.muted))
  itemHead:SetText("Item")
  v.scroll, v.body = Style.Scroll(v)
  v.scroll:SetPoint("TOPLEFT", 0, -36)
  v.scroll:SetPoint("BOTTOMRIGHT", -10, 0)
  v.rows = {}
  -- Shown while there is no hit: the list only holds what is worth buying.
  v.empty = Style.Text(v, 11)
  v.empty:SetPoint("TOPLEFT", 8, -44)
  v.empty:SetPoint("RIGHT", -8, 0)
  v.empty:SetJustifyH("LEFT")
  v.empty:SetTextColor(unpack(Style.C.muted))
  return v
end

-- Texts of the three columns: buy up to, sell at (hits) or cheapest now (last search), checked.
local function sniperCells(e)
  local price, checked
  if e.price == false and not e.hit then price = MUTED .. "nicht im Angebot|r"
  elseif e.hit and e.hit.recipe then price = e.hit.usual and (MUTED .. (e.hit.usualShort or "gestern") .. " " .. money(e.hit.usual) .. "|r") or (MUTED .. "–|r")
  elseif e.hit then price = GREEN .. money(e.hit.sellAt) .. "|r"
  elseif e.price then price = money(e.price)
  else price = MUTED .. "–|r" end
  if e.current then checked = ns.Style.ACCENT .. "gerade …|r"
  elseif e.checked then checked = MUTED .. ago(e.checked) .. "|r"
  else checked = MUTED .. "–|r" end
  return e.limit and money(e.limit) or (MUTED .. "–|r"), price, checked
end

local function sniperProgress(st, lines)
  if st.total == 0 then return lines[1] or "" end
  if not st.running then
    return string.format("%s  ·  Stand Runde %d: %d Items", lines[1] or "", st.round, st.total)
  end
  if st.phase == "detail" then
    return string.format("Runde %d  ·  %d/%d  ·  %s bis zum Ende", st.round, st.index, st.total, clock(st.eta))
  end
  return string.format("Runde %d fertig  ·  %d/%d  ·  %s", st.round, st.index, st.total, lines[1] or "")
end

-- Mode "Auktionen": own auctions ------------------------------------------------------------

local function mineTooltip(self)
  local e = self.entry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(e.itemID)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Meine Auktionen:", 0.92, 0.92, 0.92)
  for i, a in ipairs(e.auctions or {}) do
    if i > 6 then GameTooltip:AddLine(string.format("… und %d weitere", #e.auctions - 6), 0.6, 0.6, 0.62); break end
    local state = a.sold and "verkauft" or (a.expired and "abgelaufen")
      or (a.timeLeftSeconds and string.format("noch %d h", math.ceil(a.timeLeftSeconds / 3600))) or ""
    GameTooltip:AddLine(string.format("%dx zu %s  %s", a.quantity or 1, a.buyout and money(a.buyout) or "Gebot", state), 0.6, 0.6, 0.62)
  end
  GameTooltip:AddLine("Alt+Klick: Details", 0.31, 0.76, 0.63)
  GameTooltip:Show()
end

local function cancelTooltip(self)
  local a = self.row and ns.MyAuctions.CancelTarget(self.row)
  if not a then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Eine Auktion abbrechen", 0.92, 0.92, 0.92)
  GameTooltip:AddLine(string.format("%dx zu %s (die teuerste)", a.quantity or 1, money(self.row.top.unit)), 0.6, 0.6, 0.62)
  GameTooltip:AddLine("Die Einstellgebühr ist dabei verloren.", 1, 0.71, 0.28)
  local cost = api.GetCancelCost and api.GetCancelCost(a.auctionID)
  if cost and cost > 0 then GameTooltip:AddLine("Abbruchkosten: " .. money(cost), 1, 0.71, 0.28) end
  GameTooltip:AddLine("Ein Klick = genau eine Auktion.", 0.6, 0.6, 0.62)
  GameTooltip:Show()
end

local function mineRow(body, i)
  local Style = ns.Style
  local r = CreateFrame("Frame", nil, body)
  r:SetHeight(MINE_ROW)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * MINE_ROW)
  r:SetPoint("RIGHT", body, "RIGHT")
  r.stripe = Style.Solid(r, Style.C.row)
  r.stripe:SetAllPoints()
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(20, 20)
  r.icon:SetPoint("TOPLEFT", 2, -4)
  r.cells = {}
  local x = 0
  for c = #MINE_COLS, 1, -1 do
    if c < #MINE_COLS then
      local fs = Style.Text(r, 11)
      fs:SetPoint("TOPRIGHT", r, "TOPRIGHT", -x - 4, -3)
      fs:SetWidth(MINE_COLS[c][2] - 6)
      fs:SetJustifyH("RIGHT")
      r.cells[c] = fs
    end
    x = x + MINE_COLS[c][2]
  end
  r.name = Style.Text(r, 12)
  r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 5, 2)
  r.name:SetPoint("RIGHT", r, "RIGHT", -x - 4, 0)
  r.name:SetJustifyH("LEFT")
  r.info = Style.Text(r, 11)
  r.info:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
  r.info:SetJustifyV("TOP")
  r.info:SetPoint("RIGHT", r, "RIGHT", -MINE_COLS[#MINE_COLS][2] - 4, 0)
  r.info:SetJustifyH("LEFT")
  -- Cancels exactly one auction of the row per click (ns.MyAuctions.Cancel).
  r.button = Style.Button(r, "Abbrechen", MINE_COLS[#MINE_COLS][2] - 2, 20, function(self)
    if self.row and ns.MyAuctions.Cancel(self.row) then
      GameTooltip:Hide()
      ns.Safe(Selling.Refresh)
    end
  end)
  r.button:SetPoint("RIGHT", -1, 0)
  r.button:HookScript("OnEnter", cancelTooltip)
  r.button:HookScript("OnLeave", function() GameTooltip:Hide() end)
  r:EnableMouse(true)
  r:SetScript("OnEnter", mineTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- A click opens the item's detail (a second click closes it), like a sniper hit.
  r:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and self.entry and not ns.ItemDetail.IsAltClick() then
      ns.Safe(ns.ItemDetail.Toggle, self.entry.itemID, nil, "mine")
    end
  end)
  return r
end

createMineView = function()
  local Style = ns.Style
  local v = CreateFrame("Frame", nil, panel)
  v:SetPoint("TOPLEFT", 8, -34)
  v:SetPoint("BOTTOMRIGHT", -8, 36) -- "Prüfen" and the hint line below
  v.info = Style.Text(v, 12)
  v.info:SetPoint("TOPLEFT", 2, -2)
  v.info:SetPoint("RIGHT", v, "RIGHT", -2, 0)
  v.info:SetJustifyH("LEFT")
  local head = CreateFrame("Frame", nil, v)
  head:SetHeight(14)
  head:SetPoint("TOPLEFT", 0, -20)
  head:SetPoint("RIGHT", v, "RIGHT", -10, 0)
  local x = 0
  for c = #MINE_COLS, 1, -1 do
    local fs = Style.Text(head, 10)
    fs:SetPoint("RIGHT", head, "RIGHT", -x - 4, 0)
    fs:SetWidth(MINE_COLS[c][2] - 6)
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(unpack(Style.C.muted))
    fs:SetText(MINE_COLS[c][1])
    x = x + MINE_COLS[c][2]
  end
  local itemHead = Style.Text(head, 10)
  itemHead:SetPoint("LEFT", 2, 0)
  itemHead:SetTextColor(unpack(Style.C.muted))
  itemHead:SetText("Item")
  v.scroll, v.body = Style.Scroll(v)
  v.scroll:SetPoint("TOPLEFT", 0, -36)
  v.scroll:SetPoint("BOTTOMRIGHT", -10, 0)
  v.items = {}
  v.empty = Style.Text(v, 11)
  v.empty:SetPoint("TOPLEFT", 8, -44)
  v.empty:SetPoint("RIGHT", -8, 0)
  v.empty:SetJustifyH("LEFT")
  v.empty:SetTextColor(unpack(Style.C.muted))
  return v
end

-- Status text of a row: "bester Preis" (green), "unterboten um X (P %)" (red), "allein im AH",
-- "verkauft", "abgelaufen", "–" before the check; with the age of the check.
function Selling.MineStatus(e)
  local text
  if e.status == "best" then text = GREEN .. "bester Preis|r"
  elseif e.status == "under" then text = RED .. string.format("unterboten um %s (%d %%)", money(e.diff), math.floor(e.pct + 0.5)) .. "|r"
  elseif e.status == "alone" then text = MUTED .. "allein im AH|r"
  elseif e.status == "sold" then text = MUTED .. "verkauft|r"
  elseif e.status == "expired" then text = MUTED .. "abgelaufen|r"
  elseif e.status == "bid" then text = MUTED .. "nur Gebot|r"
  elseif e.searching then text = ns.Style.ACCENT .. "suche …|r"
  elseif e.status == "failed" then text = ORANGE .. "keine Antwort|r"
  else text = MUTED .. "–|r" end
  if e.searching and e.checked and e.status ~= "unknown" then text = text .. ns.Style.ACCENT .. "  suche …|r" end
  if e.checked and e.status ~= "sold" and e.status ~= "expired" then
    text = text .. MUTED .. "  ·  geprüft " .. ago(e.checked) .. "|r"
  end
  return text .. Selling.MineRoom(e)
end

-- "Einstand gekauft · Luft 3s · ab 13s ohne Verlust": where the cost (column "Einstand") comes
-- from and how far the price can still go down: undercutting the cheapest other offer by 1 copper, after the 5 % cut, minus the cost.
-- Always shown: without a known cost it says so (looted, or bought before the ledger ran).
function Selling.MineRoom(e)
  -- (not "a and b and f()": that keeps only the first return value)
  local cost, source
  if ns.Profit and ns.Profit.UnitCost then cost, source = ns.Profit.UnitCost(e.itemID) end
  if not cost then
    return "\n" .. MUTED .. "Einkauf unbekannt – kein Kauf erfasst (Details: eintragen)|r"
  end
  local text = "\n" .. MUTED .. "Einkauf " .. source .. "|r"
  local target = e.foreign and (e.foreign - 1) or e.unit
  if target then
    local room = math.floor(target * (1 - 0.05) - cost)
    text = text .. MUTED .. "  ·  |r" .. (room >= 0 and (GREEN .. "Luft " .. money(room))
      or (RED .. "unter Einkauf " .. money(-room))) .. "|r"
      .. MUTED .. "  ·  ab " .. money(ns.Profit.BreakEven(cost)) .. " ohne Verlust|r"
  end
  return text
end

local function mineProgress(My, rows)
  if not My.Supported() then return MUTED .. "Dieser Client meldet keine eigenen Auktionen.|r" end
  local done, total, running = My.Progress()
  if running and total == 0 then return "Lade eigene Auktionen …" end
  if running then return string.format("%d/%d geprüft …", done, total) end
  if not My.Updated() then return MUTED .. "Noch nicht geladen – „Prüfen“ klicken.|r" end
  local under = 0
  for _, e in ipairs(rows) do if e.status == "under" then under = under + 1 end end
  local text = string.format("%d Items  ·  %d Auktionen", #rows, My.Count())
  if total > 0 then text = text .. string.format("  ·  %d/%d geprüft", done, total) end
  if under > 0 then text = text .. "  ·  " .. RED .. under .. " unterboten|r" end
  return text
end

refreshMine = function()
  local My, Style = ns.MyAuctions, ns.Style
  local v = mineView
  local rows = My and My.Rows() or {}
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  v.info:SetText(My and mineProgress(My, rows) or "")
  if #rows == 0 then
    v.empty:SetText(My and My.Updated() and "Keine eigenen Auktionen." or "")
    v.empty:Show()
  else
    v.empty:Hide()
  end
  v.body:SetSize(WIDTH - 26, math.max(1, #rows * MINE_ROW))
  for i, e in ipairs(rows) do
    local r = v.items[i]
    if not r then r = mineRow(v.body, i); v.items[i] = r end
    r.entry, r.button.row = e, e
    r.icon:SetTexture(getIcon and getIcon(e.itemID) or nil)
    local qty = e.active > 0 and e.quantity or (e.soldCount + e.expiredCount)
    r.name:SetText((ns.ItemName(e.itemID) or ("#" .. e.itemID)) .. MUTED .. "  " .. qty .. "x|r"
      .. (e.soldCount > 0 and e.active > 0 and (MUTED .. "  ·  " .. e.soldCount .. " verkauft|r") or ""))
    local cost = ns.Profit and ns.Profit.UnitCost and ns.Profit.UnitCost(e.itemID)
    r.cells[1]:SetText(cost and money(math.floor(cost + 0.5)) or (MUTED .. "–|r"))
    r.cells[2]:SetText(e.unit and money(e.unit) or (MUTED .. "–|r"))
    r.cells[3]:SetText(e.foreign and money(e.foreign) or (MUTED .. "–|r"))
    r.info:SetText(Selling.MineStatus(e))
    r.button:SetShown(e.active > 0 and My.CancelTarget(e) ~= nil)
    if e.status == "under" then
      r.stripe:SetColorTexture(1, 0.42, 0.42, 0.12)
    elseif e.status == "best" then
      r.stripe:SetColorTexture(0.37, 0.83, 0.55, 0.08)
    else
      r.stripe:SetColorTexture(unpack(Style.C.row))
    end
    r.stripe:SetShown((e.status == "under" or e.status == "best" or i % 2 == 0) and true or false)
    r:Show()
  end
  for i = #rows + 1, #v.items do
    v.items[i].entry, v.items[i].button.row = nil, nil
    v.items[i]:Hide()
  end
  if v.scroll.UpdateBar then v.scroll.UpdateBar() end
  status:SetText("Abbrechen: eine Auktion je Klick, Gebühr ist weg")
  ns.ItemDetail.Refresh()
end

-- Status lines of the shown own-auction rows only ("geprüft vor 48 s").
function Selling.RefreshMineTimes()
  if not (panel and panel:IsShown() and mode == "mine" and mineView) then return end
  for _, r in ipairs(mineView.items) do
    if r:IsShown() and r.entry then r.info:SetText(Selling.MineStatus(r.entry)) end
  end
end

-- Panel --------------------------------------------------------------------------

local function createPanel(parent)
  local Style = ns.Style
  panel = CreateFrame("Frame", "M4CompanionSelling", parent)
  panel:SetWidth(WIDTH)
  panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
  panel:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 4, 0)
  Style.Panel(panel, 30)
  modeTabs = {}
  local mx = 6
  for _, def in ipairs({ { "sell", "Verkaufen", 70 }, { "sniper", "Sniper", 70 }, { "mine", "Auktionen", 74 } }) do
    local tab = Style.Tab(panel, def[2], def[3], function()
      mode = def[1]
      -- Opening "Auktionen" is the player's action that checks the own auctions.
      if mode == "mine" and ns.MyAuctions then ns.Safe(ns.MyAuctions.Check) end
      ns.Safe(Selling.Refresh)
    end)
    tab:SetPoint("TOPLEFT", mx, -2)
    modeTabs[def[1]] = tab
    mx = mx + def[3] + 2
  end

  ledgerButton = Style.Button(panel, "Handelsbuch", 84, 20, function()
    ns.Safe(ns.PlannerUI.Show, "ledger")
  end)
  ledgerButton:SetPoint("TOPRIGHT", -8, -5)

  durationButtons = {}
  local x = -8
  for i = #DURATIONS, 1, -1 do
    local d = DURATIONS[i]
    local b = Style.Tab(panel, d[2], 40, function()
      duration = d[1]
      ns.Safe(Selling.Refresh)
    end)
    b:SetPoint("TOPRIGHT", x, -2)
    durationButtons[d[1]] = b
    x = x - 42
  end

  rowsFrames = {}
  for i = 1, MAX_ROWS do
    local r = CreateFrame("Frame", nil, panel)
    r:SetSize(WIDTH - 16, ROW)
    r:SetPoint("TOPLEFT", 8, -36 - (i - 1) * ROW)
    r.stripe = Style.Solid(r, Style.C.row)
    r.stripe:SetAllPoints()
    r.stripe:SetShown(i % 2 == 0)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", 2, 0)
    r.name = Style.Text(r, 12)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 5)
    r.name:SetWidth(170)
    r.name:SetJustifyH("LEFT")
    r.info = Style.Text(r, 11)
    r.info:SetPoint("LEFT", r.icon, "RIGHT", 6, -6)
    r.info:SetWidth(190)
    r.info:SetJustifyH("LEFT")
    r.info:SetTextColor(unpack(Style.C.muted))
    r.price = Style.Text(r, 12)
    r.price:SetPoint("RIGHT", -82, 0)
    r.price:SetJustifyH("RIGHT")
    r.button = Style.Button(r, "Einstellen", 74, 20, function(self)
      if self.entry then ns.Safe(post, self.entry) end
    end, Style.C.accent)
    r.button:SetPoint("RIGHT", 0, 0)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      if not self.entry then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.entry.itemID)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnMouseUp", function(self, button)
      if button == "LeftButton" and self.entry then ns.Safe(ns.ItemDetail.AltClick, self.entry.itemID) end
    end)
    rowsFrames[i] = r
  end
  control = Style.Button(panel, "Start", 70, 22, function()
    ns.Safe(ns.Sniper.Click)
  end, Style.C.accent)
  control:SetPoint("BOTTOMRIGHT", -8, 8)
  -- Sniper status block: four lines above the bottom edge, separated by a rule.
  sniperLines = {}
  local colors = { Style.C.text, Style.C.muted, Style.C.muted, { 1, 0.71, 0.28, 1 } }
  for i = 4, 1, -1 do
    local fs = Style.Text(panel, i == 1 and 13 or 12)
    fs:SetPoint("BOTTOMLEFT", 10, 10 + (4 - i) * 17)
    fs:SetWidth(WIDTH - 96)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(unpack(colors[i]))
    sniperLines[i] = fs
  end
  -- Line 1 (state) moved into the progress line above the watch list.
  sniperLines.rule = Style.Solid(panel, Style.C.border)
  sniperLines.rule:SetHeight(1)
  sniperLines.rule:SetPoint("BOTTOMLEFT", 8, 63)
  sniperLines.rule:SetPoint("BOTTOMRIGHT", -8, 63)
  sniperView = createSniperView()
  mineView = createMineView()
  checkButton = Style.Button(panel, "Prüfen", 70, 22, function()
    if ns.MyAuctions then ns.Safe(ns.MyAuctions.Check) end
    ns.Safe(Selling.Refresh)
  end, Style.C.accent)
  checkButton:SetPoint("BOTTOMRIGHT", -8, 8)
  -- "geprüft vor 40 s" and the time left run on: once a second the sniper view is refreshed,
  -- the own auctions only get their status lines rewritten (a full rebuild there happens on
  -- new data: owned auctions, search results).
  local elapsed = 0
  panel:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 1 then return end
    elapsed = 0
    if mode == "sniper" then ns.Safe(Selling.Refresh)
    elseif mode == "mine" then ns.Safe(Selling.RefreshMineTimes) end
  end)
  status = Style.Text(panel, 11)
  status:SetPoint("BOTTOMLEFT", 10, 10)
  status:SetWidth(WIDTH - 20)
  status:SetJustifyH("LEFT")
  status:SetTextColor(unpack(Style.C.muted))
end

local function refreshSniper()
  local Sniper, Style = ns.Sniper, ns.Style
  local st = Sniper.State()
  local pending = Sniper.Pending()
  local lines = Sniper.StatusLines()
  local v = sniperView
  local detailID = ns.ItemDetail.ItemID()
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  -- Only hits (offers worth buying); the watched items are on the main window's Sniper page.
  local shown, current = {}, nil
  for _, e in ipairs(st.rows) do
    if e.hit then table.insert(shown, e) end
    if e.current then current = e end
  end
  if #shown == 0 then
    local text = "Noch kein Treffer."
    if current then text = text .. "\nPrüfe gerade: " .. (ns.ItemName(current.itemID) or ("#" .. current.itemID)) end
    v.empty:SetText(text .. "\n\nBeobachtete Items: Hauptfenster (/m4) → Sniper")
    v.empty:Show()
  else
    v.empty:Hide()
  end
  v.body:SetSize(WIDTH - 26, math.max(1, #shown * SNIPER_ROW))
  for i, e in ipairs(shown) do
    local r = v.rows[i]
    if not r then r = sniperRow(v.body, i); v.rows[i] = r end
    local h = e.hit
    r.entry = e
    r.button.entry = h
    r.icon:SetTexture(getIcon and getIcon(e.itemID) or nil)
    local name = ns.ItemName(e.itemID) or ("#" .. e.itemID)
    if h and h.recipe then
      r.name:SetText(ORANGE .. "Rezept|r  " .. name .. "  " .. money(h.best))
    else
      r.name:SetText(h and (GREEN .. name .. "  +" .. money(h.profit) .. "|r") or name)
    end
    local limit, price, checked = sniperCells(e)
    r.cells[1]:SetText(limit)
    r.cells[2]:SetText(price)
    r.cells[3]:SetText(h and "" or checked)
    if h and h.recipe then
      r.stripe:SetColorTexture(1, 0.71, 0.28, 0.16)
      local confirm = pending and pending.hit == h and pending.quoted
      r.button.label:SetText(confirm and "Bestätigen" or (h.commodity and "Kaufen" or "Kaufen 1"))
      r.button:Show()
    elseif h then
      r.stripe:SetColorTexture(0.37, 0.83, 0.55, 0.14)
      local confirm = pending and pending.hit == h and pending.quoted
      r.button.label:SetText(confirm and "Bestätigen" or (h.commodity and "Kaufen" or "Kaufen 1"))
      r.button:Show()
    else
      r.stripe:SetColorTexture(unpack(e.current and Style.C.hover or Style.C.row))
      r.button:Hide()
    end
    -- The item open in the detail window is marked like a hovered row.
    local selected = e.itemID == detailID
    if selected then r.stripe:SetColorTexture(0.31, 0.76, 0.63, 0.3) end
    r.stripe:SetShown((selected or h or e.current or i % 2 == 0) and true or false)
    r:Show()
  end
  for i = #shown + 1, #v.rows do
    v.rows[i].entry, v.rows[i].button.entry = nil, nil
    v.rows[i]:Hide()
  end
  if v.scroll.UpdateBar then v.scroll.UpdateBar() end
  v.progress:SetText(sniperProgress(st, lines))
  control.label:SetText(Sniper.NeedsClick() and "Suchen" or (Sniper.IsRunning() and "Stop" or "Start"))
  for i = 2, 4 do sniperLines[i]:SetText(lines[i] or "") end
  status:SetText("")
  ns.ItemDetail.Refresh()
end

-- The panel at the auction house (the item detail docks right of it), nil before the first visit.
function Selling.Frame() return panel end

function Selling.Refresh()
  if not panel or not panel:IsShown() then return end
  for key, tab in pairs(modeTabs) do tab:SetActive(key == mode) end
  for _, b in pairs(durationButtons) do b:SetShown(mode == "sell") end
  control:SetShown(mode == "sniper")
  ledgerButton:SetShown(mode ~= "sell")
  sniperLines[1]:Hide()
  for i = 2, 4 do sniperLines[i]:SetShown(mode == "sniper") end
  sniperLines.rule:SetShown(mode == "sniper")
  sniperView:SetShown(mode == "sniper")
  mineView:SetShown(mode == "mine")
  checkButton:SetShown(mode == "mine")
  status:SetShown(mode ~= "sniper")
  status:SetWidth(mode == "mine" and WIDTH - 100 or WIDTH - 20) -- room for "Prüfen"
  ns.ItemDetail.HideSniper(mode)
  if mode == "sniper" or mode == "mine" then
    for _, r in ipairs(rowsFrames) do r.entry, r.button.entry = nil, nil; r:Hide() end
    if mode == "mine" then return refreshMine() end
    return refreshSniper()
  end
  for d, b in pairs(durationButtons) do b:SetActive(d == duration) end
  -- Everything the Bestand logic sends to the auction house.
  entries = {}
  for _, e in pairs(bagItems()) do
    local action = ns.Inventory.Advise(e.itemID, e)
    if action == "AH" then
      local item = ns.Item(e.itemID)
      e.value = item.now or item.ref or 0
      table.insert(entries, e)
    end
  end
  table.sort(entries, function(a, b) return a.value * a.n > b.value * b.n end)
  local total = 0
  for i, r in ipairs(rowsFrames) do
    local e = entries[i]
    r.entry = e
    r.button.entry = e
    if e then
      local commodity = isCommodity(e)
      local qty = commodity and e.n or 1
      r.icon:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(e.itemID))
      r.name:SetText(ns.ItemName(e.itemID))
      local ask, note, belowFloor = askPrice(e)
      if ask then
        local deposit = commodity and api.CalculateCommodityDeposit and api.CalculateCommodityDeposit(e.itemID, duration, qty)
          or (api.CalculateItemDeposit and api.CalculateItemDeposit(e.location, duration, qty))
        r.price:SetText(money(ask))
        r.button.label:SetText(belowFloor and "Trotzdem" or "Einstellen")
        r.info:SetText(string.format("%dx  ·  Gebühr %s%s", qty, money(deposit or 0),
          note and ("  ·  |cffffb547" .. note .. "|r") or ""))
        r.button:Show()
        total = total + ask * qty * 0.95
      else
        r.price:SetText("")
        r.info:SetText(string.format("%dx  ·  %s", qty, note or ""))
        r.button:Hide()
      end
      requestPrice(e)
      r:Show()
    else
      r:Hide()
    end
  end
  status:SetText(#entries == 0 and "Nichts in den Taschen, das ins AH gehört."
    or string.format("%d Items fürs AH  ·  Erlös nach Gebühr ca. %s  ·  ein Klick = eine Auktion",
      #entries, money(total)))
end

-- The panel at the auction house is retired (20 Nov 2026): Blizzard's own tabs plus the
-- native detail window ("Marktdaten") and the cost rows in the sell frame replace it.
-- Selling.ENABLED = true brings it back (code kept).
Selling.ENABLED = false

ns.On("AUCTION_HOUSE_SHOW", function()
  if not Selling.ENABLED then return end
  C_Timer.After(0.2, function()
    local parent = AuctionHouseFrame
    if not parent or not api.PostCommodity then return end
    if not panel then ns.Safe(createPanel, parent) end
    if not panel then return end
    panel:Show()
    -- Opening the auction house with "Auktionen" selected is opening that mode: check it.
    if mode == "mine" and ns.MyAuctions then ns.Safe(ns.MyAuctions.Check) end
    ns.Safe(Selling.Refresh)
  end)
end)
ns.On("AUCTION_HOUSE_CLOSED", function()
  ns.ItemDetail.HideSniper()
  if panel then panel:Hide() end
end)
ns.On("BAG_UPDATE_DELAYED", function() ns.Safe(Selling.Refresh) end)
ns.On("AUCTION_HOUSE_AUCTION_CREATED", function()
  -- a new own auction: the list of the mode "Auktionen" is loaded again (no item searches)
  if mode == "mine" and panel and panel:IsShown() and ns.MyAuctions then ns.Safe(ns.MyAuctions.Query) end
  ns.Safe(Selling.Refresh)
end)
