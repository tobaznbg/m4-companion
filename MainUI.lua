-- MainUI: the main m4-companion window (flat, dark, dense tables).
-- Header with emblem, data status and close; navigation on the left; pages on the
-- right, each created on first use:
--   overview     gold, profit, own professions, best recipes, market, open auctions, trades
--   professions  crafting table (AHTable embed) + button to the skill planner
--   planner      skill planner for any crafting profession (ns.Planner via ns.Costs)
--   market       sub tabs Trends / Anlage / Händler (AHTable embeds)
--   ledger       profit and loss: key figures, areas with items, item trades, valued stock
--   analysis     market analysis from the collector (ns.MarketAnalysis)
--   settings     switches in ns.db.settings
-- Position, scale and last page in ns.db.mainui. Parts built elsewhere (ns.Profit,
-- ns.MarketAnalysis, ns.AHTable.Embed) are optional: every page shows without them.
-- Other files add pages with MainUI.RegisterPage(key, label, build, opts).
local ADDON, ns = ...

local MainUI = {}
ns.MainUI = MainUI

local Style = ns.Style

local WIDTH, HEIGHT = 1100, 680
local HEADER, SIDEBAR = 40, 170
local PAD, GAP = 14, 10
local PAGE_W = WIDTH - SIDEBAR - 2
local PAGE_H = HEIGHT - HEADER - 2
local INNER_W = PAGE_W - 2 * PAD
local TOOLBAR = 30
local ROW = 20
local TILE_H = 62
local CHART_DAYS = 30
local EMBLEM = "Interface\\AddOns\\m4-companion\\media\\emblem"
local FRAME_NAME = "M4CompanionMainFrame"

local GREEN, RED = "|cff5fd38d", "|cffff6b6b"
local CARD_BG = { 1, 1, 1, 0.025 }
local NO_ANALYSIS = "Analyse kommt mit den nächsten Daten"

local NAV = {
  { key = "overview", label = "Übersicht" },
  { key = "professions", label = "Berufe" },
  { key = "planner", label = "Skill-Planer", sub = true, parent = "professions" },
  { key = "market", label = "Markt" },
  { key = "trends", label = "Trends", sub = true, parent = "market" },
  { key = "invest", label = "Anlage", sub = true, parent = "market" },
  { key = "vendor", label = "Händler", sub = true, parent = "market" },
  { key = "ledger", label = "Handelsbuch" },
  { key = "analysis", label = "Analyse" },
  { key = "settings", label = "Einstellungen" },
}
local MARKET_SUBS = {
  { key = "trends", label = "Trends", table = "Trends" },
  { key = "invest", label = "Anlage", table = "Invest" },
  { key = "vendor", label = "Händler", table = "Vendor" },
}
local ALIASES = { handel = "ledger", berufe = "professions", markt = "market", analyse = "analysis",
  skill = "planner", planer = "planner" }

local KINDS = { buy = "Kauf", post = "Eingestellt", sale = "Verkauf", vendor = "Händler", expired = "Abgelaufen", cancelled = "Abgebrochen", craft = "Hergestellt" }
-- Auction durations of the post hooks (1/2/3) in seconds.
local DURATIONS = { [1] = 12 * 3600, [2] = 24 * 3600, [3] = 48 * 3600 }

-- the lines the tooltip still has (Tooltip.lua): price, guild sales, crafting profit, hint
local TOOLTIP_LINES = {
  { "price", "Preis" }, { "guildSales", "Gilde verkauft (echte Verkäufe)" }, { "crafting", "Crafting (Gewinn)" },
  { "recipe", "Crafting bei Rezept-Items (Gewinn des Produkts)" }, { "hint", "Hinweis „Alt+Klick: Details“" },
}

local frame, statusText
local nav = {}          -- sidebar buttons in NAV order
local navByKey = {}
local pages = {}
local current
local marketSub = "trends"
local ahShown = false   -- auction house open (search buttons in the planner)

-- Saved state --------------------------------------------------------------------

local function state()
  ns.db.mainui = ns.db.mainui or {}
  return ns.db.mainui
end

local function settings()
  ns.db.settings = ns.db.settings or {}
  local s = ns.db.settings
  s.tooltip = s.tooltip or {}
  if s.autoScan == nil then s.autoScan = true end   -- AuctionScan scans on AH open unless switched off
  for _, line in ipairs(TOOLTIP_LINES) do
    if s.tooltip[line[1]] == nil then s.tooltip[line[1]] = true end
  end
  return s
end

-- Formatting ---------------------------------------------------------------------

local function money(copper)
  return ns.FormatMoney(copper or 0, true)
end

local function signedMoney(copper)
  if type(copper) ~= "number" then return "–" end
  if copper > 0 then return GREEN .. "+" .. money(copper) .. "|r" end
  if copper < 0 then return RED .. money(copper) .. "|r" end
  return money(0)
end

local function pct(value, colored)
  if type(value) ~= "number" then return "–" end
  local text = string.format("%+.1f %%", value)
  if not colored or value == 0 then return text end
  return (value > 0 and GREEN or RED) .. text .. "|r"
end

local function startOfToday()
  local t = date("*t")
  t.hour, t.min, t.sec = 0, 0, 0
  return time(t)
end

-- Optional function of a module built elsewhere: its result, or nil if missing or failing.
local function optional(module, name, ...)
  local fn = type(module) == "table" and module[name]
  if type(fn) ~= "function" then return nil end
  local ok, result = ns.Safe(fn, ...)
  if ok then return result end
  return nil
end

local function analysis()
  local a = ns.MarketAnalysis
  if type(a) ~= "table" or type(a.summary) ~= "table" then return nil end
  return a
end

local function recipeName(professionID, recipeID)
  local data = ns.RecipeData and ns.RecipeData[professionID]
  local recipe = data and data.recipes and data.recipes[recipeID]
  return recipe and recipe[1], data and data.name, recipe and recipe[2]
end

-- Widgets ------------------------------------------------------------------------

local function muted(fs)
  fs:SetTextColor(unpack(Style.C.muted))
  return fs
end

local function pageTitle(page, text)
  local t = Style.Text(page, 15)
  t:SetPoint("TOPLEFT", PAD, -PAD - 6)
  t:SetText(text)
  return t
end

-- Card: faint panel with a border and an optional title.
local function card(parent, w, h, title)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(w, h)
  local bg = Style.Solid(f, CARD_BG)
  bg:SetAllPoints()
  Style.Border(f)
  if title then
    f.title = Style.Text(f, 12)
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetText(Style.HEAD .. title .. "|r")
  end
  return f
end

-- Key figure: label, big value, small line under it.
local function tile(parent, w, label)
  local f = card(parent, w, TILE_H)
  f.label = Style.Text(f, 11)
  f.label:SetPoint("TOPLEFT", 10, -8)
  muted(f.label):SetText(label)
  f.value = Style.Text(f, 18)
  f.value:SetPoint("TOPLEFT", 10, -23)
  f.value:SetWidth(w - 20)
  f.value:SetJustifyH("LEFT")
  f.sub = muted(Style.Text(f, 11))
  f.sub:SetPoint("TOPLEFT", 10, -45)
  f.sub:SetWidth(w - 20)
  f.sub:SetJustifyH("LEFT")
  function f:Set(value, sub)
    self.value:SetText(value or "–")
    self.sub:SetText(sub or "")
  end
  return f
end

-- Table: header row and striped rows.
--   columns  { { title, width (0 = takes the rest), align }... }
--   opts     { scroll = true }
-- A column given as { title, width, align, true } is the item column: rows with
-- data.itemID show the item icon there and the item tooltip on hover. A column with
-- button = true holds a small button per row, shown for rows with data.button.
-- g:SetRows(list, emptyText): list of { cell texts..., itemID = n, color = {r,g,b} (first cell),
-- onClick = fn, span = text (one line over the whole width, or up to column spanTo; the
-- cells after it keep their texts), button = { label, fn } }.
-- g:SetRows(list, emptyText, keepScroll): keepScroll keeps the scroll position (toggles).
local function grid(parent, w, h, columns, opts)
  opts = opts or {}
  local g = CreateFrame("Frame", nil, parent)
  g:SetSize(w, h)
  local inner = w - (opts.scroll and 10 or 0)
  local fixed = 0
  for _, c in ipairs(columns) do fixed = fixed + (c[2] or 0) end
  local xs, ws, x = {}, {}, 0
  local itemCol
  for i, c in ipairs(columns) do if c[4] then itemCol = i end end
  for i, c in ipairs(columns) do
    local cw = (c[2] and c[2] > 0) and c[2] or math.max(40, inner - fixed)
    xs[i], ws[i] = x, cw
    x = x + cw
  end

  local head = Style.Solid(g, Style.C.header, "BACKGROUND", 1)
  head:SetPoint("TOPLEFT")
  head:SetPoint("TOPRIGHT")
  head:SetHeight(ROW)
  for i, c in ipairs(columns) do
    local t = muted(Style.Text(g, 11))
    t:SetPoint("TOPLEFT", xs[i] + 6, -5)
    t:SetWidth(ws[i] - 12)
    t:SetJustifyH(c[3] or "LEFT")
    t:SetText(c[1])
  end

  local body
  if opts.scroll then
    local scroll
    scroll, body = Style.Scroll(g)
    scroll:SetPoint("TOPLEFT", 0, -ROW)
    scroll:SetPoint("BOTTOMRIGHT", -10, 0)
    body:SetSize(inner, 1)
    g.scroll = scroll
  else
    body = CreateFrame("Frame", nil, g)
    body:SetPoint("TOPLEFT", 0, -ROW)
    body:SetSize(inner, math.max(1, h - ROW))
  end
  local empty = muted(Style.Text(g, 12))
  empty:SetPoint("TOPLEFT", 6, -(ROW + 6))

  local rows = {}
  local function rowAt(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, body)
    r:SetSize(inner, ROW)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
    r.stripe = Style.Solid(r, Style.C.row)
    r.stripe:SetAllPoints()
    r.stripe:SetShown(i % 2 == 0)
    r.hover = Style.Solid(r, Style.C.hover, "ARTWORK")
    r.hover:SetAllPoints()
    r.hover:Hide()
    r.cells = {}
    for c = 1, #columns do
      local t = Style.Text(r, 12)
      t:SetPoint("LEFT", xs[c] + 6, 0)
      t:SetWidth(ws[c] - 12)
      t:SetJustifyH(columns[c][3] or "LEFT")
      r.cells[c] = t
    end
    for c, def in ipairs(columns) do
      if def.button then
        r.button = Style.Button(r, "", ws[c] - 8, ROW - 4, function(self) if self.fn then ns.Safe(self.fn) end end)
        r.button:SetPoint("LEFT", xs[c] + 4, 0)
        r.button:Hide()
      end
    end
    if itemCol then
      r.icon = r:CreateTexture(nil, "ARTWORK")
      r.icon:SetSize(ROW - 6, ROW - 6)
      r.icon:SetPoint("LEFT", xs[itemCol] + 4, 0)
    end
    r:SetScript("OnEnter", function(self)
      if self.onClick or self.itemID then self.hover:Show() end
      if self.itemID then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
      end
    end)
    r:SetScript("OnLeave", function(self) self.hover:Hide(); GameTooltip:Hide() end)
    -- Alt+click on an item row: item detail window (ItemDetail.lua); a plain click keeps onClick.
    r:SetScript("OnClick", function(self)
      if self.itemID and ns.ItemDetail and ns.ItemDetail.AltClick(self.itemID) then return end
      if self.onClick then ns.Safe(self.onClick) end
    end)
    rows[i] = r
    return r
  end

  function g:SetRows(list, emptyText, keepScroll)
    for i, data in ipairs(list) do
      local r = rowAt(i)
      for c, cell in ipairs(r.cells) do
        cell:SetText(tostring(data[c] or ""))
        cell:SetTextColor(unpack(Style.C.text))
      end
      if data.color then r.cells[1]:SetTextColor(unpack(data.color)) end
      r.itemID = data.itemID
      if r.spanned then
        r.cells[1]:ClearAllPoints()
        r.cells[1]:SetPoint("LEFT", xs[1] + 6, 0)
        r.cells[1]:SetWidth(ws[1] - 12)
        r.spanned = false
      end
      if r.icon then
        local cell = r.cells[itemCol]
        cell:ClearAllPoints()
        if data.itemID then
          local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
          r.icon:SetTexture(getIcon and getIcon(data.itemID) or nil)
          r.icon:Show()
          cell:SetPoint("LEFT", xs[itemCol] + ROW, 0)
          cell:SetWidth(ws[itemCol] - ROW - 6)
        else
          r.icon:Hide()
          cell:SetPoint("LEFT", xs[itemCol] + 6, 0)
          cell:SetWidth(ws[itemCol] - 12)
        end
      end
      if data.span then
        local last = data.spanTo or #columns
        for c, cell in ipairs(r.cells) do
          if c <= last then cell:SetText("") end
        end
        if r.icon then r.icon:Hide() end
        r.cells[1]:ClearAllPoints()
        r.cells[1]:SetPoint("LEFT", 6, 0)
        r.cells[1]:SetWidth((last >= #columns and inner or xs[last] + ws[last]) - 12)
        r.cells[1]:SetText(data.span)
        r.spanned = true
      end
      if r.button then
        r.button.fn = data.button and data.button.fn
        if data.button then r.button.label:SetText(data.button.label) end
        r.button:SetShown(data.button ~= nil)
      end
      r.onClick = data.onClick
      r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    empty:SetText(#list == 0 and (emptyText or "") or "")
    body:SetHeight(math.max(1, #list * ROW))
    if g.scroll then
      local top = 0
      if keepScroll then
        top = math.max(0, math.min(g.scroll:GetVerticalScroll() or 0, #list * ROW - (h - ROW)))
      end
      g.scroll:SetVerticalScroll(top)
      g.scroll.UpdateBar()
    end
  end
  return g
end

-- Label/value lines (e.g. market in short).
local function pairsList(parent, n, w)
  local list = { lines = {} }
  for i = 1, n do
    local label = muted(Style.Text(parent, 12))
    label:SetPoint("TOPLEFT", 10, -30 - (i - 1) * ROW)
    local value = Style.Text(parent, 12)
    value:SetPoint("TOPRIGHT", -10, -30 - (i - 1) * ROW)
    value:SetWidth(w - 150)
    value:SetJustifyH("RIGHT")
    list.lines[i] = { label = label, value = value }
  end
  function list:Set(items)
    for i, line in ipairs(self.lines) do
      local item = items[i]
      line.label:SetText(item and item[1] or "")
      line.value:SetText(item and item[2] or "")
    end
  end
  return list
end

-- Chart drawn with textures: kind "bars" or "line". c:SetData(values, opts) with
-- opts = { fmt = fn(value) -> text, first = label, last = label,
--          certain = { part of each bar that is certain (number) or false } }.
local function chart(parent, w, h, kind)
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(w, h)
  local LABEL = 14
  local plotH = h - 2 * LABEL
  local base = Style.Solid(c, Style.C.border, "BORDER")
  base:SetPoint("BOTTOMLEFT", 0, LABEL)
  base:SetPoint("BOTTOMRIGHT", 0, LABEL)
  base:SetHeight(1)
  c.maxLabel = muted(Style.Text(c, 10))
  c.maxLabel:SetPoint("TOPLEFT", 0, 0)
  c.lastLabel = Style.Text(c, 10)
  c.lastLabel:SetPoint("TOPRIGHT", 0, 0)
  c.firstDay = muted(Style.Text(c, 10))
  c.firstDay:SetPoint("BOTTOMLEFT", 0, 0)
  c.lastDay = muted(Style.Text(c, 10))
  c.lastDay:SetPoint("BOTTOMRIGHT", 0, 0)
  local pool = { back = {}, front = {}, lines = {}, dots = {} }

  local function texture(list, i, color, layer)
    if not list[i] then list[i] = Style.Solid(c, color, layer or "ARTWORK") end
    list[i]:Show()
    return list[i]
  end
  local function hideFrom(list, n)
    for i = n, #list do list[i]:Hide() end
  end

  function c:SetData(values, opts)
    opts = opts or {}
    local fmt = opts.fmt or tostring
    local n = #values
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(values) do lo, hi = math.min(lo, v), math.max(hi, v) end
    self.firstDay:SetText(opts.first or "")
    self.lastDay:SetText(opts.last or "")
    self.maxLabel:SetText(n > 0 and fmt(hi) or "")
    self.lastLabel:SetText(n > 0 and fmt(values[n]) or "")
    local accent = Style.C.accent
    if kind == "bars" then
      local gap = n > 40 and 1 or 2
      local bw = n > 0 and math.max(1, (w - gap * (n - 1)) / n) or 0
      local top = math.max(hi, 0)
      for i, v in ipairs(values) do
        local height = top > 0 and math.max(v > 0 and 1 or 0, v / top * plotH) or 0
        local x = (i - 1) * (bw + gap)
        local back = texture(pool.back, i, { accent[1], accent[2], accent[3], 0.35 })
        back:ClearAllPoints()
        back:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x, LABEL + 1)
        back:SetSize(bw, math.max(0.01, height))
        back:SetShown(height > 0)
        local certain = opts.certain and opts.certain[i]
        local share = 1
        if certain == false then share = 0
        elseif type(certain) == "number" and v > 0 then share = math.max(0, math.min(1, certain / v)) end
        local front = texture(pool.front, i, accent, "OVERLAY")
        front:ClearAllPoints()
        front:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x, LABEL + 1)
        front:SetSize(bw, math.max(0.01, height * share))
        front:SetShown(height * share > 0)
      end
      hideFrom(pool.back, n + 1)
      hideFrom(pool.front, n + 1)
    else
      if hi == lo then hi, lo = hi + 1, lo - 1 end
      local step = n > 1 and w / (n - 1) or 0
      local points = {}
      for i, v in ipairs(values) do
        points[i] = { (i - 1) * step, LABEL + 1 + (v - lo) / (hi - lo) * (plotH - 2) }
      end
      local lines = 0
      if c.CreateLine then
        for i = 2, n do
          lines = i - 1
          local line = pool.lines[lines]
          if not line then
            line = c:CreateLine(nil, "ARTWORK")
            line:SetThickness(2)
            line:SetColorTexture(unpack(accent))
            pool.lines[lines] = line
          end
          line:SetStartPoint("BOTTOMLEFT", c, points[i - 1][1], points[i - 1][2])
          line:SetEndPoint("BOTTOMLEFT", c, points[i][1], points[i][2])
          line:Show()
        end
      end
      hideFrom(pool.lines, lines + 1)
      for i, p in ipairs(points) do
        local dot = texture(pool.dots, i, accent, "OVERLAY")
        dot:ClearAllPoints()
        dot:SetSize(3, 3)
        dot:SetPoint("CENTER", c, "BOTTOMLEFT", p[1], p[2])
      end
      hideFrom(pool.dots, n + 1)
    end
  end
  return c
end

-- Flat toggle: square box (accent when on) and a label.
local function toggle(parent, label, get, set)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(360, 24)
  local box = CreateFrame("Frame", nil, b)
  box:SetSize(14, 14)
  box:SetPoint("LEFT", 0, 0)
  local boxBg = Style.Solid(box, Style.C.button)
  boxBg:SetAllPoints()
  Style.Border(box)
  local fill = Style.Solid(box, Style.C.accent, "ARTWORK")
  fill:SetPoint("TOPLEFT", 3, -3)
  fill:SetPoint("BOTTOMRIGHT", -3, 3)
  b.label = Style.Text(b, 12)
  b.label:SetPoint("LEFT", box, "RIGHT", 10, 0)
  b.label:SetText(label)
  function b:Update() fill:SetShown(get() and true or false) end
  b:SetScript("OnClick", function(self)
    set(not get())
    self:Update()
  end)
  b:SetScript("OnEnter", function() boxBg:SetColorTexture(unpack(Style.C.buttonHi)) end)
  b:SetScript("OnLeave", function() boxBg:SetColorTexture(unpack(Style.C.button)) end)
  b:Update()
  return b
end

local function setButtonActive(b, active)
  b.active = active
  b.bg:SetColorTexture(unpack(active and Style.C.buttonHi or Style.C.button))
  b.label:SetTextColor(unpack(active and Style.C.accent or Style.C.text))
end

-- Ledger data --------------------------------------------------------------------

local function ledgerEvents(n)
  return optional(ns.Ledger, "Recent", n) or {}
end

local function eventRow(e)
  local amount = "–"
  if e.k == "buy" then
    amount = RED .. "-" .. money(e.c) .. "|r"
  elseif e.k == "sale" then
    amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
  elseif e.k == "vendor" then
    amount = GREEN .. "+" .. money(e.c or 0) .. "|r"
  elseif e.k == "post" and e.p then
    amount = Style.MUTED .. money(e.p * (e.u or 1)) .. "|r"
  end
  local name = e.n or (e.i and ns.ItemName(e.i)) or "?"
  return { date("%d.%m. %H:%M", e.t or 0), KINDS[e.k] or tostring(e.k), name, tostring(e.u or 1), amount,
    itemID = e.i }
end

-- Auctions that are probably still running (rough): posts within their duration whose
-- units were not yet matched by a sale, expiry or cancel mail of the same item.
local function openAuctions()
  local all = optional(ns.Ledger, "Events")
  local events = {}
  if type(all) == "table" then
    for i = #all, 1, -1 do events[#events + 1] = all[i] end   -- newest first, like Recent
  else
    events = ledgerEvents(3000)
  end
  local now, since = time(), time() - DURATIONS[3] - 3600
  local queues, order = {}, {}
  for i = #events, 1, -1 do   -- oldest first
    local e = events[i]
    if (e.t or 0) >= since then
      local key = e.i or e.n
      if key then
        local q = queues[key]
        if not q then
          q = {}
          queues[key] = q
          table.insert(order, key)
        end
        if e.k == "post" then
          table.insert(q, { e = e, u = e.u or 1, ends = (e.t or now) + (DURATIONS[e.d] or DURATIONS[3]) })
        elseif e.k == "sale" or e.k == "expired" or e.k == "cancelled" then
          local units = e.u or 1
          while units > 0 and #q > 0 do
            local take = math.min(units, q[1].u)
            q[1].u, units = q[1].u - take, units - take
            if q[1].u <= 0 then table.remove(q, 1) end
          end
        end
      end
    end
  end
  local list, units, value = {}, 0, 0
  for _, key in ipairs(order) do
    for _, p in ipairs(queues[key]) do
      if p.u > 0 and p.ends > now then
        local worth = (p.e.p or 0) * p.u
        units, value = units + p.u, value + worth
        table.insert(list, { e = p.e, u = p.u, ends = p.ends, worth = worth })
      end
    end
  end
  table.sort(list, function(a, b) return a.ends < b.ends end)
  return list, units, value
end

-- Pages --------------------------------------------------------------------------

local PAGES = {}

-- Overview.
PAGES.overview = function(p)
  pageTitle(p, "Übersicht")
  local y = -(PAD + TOOLBAR + 6)
  local tw = (INNER_W - 3 * GAP) / 4
  local gold = tile(p, tw, "Gold")
  gold:SetPoint("TOPLEFT", PAD, y)
  local today = tile(p, tw, "Gewinn heute")
  today:SetPoint("TOPLEFT", gold, "TOPRIGHT", GAP, 0)
  local week = tile(p, tw, "Gewinn 7 Tage")
  week:SetPoint("TOPLEFT", today, "TOPRIGHT", GAP, 0)
  local stock = tile(p, tw, "Bestand (Wert)")
  stock:SetPoint("TOPLEFT", week, "TOPRIGHT", GAP, 0)

  y = y - TILE_H - GAP
  local colW = (INNER_W - GAP) / 2
  local avail = PAGE_H + y - PAD

  local profH, recipeH = 166, 112
  local profCard = card(p, colW, profH, "Deine Berufe")
  profCard:SetPoint("TOPLEFT", PAD, y)
  local profLines = {}
  for i = 1, 5 do
    local top = -30 - (i - 1) * 26
    local name = Style.Text(profCard, 12)
    name:SetPoint("TOPLEFT", 10, top)
    local rank = Style.Text(profCard, 12)
    rank:SetPoint("TOPRIGHT", -10, top)
    local track = Style.Solid(profCard, { 1, 1, 1, 0.06 }, "ARTWORK")
    track:SetPoint("TOPLEFT", 10, top - 15)
    track:SetSize(colW - 20, 3)
    local bar = Style.Solid(profCard, Style.C.accent, "OVERLAY")
    bar:SetPoint("TOPLEFT", track, "TOPLEFT")
    bar:SetHeight(3)
    profLines[i] = { name = name, rank = rank, track = track, bar = bar }
  end
  local profEmpty = muted(Style.Text(profCard, 12))
  profEmpty:SetPoint("TOPLEFT", 10, -30)

  local recipeCard = card(p, colW, recipeH, "Lohnt sich gerade")
  recipeCard:SetPoint("TOPLEFT", profCard, "BOTTOMLEFT", 0, -GAP)
  local recipes = grid(recipeCard, colW - 2, recipeH - 30, {
    { "Rezept", 0, nil, true }, { "Beruf", 110 }, { "Gewinn", 100, "RIGHT" } })
  recipes:SetPoint("TOPLEFT", 1, -29)

  local marketCard = card(p, colW, avail - profH - recipeH - 2 * GAP, "Markt")
  marketCard:SetPoint("TOPLEFT", recipeCard, "BOTTOMLEFT", 0, -GAP)
  local market = pairsList(marketCard, 4, colW)
  local marketEmpty = muted(Style.Text(marketCard, 12))
  marketEmpty:SetPoint("TOPLEFT", 10, -30)

  local openH = 200
  local openCard = card(p, colW, openH, "Offene Auktionen")
  openCard:SetPoint("TOPLEFT", PAD + colW + GAP, y)
  local openInfo = muted(Style.Text(openCard, 11))
  openInfo:SetPoint("TOPRIGHT", -10, -9)
  local open = grid(openCard, colW - 2, openH - 30, {
    { "Item", 0, nil, true }, { "Menge", 50, "RIGHT" }, { "Wert", 100, "RIGHT" }, { "Endet", 60, "RIGHT" } })
  open:SetPoint("TOPLEFT", 1, -29)

  local recentCard = card(p, colW, avail - openH - GAP, "Letzte Vorgänge")
  recentCard:SetPoint("TOPLEFT", openCard, "BOTTOMLEFT", 0, -GAP)
  local recent = grid(recentCard, colW - 2, avail - openH - GAP - 30, {
    { "Zeit", 82 }, { "Art", 76 }, { "Item", 0, nil, true }, { "Menge", 44, "RIGHT" }, { "Betrag", 92, "RIGHT" } })
  recent:SetPoint("TOPLEFT", 1, -29)

  function p:Refresh()
    gold:Set(money(GetMoney()))
    local dayTotals = optional(ns.Profit, "Totals", startOfToday())
    local weekTotals = optional(ns.Profit, "Totals", time() - 7 * 86400)
    local allTotals = optional(ns.Profit, "Totals", 0)
    today:Set(dayTotals and signedMoney(dayTotals.profit),
      dayTotals and ("Erlöse " .. money(dayTotals.revenue)) or "")
    week:Set(weekTotals and signedMoney(weekTotals.profit),
      weekTotals and ("Erlöse " .. money(weekTotals.revenue)) or "")
    stock:Set(allTotals and allTotals.stockValue and money(allTotals.stockValue) or "–")

    local char = ns.db.chars and ns.db.chars[ns.CharKey()]
    local profs = char and char.professions or {}
    for i, line in ipairs(profLines) do
      local prof = profs[i]
      line.name:SetText(prof and prof.name or "")
      line.rank:SetText(prof and string.format("%d / %d", prof.rank or 0, prof.max or 0) or "")
      line.track:SetShown(prof ~= nil)
      local share = prof and (prof.max or 0) > 0 and math.min(1, (prof.rank or 0) / prof.max) or 0
      line.bar:SetWidth(math.max(0.01, (colW - 20) * share))
      line.bar:SetShown(share > 0)
    end
    profEmpty:SetText(#profs == 0 and "Noch keine Berufe erfasst" or "")

    local best = {}
    local stats = ns.ProfessionStats and ns.ProfessionStats.professions or {}
    for pid, s in pairs(stats) do
      local name, profName, itemID = recipeName(pid, s[2])
      if name and (s[3] or 0) > 0 then
        table.insert(best, { name, profName or "", money(s[3]), profit = s[3], itemID = itemID,
          onClick = function() MainUI.Show("professions") end })
      end
    end
    table.sort(best, function(a, b) return a.profit > b.profit end)
    for i = #best, 4, -1 do best[i] = nil end
    recipes:SetRows(best, "Noch keine Berufsdaten")

    local a = analysis()
    if a then
      local s = a.summary
      market:Set({
        { "Umsatz 7 Tage", (s.turnover7d and money(s.turnover7d) or "–") .. "  " .. pct(s.turnoverChangePct, true) },
        { "Angebote", pct(s.offersChangePct) },
        { "Inflation", pct(s.inflationPct) },
        { "Top-Beruf", s.topProfession and s.topProfession.name or "–" },
      })
      marketEmpty:SetText("")
    else
      market:Set({})
      marketEmpty:SetText(NO_ANALYSIS)
    end

    local list, units, value = openAuctions()
    local rows = {}
    for i = 1, math.min(#list, 7) do
      local o = list[i]
      table.insert(rows, { o.e.n or (o.e.i and ns.ItemName(o.e.i)) or "?", tostring(o.u),
        o.worth > 0 and money(o.worth) or "–", date("%H:%M", o.ends), itemID = o.e.i })
    end
    open:SetRows(rows, "Keine offenen Auktionen")
    openInfo:SetText(#list > 0 and string.format("%d Stück · %s", units, money(value)) or "")

    rows = {}
    for _, e in ipairs(ledgerEvents(8)) do table.insert(rows, eventRow(e)) end
    recent:SetRows(rows, "Noch keine Vorgänge")
  end
end

-- Embedded auction table in `holder`, created on first success.
local function embed(holder, id)
  if not holder.table then
    local t = optional(ns.AHTable, "Embed", id, holder, { detailAnchor = frame })
    if t then
      holder.table = t
      if t.GetNumPoints and t:GetNumPoints() == 0 then t:SetAllPoints(holder) end
      holder.missing:SetText("")
    else
      holder.missing:SetText("Tabelle nicht verfügbar")
    end
  end
  if holder.table then
    holder.table:Show()
    if holder.table.Refresh then ns.Safe(holder.table.Refresh, holder.table) end
  end
end

local function holderFrame(p)
  local h = CreateFrame("Frame", nil, p)
  h:SetPoint("TOPLEFT", PAD, -(PAD + TOOLBAR + 6))
  h:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  h.missing = muted(Style.Text(h, 12))
  h.missing:SetPoint("TOPLEFT", 6, -6)
  return h
end

-- Professions.
PAGES.professions = function(p)
  pageTitle(p, "Berufe")
  local planner = Style.Button(p, "Skill-Planer", 100, 22, function() MainUI.Show("planner") end)
  planner:SetPoint("TOPRIGHT", -PAD, -PAD - 2)
  local holder = holderFrame(p)
  function p:Refresh() embed(holder, "Crafting") end
end

-- Market with sub tabs.
PAGES.market = function(p)
  local title = pageTitle(p, "Markt")
  local tabs, holders = {}, {}
  local anchor, offset = title, 24
  for _, sub in ipairs(MARKET_SUBS) do
    local tab = Style.Tab(p, sub.label, 84, function() MainUI.Show(sub.key) end)
    tab:SetPoint("LEFT", anchor, "RIGHT", offset, 0)
    anchor, offset = tab, 2
    tabs[sub.key] = tab
    holders[sub.key] = holderFrame(p)
  end
  function p:Refresh()
    for _, sub in ipairs(MARKET_SUBS) do
      local active = sub.key == marketSub
      tabs[sub.key]:SetActive(active)
      holders[sub.key]:SetShown(active)
      if active then embed(holders[sub.key], sub.table) end
    end
  end
end

-- Ledger: profit and loss of a period, all numbers from ns.Profit.Report.
--   figures  period: revenue, purchases, cut, lost deposits, result; stock now: units,
--            cost, selling after the cut (Item.SellNet), book gain (Buchgewinn)
--   areas    professions, trade, farmed; a click opens / closes the items of an area
--            (ns.db.mainui.ledgerOpen); a click on an item shows its trades below
--   below    recent trades, the trades of the clicked item, or the valued stock
local PERIODS = {
  { key = "today", label = "Heute", since = function() return startOfToday() end },
  { key = "week", label = "7 Tage", since = function() return time() - 7 * 86400 end },
  { key = "all", label = "Alles", since = function() return 0 end },
}
local ITEM_KINDS = { buy = "gekauft", craft = "hergestellt", post = "eingestellt", cancelled = "abgebrochen",
  expired = "abgelaufen", sale = "verkauft", vendor = "an Händler" }
local AREA_COLOR = { 0.85, 0.79, 0.64, 1 }
local FIG_H = 56

local function units(n) return string.format("%d", math.floor((n or 0) + 0.5)) end
local function count(n) return (type(n) == "number" and n > 0) and units(n) or "–" end
local function moneyOr(copper) return type(copper) == "number" and money(copper) or "–" end
local function lostMoney(copper) return (copper or 0) > 0 and money(copper) or "–" end
local function backText(r)
  if (r.expired or 0) == 0 and (r.cancelled or 0) == 0 then return "–" end
  return string.format("%d / %d", r.expired or 0, r.cancelled or 0)
end

-- One trade of the clicked item (ns.Profit.ItemEvents).
local function itemEventRow(e, itemID)
  local amount, detail = "–", ""
  if e.k == "buy" then
    amount = RED .. "-" .. money(e.c) .. "|r"
    if (e.u or 0) > 0 and e.c then detail = "je " .. money(e.c / e.u) end
  elseif e.k == "sale" then
    amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
    detail = "brutto " .. money(e.c) .. ", AH-Gebühr " .. money(e.cut)
  elseif e.k == "vendor" then
    amount = GREEN .. "+" .. money(e.c or 0) .. "|r"
    if (e.u or 0) > 0 and e.c then detail = "je " .. money(e.c / e.u) end
  elseif e.k == "post" then
    local parts = {}
    if e.p then table.insert(parts, "je " .. money(e.p)) end
    if e.dep then table.insert(parts, "Einstellgebühr " .. money(e.dep)) end
    detail = table.concat(parts, ", ")
  elseif (e.k == "expired" or e.k == "cancelled") and e.lost then
    amount = RED .. "-" .. money(e.lost) .. "|r"
    detail = "Einstellgebühr verloren"
  end
  return { date("%d.%m. %H:%M", e.t or 0), ITEM_KINDS[e.k] or tostring(e.k), units(e.u or 1), amount,
    Style.MUTED .. detail .. "|r", itemID = itemID }
end

-- Card of key figures side by side: label, value, small line. cols = { { label, width }... }
local function figureCard(parent, cols)
  local w = 0
  for _, c in ipairs(cols) do w = w + c[2] end
  local f = card(parent, w, FIG_H)
  f.cols = {}
  local x = 0
  for i, c in ipairs(cols) do
    local col = {}
    col.label = muted(Style.Text(f, 11))
    col.value = Style.Text(f, 14)
    col.sub = muted(Style.Text(f, 10))
    for line, top in pairs({ label = -7, value = -21, sub = -39 }) do
      col[line]:SetPoint("TOPLEFT", x + 10, top)
      col[line]:SetWidth(c[2] - 14)
      col[line]:SetJustifyH("LEFT")
    end
    col.label:SetText(c[1])
    f.cols[i] = col
    x = x + c[2]
  end
  function f:Set(i, value, sub)
    self.cols[i].value:SetText(value or "–")
    self.cols[i].sub:SetText(sub or "")
  end
  return f
end

-- Stock of the ledger page as a generic table (sortable, filterable); a click shows the
-- item's trades on the ledger page (stockClick, set by the page).
local stockClick
if ns.AHTable and ns.AHTable.Add then
  local function signed(c) return type(c) == "number" and signedMoney(c) or "–" end
  local function signedPct(v)
    if type(v) ~= "number" then return "–" end
    local n = math.floor(math.abs(v) * 100 + 0.5) * (v < 0 and -1 or 1)
    return (n > 0 and GREEN or n < 0 and RED or "") .. string.format("%+d %%", n) .. (n ~= 0 and "|r" or "")
  end
  -- Buchgewinn (book gain, not realised): selling now after the cut (Item.SellNet: cheapest
  -- offer - 1 copper, at most R, minus 5 %) minus the cost; the same basis as the Discord
  -- message. "AH jetzt/Stk" stays as information (before the cut).
  ns.AHTable.Add({
    id = "Stock", label = "Bestand", title = "Bestand", ahTab = false, sort = "sell",
    columns = {
      { key = "name", title = "Item", width = 0, align = "LEFT" },
      { key = "units", title = "Stück", width = 56, filter = "num", fmt = function(e) return units(e.units) end },
      { key = "source", title = "Herkunft", width = 120, align = "LEFT", muted = true, optional = true,
        fmt = function(e) return e.source or "" end },
      { key = "unitCost", title = "Einkauf/Stk", width = 96, filter = "money", fmt = function(e) return money(e.unitCost) end },
      { key = "marketUnit", title = "AH jetzt/Stk", width = 100, filter = "money", optional = true,
        fmt = function(e) return moneyOr(e.marketUnit) end },
      { key = "cost", title = "Einkauf", width = 96, filter = "money", muted = true, fmt = function(e) return money(e.cost) end },
      { key = "sell", title = "Erlös netto", width = 100, filter = "money", fmt = function(e) return moneyOr(e.sell) end },
      { key = "gain", title = "Buchgewinn", width = 106, filter = "money", fmt = function(e) return signed(e.gain) end },
      { key = "gainPct", title = "Buchgewinn %", width = 100, filter = "pct", fmt = function(e) return signedPct(e.gainPct) end },
    },
    rows = function()
      local list = {}
      for _, s in ipairs(ns.Profit and ns.Profit.Stock and ns.Profit.Stock() or {}) do
        table.insert(list, { itemID = s.itemId, units = s.units, source = s.source, unitCost = s.unitCost,
          marketUnit = s.marketUnit, cost = s.cost, market = s.market, diff = s.diff,
          sell = s.sell, gain = s.gain, gainPct = s.gainPct })
      end
      return list
    end,
    onClick = function(e) if stockClick then stockClick(e.itemID) end end,
  })
end

PAGES.ledger = function(p)
  pageTitle(p, "Handelsbuch")
  local buttons = {}
  local right = -PAD
  for i = #PERIODS, 1, -1 do
    local period = PERIODS[i]
    local b = Style.Button(p, period.label, 70, 22, function()
      state().period = period.key
      p:Refresh(true)
    end)
    b:SetScript("OnLeave", function(self)
      self.bg:SetColorTexture(unpack(self.active and Style.C.buttonHi or Style.C.button))
    end)
    b:SetPoint("TOPRIGHT", right, -PAD - 2)
    right = right - 74
    buttons[period.key] = b
  end

  local y = -(PAD + TOOLBAR + 6)
  local figPeriod = figureCard(p, { { "Umsatz (brutto)", 104 }, { "Einkauf", 100 }, { "AH-Gebühr", 90 },
    { "Einstellgeb. verloren", 112 }, { "Ergebnis", 104 } })
  figPeriod:SetPoint("TOPLEFT", PAD, y)
  local figStock = figureCard(p, { { "Bestand (jetzt)", 80 }, { "Einkauf", 96 }, { "Erlös netto", 98 },
    { "Buchgewinn", INNER_W - GAP - 510 - 274 } })
  figStock:SetPoint("TOPLEFT", figPeriod, "TOPRIGHT", GAP, 0)

  y = y - FIG_H - GAP
  local plH = 250
  local pl = grid(p, INNER_W, plH, {
    { "Bereich / Item", 0, nil, true }, { "herg./gek.", 66, "RIGHT" }, { "verkauft", 60, "RIGHT" },
    { "Ø Verkauf", 88, "RIGHT" }, { "Einkauf/Stk", 88, "RIGHT" }, { "Gewinn/Stk", 88, "RIGHT" },
    { "Ergebnis", 100, "RIGHT" }, { "abgel./abgebr.", 84, "RIGHT" }, { "Gebühr verloren", 96, "RIGHT" } },
    { scroll = true })
  pl:SetPoint("TOPLEFT", PAD, y)

  -- Below: recent trades / trades of one item / stock.
  local barY = y - plH - 8
  local label = Style.Text(p, 12)
  label:SetPoint("TOPLEFT", PAD, barY - 6)
  local summary = muted(Style.Text(p, 11))
  summary:SetPoint("TOPLEFT", PAD + 230, barY - 7)
  summary:SetWidth(INNER_W - 230 - 350)
  summary:SetJustifyH("LEFT")
  local selected   -- itemID whose trades are shown
  local listButtons = {}
  local back = Style.Button(p, "← alle Vorgänge", 120, 22, function()
    selected = nil
    p:Refresh()
  end)
  for i, def in ipairs({ { "stock", "Bestand" }, { "recent", "Vorgänge" } }) do
    local b = Style.Button(p, def[2], 90, 22, function()
      selected = nil
      state().ledgerList = def[1]
      p:Refresh()
    end)
    b:SetScript("OnLeave", function(self)
      self.bg:SetColorTexture(unpack(self.active and Style.C.buttonHi or Style.C.button))
    end)
    b:SetPoint("TOPRIGHT", -PAD - (i - 1) * 94, barY - 2)
    listButtons[def[1]] = b
  end
  back:SetPoint("TOPRIGHT", -PAD - 2 * 94, barY - 2)

  local listTop = barY - 30
  local listH = PAGE_H + listTop - PAD
  local recent = grid(p, INNER_W, listH, {
    { "Datum", 110 }, { "Art", 100 }, { "Item", 0, nil, true }, { "Menge", 70, "RIGHT" }, { "Betrag", 140, "RIGHT" } },
    { scroll = true })
  recent:SetPoint("TOPLEFT", PAD, listTop)
  local trades = grid(p, INNER_W, listH, {
    { "Datum", 110 }, { "Art", 100 }, { "Menge", 70, "RIGHT" }, { "Betrag", 120, "RIGHT" }, { "", 0 } },
    { scroll = true })
  trades:SetPoint("TOPLEFT", PAD, listTop)
  local stockList = CreateFrame("Frame", nil, p)
  stockList:SetSize(INNER_W, listH)
  stockList:SetPoint("TOPLEFT", PAD, listTop)
  stockList.missing = muted(Style.Text(stockList, 12))
  stockList.missing:SetPoint("TOPLEFT", 6, -6)

  local report, since, periodLabel

  local function selectItem(itemID)
    selected = itemID
    p:Refresh()
  end
  stockClick = selectItem

  local function itemRow(r, area)
    local made = "–"
    if area == ns.Profit.TRADE then made = count(r.bought)
    elseif area ~= ns.Profit.FARMED then made = count(r.crafted) end
    local cost = r.soldUnitCost or r.unitCost
    local name = r.name or ns.ItemName(r.itemId) or ("Item " .. tostring(r.itemId))
    return { name, made, count(r.sold), moneyOr(r.avgPrice), moneyOr(cost),
      type(r.unitProfit) == "number" and signedMoney(r.unitProfit) or "–", signedMoney(r.profit or 0),
      backText(r), lostMoney(r.depositsLost), itemID = r.itemId,
      color = r.itemId == selected and Style.C.accent or nil,
      onClick = function() selectItem(r.itemId) end }
  end

  local function areaRows()
    local rows = {}
    local open = state().ledgerOpen or {}
    state().ledgerOpen = open
    for _, g in ipairs(report.groups) do
      local items = report.items[g.name] or {}
      local isOpen = open[g.name] and true or false
      table.insert(rows, {
        span = string.format("%s%s (%d)   %sUmsatz %s · Einkauf %s · AH-Gebühr %s|r", isOpen and "– " or "+ ",
          g.name, #items, Style.MUTED, money(g.revenue), money(g.materials), money(g.cut)),
        spanTo = 6, [7] = signedMoney(g.profit or 0), [8] = backText(g), [9] = lostMoney(g.depositsLost),
        color = AREA_COLOR,
        onClick = function()
          open[g.name] = not isOpen or nil
          p:Refresh()
        end })
      if isOpen then
        for _, r in ipairs(items) do table.insert(rows, itemRow(r, g.name)) end
      end
    end
    return rows
  end

  -- Totals of the clicked item over its areas (crafted and bought rows of one item).
  local function itemSummary(itemID)
    local t = { bought = 0, crafted = 0, sold = 0, expired = 0, cancelled = 0, depositsLost = 0 }
    for _, list in pairs(report and report.items or {}) do
      for _, r in ipairs(list) do
        if r.itemId == itemID then
          for k in pairs(t) do t[k] = t[k] + (r[k] or 0) end
        end
      end
    end
    local parts = {}
    if t.bought > 0 then table.insert(parts, units(t.bought) .. " gekauft") end
    if t.crafted > 0 then table.insert(parts, units(t.crafted) .. " hergestellt") end
    table.insert(parts, units(t.sold) .. " verkauft")
    table.insert(parts, t.expired .. "× abgelaufen")
    table.insert(parts, t.cancelled .. "× abgebrochen")
    table.insert(parts, "Einstellgebühr verloren " .. money(t.depositsLost))
    return table.concat(parts, " · ")
  end

  local function showList()
    local mode = selected and "item" or (state().ledgerList == "stock" and "stock" or "recent")
    recent:SetShown(mode == "recent")
    trades:SetShown(mode == "item")
    stockList:SetShown(mode == "stock")
    back:SetShown(mode == "item")
    for key, b in pairs(listButtons) do setButtonActive(b, mode == key) end
    summary:SetText("")
    if mode == "item" then
      local name = ns.ItemName(selected) or ("Item " .. tostring(selected))
      label:SetText(Style.HEAD .. name .. "|r " .. Style.MUTED .. "(" .. periodLabel .. ")|r")
      local rows = { { span = Style.MUTED .. itemSummary(selected) .. "|r" } }
      for _, e in ipairs(optional(ns.Profit, "ItemEvents", selected, since) or {}) do
        table.insert(rows, itemEventRow(e, selected))
      end
      if #rows == 1 then table.insert(rows, { span = Style.MUTED .. "Keine Vorgänge im Zeitraum|r" }) end
      trades:SetRows(rows)
    elseif mode == "stock" then
      label:SetText(Style.HEAD .. "Bestand|r " .. Style.MUTED .. "(noch nicht verkauft)|r")
      summary:SetText("Einkauf: Kaufpreis bzw. gekauftes Material; AH jetzt: billigstes Angebot gerade")
      embed(stockList, "Stock")
    else
      label:SetText(Style.HEAD .. "Letzte Vorgänge|r")
      local rows = {}
      for _, e in ipairs(ledgerEvents(40)) do table.insert(rows, eventRow(e)) end
      recent:SetRows(rows, "Noch keine Vorgänge")
    end
  end

  -- reset: new period, the areas scroll back to the top (else they keep their position).
  function p:Refresh(reset)
    local key = state().period or "week"
    since, periodLabel = 0, ""
    for _, period in ipairs(PERIODS) do
      setButtonActive(buttons[period.key], period.key == key)
      if period.key == key then since, periodLabel = period.since(), period.label end
    end
    report = optional(ns.Profit, "Report", since)
    if type(report) ~= "table" then
      report = nil
      for i = 1, 5 do figPeriod:Set(i, "–") end
      for i = 1, 4 do figStock:Set(i, "–") end
      pl:SetRows({}, "Gewinnrechnung noch nicht verfügbar")
      showList()
      return
    end
    local t, st = report.totals, report.stockTotals
    local sold, expired, cancelled = 0, 0, 0
    for _, g in ipairs(report.groups) do
      sold = sold + (g.sold or 0)
      expired, cancelled = expired + (g.expired or 0), cancelled + (g.cancelled or 0)
    end
    figPeriod:Set(1, money(t.revenue), units(sold) .. " verkauft")
    figPeriod:Set(2, money(t.materials), "Material + Handelsware")
    figPeriod:Set(3, money(t.cut), "beim Verkauf")
    figPeriod:Set(4, money(t.depositsLost), string.format("%d× abgel., %d× abgebr.", expired, cancelled))
    figPeriod:Set(5, signedMoney(t.profit), "Umsatz − Einkauf − Gebühren")
    figStock:Set(1, units(st.units) .. " Stk", #report.stock .. " Items")
    figStock:Set(2, money(st.cost), "")
    local unsold = 0
    for _, s in ipairs(report.stock) do if not s.sell then unsold = unsold + 1 end end
    local anySell = unsold < #report.stock
    figStock:Set(3, anySell and money(st.sell) or "–",
      unsold > 0 and (unsold .. " ohne Preis") or "nach AH-Gebühr")
    local pctText = ""
    if anySell and (st.sellCost or 0) > 0 then
      local d = st.gain / st.sellCost
      pctText = string.format("%+d %%", math.floor(math.abs(d) * 100 + 0.5) * (d < 0 and -1 or 1))
    end
    figStock:Set(4, anySell and signedMoney(st.gain) or "–",
      unsold > 0 and ("nur Items mit Preis" .. (pctText ~= "" and (", " .. pctText) or ""))
      or ("noch nicht verkauft" .. (pctText ~= "" and (", " .. pctText) or "")))
    pl:SetRows(areaRows(), "Keine Vorgänge im Zeitraum", not reset)
    showList()
  end
end

-- Analysis of the market from the collector.
PAGES.analysis = function(p)
  pageTitle(p, "Analyse")
  local stamp = muted(Style.Text(p, 11))
  stamp:SetPoint("TOPRIGHT", -PAD, -PAD - 8)
  local none = muted(Style.Text(p, 13))
  none:SetPoint("CENTER", 0, 20)
  none:SetText(NO_ANALYSIS)

  local body = CreateFrame("Frame", nil, p)
  body:SetAllPoints()
  local y = -(PAD + TOOLBAR + 6)
  local tw = (INNER_W - 3 * GAP) / 4
  local turnover = tile(body, tw, "Umsatz 7 Tage")
  turnover:SetPoint("TOPLEFT", PAD, y)
  local offers = tile(body, tw, "Angebote")
  offers:SetPoint("TOPLEFT", turnover, "TOPRIGHT", GAP, 0)
  local inflation = tile(body, tw, "Inflation")
  inflation:SetPoint("TOPLEFT", offers, "TOPRIGHT", GAP, 0)
  local top = tile(body, tw, "Top-Beruf")
  top:SetPoint("TOPLEFT", inflation, "TOPRIGHT", GAP, 0)

  y = y - TILE_H - GAP
  local chartH = 168
  local cw = (INNER_W - 2 * GAP) / 3
  local charts = {}
  local defs = {
    { "Umsatz pro Tag", "bars", "turnover" },
    { "Preisindex", "line", "priceIndex" },
    { "Angebote pro Tag", "bars", "offers" },
  }
  for i, def in ipairs(defs) do
    local c = card(body, cw, chartH, def[1])
    c:SetPoint("TOPLEFT", PAD + (i - 1) * (cw + GAP), y)
    local drawing = chart(c, cw - 20, chartH - 40, def[2])
    drawing:SetPoint("TOPLEFT", 10, -30)
    charts[i] = { chart = drawing, field = def[3] }
  end

  y = y - chartH - GAP
  local listH = PAGE_H + y - PAD
  local colW = (INNER_W - GAP) / 2
  local recipeCard = card(body, colW, listH, "Top-Rezepte")
  recipeCard:SetPoint("TOPLEFT", PAD, y)
  local recipes = grid(recipeCard, colW - 2, listH - 30, {
    { "Rezept", 0, nil, true }, { "Beruf", 110 }, { "Gewinn", 96, "RIGHT" }, { "Nachfrage", 72, "RIGHT" } })
  recipes:SetPoint("TOPLEFT", 1, -29)

  local moverCard = card(body, colW, listH, "Gewinner und Verlierer")
  moverCard:SetPoint("TOPLEFT", PAD + colW + GAP, y)
  local half = (colW - 2 - GAP) / 2
  local up = grid(moverCard, half, listH - 30, { { "Steigt", 0, nil, true }, { "", 64, "RIGHT" } })
  up:SetPoint("TOPLEFT", 1, -29)
  local down = grid(moverCard, half, listH - 30, { { "Fällt", 0, nil, true }, { "", 64, "RIGHT" } })
  down:SetPoint("TOPLEFT", 1 + half + GAP, -29)

  local function moverRows(list)
    local rows = {}
    for i = 1, math.min(#(list or {}), 8) do
      local m = list[i]
      table.insert(rows, { m.itemId and ns.ItemName(m.itemId) or "?", pct(m.change and m.change * 100, true),
        itemID = m.itemId })
    end
    return rows
  end

  function p:Refresh()
    local a = analysis()
    body:SetShown(a ~= nil)
    none:SetShown(a == nil)
    stamp:SetText(a and a.updated and ("Stand " .. tostring(a.updated)) or "")
    if not a then return end
    local s = a.summary
    turnover:Set(s.turnover7d and money(s.turnover7d) or "–", pct(s.turnoverChangePct, true) .. " zur Vorwoche")
    offers:Set(pct(s.offersChangePct), "")
    inflation:Set(pct(s.inflationPct), "")
    local tp = s.topProfession
    top:Set(tp and tp.name or "–", "")

    local days = {}
    for _, d in ipairs(a.days or {}) do table.insert(days, d) end
    table.sort(days, function(x, z) return tostring(x.day) < tostring(z.day) end)
    while #days > CHART_DAYS do table.remove(days, 1) end
    local first = days[1] and tostring(days[1].day or ""):sub(6) or ""
    local last = days[#days] and tostring(days[#days].day or ""):sub(6) or ""
    for _, c in ipairs(charts) do
      local values, certain = {}, {}
      for i, d in ipairs(days) do
        values[i] = tonumber(d[c.field]) or 0
        if c.field == "turnover" then
          if d.turnoverCertain == nil then certain[i] = true else certain[i] = d.turnoverCertain end
        end
      end
      local fmt = tostring
      if c.field == "turnover" then fmt = money
      elseif c.field == "priceIndex" then fmt = function(v) return string.format("%.1f", v) end
      elseif c.field == "offers" then fmt = function(v) return tostring(math.floor(v + 0.5)) end end
      c.chart:SetData(values, { fmt = fmt, first = first, last = last,
        certain = c.field == "turnover" and certain or nil })
    end

    local rows = {}
    for i = 1, math.min(#(s.topRecipes or {}), 5) do
      local r = s.topRecipes[i]
      local _, profName, itemID = recipeName(r.professionId, r.id)
      table.insert(rows, { r.name or recipeName(r.professionId, r.id) or "?", profName or "",
        r.profit and money(r.profit) or "–", r.demand and string.format("%.1f", r.demand) or "–",
        itemID = r.itemId or itemID })
    end
    recipes:SetRows(rows, "Keine Rezepte")
    local movers = s.movers or {}
    up:SetRows(moverRows(movers.up), "–")
    down:SetRows(moverRows(movers.down), "–")
  end
end

-- Skill planner: choice of a crafting profession, then two ways between two skill levels
-- (ns.Costs.Plan over ns.Planner; prices only via ns.Item):
--   Standard-Weg   only what is certain right away: learned, trainer, unlimited vendor
--   Dynamischer Weg  plus limited vendors, reputation and Merchant's Favor patterns the
--                  character can use now, and patterns cheap at the auction house now
-- Each step names the recipe, crafts, costs and where to learn it (NPC, zone, coordinates
-- for the own faction); trainer visits for the ranks with skill and character level; a
-- shopping list with what is in bags/bank and where to buy. Where the standard way ends,
-- the page says so and lists the options.
local AH_CAP = 3              -- units per product assumed to sell at auction (AH mode)
local ORANGE, YELLOW, LGREEN, GREY = "|cffff8040", "|cffffff00", "|cff40bf40", "|cff808080"
local QUESTION_ICON = 134400
local MAX_OPTIONS = 6         -- options listed where the standard way ends
local plannerDirty = false    -- prices or recipes changed: compute the path again

local function plannerState()
  local s = state()
  s.planner = s.planner or {}
  return s.planner
end

-- Recipe color at a skill: orange, yellow, green, grey (thresholds { o, y, g, grey }).
local function difficultyColor(colors, skill)
  if skill >= (colors[4] or 0) then return GREY end
  if skill >= (colors[3] or 0) then return LGREEN end
  if skill >= (colors[2] or 0) then return YELLOW end
  return ORANGE
end

-- "41,4 / 42,6" (German decimal comma); "" without coordinates.
local function coords(x, y)
  if not (x and y) then return "" end
  return (string.format("%.1f / %.1f", x, y):gsub("%.", ","))
end

-- "Una, Donnerfels 41,4 / 42,6" from an NPC row { name, zone, x, y, faction, roam }.
local function npcText(npc)
  if not npc then return "?" end
  local text = npc[1] .. ", " .. npc[2]
  local c = coords(npc[3], npc[4])
  if c ~= "" then text = text .. " " .. c end
  if npc.roam == 1 then text = text .. " (wandert)" end
  return text
end

local function trainerText(t)
  if not t then return "Lehrer" end
  return npcText({ t.npc, t.zone, t.x, t.y })
end

local WAY_LABEL = { vendor = "Händler", limited = "Händler (begrenzt)", rep = "Ruf-Händler", favor = "Händlergunst",
  ah = "Gelegenheit AH", cond = "Händler (Bedingung)", unknown = "Händler (unbekannt)" }

-- Short "Lernen" cell of a step.
local function learnText(c)
  local how = c.how or {}
  if how.way == "learned" or c.learned then return GREEN .. "gelernt|r" end
  local fee = (c.learnCost or 0) > 0 and (" " .. money(c.learnCost)) or ""
  if how.way == "trainer" then
    if c.artisan then return ORANGE .. "Fachmann-Lehrer|r" .. fee end
    return "Lehrer" .. fee
  end
  if how.way == "favor" then return ORANGE .. "Händlergunst|r " .. tostring(how.option and how.option.favor or "") end
  if how.way == "ah" then return YELLOW .. "Gelegenheit AH|r" .. fee end
  return (WAY_LABEL[how.way] or "Muster") .. fee
end

-- Detail line of a step: where to learn the recipe; nil for learned recipes.
local function whereText(c, srcs, faction)
  local how = c.how or {}
  if how.way == "learned" or c.learned then return nil end
  if how.way == "trainer" then
    local rank = how.rank or ns.Planner.RankFor(c.learnAt or 0).name
    if c.artisan then rank = "Fachmann" end
    return string.format("Lehrer (%s): %s", rank, trainerText(ns.Planner.Trainer(srcs, rank, faction)))
  end
  local o = how.option or {}
  if how.way == "ah" then
    return string.format("Muster jetzt im AH für %s – Gelegenheit, kann morgen weg sein", money(o.cost or 0))
  end
  local text = string.format("%s: %s", WAY_LABEL[how.way] or "Händler", npcText(o.npc))
  if how.way == "favor" then
    text = text .. string.format(" – %d Händlergunst", o.favor or 0)
  elseif (o.cost or 0) > 0 then
    text = text .. " – Muster " .. money(o.cost)
  end
  if o.stock then text = text .. string.format(", nur %d auf Lager (füllt nach)", o.stock) end
  if o.rep then text = text .. ", Ruf " .. o.rep.faction .. " " .. o.rep.standing end
  if o.level then text = text .. ", ab Stufe " .. o.level end
  if o.classic then text = text .. "  " .. GREY .. "(NPC aus Classic-Daten)|r" end
  return text
end

-- One option line where the standard way ends.
local function optionText(m, srcs, faction)
  local parts = {}
  for _, o in ipairs(m.options) do
    local where = o.way == "ah" and ("im AH für " .. money(o.cost))
      or ((WAY_LABEL[o.way] or "Händler") .. " " .. (o.npc and npcText(o.npc) or "?")
        .. ((o.cost or 0) > 0 and (" – " .. money(o.cost)) or "")
        .. (o.way == "favor" and (" – " .. (o.favor or 0) .. " Händlergunst") or "")
        .. (o.classic and (GREY .. " (Classic-Daten)|r") or ""))
    if o.why then where = where .. " (" .. o.why .. ")" end
    if o.usable then where = where .. GREEN .. " → im dynamischen Weg|r" end
    table.insert(parts, where)
    if #parts >= 2 then break end
  end
  if #parts == 0 then
    table.insert(parts, m.quest and ("Quest „" .. m.quest .. "“") or (m.drop and "nur Drop" or "keine Quelle bekannt"))
  end
  return string.format("  · %s (ab %d): %s", m.name, m.learnAt or 0, table.concat(parts, "; "))
end

-- A cost: positive is money spent, negative a gain (green).
local function netCost(copper)
  if copper <= 0 then return GREEN .. "+" .. money(-copper) .. "|r" end
  return "-" .. money(copper)
end

local function searchAH(itemID)
  if not ahShown then return end
  if AuctionHouseFrame and AuctionHouseFrameDisplayMode then
    AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
  end
  C_Timer.After(0.1, function() optional(ns.Deals, "Search", itemID) end)
end

local function shiftDown() return IsShiftKeyDown and IsShiftKeyDown() or false end

-- Number field with -/+ buttons (shift: steps of 10). onChange(value or nil).
local function stepper(parent, label, onChange)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(150, 22)
  local text = muted(Style.Text(f, 12))
  text:SetPoint("LEFT", 0, 0)
  text:SetText(label)
  local minus = Style.Button(f, "–", 22, 22, function()
    onChange((f.value or 0) - (shiftDown() and 10 or 1))
  end)
  minus:SetPoint("LEFT", 52, 0)
  local box = CreateFrame("EditBox", nil, f)
  box:SetSize(44, 22)
  box:SetPoint("LEFT", minus, "RIGHT", 4, 0)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(3)
  box:SetFontObject(Style.Font(12))
  box:SetJustifyH("CENTER")
  local bg = Style.Solid(box, Style.C.button)
  bg:SetAllPoints()
  Style.Border(box)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEscapePressed", function(self) self.cancel = true; self:ClearFocus() end)
  box:SetScript("OnEditFocusLost", function(self)
    local v = not self.cancel and tonumber(self:GetText()) or nil
    self.cancel = nil
    onChange(v)
  end)
  local plus = Style.Button(f, "+", 22, 22, function()
    onChange((f.value or 0) + (shiftDown() and 10 or 1))
  end)
  plus:SetPoint("LEFT", box, "RIGHT", 4, 0)
  function f:Set(v)
    self.value = v
    box:SetText(tostring(v))
  end
  return f
end

PAGES.planner = function(p)
  local title = pageTitle(p, "Skill-Planer")
  local ranges = {}   -- professionID -> { from, to } while the window lives
  local cache         -- last computed plans { key, ... }

  local back = Style.Button(p, "Andere Berufe", 110, 22, function()
    plannerState().pid = nil
    p:Refresh()
  end)
  back:SetPoint("TOPRIGHT", -PAD, -PAD - 2)
  local hint = muted(Style.Text(p, 13))
  hint:SetPoint("TOP", 0, -200)

  -- Profession choice: tiles with icon, own professions first.
  local chooser = CreateFrame("Frame", nil, p)
  chooser:SetAllPoints()
  local tiles = {}
  local tileW, tileH = (INNER_W - 3 * GAP) / 4, 70
  local function tileAt(i)
    if tiles[i] then return tiles[i] end
    local b = CreateFrame("Button", nil, chooser)
    b:SetSize(tileW, tileH)
    b:SetPoint("TOPLEFT", PAD + ((i - 1) % 4) * (tileW + GAP), -(PAD + TOOLBAR + 6) - math.floor((i - 1) / 4) * (tileH + GAP))
    local bg = Style.Solid(b, CARD_BG)
    bg:SetAllPoints()
    Style.Border(b)
    b.hover = Style.Solid(b, Style.C.hover, "ARTWORK")
    b.hover:SetAllPoints()
    b.hover:Hide()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(36, 36)
    b.icon:SetPoint("LEFT", 10, 0)
    b.label = Style.Text(b, 13)
    b.label:SetPoint("TOPLEFT", 56, -12)
    b.info = Style.Text(b, 11)
    b.info:SetPoint("TOPLEFT", 56, -30)
    b.status = muted(Style.Text(b, 11))
    b.status:SetPoint("TOPLEFT", 56, -46)
    b:SetScript("OnEnter", function(self) self.hover:Show() end)
    b:SetScript("OnLeave", function(self) self.hover:Hide() end)
    b:SetScript("OnClick", function(self)
      if not self.pid then return end
      plannerState().pid = self.pid
      p:Refresh()
    end)
    tiles[i] = b
    return b
  end

  -- Path view.
  local view = CreateFrame("Frame", nil, p)
  view:SetAllPoints()
  local y = -(PAD + TOOLBAR + 6)
  local fromStep, toStep
  local function setRange(from, to)
    local pid = plannerState().pid
    local r = ranges[pid]
    if not r then return end
    from = math.floor(from or r.from)
    to = math.floor(to or r.to)
    from = math.max(1, math.min(from, ns.Planner and ns.Planner.MAX_SKILL - 1 or 299))
    to = math.max(from + 1, math.min(to, ns.Planner and ns.Planner.MAX_SKILL or 300))
    r.from, r.to = from, to
    p:Refresh()
  end
  fromStep = stepper(view, "von Skill", function(v) setRange(v, nil) end)
  fromStep:SetPoint("TOPLEFT", PAD, y)
  toStep = stepper(view, "bis Skill", function(v) setRange(nil, v) end)
  toStep:SetPoint("TOPLEFT", PAD + 160, y)
  local wayStd = Style.Button(view, "Standard-Weg", 104, 22, function()
    plannerState().way = "standard"
    p:Refresh()
  end)
  wayStd:SetPoint("TOPLEFT", PAD + 318, y)
  local wayDyn = Style.Button(view, "Dynamischer Weg", 124, 22, function()
    plannerState().way = "dynamic"
    p:Refresh()
  end)
  wayDyn:SetPoint("LEFT", wayStd, "RIGHT", 4, 0)
  local modeSafe = Style.Button(view, "Händlerverkauf", 112, 22, function()
    plannerState().ah = false
    p:Refresh()
  end)
  local modeAH = Style.Button(view, "AH-Verkauf (bis " .. AH_CAP .. ")", 124, 22, function()
    plannerState().ah = true
    p:Refresh()
  end)
  modeAH:SetPoint("TOPRIGHT", -PAD, y)
  modeSafe:SetPoint("RIGHT", modeAH, "LEFT", -4, 0)
  for _, b in ipairs({ modeSafe, modeAH, wayStd, wayDyn }) do
    b:SetScript("OnLeave", function(self)
      self.bg:SetColorTexture(unpack(self.active and Style.C.buttonHi or Style.C.button))
    end)
  end

  y = y - 34
  local pathH = 262
  local path = grid(view, INNER_W, pathH, {
    { "Skill", 72 }, { "Rezept", 0, nil, true }, { "Stück", 50, "RIGHT" }, { "Material", 92, "RIGHT" },
    { "Lernen", 170 }, { "Kosten netto", 100, "RIGHT" } }, { scroll = true })
  path:SetPoint("TOPLEFT", PAD, y)
  y = y - pathH - 6
  local sums = Style.Text(view, 12)
  sums:SetPoint("TOPLEFT", PAD + 6, y)
  local compare = Style.Text(view, 12)
  compare:SetPoint("TOPLEFT", PAD + 6, y - 17)
  local reach = muted(Style.Text(view, 12))
  reach:SetPoint("TOPLEFT", PAD + 6, y - 34)
  y = y - 56
  local shopLabel = Style.Text(view, 12)
  shopLabel:SetPoint("TOPLEFT", PAD, y)
  shopLabel:SetText(Style.HEAD .. "Einkaufsliste|r")
  y = y - 20
  local shop = grid(view, INNER_W, PAGE_H + y - PAD, {
    { "Material", 0, nil, true }, { "brauchst", 66, "RIGHT" }, { "hast", 56, "RIGHT" }, { "kaufen", 60, "RIGHT" },
    { "je Stück", 84, "RIGHT" }, { "Summe", 92, "RIGHT" }, { "wo", 90 }, { "", 70, nil, nil, button = true } },
    { scroll = true })
  shop:SetPoint("TOPLEFT", PAD, y)

  local function showChooser()
    chooser:Show()
    view:Hide()
    back:Hide()
    title:SetText("Skill-Planer")
    local list = ns.Costs and ns.Costs.AllProfessions and ns.Costs.AllProfessions() or {}
    for i, prof in ipairs(list) do
      local b = tileAt(i)
      b.pid = prof.pid
      b.icon:SetTexture(prof.icon or QUESTION_ICON)
      b.label:SetText(prof.name)
      b.info:SetText(prof.own and (Style.ACCENT .. string.format("dein Skill %d / %d", prof.rank or 0, prof.max or 0) .. "|r")
        or Style.MUTED .. "nicht erlernt|r")
      b.status:SetText(prof.hasData and "" or "noch keine Skilldaten")
      b:Show()
    end
    for i = #list + 1, #tiles do tiles[i]:Hide() end
    hint:SetText(#list == 0 and "Keine Berufsdaten geladen" or "")
    hint:SetShown(#list == 0)
  end

  local function compute(pid, from, to, ah)
    local prof, why = ns.Costs.Profession(pid)
    if not prof then return { why = why } end
    prof.ctx = ns.Costs.Context()
    local cap = ah and AH_CAP or 0
    local plans = { standard = ns.Costs.Plan(prof, from, to, cap, "standard"),
      dynamic = ns.Costs.Plan(prof, from, to, cap, "dynamic") }
    -- The own cap counts only when planning from the own skill range.
    local max = prof.max
    if not (max and from <= max and from >= max - 75) then max = nil end
    for _, plan in pairs(plans) do
      plan.steps = plan.segments and ns.Planner.Steps(plan.segments, from, max)
    end
    return { prof = prof, plans = plans, ctx = prof.ctx, srcs = ns.RecipeSources and ns.RecipeSources[pid] }
  end

  local function showPlan(pid)
    chooser:Hide()
    back:Show()
    local entry
    for _, prof in ipairs(ns.Costs.AllProfessions()) do if prof.pid == pid then entry = prof end end
    title:SetText("Skill-Planer  ·  " .. (entry and entry.name or ("Beruf " .. pid)))
    if not ranges[pid] then
      ranges[pid] = { from = math.max(1, math.min(entry and entry.rank or 1, ns.Planner.MAX_SKILL - 1)),
        to = ns.Planner.MAX_SKILL }
    end
    local r, ah = ranges[pid], plannerState().ah and true or false
    local way = plannerState().way == "dynamic" and "dynamic" or "standard"
    fromStep:Set(r.from)
    toStep:Set(r.to)
    setButtonActive(modeSafe, not ah)
    setButtonActive(modeAH, ah)
    setButtonActive(wayStd, way == "standard")
    setButtonActive(wayDyn, way == "dynamic")

    local key = table.concat({ pid, r.from, r.to, tostring(ah) }, ":")
    if not cache or cache.key ~= key or plannerDirty then
      cache = compute(pid, r.from, r.to, ah)
      cache.key = key
      plannerDirty = false
    end
    local result = cache
    local plan = result.plans and result.plans[way]
    local message
    if result.why == "nodata" then
      message = "Für diesen Beruf fehlen noch Skilldaten."
    elseif result.why == "noscan" then
      message = "Berufsfenster einmal öffnen, dann plant m4-companion den Weg."
    elseif not (plan and plan.segments) then
      message = "Kein Weg gefunden – für manche Zutaten fehlen Preise. Im AH einmal scannen."
    end
    view:SetShown(true)
    for _, w in ipairs({ path, sums, compare, reach, shopLabel, shop }) do w:SetShown(message == nil) end
    hint:SetText(message or "")
    hint:SetShown(message ~= nil)
    if message then return end

    local ctx, srcs = result.ctx or {}, result.srcs
    local rows = {}
    if not (entry and entry.own) and r.from <= 1 then
      local t = ns.Planner.Trainer(srcs, "Lehrling", ctx.faction)
      table.insert(rows, { span = ORANGE .. "Zuerst den Beruf beim Lehrer lernen (Lehrling, bis 75)"
        .. (t and (": " .. trainerText(t)) or "") .. ".|r" })
    end
    local spend, learn, income = 0, 0, 0
    local gold, outlay, reachable = GetMoney(), 0, r.from
    for _, step in ipairs(plan.steps) do
      if step.rank then
        local rank = step.rank
        local t = ns.Planner.Trainer(srcs, rank.name, ctx.faction)
        local levelNote = ""
        if ctx.level and ctx.level < rank.level then
          levelNote = string.format("  %s– du bist Stufe %d, erst ab %d möglich!|r", RED, ctx.level, rank.level)
        end
        table.insert(rows, { span = string.format("%sBei %d: %s lernen (bis %d) bei %s – ab Skill %d und Charakterstufe %d.|r%s",
          ORANGE, rank.at, rank.name, rank.cap, trainerText(t), t and t.skill or rank.at, rank.level, levelNote) })
      else
        local seg, c = step.seg, step.seg.recipe
        table.insert(rows, { string.format("%d–%d", seg.from, seg.to), difficultyColor(c.colors, seg.from) .. c.name .. "|r",
          tostring(math.ceil(seg.crafts)), money(seg.spend), learnText(c), netCost(seg.cost), itemID = c.out })
        local where = whereText(c, srcs, ctx.faction)
        if where then table.insert(rows, { span = Style.MUTED .. "      " .. where .. "|r" }) end
        spend, learn, income = spend + seg.spend, learn + seg.learned, income + seg.income
        -- How far the gold reaches, paying everything up front.
        if reachable == seg.from and outlay + seg.spend + seg.learned <= gold then
          outlay = outlay + seg.spend + seg.learned
          reachable = seg.to
        end
      end
    end
    if plan.reached < r.to then
      table.insert(rows, { span = string.format("%sDer %s endet bei Skill %d: kein %s Rezept gibt hier noch Punkte.|r",
        ORANGE, way == "standard" and "Standard-Weg" or "dynamische Weg", plan.reached,
        way == "standard" and "sicher verfügbares" or "jetzt erreichbares") })
      local missing = plan.missing or {}
      if #missing > 0 then
        table.insert(rows, { span = ORANGE .. "Optionen für die nächsten Punkte:|r" })
        for i = 1, math.min(MAX_OPTIONS, #missing) do
          table.insert(rows, { span = optionText(missing[i], srcs, ctx.faction) })
        end
      end
    end
    path:SetRows(rows, "")
    sums:SetText(string.format("Material %s   ·   Lernen %s   ·   Rückverkauf %s   ·   unterm Strich %s",
      money(spend), money(learn), GREEN .. money(income) .. "|r", netCost(plan.total or 0)))

    -- Standard against dynamic.
    local std, dyn = result.plans.standard, result.plans.dynamic
    local cmp
    if dyn.reached > std.reached then
      cmp = string.format("Dynamischer Weg kommt bis %d (Standard nur bis %d).", dyn.reached, std.reached)
    elseif (std.total or 0) - (dyn.total or 0) > 0 and dyn.reached >= std.reached then
      cmp = string.format("Dynamischer Weg spart %s gegenüber Standard.", money((std.total or 0) - (dyn.total or 0)))
    else
      cmp = "Dynamischer Weg bringt gerade nichts – Standard-Weg ist so günstig wie es geht."
    end
    compare:SetText((way == "standard" and Style.ACCENT or "") .. cmp .. (way == "standard" and "|r" or ""))

    local reachText
    if reachable >= plan.reached then
      reachText = string.format("Dein Gold (%s) reicht für den ganzen Weg.", money(gold))
    else
      reachText = string.format("Mit deinem Gold (%s) erreichbar bis Skill %d – dann verkaufen und weiter.", money(gold), reachable)
    end
    if #(plan.skipped or {}) > 0 then
      reachText = reachText .. string.format("   %d Rezepte ohne Preis für eine Zutat nicht eingeplant.", #plan.skipped)
    end
    reach:SetText(reachText)

    local list = {}
    for itemID, count in pairs(plan.need or {}) do
      local unit, where = ns.Costs.Buy(itemID)
      local avg = ns.Costs.BuyMany(itemID, count)
      local owned = ns.Costs.Owned(itemID) or 0
      table.insert(list, { id = itemID, count = count, owned = owned, buy = math.max(0, count - owned),
        unit = avg or unit or 0, where = where, scarce = plan.scarce and plan.scarce[itemID] })
    end
    table.sort(list, function(a, b)
      if a.buy * a.unit ~= b.buy * b.unit then return a.buy * a.unit > b.buy * b.unit end
      return a.id < b.id
    end)
    local shopRows, total = {}, 0
    for _, it in ipairs(list) do
      total = total + it.buy * it.unit
      local id = it.id
      local where = it.where and (it.scarce and (RED .. "AH knapp|r") or it.where) or (Style.MUTED .. "kein Preis|r")
      table.insert(shopRows, { ns.ItemName(id) or ("Item " .. id), tostring(it.count), tostring(it.owned),
        it.buy > 0 and tostring(it.buy) or (GREEN .. "0|r"), it.where and money(it.unit) or "–",
        it.where and money(it.buy * it.unit) or "–", where, itemID = id,
        button = ahShown and it.buy > 0 and { label = "Suchen", fn = function() searchAH(id) end } or nil })
    end
    if #shopRows > 0 then
      table.insert(shopRows, { "Noch zu kaufen", "", "", "", "", money(total), "", color = Style.C.accent })
    end
    for itemID, m in pairs(plan.made or {}) do
      table.insert(shopRows, { span = Style.MUTED .. string.format("Selbst herstellen: %d× %s mit %s (%d×) – Material oben enthalten|r",
        m.count, ns.ItemName(itemID) or ("Item " .. itemID), m.recipe.name or "?", m.crafts) })
    end
    shop:SetRows(shopRows, "Nichts zu kaufen")
  end

  function p:Refresh()
    hint:SetShown(false)
    if not (ns.Costs and ns.Costs.Plan and ns.Planner and ns.Planner.Steps) then
      chooser:Hide()
      view:Hide()
      back:Hide()
      hint:SetText("Skill-Planer nicht verfügbar")
      hint:Show()
      return
    end
    local pid = plannerState().pid
    if pid then showPlan(pid) else showChooser() end
  end
end

-- Settings (saved in ns.db.settings, the minimap switch in ns.db.minimap.hide).
PAGES.settings = function(p)
  pageTitle(p, "Einstellungen")
  local toggles = {}
  local y = -(PAD + TOOLBAR + 10)
  local function section(text)
    local t = Style.Text(p, 12)
    t:SetPoint("TOPLEFT", PAD, y)
    t:SetText(Style.HEAD .. text .. "|r")
    y = y - 24
  end
  local function add(label, get, set)
    local t = toggle(p, label, get, set)
    t:SetPoint("TOPLEFT", PAD + 4, y)
    table.insert(toggles, t)
    y = y - 26
    return t
  end

  section("Allgemein")
  local reload = Style.Button(p, "Neu laden", 90, 20, function() ReloadUI() end)
  reload:Hide()
  local minimap = add("Minimap-Symbol anzeigen", function()
    return not (ns.db.minimap and ns.db.minimap.hide)
  end, function(on)
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.hide = not on
    reload:Show()
  end)
  reload:SetPoint("LEFT", minimap.label, "RIGHT", 14, 0)
  add("Auto-Vollscan beim Öffnen des Auktionshauses",
    function() return settings().autoScan end,
    function(on) settings().autoScan = on end)
  -- Reduced-UI: no markers in the bags and no M4 lines in item tooltips (BagMarks, Tooltip).
  add("Reduced-UI (keine Markierungen im Inventar, keine Tooltip-Zeilen)",
    function() return settings().reducedUI == true end,
    function(on)
      settings().reducedUI = on
      if ns.BagMarks then ns.BagMarks.Refresh() end
    end)

  y = y - 10
  section("Tooltip")
  for _, line in ipairs(TOOLTIP_LINES) do
    add(line[2], function() return settings().tooltip[line[1]] end,
      function(on) settings().tooltip[line[1]] = on end)
  end

  y = y - 10
  section("Discord")
  local function discord() return ns.MyAuctions and ns.MyAuctions.Discord() or {} end
  add("Meine Verkäufe in #wow-broker melden (mit Erwähnung)", function() return discord().sales end,
    function(on) discord().sales = on end)
  -- Book gain of the stock: a direct message from the server when an item in the stock is
  -- worth much more than it cost (opt-in; threshold via the stepper, at least stockMin).
  local stockToggle = add("DM, wenn ein Item im Bestand stark gestiegen ist",
    function() return discord().stock end, function(on) discord().stock = on; p:Refresh() end)
  local STOCK_STEPS = ns.MyAuctions and ns.MyAuctions.STOCK_STEPS or { 25, 50, 100, 200 }
  local stockLabel = Style.Text(p, 12)
  local function stepStock(delta)
    local d = discord()
    local cur, at = d.stockPct or 50, 1
    for i, v in ipairs(STOCK_STEPS) do if v <= cur then at = i end end
    at = math.max(1, math.min(#STOCK_STEPS, at + delta))
    d.stockPct = STOCK_STEPS[at]
    p:Refresh()
  end
  -- Threshold stepper on the same row, right of the switch (the page has no room for one more row).
  local stockMinus = Style.Button(p, "–", 24, 20, function() stepStock(-1) end)
  stockMinus:SetPoint("TOPLEFT", stockToggle, "TOPRIGHT", 10, -2)
  stockLabel:SetPoint("LEFT", stockMinus, "RIGHT", 10, 0)
  stockLabel:SetWidth(150)
  local stockPlus = Style.Button(p, "+", 24, 20, function() stepStock(1) end)
  stockPlus:SetPoint("LEFT", stockLabel, "RIGHT", 10, 0)
  local discordHint = Style.Text(p, 11)
  discordHint:SetPoint("TOPLEFT", PAD + 4, y)
  discordHint:SetJustifyH("LEFT")
  discordHint:SetText(Style.MUTED .. "Bestand: Buchgewinn nach AH-Gebühr, mind. "
    .. money(discord().stockMin or 10000) .. ", je Item einmal pro Stufe (Server prüft stündlich).\n"
    .. "Snipes und Rezepte postet der Server für die ganze Gilde. Gilt nach /reload oder Logout.|r")
  y = y - 38

  y = y - 10
  section("Fenster")
  local scaleLabel = Style.Text(p, 12)
  local function changeScale(delta)
    local s = state()
    s.scale = math.max(0.6, math.min(1.4, (s.scale or 1) + delta))
    MainUI.ApplyScale()
    p:Refresh()
  end
  local minus = Style.Button(p, "–", 24, 20, function() changeScale(-0.05) end)
  minus:SetPoint("TOPLEFT", PAD + 4, y)
  scaleLabel:SetPoint("LEFT", minus, "RIGHT", 10, 0)
  scaleLabel:SetWidth(110)
  local plus = Style.Button(p, "+", 24, 20, function() changeScale(0.05) end)
  plus:SetPoint("LEFT", scaleLabel, "RIGHT", 10, 0)

  -- Right column (the left one is full): Min-Max-Optimierung unlocks Dr. Porzellan's toilet
  -- break planner in the ledger, the tab under "Marktsuche" (Boxenstopp.lua).
  local rx, ry = PAD + 470, -(PAD + TOOLBAR + 10)
  local extra = Style.Text(p, 12)
  extra:SetPoint("TOPLEFT", rx, ry)
  extra:SetText(Style.HEAD .. "Experimentell|r")
  local minMax = toggle(p, "Min-Max-Optimierung", function() return settings().minMax == true end,
    function(on)
      settings().minMax = on
      if ns.TradeBook and ns.TradeBook.UpdateTabs then ns.TradeBook.UpdateTabs() end
    end)
  minMax:SetPoint("TOPLEFT", rx + 4, ry - 24)
  table.insert(toggles, minMax)
  local minMaxHint = Style.Text(p, 11)
  minMaxHint:SetPoint("TOPLEFT", rx + 28, ry - 50)
  minMaxHint:SetWidth(380)
  minMaxHint:SetJustifyH("LEFT")
  minMaxHint:SetText(Style.MUTED .. "Schaltet im Handelsbuch unter der Marktsuche den Boxenstopp-Planer\n"
    .. "von Dr. med. Porzellan frei: Klo-Pausen medizinisch (halbwegs) optimal\n"
    .. "um die Zocksession planen. Auch mit /m4 klo.|r")

  function p:Refresh()
    for _, t in ipairs(toggles) do t:Update() end
    local d = discord()
    local on = d.stock and true or false
    stockLabel:SetText((on and "" or Style.MUTED) .. string.format("ab +%d %% Buchgewinn", d.stockPct or 50)
      .. (on and "" or "|r"))
    stockMinus:SetEnabled(on)
    stockPlus:SetEnabled(on)
    scaleLabel:SetText(string.format("Größe %d %%", math.floor((state().scale or 1) * 100 + 0.5)))
  end
end

-- Window ---------------------------------------------------------------------------

local function updateStatus()
  if statusText and ns.Status and ns.Status.Text then
    local ok, text = ns.Safe(ns.Status.Text)
    statusText:SetText(ok and text or "")
  end
end

local function updateNav()
  for _, b in ipairs(nav) do
    local entry = b.entry
    local active
    if entry.parent == "market" then
      active = current == "market" and marketSub == entry.key
    else
      active = current == entry.key
    end
    b.active = active
    b.bar:SetShown(active)
    b.bg:SetShown(active)
    -- The parent of the shown page stays bright (Markt for its tabs, Berufe for the planner).
    local open = (entry.key == "market" and current == "market")
    for _, e in ipairs(NAV) do
      if e.parent == entry.key and e.key == current then open = true end
    end
    b.label:SetTextColor(unpack((active or open) and Style.C.text or Style.C.muted))
  end
end

-- Sidebar buttons in NAV order; creates the ones still missing (pages registered later).
local function layoutNav()
  local y = -(HEADER + 10)
  nav = {}
  for _, entry in ipairs(NAV) do
    local h = entry.sub and 24 or 30
    local b = navByKey[entry.key]
    if not b then
      b = CreateFrame("Button", nil, frame)
      b:SetSize(SIDEBAR, h)
      b.entry = entry
      b.bg = Style.Solid(b, Style.C.hover, "ARTWORK")
      b.bg:SetAllPoints()
      b.bar = Style.Solid(b, Style.C.accent, "OVERLAY")
      b.bar:SetPoint("TOPLEFT")
      b.bar:SetPoint("BOTTOMLEFT")
      b.bar:SetWidth(3)
      b.label = Style.Text(b, entry.sub and 12 or 13)
      b.label:SetPoint("LEFT", entry.sub and 30 or 16, 0)
      b.label:SetText(entry.label)
      b:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(Style.C.text)) end)
      b:SetScript("OnLeave", function() updateNav() end)
      b:SetScript("OnClick", function() MainUI.Show(entry.key) end)
      navByKey[entry.key] = b
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 1, y)
    table.insert(nav, b)
    y = y - h
  end
end

local function selectPage(key)
  current = key
  for k, page in pairs(pages) do page:SetShown(k == key) end
  local page = pages[key]
  if not page then
    page = CreateFrame("Frame", nil, frame.content)
    page:SetAllPoints()
    pages[key] = page
    PAGES[key](page)
  end
  page:Show()
  updateNav()
  if page.Refresh then ns.Safe(page.Refresh, page) end
end

-- Scale: the saved one, made smaller when the window would not fit on the screen.
function MainUI.ApplyScale()
  if not frame then return end
  local s = state().scale or 1
  local w, h = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
  if w > 0 then s = math.min(s, w / (WIDTH + 20)) end
  if h > 0 then s = math.min(s, h / (HEIGHT + 20)) end
  frame:SetScale(math.max(0.5, s))
end

local function createFrame()
  frame = CreateFrame("Frame", FRAME_NAME, UIParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    state().pos = { point, relPoint, x, y }
  end)
  frame:Hide()
  Style.Panel(frame, HEADER)
  tinsert(UISpecialFrames, FRAME_NAME)
  MainUI.ApplyScale()
  local pos = state().pos
  if pos then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("CENTER")
  end

  -- Header.
  local emblem = frame:CreateTexture(nil, "ARTWORK")
  emblem:SetSize(28, 28)
  emblem:SetPoint("TOPLEFT", 10, -6)
  emblem:SetTexture(EMBLEM)
  local brand = Style.Text(frame, 16)
  brand:SetPoint("LEFT", emblem, "RIGHT", 8, 0)
  brand:SetText(Style.ACCENT .. "m4|r-companion")
  local close = Style.Close(frame)
  close:SetPoint("TOPRIGHT", -8, -8)
  statusText = muted(Style.Text(frame, 12))
  statusText:SetPoint("RIGHT", close, "LEFT", -12, 0)
  statusText:SetJustifyH("RIGHT")

  -- Sidebar.
  local side = Style.Solid(frame, { 0, 0, 0, 0.2 }, "BACKGROUND", 1)
  side:SetPoint("TOPLEFT", 1, -(HEADER + 1))
  side:SetPoint("BOTTOMLEFT", 1, 1)
  side:SetWidth(SIDEBAR)
  local edge = Style.Solid(frame, Style.C.border, "BORDER")
  edge:SetPoint("TOPLEFT", side, "TOPRIGHT")
  edge:SetPoint("BOTTOMLEFT", side, "BOTTOMRIGHT")
  edge:SetWidth(1)
  layoutNav()

  -- Page area.
  local content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", SIDEBAR + 2, -(HEADER + 1))
  content:SetPoint("BOTTOMRIGHT", -1, 1)
  frame.content = content

  -- Data status once a minute while open.
  local elapsed = 0
  frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 60 then return end
    elapsed = 0
    updateStatus()
  end)
  frame:SetScript("OnShow", function() elapsed = 0; updateStatus() end)
end

-- Opens the window on a page: overview, professions, market, trends, invest, vendor,
-- ledger, analysis, settings (default: the last one shown).
function MainUI.Show(page)
  if not ns.db then return end
  if not frame then createFrame() end
  page = ALIASES[page] or page or state().page or "overview"
  if not current and state().marketSub then marketSub = state().marketSub end   -- first open
  for _, sub in ipairs(MARKET_SUBS) do
    if sub.key == page then
      marketSub, page = page, "market"
    end
  end
  if not PAGES[page] then page = "overview" end
  state().page, state().marketSub = page, marketSub
  frame:Show()
  updateStatus()
  selectPage(page)
end

-- Adds a page from another file. build(pageFrame, width, height) creates its content on
-- first use and may return an object with :Refresh() (called whenever the page shows).
-- opts.after: key of the sidebar entry it follows (after that entry's sub entries);
-- without it the page goes before the settings. Works before and after the window exists.
function MainUI.RegisterPage(key, label, build, opts)
  opts = opts or {}
  PAGES[key] = function(p)
    local obj = build(p, PAGE_W, PAGE_H)
    if type(obj) == "table" and type(obj.Refresh) == "function" then
      function p:Refresh() return obj:Refresh() end
    end
  end
  local exists = false
  for _, e in ipairs(NAV) do if e.key == key then exists = true end end
  if not exists then
    local at
    for i, e in ipairs(NAV) do
      if opts.after and (e.key == opts.after or (at and e.parent == opts.after)) then at = i + 1 end
    end
    if not at then
      at = #NAV + 1
      for i, e in ipairs(NAV) do if e.key == "settings" then at = i end end
    end
    table.insert(NAV, at, { key = key, label = label })
  end
  if frame then
    layoutNav()
    updateNav()
  end
end

function MainUI.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    MainUI.Show()
  end
end

-- Redraws the visible page.
function MainUI.Refresh()
  if not (frame and frame:IsShown() and current and pages[current]) then return end
  local page = pages[current]
  if page.Refresh then ns.Safe(page.Refresh, page) end
end

-- Own pages follow new item names, money and mails (embedded tables refresh themselves).
local pending = false
local function refreshSoon()
  if pending or not (frame and frame:IsShown()) then return end
  if current ~= "overview" and current ~= "ledger" and current ~= "analysis" and current ~= "planner" then return end
  pending = true
  C_Timer.After(0.5, function()
    pending = false
    MainUI.Refresh()
  end)
end
ns.On("GET_ITEM_INFO_RECEIVED", refreshSoon)
ns.On("PLAYER_MONEY", refreshSoon)
ns.On("MAIL_INBOX_UPDATE", refreshSoon)
ns.On("AUCTION_HOUSE_CLOSED", refreshSoon)
ns.On("DISPLAY_SIZE_CHANGED", function() MainUI.ApplyScale() end)
ns.On("UI_SCALE_CHANGED", function() MainUI.ApplyScale() end)
-- Planner: search buttons follow the auction house; new prices or a new profession
-- scan mean a new path; bags change what is left to buy.
ns.On("AUCTION_HOUSE_SHOW", function() ahShown = true; refreshSoon() end)
ns.On("AUCTION_HOUSE_CLOSED", function() ahShown = false; plannerDirty = true end)
ns.On("TRADE_SKILL_LIST_UPDATE", function() plannerDirty = true end)
ns.On("BAG_UPDATE_DELAYED", refreshSoon)
