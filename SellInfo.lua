-- SellInfo: two rows in Blizzard's "Auktion erstellen" (auction house tab "Verkaufen"), right
-- under "Gesamtpreis" and in its style, recomputed while the price or quantity is typed:
--   Einstand   1g 96s 26c          (cost of the units, ns.Profit.UnitCost x quantity)
--   Gewinn    -49s 80c             (total price after the 5 % cut minus that cost; green/red)
-- Without a known cost: "Einstand  unbekannt", no profit row. The post button moves below the
-- rows. Only reads Blizzard's frames, never posts or changes a price.
-- Pilot: while the sell slot holds an item, the item detail window (ItemDetail.lua) docks at
-- the auction house frame in the native Blizzard look, and the own Selling panel steps aside.
local ADDON, ns = ...

local SellInfo = {}
ns.SellInfo = SellInfo

local CUT = 0.05
local ROW_H = 24

local function money(c) return ns.FormatMoney(c) end

-- The item location in a sell frame: the one Blizzard put in with SetItem (hooked in attach),
-- else the frame's GetItem; nil when the slot is empty.
local function locationOf(frame)
  local location = frame.m4Location
  if location == nil and frame.GetItem then
    local ok, loc = pcall(frame.GetItem, frame)
    location = ok and loc or nil
  end
  return location
end

-- The item link of a location (keeps a random suffix such as "des arkanen Zorns").
local function linkOf(location)
  if type(location) ~= "table" then return nil end
  if C_Item and C_Item.GetItemLink then
    local ok, link = pcall(C_Item.GetItemLink, location)
    if ok and link then return link end
  end
  if location.GetBagAndSlot then
    local ok, bag, slot = pcall(location.GetBagAndSlot, location)
    local get = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    if ok and bag and slot and get then
      local ok2, link = pcall(get, bag, slot)
      if ok2 then return link end
    end
  end
end

-- The item id in a sell frame, nil when the slot is empty.
local function itemOf(frame)
  local location = locationOf(frame)
  if not location then return nil end
  if type(location) == "table" and location.IsValid and not location:IsValid() then return nil end
  local getID = C_Item and C_Item.GetItemID
  if not getID then return nil end
  local ok, id = pcall(getID, location)
  return ok and id or nil
end

-- The unit price entered (copper), nil when none.
local function unitPriceOf(frame)
  if frame.GetUnitPrice then
    local ok, price = pcall(frame.GetUnitPrice, frame)
    if ok and type(price) == "number" and price > 0 then return price end
  end
  local input = frame.PriceInput
  if input and input.GetAmount then
    local ok, price = pcall(input.GetAmount, input)
    if ok and type(price) == "number" and price > 0 then return price end
  end
  return nil
end

-- The quantity entered, 1 when it cannot be read.
local function quantityOf(frame)
  for _, get in ipairs({
    function() return frame:GetQuantity() end,
    function() return frame.QuantityInput:GetQuantity() end,
    function() return frame.QuantityInput.InputBox:GetNumber() end,
  }) do
    local ok, n = pcall(get)
    if ok and type(n) == "number" and n > 0 then return n end
  end
  return 1
end

-- The two values for item `id`, unit price `price` (nil: none yet) and `qty` units:
-- costText, profitText (nil: no profit row). Nothing at all without an item.
function SellInfo.Values(id, price, qty)
  if not (id and ns.Profit and ns.Profit.UnitCost) then return nil end
  local cost, source = ns.Profit.UnitCost(id)
  if not cost then return "|cff999999unbekannt|r", nil end
  qty = qty or 1
  local total = math.floor(cost * qty + 0.5)
  local costText = source == "Beute" and "Beute" or money(total)
  if not price then return costText, nil end
  local profit = math.floor(price * qty * (1 - CUT) - total)
  local text = profit >= 0 and ("|cff5fd38d" .. money(profit) .. "|r") or ("|cffff6b6b-" .. money(-profit) .. "|r")
  return costText, text
end

-- One row like Blizzard's: label right-aligned in the label column, value left in the value column.
local function newRow(holder, frame, labelText, index)
  local total = frame.TotalPrice
  local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local value = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetText(labelText)
  label:SetJustifyH("RIGHT")
  value:SetJustifyH("LEFT")
  local y = -(index - 1) * ROW_H - 10
  if total and total.Label then
    label:SetPoint("TOPRIGHT", total.Label, "BOTTOMRIGHT", 0, y)
  elseif total then
    label:SetPoint("TOPLEFT", total, "BOTTOMLEFT", 0, y)
  else
    label:SetPoint("BOTTOMLEFT", frame.PostButton or frame, "TOPLEFT", 0, -y)
  end
  local valueAnchor = total and (total.MoneyDisplayFrame or total.MoneyFrame)
  if valueAnchor then
    value:SetPoint("TOPLEFT", valueAnchor, "BOTTOMLEFT", 0, y)
  else
    value:SetPoint("LEFT", label, "RIGHT", 18, 0)
  end
  return { label = label, value = value }
end

-- The detail window of the item in the sell slot (nil: none), native look, docked at the AH.
local DETAIL_ORIGIN = "ahsell"
local opened -- item the window was opened for: closed with × it stays closed for that item
local function syncDetail(id, itemKey, location)
  local Detail = ns.ItemDetail
  if not Detail then return end
  local mine = Detail.Origin and Detail.Origin() == DETAIL_ORIGIN
  if id then
    if mine and Detail.ItemID() == id then return end
    if id == opened and not Detail.IsShown() then return end -- closed by the player
    opened = id
    -- the item's link carries the variant's full name ("… des arkanen Zorns")
    local link = linkOf(location)
    if ns.db then ns.db.sellInfoLink = { id = id, link = link and link:gsub("|", "!") or "nil", t = time() } end
    Detail.Show(link or id, { anchor = AuctionHouseFrame, origin = DETAIL_ORIGIN, skin = "blizzard", itemKey = itemKey })
  else
    opened = nil
    if mine then Detail.Hide() end
  end
end

-- The own Selling panel (Verkaufen/Sniper/Auktionen) steps aside while the sell frame shows.
local function sellingPanel(show)
  local panel = ns.Selling and ns.Selling.Frame and ns.Selling.Frame()
  if not panel then return end
  if show then
    if not ns.Selling.ENABLED then return end
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() and not panel:IsShown() then
      panel:Show()
      if ns.Selling.Refresh then ns.Safe(ns.Selling.Refresh) end
    end
  elseif panel:IsShown() then
    panel:Hide()
  end
end

local function attach(frame)
  if not frame or frame.m4SellInfo then return end
  -- Own layer above Blizzard's inset frames (a text on the sell frame itself lies under them).
  local holder = CreateFrame("Frame", nil, frame)
  holder:SetAllPoints(frame)
  holder:SetFrameStrata(frame:GetFrameStrata())
  holder:SetFrameLevel(frame:GetFrameLevel() + 50)
  local rows = { newRow(holder, frame, "Einkauf", 1), newRow(holder, frame, "Gewinn", 2) }
  frame.m4SellInfo = holder
  -- Layout check: what "Gesamtpreis" consists of in this client (saved variables).
  if ns.db and frame.TotalPrice then
    local keys = {}
    for k, v in pairs(frame.TotalPrice) do
      if type(v) == "table" and v.GetObjectType then keys[#keys + 1] = tostring(k) .. ":" .. v:GetObjectType() end
    end
    table.sort(keys)
    ns.db.sellInfoLayout = table.concat(keys, ", ")
  end
  if frame.SetItem then
    hooksecurefunc(frame, "SetItem", function(self, itemLocation) self.m4Location = itemLocation end)
  end
  -- The post button sits below the last shown row. Blizzard places it again when the frame
  -- shows (and on its own layout changes), so every check moves it again when needed.
  local button = frame.PostButton
  local function placeButton()
    if not (button and button.GetPoint and button:GetNumPoints() > 0) then return end
    local last = rows[2].label:IsShown() and rows[2].label or rows[1].label
    if not last:IsShown() then return end
    local top, bottom = button:GetTop(), last:GetBottom()
    if not (top and bottom) then return end
    local overlap = top - (bottom - 8)
    if overlap > 0.5 then
      local p, rel, rp, x, y = button:GetPoint(1)
      button:ClearAllPoints()
      button:SetPoint(p, rel, rp, x, (y or 0) - overlap)
    end
  end
  local function show(costText, profitText)
    rows[1].label:SetShown(costText ~= nil)
    rows[1].value:SetText(costText or "")
    rows[2].label:SetShown(profitText ~= nil)
    rows[2].value:SetText(profitText or "")
  end
  show(nil, nil)
  -- Price, quantity and item change while the frame is open: a light check five times a second.
  local elapsed, lastKey = 0, nil
  local function tick()
    local id, price, qty = itemOf(frame), unitPriceOf(frame), quantityOf(frame)
    local key = tostring(id) .. ":" .. tostring(price) .. ":" .. tostring(qty)
    if key ~= lastKey then
      lastKey = key
      show(SellInfo.Values(id, price, qty))
    end
    placeButton()
    sellingPanel(false)
    -- the full key of the item in the slot (a random suffix such as "des arkanen Zorns")
    local key, location = nil, id and locationOf(frame)
    if location and C_AuctionHouse and C_AuctionHouse.GetItemKeyFromItem then
      local ok, k = pcall(C_AuctionHouse.GetItemKeyFromItem, location)
      key = ok and k or nil
    end
    syncDetail(id, key, location)
  end
  holder:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.2 then return end
    elapsed = 0
    ns.Safe(tick)
  end)
  holder:SetScript("OnHide", function()
    lastKey = nil
    ns.Safe(syncDetail, nil)
    ns.Safe(sellingPanel, true)
  end)
end

-- Blizzard's tab "Auktionen": in each own auction's row, in the (empty) bid price column,
-- what one unit cost and what the auction brings after the cut:
--   Einstand 2g 88s
--   Gewinn +2g 81s        (green / red; nothing without a known cost or with a bid shown)
local function auctionsList(af)
  return rawget(af, "AllAuctionsList") or rawget(af, "ItemList")
end

local function forEachRow(list, fn)
  local box = rawget(list, "ScrollBox")
  if type(box) == "table" and box.ForEachFrame then
    box:ForEachFrame(fn)
    return
  end
  local sf = rawget(list, "ScrollFrame")
  for _, row in ipairs(type(sf) == "table" and rawget(sf, "buttons") or {}) do fn(row) end
end

-- Runs fn(row) right after Blizzard filled a row (scrolling recycles the row frames with other
-- data), so our cells never show the previous row's values or stay empty until the next timer
-- tick. Modern ScrollBox: initialized-frame callback; else after every list refresh.
local function onRowFilled(list, fn)
  if rawget(list, "m4RowHook") then return end
  list.m4RowHook = true
  -- TableBuilder:AddRow builds the row's cells (Populate runs before the cell is in row.cells),
  -- so the hook after AddRow sees every cell at its column index.
  local builder = rawget(list, "tableBuilder")
  if type(builder) == "table" and type(builder.AddRow) == "function" then
    hooksecurefunc(builder, "AddRow", function(_, row) ns.Safe(fn, row) end)
  end
  if list.RefreshScrollFrame then
    hooksecurefunc(list, "RefreshScrollFrame", function() forEachRow(list, function(row) ns.Safe(fn, row) end) end)
  end
end

local function rowData(row)
  local d = rawget(row, "rowData")
  if d == nil and row.GetRowData then
    local ok, v = pcall(row.GetRowData, row)
    d = ok and v or nil
  end
  if d == nil and row.GetElementData then
    local ok, v = pcall(row.GetElementData, row)
    d = ok and v or nil
  end
  return type(d) == "table" and d or nil
end

local function rowText(row)
  if row.m4Info then return row.m4Info end
  local layer = CreateFrame("Frame", nil, row)
  layer:SetAllPoints(row)
  layer:SetFrameLevel((row:GetFrameLevel() or 1) + 5)
  local fs = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("RIGHT")
  local cells = rawget(row, "cells")
  local cell = type(cells) == "table" and cells[2]
  if type(cell) == "table" and cell.GetObjectType then
    fs:SetPoint("RIGHT", cell, "RIGHT", -4, 0)
  else
    -- no cells table: the bid column starts right of the item name (about 62 % of the row)
    fs:SetPoint("RIGHT", row, "LEFT", (row:GetWidth() or 560) * 0.66, 0)
  end
  row.m4Info = fs
  return fs
end

function SellInfo.AuctionText(id, unit, qty)
  if not (id and unit and unit > 0 and ns.Profit and ns.Profit.UnitCost) then return nil end
  local cost, source = ns.Profit.UnitCost(id)
  if not cost then return nil end
  qty = qty or 1
  local profit = math.floor((unit * (1 - CUT) - cost) * qty)
  local short = function(c) return ns.FormatMoney(c, true) end
  return "|cff999999Einkauf " .. (source == "Beute" and "Beute" or short(math.floor(cost + 0.5))) .. "|r\n"
    .. (profit >= 0 and ("|cff5fd38dGewinn +" .. short(profit)) or ("|cffff6b6bGewinn -" .. short(-profit))) .. "|r"
end

-- Own columns: Blizzard builds the table from a layout function (AuctionHouseTableBuilder.
-- GetAllAuctionsLayout). It runs on a stand-in for the table builder that adds two text columns
-- "Einkauf" and "Gewinn" where Blizzard adds the bid price column (always empty when posting
-- with buyout only). The cells are filled from the rows' data (updateAuctionRows).
-- the bid column's cell template (Forever: "...AllAuctionsBid...", retail: "...AuctionsBid...")
local BID_TEMPLATES = { AuctionHouseTableCellAllAuctionsBidTemplate = true, AuctionHouseTableCellAuctionsBidTemplate = true }
local TEXT_TEMPLATE = "AuctionHouseTableCellTextTemplate"
local OWN_WIDTH = 82
local CANCEL_WIDTH = 66
SellInfo.columns = false -- true once the own columns are in the table

-- Our columns sort by nothing: no arrow, no click (Blizzard's header would sort by the price).
local function plainHeader(col, text)
  local header = col:GetHeaderFrame()
  header:SetText(text)
  if header.EnableMouse then header:EnableMouse(false) end
  local arrow = rawget(header, "Arrow")
  if type(arrow) == "table" and arrow.Hide then
    arrow:Hide()
    hooksecurefunc(arrow, "Show", function(self) self:Hide() end)
  end
end

local function silentColumn(col)
  -- the caller names the replaced column "Gebotspreis": that text is ignored, ours stays
  return setmetatable({ GetHeaderFrame = function()
    local header = col:GetHeaderFrame()
    return setmetatable({ SetText = function() end }, { __index = function(_, k)
      local v = header[k]
      if type(v) == "function" then return function(_, ...) return v(header, ...) end end
      return v
    end })
  end }, { __index = function(_, k)
    local v = col[k]
    if type(v) == "function" then return function(_, ...) return v(col, ...) end end
    return v
  end })
end

local wrapped = setmetatable({}, { __mode = "k" }) -- layout functions made by wrapLayout

local function trace(key, value)
  if not ns.db then return end
  ns.db.columnsTrace = ns.db.columnsTrace or {}
  ns.db.columnsTrace[key] = value
end

local function wrapLayout(original)
  local fn
  fn = function(tableBuilder)
    local replaced = false
    local seen = {}
    local function addOwn(method, ...)
      local args = { ... }
      local n = select("#", ...)
      local sig = {}
      for i = 1, n do sig[#sig + 1] = type(args[i]) == "string" and args[i] or type(args[i]) end
      seen[#seen + 1] = table.concat(sig, " ")
      for i = 1, n do
        if type(args[i]) == "string" and BID_TEMPLATES[args[i]] then
          for k = 1, n do
            if type(args[k]) == "number" and args[k] > 60 then args[k] = OWN_WIDTH break end -- the width
          end
          args[i] = TEXT_TEMPLATE
          local cost = method(tableBuilder, unpack(args, 1, n))
          local profit = method(tableBuilder, unpack(args, 1, n))
          -- third: what cancelling costs (the game's GetCancelCost)
          for k = 1, n do
            if args[k] == OWN_WIDTH then args[k] = CANCEL_WIDTH break end
          end
          local cancel = method(tableBuilder, unpack(args, 1, n))
          plainHeader(cost, "Einkauf")
          plainHeader(profit, "Gewinn")
          plainHeader(cancel, "Abbruch")
          replaced = true
          return silentColumn(cost)
        end
      end
      return method(tableBuilder, ...)
    end
    local calls = {}
    local proxy = setmetatable({}, { __index = function(_, k)
      local v = tableBuilder[k]
      if type(v) ~= "function" then return v end
      calls[#calls + 1] = tostring(k)
      if k == "AddFixedWidthColumn" or k == "AddUnsortableFixedWidthColumn" then
        return function(_, ...) return addOwn(v, ...) end
      end
      return function(_, ...) return v(tableBuilder, ...) end
    end })
    local ok, err = pcall(original, proxy)
    trace("layoutRan", time())
    trace("layoutOk", ok and true or tostring(err))
    trace("replaced", replaced)
    trace("calls", table.concat(calls, ","))
    trace("columns", table.concat(seen, " | "))
    -- (on an error the layout stays as far as it got: running it again would add columns twice)
    SellInfo.columns = ok and replaced
  end
  wrapped[fn] = true
  return fn
end

-- Every layout Blizzard sets on the list (on load, on showing, on switching views) is wrapped
-- right after it was set.
local function installColumns(af)
  local tb = rawget(_G, "AuctionHouseTableBuilder")
  local list = rawget(af, "AllAuctionsList")
  trace("install", time())
  if not (type(tb) == "table" and tb.GetAllAuctionsLayout and list and list.SetTableBuilderLayout) then
    trace("installMissing", true)
    return
  end
  if not list.m4Hooked then
    list.m4Hooked = true
    hooksecurefunc(list, "SetTableBuilderLayout", function(self, layout)
      if type(layout) == "function" and not wrapped[layout] then
        trace("blizzardSet", time())
        self:SetTableBuilderLayout(wrapLayout(layout))
      end
    end)
  end
  local current = rawget(list, "tableBuilderLayoutFunction")
  local ok, err = pcall(function()
    if type(current) == "function" and not wrapped[current] then
      list:SetTableBuilderLayout(wrapLayout(current))
    elseif type(current) ~= "function" then
      list:SetTableBuilderLayout(wrapLayout(tb.GetAllAuctionsLayout(af, list)))
    end
    if list.RefreshScrollFrame then list:RefreshScrollFrame() end
  end)
  trace("installOk", ok and true or tostring(err))
end

-- The text of a cell of the own columns.
local function cellText(cell)
  local t = rawget(cell, "Text")
  if type(t) == "table" and t.SetText then return t end
  if not cell.m4Text then
    cell.m4Text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.m4Text:SetPoint("RIGHT", cell, "RIGHT", -6, 0)
    cell.m4Text:SetJustifyH("RIGHT")
  end
  return cell.m4Text
end

-- Values of the two columns: cost of the units, profit after the cut ("" without a cost).
function SellInfo.AuctionValues(id, unit, qty)
  if not (id and unit and unit > 0 and ns.Profit and ns.Profit.UnitCost) then return "", "" end
  local cost, source = ns.Profit.UnitCost(id)
  if not cost then return "|cff999999–|r", "|cff999999–|r" end
  qty = qty or 1
  local profit = math.floor((unit * (1 - CUT) - cost) * qty)
  local fmt = function(c) return ns.FormatMoney(c, true) end
  return source == "Beute" and "|cff999999Beute|r" or fmt(math.floor(cost * qty + 0.5)),
    profit >= 0 and ("|cff5fd38d+" .. fmt(profit) .. "|r") or ("|cffff6b6b-" .. fmt(-profit) .. "|r")
end

-- Unit price of a row in the "Auktionen" tab. An active auction carries the price per unit in
-- buyoutAmount; a sold one ("Verkauft:") carries what the whole stack brought, so it is split
-- over the quantity.
local function isSold(d)
  local e = Enum and Enum.AuctionStatus
  local sold = e and e.Sold or 1 -- Retail: Active 0, Sold 1
  return d.status ~= nil and d.status == sold
end

function SellInfo.RowUnit(d)
  local buyout, qty = d.buyoutAmount, d.quantity or 1
  if buyout and qty > 1 and isSold(d) then return buyout / qty end
  return buyout
end

local probed = false
local function updateAuctionRow(row)
  local d = rowData(row)
  local key = d and d.itemKey
  local id = type(key) == "table" and key.itemID or nil
  local cells = rawget(row, "cells")
  if SellInfo.columns and type(cells) == "table" and cells[2] and cells[3] then
    local costText, profitText = "", ""
    if id then costText, profitText = SellInfo.AuctionValues(id, SellInfo.RowUnit(d), d.quantity) end
    cellText(cells[2]):SetText(costText or "")
    cellText(cells[3]):SetText(profitText or "")
    -- cancelling an active auction loses its deposit (a sale would give it back) plus what the
    -- game charges on top (GetCancelCost, 0 on Forever); the deposit from the logged posts
    if cells[4] then
      local text = ""
      local api = C_AuctionHouse
      if d and id and not isSold(d) then
        local lost = 0
        local per = ns.Profit and ns.Profit.DepositPerUnit and ns.Profit.DepositPerUnit(id)
        if per then lost = lost + per * (d.quantity or 1) end
        if d.auctionID and api and api.GetCancelCost then
          local ok, c = pcall(api.GetCancelCost, d.auctionID)
          if ok and c then lost = lost + c end
        end
        lost = math.floor(lost + 0.5)
        text = lost > 0 and ("|cffff6b6b-" .. ns.FormatMoney(lost, true) .. "|r") or (per and "|cff999999frei|r" or "|cff999999?|r")
      end
      cellText(cells[4]):SetText(text)
    end
    if row.m4Info then row.m4Info:SetText("") end
  else
    local text
    if id and not ((d.bidAmount or 0) > 0) then
      text = SellInfo.AuctionText(id, SellInfo.RowUnit(d), d.quantity)
    end
    local fs = row.m4Info
    if text or fs then rowText(row):SetText(text or "") end
  end
  if not probed and ns.db and d then
    probed = true
    local keys = {}
    for k, v in pairs(row) do if type(v) == "table" then keys[#keys + 1] = tostring(k) end end
    table.sort(keys)
    ns.db.auctionsProbe = { row = table.concat(keys, ","), data = (d.buyoutAmount and "buyout " or "") .. (d.quantity and "qty" or ""),
      t = time() }
  end
end

local function updateAuctionRows(af)
  local list = auctionsList(af)
  if not list then return end
  onRowFilled(list, updateAuctionRow)
  forEachRow(list, updateAuctionRow)
end

-- One-time probe of Blizzard's table building blocks in this client (saved variables), for the
-- own columns in the "Auktionen" tab.
local function probeTable(af)
  if not ns.db or (ns.db.tableProbe and ns.db.tableProbe.v == 1) then return end
  local out = { v = 1, t = time() }
  local tb = rawget(_G, "AuctionHouseTableBuilder")
  out.builder = type(tb)
  if type(tb) == "table" then
    local fns = {}
    for k, v in pairs(tb) do if type(v) == "function" then fns[#fns + 1] = k end end
    table.sort(fns)
    out.builderFns = table.concat(fns, ",")
  end
  local keys = {}
  for k, v in pairs(af) do
    if type(v) == "table" and v.GetObjectType then keys[#keys + 1] = tostring(k) end
  end
  table.sort(keys)
  out.auctionsFrame = table.concat(keys, ",")
  local list = auctionsList(af)
  if list then
    out.listSetLayout = list.SetTableBuilderLayout ~= nil
    out.listRefresh = list.RefreshScrollFrame ~= nil
    local lk = {}
    for k, v in pairs(list) do lk[#lk + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(lk)
    out.listKeys = table.concat(lk, ",")
    local builder = rawget(list, "tableBuilder")
    if type(builder) == "table" then
      local bk = {}
      for k, v in pairs(builder) do bk[#bk + 1] = tostring(k) .. ":" .. type(v) end
      local mt = getmetatable(builder)
      local idx = mt and mt.__index
      if type(idx) == "table" then for k in pairs(idx) do bk[#bk + 1] = "mt." .. tostring(k) end end
      table.sort(bk)
      out.tableBuilder = table.concat(bk, ",")
    end
  end
  local info = C_XMLUtil and C_XMLUtil.GetTemplateInfo
  local templates = {}
  for _, name in ipairs({ "AuctionHouseTableCellTemplate", "AuctionHouseTableCellTextTemplate",
      "AuctionHouseTableCellAuctionsItemTemplate", "AuctionHouseTableCellAuctionsBidTemplate",
      "AuctionHouseTableCellAuctionsBuyoutTemplate", "AuctionHouseTableCellTimeLeftTemplate",
      "AuctionHouseTableCellAuctionsTimeLeftTemplate", "AuctionHouseTableHeaderStringTemplate",
      "AuctionHousePriceDisplayTableCellTemplate", "AuctionHouseTableCellMoneyTemplate" }) do
    local ok, ti = pcall(function() return info and info(name) end)
    templates[#templates + 1] = name .. "=" .. tostring(ok and ti ~= nil)
  end
  out.templates = table.concat(templates, ",")
  for _, name in ipairs({ "AuctionHouseTableCellMixin", "AuctionHouseTablePriceCellMixin",
      "AuctionHouseTableCellAuctionsBidMixin", "AuctionHouseTableCellAuctionsBuyoutMixin",
      "AuctionHouseTableCellTextMixin" }) do
    out["mixin_" .. name] = type(rawget(_G, name))
  end
  ns.db.tableProbe = out
end

local function attachAuctions()
  local af = AuctionHouseFrame and rawget(AuctionHouseFrame, "AuctionsFrame")
  if type(af) == "table" then ns.Safe(probeTable, af) end
  if type(af) ~= "table" or af.m4Rows then return end
  local layer = CreateFrame("Frame", nil, af)
  af.m4Rows = layer
  -- after Blizzard's own OnShow (which sets its layout): ours on top
  af:HookScript("OnShow", function() ns.Safe(installColumns, af) end)
  if af:IsShown() then ns.Safe(installColumns, af) end
  local elapsed = 0
  layer:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.3 then return end
    elapsed = 0
    ns.Safe(updateAuctionRows, af)
  end)
end

-- Blizzard's tab "Kaufen" (browse results): right of the price two columns, "zu Marktwert"
-- (cheapest offer against R, the market value of yesterday: green from -10 %, red from +10 %)
-- and "Nachfrage" (ns.Item.DemandText). Same technique as the auction columns: every layout
-- Blizzard sets on the list is wrapped and gets the two text columns after its price column.
local BROWSE_WIDTH = 52
local browseWrapped = setmetatable({}, { __mode = "k" })

local function wrapBrowseLayout(original, list)
  local fn
  fn = function(tableBuilder)
    local count, added = 0, false
    local cols = {}
    local function addColumn(method, ...)
      count = count + 1
      local col = method(tableBuilder, ...)
      if added then return col end
      local args = { ... }
      local n = select("#", ...)
      local isPrice = false
      for i = 1, n do
        if type(args[i]) == "string" and args[i]:find("Price") then isPrice = true end
      end
      if isPrice then
        added = true
        for i = 1, n do
          if type(args[i]) == "string" then
            args[i] = TEXT_TEMPLATE
          end
        end
        local widthSet = false
        for i = 1, n do
          if not widthSet and type(args[i]) == "number" and args[i] > 60 then args[i] = BROWSE_WIDTH; widthSet = true end
        end
        if method == tableBuilder.AddFillColumn then
          method = tableBuilder.AddFixedWidthColumn -- a fill price column: ours are fixed
        end
        local pct = method(tableBuilder, unpack(args, 1, n))
        local demand = method(tableBuilder, unpack(args, 1, n))
        plainHeader(pct, "± MW")
        plainHeader(demand, "Nachfr.")
        count = count + 2
        cols.pct, cols.demand = count - 1, count
      end
      return col
    end
    local proxy = setmetatable({}, { __index = function(_, k)
      local v = tableBuilder[k]
      if type(v) ~= "function" then return v end
      if type(k) == "string" and k:find("^Add") and k:find("Column") then
        return function(_, ...) return addColumn(v, ...) end
      end
      return function(_, ...) return v(tableBuilder, ...) end
    end })
    local ok, err = pcall(original, proxy)
    trace("browseLayouts", ((ns.db and ns.db.columnsTrace and ns.db.columnsTrace.browseLayouts) or 0) + 1)
    if not ok then
      trace("browseError", tostring(err)) -- the layout stays as far as it got (never twice)
      list.m4Cols = nil
      return
    end
    list.m4Cols = added and cols or nil
  end
  browseWrapped[fn] = true
  return fn
end

local function installBrowse(list)
  if not (list and list.SetTableBuilderLayout) or list.m4BrowseHooked then return end
  list.m4BrowseHooked = true
  hooksecurefunc(list, "SetTableBuilderLayout", function(self, layout)
    if type(layout) == "function" and not browseWrapped[layout] then
      self:SetTableBuilderLayout(wrapBrowseLayout(layout, self))
    end
  end)
  local current = rawget(list, "tableBuilderLayoutFunction")
  if type(current) == "function" and not browseWrapped[current] then
    pcall(function()
      list:SetTableBuilderLayout(wrapBrowseLayout(current, list))
      if list.RefreshScrollFrame then list:RefreshScrollFrame() end
    end)
  end
end

-- The two values of a browse row: price against the market value, demand.
function SellInfo.BrowseValues(id, price)
  if not (id and ns.Item) then return "", "" end
  local item = ns.Item(id)
  local pctText = "|cff999999–|r"
  if price and price > 0 and item.ref and item.ref > 0 then
    local d = price / item.ref - 1
    local pct = math.floor(math.abs(d) * 100 + 0.5) * (d < 0 and -1 or 1)
    local text = string.format("%+d %%", pct)
    if d <= -0.10 then text = "|cff5fd38d" .. text .. "|r"
    elseif d >= 0.10 then text = "|cffff6b6b" .. text .. "|r"
    else text = "|cff999999" .. text .. "|r" end
    pctText = text
  end
  return pctText, ns.Item.DemandIcon(item) or "|cff999999–|r"
end

local function updateBrowseRow(list, row)
  local cols = list.m4Cols
  if not cols then return end
  local d = rowData(row)
  local cells = rawget(row, "cells")
  if type(cells) ~= "table" then return end
  local pc, dc = cells[cols.pct], cells[cols.demand]
  if not (pc and dc) then return end
  local key = d and d.itemKey
  local id = type(key) == "table" and key.itemID or nil
  local pctText, demandText = "", ""
  if id then pctText, demandText = SellInfo.BrowseValues(id, d.minPrice) end
  cellText(pc):SetText(pctText)
  cellText(dc):SetText(demandText)
end

local function updateBrowseRows(list)
  if not list.m4Cols then return end
  local fn = function(row) updateBrowseRow(list, row) end
  onRowFilled(list, fn)
  forEachRow(list, fn)
end

local function attachBrowse()
  local bf = AuctionHouseFrame and rawget(AuctionHouseFrame, "BrowseResultsFrame")
  local list = type(bf) == "table" and rawget(bf, "ItemList")
  if type(list) ~= "table" or bf.m4Browse then return end
  bf.m4Browse = true
  ns.Safe(installBrowse, list)
  local layer = CreateFrame("Frame", nil, bf)
  local elapsed = 0
  layer:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.3 then return end
    elapsed = 0
    ns.Safe(updateBrowseRows, list)
  end)
end

local function attachAll()
  local ah = AuctionHouseFrame
  if not ah then return end
  attach(ah.ItemSellFrame)
  attach(ah.CommoditiesSellFrame)
  attachAuctions()
  attachBrowse()
end

if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function()
    attachAll()
    -- The auction house UI loads on demand: its frames may only exist a moment later.
    if C_Timer then C_Timer.After(0.2, function() ns.Safe(attachAll) end) end
  end)
end
