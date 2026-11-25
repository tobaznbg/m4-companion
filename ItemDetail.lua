-- ItemDetail: detail window for any item. With the auction house open it docks right of the
-- AH panel (the Selling panel, else the auction house frame); otherwise it is a movable
-- window of its own (position in ns.db.itemDetail), closed by × or ESC.
-- Opened from everywhere: a click on a sniper hit at the auction house (Selling.lua),
-- Alt+left click on an item (bags, bank, character, loot, chat links, Blizzard's AH lists via
-- HandleModifiedItemClick; the addon's own tables via ItemDetail.AltClick) and /m4 item.
-- Shows why the offer is a sniper hit (only while it is one), the price and quantity of the
-- last 48 hours hourly or of the last 7 days (ns.Item.History, switchable), the market figures (ns.Item), the price stair
-- (the sniper's last search, else the own full scan via ns.Item.Listings) and the crafting
-- cost (ns.CraftInfo from Tooltip.lua); for recipe items what the recipe teaches
-- (ns.RecipeTeachInfo from Crafting.lua). No own price logic here.
-- Opened while the auction house is open, it searches the item right away (ns.AHSearch,
-- one search a second, through the sniper while it runs): "suche …", then the price stair
-- and "AH jetzt" of that search ("Preistreppe (gerade gesucht)").
-- "Details" right of the chart's view switch opens the big price chart (Detail.Big, below) in
-- a movable window of its own; it follows the item shown here while it is open.
local ADDON, ns = ...

local Detail = {}
ns.ItemDetail = Detail
ns.SniperDetail = Detail -- old name, kept for callers that still use it
-- The big price chart window ("Details"); filled in its own section below, declared here
-- because the small chart's button and render() call it.
local Big = {}
Detail.Big = Big

local WIDTH = 340
local FREE_HEIGHT = 560 -- height as a window of its own (docked it follows the anchor)
local LINE = 16
local CHART_H = 96
local GREEN, ORANGE = "|cff5fd38d", "|cffffb547"

local frame, body, scroll, itemID
local recipeButton -- "Im Beruf zeigen" under the crafting / recipe lines
local watchButton -- "Beobachten" / "Entfernen" at the very bottom (ns.Watch, the overlay's list)
local origin   -- "sniper" when opened from the sniper list at the auction house
local docked   -- anchor frame while docked at the auction house, nil as a window of its own
local lines, sections = {}, {}
local chart
local live     -- { itemID, state = "searching"|"done"|"failed", offers, t } of the search on opening
local liveKey -- full item key for the live search (suffix items), nil for plain items
local liveName -- the variant's name ("Zornprankengürtel des arkanen Zorns"), nil: the item's
local skin = "blizzard" -- "blizzard" (native look, default) or "m4" (own flat look)
local GOLD_RGB = { 1, 0.82, 0 }
local MEDIAN_WINDOW = 24 * 3600 -- the chart's median line: median of the hourly cheapest of the last 24 h

-- Trailing median of the cheapest offers per slot over `window` seconds (slots without an
-- offer left out; nil where the window holds none). Same basis as "Median gestern".
function Detail.RollingMedian(prices, step, window)
  local n = math.max(1, math.floor(window / step + 0.5))
  local out = {}
  for i = 1, #prices do
    local vals = {}
    for j = math.max(1, i - n + 1), i do
      local p = prices[j]
      if p and p > 0 then vals[#vals + 1] = p end
    end
    if #vals > 0 then
      table.sort(vals)
      local m = #vals
      out[i] = m % 2 == 1 and vals[(m + 1) / 2] or (vals[m / 2] + vals[m / 2 + 1]) / 2
    end
  end
  return out
end

-- Width of the scroll body: the native frame has a wider border and inset.
-- (native: as wide as the scroll frame, so the right margin equals the left one; the thin bar
-- sits in the margin)
local function contentWidth() return skin == "blizzard" and WIDTH - 28 or WIDTH - 26 end
-- Line color of the chart and highlight color of the active view: gold in the native look.
local function lineColor() return skin == "blizzard" and GOLD_RGB or ns.Style.C.accent end
local render -- forward declared: used by Show/Toggle/Refresh, defined below
local place  -- forward declared: used by create and the auction house events

local function money(c) return ns.FormatMoney(c, true) end

local function ago(t)
  local s = math.max(0, time() - t)
  if s < 60 then return string.format("vor %d s", s) end
  if s < 3600 then return string.format("vor %d min", math.floor(s / 60)) end
  if s < 2 * 86400 then return string.format("vor %d h", math.floor(s / 3600)) end
  return string.format("vor %d Tagen", math.floor(s / 86400))
end

local WEEKDAYS = { "So", "Mo", "Di", "Mi", "Do", "Fr", "Sa" }

-- Days since 1970-01-01 of a calendar date (proleptic Gregorian).
local function epochDays(yr, mo, d)
  if mo <= 2 then yr = yr - 1 end
  local era = math.floor(yr / 400)
  local yoe = yr - era * 400
  local doy = math.floor((153 * ((mo + 9) % 12) + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end

-- 01:00 UTC on the last Sunday of a month: the EU daylight saving switch.
local function lastSunday(yr, mo)
  local days = epochDays(yr, mo, 31)
  return (days - (days + 4) % 7) * 86400 + 3600
end

-- German time (CET / CEST) of an epoch, as an epoch to format with date("!...").
local function berlin(t)
  local yr = tonumber(date("!%Y", t))
  local summer = t >= lastSunday(yr, 3) and t < lastSunday(yr, 10)
  return t + (summer and 7200 or 3600)
end
Detail.Berlin = berlin

-- "Mo 14:00" in German time.
local function stamp(t)
  local b = berlin(t)
  return (WEEKDAYS[tonumber(date("!%w", b)) + 1] or "") .. " " .. date("!%H:%M", b)
end

-- "Mo 16.11., 14:00–15:00" in German time.
local function stampRange(t0, t1)
  local b0, b1 = berlin(t0), berlin(t1)
  return (WEEKDAYS[tonumber(date("!%w", b0)) + 1] or "") .. " " .. date("!%d.%m.", b0) .. ", "
    .. date("!%H:%M", b0) .. "–" .. date("!%H:%M", b1)
end

-- Days / units per day with one decimal, German style: "1,5".
function Detail.Days(d)
  local text = string.format("%.1f", d or 0):gsub("%.", ","):gsub(",0$", "")
  return text
end

-- Axis labels: only the units that are not zero ("40s", "1g 20s"), the grid steps are round.
local function axisMoney(c)
  c = math.floor((c or 0) + 0.5)
  if c == 0 then return "0" end
  local g, sv, cu = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "|cffffd100g|r" end
  if sv > 0 then parts[#parts + 1] = sv .. "|cffc7c7cfs|r" end
  if cu > 0 then parts[#parts + 1] = cu .. "|cffeda55fc|r" end
  return table.concat(parts, " ")
end

local function count(n)
  n = math.floor((n or 0) + 0.5)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

-- Layout helpers: everything is placed top-down on the scroll body with a y cursor.
local y, used, usedSections = 0, 0, 0

local function line(label, value)
  local Style = ns.Style
  used = used + 1
  local l = lines[used]
  if not l then
    l = {}
    l.label = Style.Text(body, 12)
    l.label:SetJustifyH("LEFT")
    l.label:SetTextColor(unpack(Style.C.muted))
    l.value = Style.Text(body, 12)
    l.value:SetJustifyH("RIGHT")
    lines[used] = l
  end
  l.label:ClearAllPoints()
  l.label:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -y)
  l.value:ClearAllPoints()
  l.value:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -y)
  if skin == "blizzard" then
    l.label:SetFontObject(GameFontNormalSmall)
    l.label:SetTextColor(1, 0.82, 0)
    l.value:SetFontObject(GameFontHighlightSmall)
  else
    l.label:SetFontObject(Style.Font(12))
    l.label:SetTextColor(unpack(Style.C.muted))
    l.value:SetFontObject(Style.Font(12))
  end
  l.label:SetText(label or "")
  l.value:SetText(value or "")
  -- the label gives way to its value (cut with "…" instead of running into it)
  local valueW = (value and value ~= "") and (l.value:GetStringWidth() or 0) + 10 or 0
  l.label:SetWidth(math.max(40, contentWidth() - 8 - valueW))
  l.label:SetWordWrap(false)
  l.label:Show()
  l.value:Show()
  y = y + LINE
  return l
end

local function section(title)
  local Style = ns.Style
  usedSections = usedSections + 1
  local s = sections[usedSections]
  if not s then
    s = {}
    s.text = Style.Text(body, 12)
    s.text:SetJustifyH("LEFT")
    s.rule = Style.Solid(body, Style.C.border, "ARTWORK")
    s.rule:SetHeight(1)
    sections[usedSections] = s
  end
  y = y + (usedSections > 1 and 8 or 2)
  s.text:ClearAllPoints()
  s.text:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -y)
  if skin == "blizzard" then
    s.text:SetFontObject(GameFontNormal)
    s.text:SetText(title)
    s.rule:SetColorTexture(1, 0.82, 0, 0.22)
  else
    s.text:SetFontObject(Style.Font(12))
    s.text:SetText(Style.HEAD .. title .. "|r")
    s.rule:SetColorTexture(unpack(Style.C.border))
  end
  -- the 1 px rule on whole screen pixels: with a scaled UI a plain 1 px line rounds to nothing
  -- at some heights (one section showed none)
  s.rule:ClearAllPoints()
  if PixelUtil and PixelUtil.SetPoint and PixelUtil.SetHeight then
    PixelUtil.SetHeight(s.rule, 1, 1)
    PixelUtil.SetPoint(s.rule, "TOPLEFT", body, "TOPLEFT", 4, -(y + 15))
    PixelUtil.SetPoint(s.rule, "TOPRIGHT", body, "TOPRIGHT", -4, -(y + 15))
  else
    s.rule:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -(y + 15))
    s.rule:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -(y + 15))
  end
  s.text:Show()
  s.rule:Show()
  y = y + 19
  return s
end

-- A click area over lines (top, height on the body): sets the map waypoint of loc.
local mapButtons, usedMap = {}, 0
local function mapButton(top, height, loc)
  usedMap = usedMap + 1
  local b = mapButtons[usedMap]
  if not b then
    b = CreateFrame("Button", nil, body)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.08)
    b:SetScript("OnClick", function(self) if self.loc and ns.ShowOnMap then ns.Safe(ns.ShowOnMap, self.loc) end end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Auf der Karte zeigen")
      if self.loc then
        GameTooltip:AddLine(string.format("%s – %s %.1f, %.1f", self.loc.name or "", self.loc.zone or "?",
          self.loc.x or 0, self.loc.y or 0), 1, 1, 1)
      end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    mapButtons[usedMap] = b
  end
  b.loc = loc
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -top + 2)
  b:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  b:SetHeight(height)
  b:Show()
end

-- Chart ------------------------------------------------------------------------------

-- The two views of the history, both on a fixed axis ending now (same scale for every item,
-- so charts compare). The choice is kept in ns.db.itemDetail.chart; 48 hours by default.
local VIEWS = {
  ["48h"] = { span = 48 * 3600, hourly = true, button = "48 h", title = "Preis 48 Stunden",
              empty = "48 Stunden lang nicht im Angebot" },
  ["7d"] = { span = 7 * 86400, button = "7 Tage", title = "Preis 7 Tage",
             empty = "7 Tage lang nicht im Angebot" },
}
local VIEW_ORDER = { "48h", "7d" }
Detail.SPAN = VIEWS["7d"].span

local function chartView()
  local v = ns.db and ns.db.itemDetail and ns.db.itemDetail.chart
  return VIEWS[v] and v or "48h"
end
Detail.ChartView = chartView

-- Scale of the price axis without outliers: every price within [low, high] is drawn true to
-- scale, the rest is cut at the edge (low/high nil: nothing cut). Quartiles of the listed
-- prices; the fences are Tukey's "far out" ones (3 IQR beyond the quartiles), widened to at
-- least ×1.5 / ÷1.5 of the quartile, so a calm item does not lose a normal swing of a few
-- per cent (its IQR is about 0). Needs 8 prices, with fewer nothing is cut.
function Detail.ChartScale(values)
  local n = #values
  if n < 8 then return nil, nil end
  local sorted = {}
  for i = 1, n do sorted[i] = values[i] end
  table.sort(sorted)
  local function quantile(q)
    local pos = 1 + (n - 1) * q
    local i = math.floor(pos)
    local f = pos - i
    return sorted[i] + ((sorted[i + 1] or sorted[i]) - sorted[i]) * f
  end
  local q1, q3 = quantile(0.25), quantile(0.75)
  local iqr = q3 - q1
  local high = math.max(q3 + 3 * iqr, q3 * 1.5)
  local low = math.min(q1 - 3 * iqr, q1 / 1.5)
  return (sorted[1] < low) and low or nil, (sorted[n] > high) and high or nil
end

local function createChart()
  local Style = ns.Style
  local c = CreateFrame("Frame", nil, body)
  c:SetHeight(CHART_H + 42)
  c.plot = CreateFrame("Frame", nil, c)
  c.plot:SetPoint("TOPLEFT", 0, 0)
  c.plot:SetPoint("TOPRIGHT", 0, 0)
  c.plot:SetHeight(CHART_H)
  local bg = Style.Solid(c.plot, { 1, 1, 1, 0.025 })
  bg:SetAllPoints()
  c.base = Style.Solid(c.plot, Style.C.border, "ARTWORK")
  c.base:SetHeight(1)
  c.base:SetPoint("BOTTOMLEFT")
  c.base:SetPoint("BOTTOMRIGHT")
  c.bars, c.lines, c.ticks, c.marks, c.markLabels, c.medLines = {}, {}, {}, {}, {}, {}
  c.limit = Style.Solid(c.plot, { 0.37, 0.83, 0.55, 0.5 }, "ARTWORK")
  c.limit:SetHeight(1)
  c.sell = Style.Solid(c.plot, { 1, 1, 1, 0.45 }, "ARTWORK")
  c.sell:SetHeight(1)
  local function label(size, point, x, yy)
    local fs = Style.Text(c, size)
    fs:SetPoint(point, c.plot, point, x, yy)
    fs:SetTextColor(unpack(Style.C.muted))
    return fs
  end
  c.hi = label(10, "TOPLEFT", 3, -2)
  c.lo = label(10, "BOTTOMLEFT", 3, 3)
  c.qtyMax = label(10, "TOPRIGHT", -3, -2)
  c.t1 = Style.Text(c, 10)
  c.t1:SetPoint("TOPLEFT", c.plot, "BOTTOMLEFT", 0, -2)
  c.t2 = Style.Text(c, 10)
  c.t2:SetPoint("TOP", c.plot, "BOTTOM", 0, -2)
  c.t3 = Style.Text(c, 10)
  c.t3:SetPoint("TOPRIGHT", c.plot, "BOTTOMRIGHT", 0, -2)
  c.legend = Style.Text(c, 10)
  c.legend:SetPoint("TOPLEFT", c.plot, "BOTTOMLEFT", 0, -15)
  c.legend:SetPoint("RIGHT", c, "RIGHT", 0, 0)
  c.legend:SetJustifyH("LEFT")
  c.legend:SetWordWrap(true) -- two lines with buy/sell lines
  for _, fs in ipairs({ c.t1, c.t2, c.t3, c.legend }) do fs:SetTextColor(unpack(Style.C.muted)) end
  c.empty = Style.Text(c.plot, 11)
  c.empty:SetPoint("CENTER")
  c.empty:SetTextColor(unpack(Style.C.muted))
  -- "Details" at the right end of the title row: the big chart of this item (Detail.Big).
  -- Apart from the segment switch (a gap), since it opens a window instead of switching a view.
  c.details = Style.Button(c, "Details", 50, 16, function()
    if itemID then ns.Safe(Big.Toggle, itemID) end
  end)
  c.details.label:SetFontObject(Style.Font(10))
  c.details:SetPoint("BOTTOMRIGHT", c.plot, "TOPRIGHT", 0, 5)
  c.details:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Großes Diagramm")
    GameTooltip:AddLine("Preisverlauf dieses Items in einem eigenen Fenster, feinste Auflösung.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  c.details:HookScript("OnLeave", function() GameTooltip:Hide() end)
  -- Segment switch "48 h | 7 Tage" on the section's title row, left of "Details".
  c.views = {}
  local right
  for k = #VIEW_ORDER, 1, -1 do
    local key = VIEW_ORDER[k]
    local b = Style.Button(c, VIEWS[key].button, key == "7d" and 46 or 38, 16, function()
      ns.db.itemDetail = ns.db.itemDetail or {}
      ns.db.itemDetail.chart = key
      render()
    end)
    b.label:SetFontObject(Style.Font(10))
    if right then
      b:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 1, 0) -- shared border, one segment control
    else
      b:SetPoint("BOTTOMRIGHT", c.details, "BOTTOMLEFT", -4, 0)
    end
    b.key = key
    c.views[key] = b
    right = b
  end
  -- Hover: a vertical line and a bubble with time, cheapest offer and units of that slot.
  c.cursor = Style.Solid(c.plot, { 1, 1, 1, 0.4 }, "OVERLAY")
  c.cursor:SetWidth(1)
  c.cursor:Hide()
  c.bubble = CreateFrame("Frame", nil, c)
  c.bubble:SetFrameLevel((c.plot:GetFrameLevel() or 1) + 5)
  local bbg = Style.Solid(c.bubble, Style.C.header)
  bbg:SetAllPoints()
  Style.Border(c.bubble)
  c.bubble.text = Style.Text(c.bubble, 10)
  c.bubble.text:SetPoint("TOPLEFT", 5, -4)
  c.bubble.text:SetJustifyH("LEFT")
  c.bubble.text:SetWordWrap(true)
  c.bubble:Hide()
  local plot = c.plot
  plot:EnableMouse(true)
  local function track(self)
    local x = GetCursorPosition()
    local scale = self:GetEffectiveScale() or 1
    local left = self:GetLeft()
    if not (x and left) then return end
    Detail.ChartHover(x / scale - left)
  end
  plot:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", track) end)
  plot:SetScript("OnLeave", function(self)
    self:SetScript("OnUpdate", nil)
    Detail.ChartHover(nil)
  end)
  return c
end

local function pooled(list, i, make)
  local t = list[i]
  if not t then t = make(); list[i] = t end
  t:Show()
  return t
end

local function hideFrom(list, first)
  for i = first, #list do list[i]:Hide() end
end

-- "Details" lit while the big chart shows this window's item.
local function updateDetailsButton()
  local b = chart and chart.details
  if not b then return end
  local on = itemID ~= nil and Big.Shows(itemID)
  b.active = on
  b.bg:SetColorTexture(unpack(on and ns.Style.C.buttonHi or ns.Style.C.button))
  b.label:SetTextColor(unpack(on and lineColor() or ns.Style.C.muted))
end
Detail.UpdateDetailsButton = updateDetailsButton

-- Draws the history on the fixed axis of the chosen view (48 hours in 1-hour slots or 7 days
-- in 2-hour slots, "jetzt" at the right edge): quantity as muted bars, cheapest offer as an
-- accent line (broken where the item was sold out or no snapshot exists), sold-out slots as
-- orange ticks on the base line, buy up to (green) and sell at (white) as thin lines. Time
-- without data stays empty. Outliers (Detail.ChartScale) are drawn at the edge and marked
-- with their price ("276g ▲"), so they do not flatten the normal range.
local function drawChart(c, history, limit, sellAt, viewKey)
  local Style = ns.Style
  local view = VIEWS[viewKey] or VIEWS["48h"]
  local SPAN = view.span
  local plot = c.plot
  updateDetailsButton()
  for key, b in pairs(c.views) do
    local on = key == viewKey
    b.active = on
    b.bg:SetColorTexture(unpack(on and Style.C.buttonHi or Style.C.button))
    b.label:SetTextColor(unpack(on and lineColor() or Style.C.muted))
  end
  local w = contentWidth() - 8 -- body width minus the chart's margins
  local prices, qty = history and history.prices or {}, history and history.qty or {}
  local SLOTS = #prices
  local step = history and history.step or 3600
  local axisEnd = time()
  local axisStart = axisEnd - SPAN
  local slotW = w * step / SPAN
  -- x of slot i on the fixed axis (nil: before the axis or in the future)
  local function sx(i)
    local t0 = history.start + (i - 1) * step
    if t0 + step <= axisStart or t0 > axisEnd then return nil end
    return (t0 - axisStart) / SPAN * w
  end
  c.view = nil
  c.cursor:Hide()
  c.bubble:Hide()
  local values, qmax = {}, 0
  for i = 1, SLOTS do
    if sx(i) then
      local p, q = prices[i], qty[i]
      if p and p > 0 then values[#values + 1] = p end
      if q and q > qmax then qmax = q end
    end
  end
  if #values == 0 then
    c.empty:SetText(history and view.empty or "Kein Verlauf für dieses Item")
    c.empty:Show()
    hideFrom(c.bars, 1); hideFrom(c.lines, 1); hideFrom(c.ticks, 1); hideFrom(c.medLines, 1)
    hideFrom(c.marks, 1); hideFrom(c.markLabels, 1)
    c.limit:Hide()
    c.sell:Hide()
    c.hi:SetText(""); c.lo:SetText(""); c.qtyMax:SetText("")
    c.t1:SetText(""); c.t2:SetText(""); c.t3:SetText("")
    c.legend:SetText("")
    return
  end
  c.empty:Hide()
  -- Scale: the median line (the market value) sets it; the cheapest offers are drawn up to
  -- 1.5x its highest and down to half its lowest value, beyond that cut with a marker.
  local med = Detail.RollingMedian(prices, step, MEDIAN_WINDOW)
  local medLo, medHi
  for i = 1, SLOTS do
    local m = med[i]
    if m and sx(i) then medLo, medHi = math.min(medLo or m, m), math.max(medHi or m, m) end
  end
  local cutLow, cutHigh
  if medLo then
    cutLow, cutHigh = medLo * 0.5, medHi * 1.5
  else
    cutLow, cutHigh = Detail.ChartScale(values)
  end
  local lo, hi = medLo, medHi
  for _, p in ipairs(values) do
    if not (cutLow and p < cutLow) and not (cutHigh and p > cutHigh) then
      lo, hi = math.min(lo or p, p), math.max(hi or p, p)
    end
  end
  local top, bottom = hi, lo
  for _, v in ipairs({ limit or 0, sellAt or 0 }) do
    if v > 0 then top, bottom = math.max(top, v), math.min(bottom, v) end
  end
  if top == bottom then top, bottom = top * 1.05 + 1, bottom * 0.95 end
  local plotTop, plotBottom = CHART_H - 14, 12 -- room for the min/max labels
  local function py(p)
    p = math.max(bottom, math.min(top, p))
    return plotBottom + (p - bottom) / (top - bottom) * (plotTop - plotBottom)
  end
  c.view = { history = history, axisStart = axisStart, span = SPAN, w = w, step = step, sx = sx }
  -- quantity bars
  local nb = 0
  for i = 1, SLOTS do
    local q, x0 = qty[i], sx(i)
    if x0 and q and q > 0 and qmax > 0 then
      nb = nb + 1
      local bar = pooled(c.bars, nb, function() return Style.Solid(plot, { 1, 1, 1, 0.09 }, "BORDER") end)
      bar:ClearAllPoints()
      bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", math.max(0, x0) + 0.5, 1)
      bar:SetSize(math.max(1, slotW - 1), math.max(1, (CHART_H - 2) * q / qmax))
    end
  end
  hideFrom(c.bars, nb + 1)
  -- price line, sold-out ticks and the runs of cut outliers (one marker each, at its extreme)
  local nl, nt, last = 0, 0, nil
  local runs, run = {}, nil
  for i = 1, SLOTS do
    local p, x0 = prices[i], sx(i)
    local x = x0 and (x0 + slotW / 2)
    local side = x0 and p and p > 0 and ((cutHigh and p > cutHigh and 1) or (cutLow and p < cutLow and -1)) or nil
    if side and run and run.side == side and run.last == i - 1 then
      run.last = i
      if p * side > run.p * side then run.p, run.x = p, x end
    elseif side then
      run = { side = side, last = i, p = p, x = x }
      runs[#runs + 1] = run
    else
      run = nil
    end
    if not x0 then
      last = nil
    elseif p and p > 0 then
      local yy = py(p)
      -- connected to the previous slot, or a short dash after a gap so it stays visible
      local x0, y0, x1 = x - 1.5, yy, x + 1.5
      if last and last[1] == i - 1 then x0, y0, x1 = last[2], last[3], x end
      if plot.CreateLine then
        nl = nl + 1
        local l = pooled(c.lines, nl, function()
          local ln = plot:CreateLine(nil, "ARTWORK")
          ln:SetThickness(1.5)
          return ln
        end)
        l:SetColorTexture(0.75, 0.75, 0.78, 0.55)
        l:SetStartPoint("BOTTOMLEFT", plot, x0, y0)
        l:SetEndPoint("BOTTOMLEFT", plot, x1, yy)
      end
      last = { i, x, yy }
    else
      last = nil
      if p == 0 then
        nt = nt + 1
        local t = pooled(c.ticks, nt, function() return Style.Solid(plot, { 1, 0.71, 0.28, 0.9 }, "OVERLAY") end)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", math.max(0, x0) + 0.5, 1)
        t:SetSize(math.max(1, slotW - 1), 3)
      end
    end
  end
  hideFrom(c.lines, nl + 1)
  hideFrom(c.ticks, nt + 1)
  -- median line (24 h, the market value): drawn over the cheapest line
  c.view.median = med
  local nm2, prev = 0, nil
  for i = 1, SLOTS do
    local m, x0 = med[i], sx(i)
    if x0 and m then
      local x, yy = x0 + slotW / 2, py(m)
      if prev and prev[1] == i - 1 and plot.CreateLine then
        nm2 = nm2 + 1
        local l = pooled(c.medLines, nm2, function()
          local ln = plot:CreateLine(nil, "OVERLAY")
          ln:SetThickness(2)
          return ln
        end)
        l:SetColorTexture(unpack(lineColor()))
        l:SetStartPoint("BOTTOMLEFT", plot, prev[2], prev[3])
        l:SetEndPoint("BOTTOMLEFT", plot, x, yy)
      end
      prev = { i, x, yy }
    else
      prev = nil
    end
  end
  hideFrom(c.medLines, nm2 + 1)
  -- Outlier markers: a small cap on the edge and the price; the most extreme runs first, at
  -- most 3 labels and none overlapping another one (the caps are always drawn).
  table.sort(runs, function(a, b) return math.abs(a.p - (a.side > 0 and top or bottom)) > math.abs(b.p - (b.side > 0 and top or bottom)) end)
  local nm, placed, coverHi, coverLo = 0, {}, false, false
  for k, r in ipairs(runs) do
    local cap = pooled(c.marks, k, function() return Style.Solid(plot, { 1, 0.71, 0.28, 1 }, "OVERLAY") end)
    cap:ClearAllPoints()
    cap:SetPoint("CENTER", plot, "BOTTOMLEFT", r.x, r.side > 0 and plotTop + 1 or plotBottom - 1)
    cap:SetSize(5, 3)
    local free = nm < 3
    for _, px in ipairs(placed) do
      if math.abs(px - r.x) < 64 then free = false end
    end
    if free then
      nm = nm + 1
      placed[#placed + 1] = r.x
      local fs = pooled(c.markLabels, nm, function()
        local t = Style.Text(c, 10)
        t:SetTextColor(1, 0.71, 0.28, 1)
        return t
      end)
      fs:ClearAllPoints()
      local lx = math.max(32, math.min(w - 32, r.x)) -- keep the label inside the plot
      if lx < 90 then
        if r.side > 0 then coverHi = true else coverLo = true end
      end
      if r.side > 0 then
        fs:SetPoint("BOTTOM", plot, "BOTTOMLEFT", lx, plotTop + 3)
        fs:SetText(money(r.p) .. " ▲")
      else
        fs:SetPoint("TOP", plot, "BOTTOMLEFT", lx, plotBottom - 1)
        fs:SetText(money(r.p) .. " ▼")
      end
    end
  end
  hideFrom(c.marks, #runs + 1)
  hideFrom(c.markLabels, nm + 1)
  if sellAt and sellAt > 0 then
    c.sell:ClearAllPoints()
    c.sell:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, py(sellAt))
    c.sell:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, py(sellAt))
    c.sell:Show()
  else
    c.sell:Hide()
  end
  if limit and limit > 0 then
    c.limit:ClearAllPoints()
    c.limit:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, py(limit))
    c.limit:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, py(limit))
    c.limit:Show()
  else
    c.limit:Hide()
  end
  -- min/max labels: the true-to-scale range (left out where an outlier label sits)
  c.hi:SetText(coverHi and "" or money(hi))
  c.lo:SetText(coverLo and "" or money(lo))
  c.qtyMax:SetText(qmax > 0 and ("max " .. count(qmax) .. " Stück") or "")
  c.t1:SetText(stamp(axisStart))
  c.t2:SetText(stamp(axisStart + SPAN / 2))
  c.t3:SetText("jetzt")
  c.legend:SetText("") -- no legend: gold = median, grey = cheapest is clear from the hover
end

-- Hover at x pixels from the plot's left edge (nil: mouse left): line on the slot under the
-- mouse and the bubble "Mo 16.11., 14:00–15:00 / billigstes … / … Stück". Returns the bubble
-- text (nil when nothing is shown).
function Detail.ChartHover(x)
  local c = chart
  if not c then return nil end
  local v = c.view
  if not (x and v and x >= 0 and x <= v.w) then
    c.cursor:Hide()
    c.bubble:Hide()
    return nil
  end
  local h = v.history
  local i = math.floor((v.axisStart + x / v.w * v.span - h.start) / v.step) + 1
  local x0 = i >= 1 and i <= #h.prices and v.sx(i)
  if not x0 then
    c.cursor:Hide()
    c.bubble:Hide()
    return nil
  end
  local cx = math.max(0, math.min(v.w, x0 + v.w * v.step / v.span / 2))
  local t0 = h.start + (i - 1) * v.step
  local p, q = h.prices[i], h.qty[i]
  local priceText
  if p and p > 0 then priceText = "billigstes " .. money(p)
  elseif p == 0 then priceText = ORANGE .. "nicht im Angebot|r"
  else priceText = ns.Style.MUTED .. "kein Snapshot|r" end
  local m = v.median and v.median[i]
  if m then priceText = "Marktwert 24 h " .. money(m) .. "\n" .. priceText end
  local text = stampRange(t0, t0 + v.step) .. "\n" .. priceText
    .. ((q and q > 0) and ("\n" .. count(q) .. " Stück") or "")
  c.cursor:ClearAllPoints()
  c.cursor:SetPoint("TOPLEFT", c.plot, "TOPLEFT", cx, 0)
  c.cursor:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", cx, 0)
  c.cursor:Show()
  local b = c.bubble
  b.text:SetText(text)
  b:SetSize(math.max(60, (b.text:GetStringWidth() or 0) + 10), (b.text:GetStringHeight() or 0) + 8)
  b:ClearAllPoints()
  -- beside the line, on the side with more room
  if cx > v.w / 2 then
    b:SetPoint("TOPRIGHT", c.plot, "TOPLEFT", cx - 4, -2)
  else
    b:SetPoint("TOPLEFT", c.plot, "TOPLEFT", cx + 4, -2)
  end
  b:Show()
  return text
end

-- Big chart ("Details") ----------------------------------------------------------------
-- The price history of one item in a large window of its own (NativeWindow look), opened by
-- "Details" over the small chart and following the market data window's item while open.
-- Finest slots the data has (Detail.FineSeries): the hourly ones where the collector sent
-- them (last 48 hours), the 2-hour ones before. Only the chart: price grid, day changes and
-- hour marks, the quantity as bars on their own smaller scale, R and - for an item of the day
-- trading pool - its buy limit, ask and the daily buy / sell windows as bands.
-- Prices are volatile: while open it redraws on new observations of the item (own searches
-- and scans, other players' via the cloud or the addon channel; bundled, at most once a
-- second) and every 30 seconds (age, "jetzt" edge, windows). Every price the item showed
-- this session that is newer than the history (Item.Get's now, by its time) is kept and
-- drawn as a lighter live tail right of the curve.
-- Every texture, line and label is pooled per kind and reused on each redraw; OnUpdate only
-- tracks the mouse.

-- The finest history of an item: the 2-hour slots up to where the hourly ones begin, then
-- the hourly ones. { t0 = {}, t1 = {}, p = {}, q = {} } per slot (p: cheapest offer, 0 = not
-- listed, false = no snapshot), first = start of the first slot with a snapshot, hourFrom =
-- start of the hourly slots (nil without), lastT = start of the last slot with a snapshot;
-- nil without any history.
function Detail.FineSeries(id)
  local coarse = ns.Item.History(id)
  local fine = ns.Item.History(id, true)
  if fine and not fine.hourly then fine = nil end -- no hourly line: History gave the 2-hour one
  local s = { t0 = {}, t1 = {}, p = {}, q = {}, hourFrom = fine and fine.start or nil }
  local cut = fine and fine.start or math.huge
  local function add(t0, t1, p, q)
    local n = #s.t0 + 1
    s.t0[n], s.t1[n], s.p[n], s.q[n] = t0, t1, p, q or false
    if p ~= false and p ~= nil then
      s.first = s.first or t0
      s.lastT = t0
    end
  end
  if coarse then
    for i = 1, #coarse.prices do
      local t0 = coarse.start + (i - 1) * coarse.step
      if t0 >= cut then break end
      -- a 2-hour slot reaching into the hourly ones ends where they begin
      add(t0, math.min(t0 + coarse.step, cut), coarse.prices[i], coarse.qty[i])
    end
  end
  if fine then
    for i = 1, #fine.prices do
      local t0 = fine.start + (i - 1) * fine.step
      add(t0, t0 + fine.step, fine.prices[i], fine.qty[i])
    end
  end
  return #s.t0 > 0 and s or nil
end

-- Bait and fish ("Köder und Fischen", live view of the chart window): one unit is posted just
-- under a catch limit as bait; undercutters post their stacks a copper under it, and what others
-- offer at or under the catch limit is bought - every post and every buy on a click of the
-- player, the addon never posts or buys by itself. The figures come from the item's last
-- commodity search, rows { { unit, qty, own }... } (own: the player's units in the row):
--   M (market): the first price level at which the foreign units up to and including it reach
--     FISH_DEPTH - a few single units in front (our own bait among them) cannot move it, a big
--     stack at the front still counts (a level after it would overstate the market and turn the
--     whole market into a catch).
--   F (catch limit) = floor((M × (1 − cut) − deposit) / (1 + minGain)), deposit = vendorSell ×
--     5 % (2 h): what is bought at F and sold again at M leaves minGain after cut and deposit.
--   K (bait) = vendor price + 25 % (without one: 55 % of M), at most 1c under the cheapest foreign
--     offer and F − 1: undercutters orient on the cheapest offer, and a bait just above the
--     vendor price costs next to nothing when a bargain hunter takes it (the vendor would not
--     have paid more) - the other bait setters at Schweres Leder use exactly that (1s50 -> 1s88).
--   N: foreign units at or under F and at most at the price of our own cheapest offer (the game
--     refuses a purchase that would take an own unit), cheapest first, as the budget pays.
-- Returns { market, dep, limit = F, bait = K, baitLies, catch (foreign units <= F), n, sum, top
-- (dearest unit price taken), left (budget left) }; market / limit nil when there is none.
Detail.FISH_DEPTH = 20
local FISH_CUT, FISH_DEPOSIT = 0.05, 0.05
local FISH_BAIT_LIFE = 2 * 3600 - 60 -- a bait gone earlier than its 2 h was taken

function Detail.FishPlan(rows, vendorSell, minGain, budget, spent)
  local list = {}
  for i, r in ipairs(rows or {}) do list[i] = r end
  table.sort(list, function(a, b) return a.unit < b.unit end)
  local function foreign(r) return math.max(0, (r.qty or 0) - (r.own or 0)) end
  local p = { catch = 0, n = 0, sum = 0, left = math.max(0, (budget or 0) - (spent or 0)) }
  local seen = 0
  for _, r in ipairs(list) do
    seen = seen + foreign(r)
    if seen >= Detail.FISH_DEPTH then p.market = r.unit break end
  end
  if not p.market then return p end
  p.dep = (vendorSell or 0) * FISH_DEPOSIT
  -- the epsilon keeps a whole result whole (0.95 is not exact in binary)
  local limit = math.floor((p.market * (1 - FISH_CUT) - p.dep) / (1 + (minGain or 0)) + 1e-6)
  if limit < 2 then return p end
  local cheapest
  for _, r in ipairs(list) do
    if foreign(r) > 0 then cheapest = r.unit break end
  end
  local low = (vendorSell and vendorSell > 0) and math.ceil(vendorSell * 1.25) or math.floor(p.market * 0.55)
  p.limit, p.bait = limit, math.max(1, math.min(limit - 1, cheapest and cheapest - 1 or limit - 1, low))
  -- The game sells the cheapest N units and refuses a purchase that would take an own one
  -- ("DatabaseError"): N counts foreign units up to the price of our cheapest own offer (our
  -- bait) - same price included, which order the game takes within one price shows in play -
  -- cheapest first; dearer levels not. A level the budget no longer pays in full is the last.
  local left = p.left
  p.ownIn = 0
  local ownFrom -- the price of our cheapest own offer: foreign ones up to it count, dearer not
  for _, r in ipairs(list) do
    if r.unit > limit or (ownFrom and r.unit > ownFrom) then break end
    if (r.own or 0) > 0 then
      if r.unit <= p.bait then p.baitLies = true end
      ownFrom = ownFrom or r.unit
    end
    local f = foreign(r)
    p.catch = p.catch + f
    local take = math.min(f, math.floor(left / r.unit))
    if take > 0 then
      p.n, p.sum, left, p.top = p.n + take, p.sum + take * r.unit, left - take * r.unit, r.unit
    end
    if take < f then break end
  end
  -- an own bait further back still "lies" for the button
  if not p.baitLies then
    for _, r in ipairs(list) do
      if (r.own or 0) > 0 and r.unit <= p.bait then p.baitLies = true break end
    end
  end
  return p
end

do
  local NAME = "M4CompanionPriceChart"
  local W, H = 900, 560
  local LEFT, RIGHT, TOP, BOTTOM = 70, 124, 74, 34 -- plot margins in the page (right: the labels, "jetzt … +12 %")
  -- the live view's bottom margin: the bait and fish line and buttons go under the time axis
  local BOTTOM_LIVE = 100
  local RANGES = {
    { key = "live", span = 20 * 60, button = "Live", label = "20 min" },
    { key = "today", today = true, button = "Heute", label = "heute" },
    { key = "2d", span = 2 * 86400, button = "2 Tage", label = "2 Tage" },
    { key = "7d", span = 7 * 86400, button = "7 Tage", label = "7 Tage" },
    { key = "all", button = "Alles", label = "alles" },
  }
  local BUY_RGB, SELL_RGB = { 0.37, 0.83, 0.55 }, { 0.45, 0.68, 1 }
  local OUT_RGB, TAIL_RGB = { 1, 0.71, 0.28 }, { 0.85, 0.95, 1 }
  local USUAL_RGB = { 0.78, 0.62, 1 } -- the usual price at this hour of the day
  local OWN_RGB = { 1, 0.45, 0.75 } -- our own running auctions
  local SOURCES = { cloud = "Cloud-Snapshot", scan = "eigener Vollscan", search = "eigene Suche",
    players = "andere Spieler (Cloud)", live = "andere Spieler (live)" }
  local TAIL_MAX = 1500 -- fine points kept per item and house (only changes: a busy day fits)
  local win, ui, shownID, ticker, pending
  local liveTicker -- the search every second while shown at the auction house
  local draw, hover -- forward declared
  local used = {}
  -- "house:itemID" -> { { t, p, q, src }... } oldest first: own and live observations finer than
  -- the hourly history, kept in the saved variables for TAIL_KEEP (across reloads and logins)
  local TAIL_KEEP = 48 * 3600
  local function tailStore()
    ns.db.chartTail = ns.db.chartTail or {}
    return ns.db.chartTail
  end

  -- Epoch of a German time (Detail.Berlin's inverse; off by an hour only inside the DST hour).
  local function fromBerlin(b)
    local t = b - 7200
    if berlin(t) ~= b then t = b - 3600 end
    return t
  end

  -- "Mo 23.11., 14:37" in German time.
  local function stampFull(t)
    local b = berlin(t)
    return (WEEKDAYS[tonumber(date("!%w", b)) + 1] or "") .. " " .. date("!%d.%m., %H:%M", b)
  end

  -- A 1 px line on whole screen pixels: with a scaled UI a plain 1 px line can round to nothing.
  local function thin(t, vertical)
    if vertical then
      if PixelUtil and PixelUtil.SetWidth then PixelUtil.SetWidth(t, 1, 1) else t:SetWidth(1) end
    elseif PixelUtil and PixelUtil.SetHeight then PixelUtil.SetHeight(t, 1, 1) else t:SetHeight(1) end
  end

  -- Pools: take(kind) hands out the next object of a kind (made by MAKERS[kind] on first
  -- need), finish() hides what this draw did not use. No objects are made on a redraw that
  -- needs no more than an earlier one.
  local function tex(layer, sub, r, g, b, a)
    local t = ui.plot:CreateTexture(nil, layer, nil, sub)
    t:SetColorTexture(r, g, b, a)
    return t
  end
  local function label(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetWordWrap(false)
    return fs
  end
  local MAKERS = {
    band = function() return tex("BACKGROUND", 1, 1, 1, 1, 0.08) end,
    vgrid = function() local t = tex("BACKGROUND", 2, 1, 1, 1, 0.04); thin(t, true); return t end,
    grid = function() local t = tex("BACKGROUND", 3, 1, 1, 1, 0.08); thin(t); return t end,
    day = function() local t = tex("BACKGROUND", 4, 1, 1, 1, 0.22); thin(t, true); return t end,
    bar = function() return tex("BORDER", 0, 1, 1, 1, 0.13) end,
    -- the live tail's quantities: lighter, so the newest supply stands out
    tailBar = function() return tex("BORDER", 1, TAIL_RGB[1], TAIL_RGB[2], TAIL_RGB[3], 0.35) end,
    dash = function() local t = tex("ARTWORK", 1, 1, 1, 1, 1); thin(t); return t end,
    mark = function() return tex("OVERLAY", 0, 1, 1, 1, 1) end,
    line = function()
      local l = ui.plot:CreateLine(nil, "ARTWORK", nil, 2)
      l:SetThickness(1.5)
      return l
    end,
    yLabel = function()
      local fs = label(ui.page, "GameFontHighlightSmall")
      fs:SetTextColor(0.7, 0.7, 0.72)
      fs:SetJustifyH("RIGHT")
      return fs
    end,
    hourLabel = function()
      local fs = label(ui.page, "GameFontHighlightSmall")
      fs:SetTextColor(0.6, 0.6, 0.62)
      return fs
    end,
    dayLabel = function() return label(ui.page, "GameFontNormalSmall") end,
    refLabel = function() return label(ui.page, "GameFontHighlightSmall") end,
  }
  local function take(kind)
    local n = (used[kind] or 0) + 1
    used[kind] = n
    local list = ui.pool[kind]
    local o = list[n]
    if not o then o = MAKERS[kind](); list[n] = o end
    o:Show()
    return o
  end
  local function finish()
    for kind, list in pairs(ui.pool) do hideFrom(list, (used[kind] or 0) + 1) end
  end

  -- A line segment in plot coordinates (bottom left = 0, 0); nothing without CreateLine.
  local function segment(x0, y0, x1, y1, rgb, alpha)
    if not ui.plot.CreateLine then return end
    local l = take("line")
    l:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha or 1)
    l:SetStartPoint("BOTTOMLEFT", ui.plot, x0, y0)
    l:SetEndPoint("BOTTOMLEFT", ui.plot, x1, y1)
  end

  -- A small square centered on x, yy (or a bar of size w x h when given).
  local function mark(x, yy, size, rgb, alpha)
    local m = take("mark")
    m:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha or 1)
    m:ClearAllPoints()
    m:SetPoint("CENTER", ui.plot, "BOTTOMLEFT", x, yy)
    m:SetSize(size, size)
    return m
  end

  -- A dashed horizontal line across the plot at height yy (dashes len px every step px:
  -- 6 / 10 by default, 2 / 5 a dotted line).
  local function dashed(yy, w, rgb, len, step)
    len, step = len or 6, step or 10
    local x = 0
    while x < w do
      local d = take("dash")
      d:SetColorTexture(rgb[1], rgb[2], rgb[3], 0.85)
      d:ClearAllPoints()
      d:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", x, yy)
      d:SetWidth(math.min(len, w - x))
      x = x + step
    end
  end

  -- 1, 2 or 5 times a power of ten, whole copper: about n steps over range.
  local function niceStep(range, n)
    local raw = math.max(range / n, 1)
    local mag = 1 -- the power of ten at or under raw (a loop: exact, no float logarithm)
    while mag * 10 <= raw do mag = mag * 10 end
    local f = raw / mag
    return (f <= 1 and 1 or f <= 2 and 2 or f <= 5 and 5 or 10) * mag
  end

  local function median(values)
    local sorted = {}
    for i, v in ipairs(values) do sorted[i] = v end
    table.sort(sorted)
    local m = #sorted
    if m == 0 then return nil end
    return m % 2 == 1 and sorted[(m + 1) / 2] or (sorted[m / 2] + sorted[m / 2 + 1]) / 2
  end

  local function rangeDef()
    local k = ns.db and ns.db.itemDetail and ns.db.itemDetail.bigRange
    for _, r in ipairs(RANGES) do
      if r.key == k then return r end
    end
    return RANGES[4] -- 7 days
  end

  -- Live tail ------------------------------------------------------------------------------

  -- The session's points of the item in the current house (created on first need).
  local function tailOf(id)
    local tails = tailStore()
    local key = tostring(ns.AuctionHouse.CloudID() or ns.AuctionHouse.Current()) .. ":" .. id
    local list = tails[key]
    if not list then list = {}; tails[key] = list end
    return list
  end
  -- old points go on login: older than TAIL_KEEP, empty lists too
  ns.OnReady(function()
    local tails, cut = tailStore(), time() - TAIL_KEEP
    for key, list in pairs(tails) do
      local keep = {}
      for _, pt in ipairs(list) do if pt.t >= cut then keep[#keep + 1] = pt end end
      tails[key] = #keep > 0 and keep or nil
    end
  end)

  -- Remembers the item's price now (Item.Get) as a point when its time is new. The cloud
  -- snapshot is what the history is made of: it is not a live point.
  local function record(id, e)
    if not (e and e.dataT) or e.dataSource == "cloud" then return end
    local list = tailOf(id)
    local last = list[#list]
    if last and last.t >= e.dataT then return end
    -- searched every second: a new point only when price or quantity moved (else the line
    -- would fill with repeats and push the older live points out)
    if last and last.p == (e.now or 0) and last.q == e.quantity then return end
    list[#list + 1] = { t = e.dataT, p = e.now or 0, q = e.quantity, src = e.dataSource }
    if #list > TAIL_MAX then table.remove(list, 1) end
  end

  -- Window ---------------------------------------------------------------------------------

  local function setActive(b, on)
    local bg = rawget(b, "bg")
    if bg then -- the flat fallback button
      b.active = on
      bg:SetColorTexture(unpack(on and ns.Style.C.buttonHi or ns.Style.C.button))
    elseif b.LockHighlight then
      if on then b:LockHighlight() else b:UnlockHighlight() end
    end
    local fs = rawget(b, "label") or (b.GetFontString and b:GetFontString())
    if fs then
      if on then fs:SetTextColor(1, 1, 1) else fs:SetTextColor(1, 0.82, 0) end
    end
  end

  local function button(parent, text, width, onClick)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not (ok and b) then return ns.Style.Button(parent, text, width, 22, onClick) end
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
  end

  -- Bait and fish (live view) -------------------------------------------------------------
  -- Session state: the rows of the shown item's last commodity search, the one price quote we
  -- asked for (pending = { itemID, n, sum, limit, state = "asking"|"confirm"|"buying", total }),
  -- whether the game demands a click for asking (autoBlocked). Only a quote we asked for is
  -- ours: Blizzard's own buy dialog gets the same price events.
  -- Figures per item in ns.db.fish = { day, spent (copper bought today, all items), items =
  -- { [itemID] = { minGain, budget } } }; a new day starts spent at 0.
  local Fish = {}
  local FISH_DURATION = 1 -- 2 h in this client (Selling.lua's durations: 1 = 2 h, 2 = 8 h, 3 = 24 h)
  local FISH_GAINS = { 0.10, 0.15, 0.20, 0.30 }
  local FISH_BUDGETS = { 100000, 250000, 300000, 500000, 1000000 }
  local FISH_DEFAULT = { minGain = 0.15, budget = 300000 }
  -- seconds: no answer to a quote, an unclicked "Bestätigen", no answer to a buy, and the pause
  -- after a dropped quote before the next one is asked by itself
  -- BUY_TIMEOUT: purchase answers came after 0.10-0.89 s (148 measured, 24 Nov); a confirm the
  -- game drops from its queue never gets one - 2 s, not 10 s blind
  local QUOTE_TIMEOUT, CONFIRM_TIMEOUT, BUY_TIMEOUT, COOLDOWN = 5, 30, 2, 3

  function Fish.DB()
    ns.db.fish = ns.db.fish or {}
    local db = ns.db.fish
    local today = date("%Y-%m-%d")
    if db.day ~= today then db.day, db.spent, db.log = today, 0, {} end
    db.spent = db.spent or 0
    -- today's own baits and catches: { k = "bait"|"catch", i, t, p (bait price), dep, n, c }
    db.log = db.log or {}
    db.items = db.items or {}
    return db
  end

  -- Today's result of one item, plain (Tobias' definition):
  --   baits     baits set today
  --   burned    baits gone without a deal: a bait round (from one bait to the next) with no buy
  --             in it; the round of the last bait is still open and not counted
  --   units, paid, avg   the deals: units bought, what they cost, the average unit price
  --   med       the market value: median of yesterday's hourly cheapest offers (cloud)
  --   gone, baitLoss   baits gone (every bait but the last, still open one) and what they
  --             were sold under the market value: sum of (med - bait price)
  --   result    units x med - paid - baitLoss (before the auction cut)
  -- nil without a bait or a deal today.
  function Fish.Balance(id)
    local b = { units = 0, paid = 0, baits = 0, burned = 0, gone = 0, goneSum = 0 }
    local open, deal = nil, false
    for _, e in ipairs(Fish.DB().log) do
      if e.i == id and e.k == "bait" then
        b.baits = b.baits + 1
        if open then
          if not deal then b.burned = b.burned + 1 end
          b.gone, b.goneSum = b.gone + 1, b.goneSum + (open.p or 0)
        end
        open, deal = e, false
      elseif e.i == id and e.k == "catch" then
        b.units, b.paid = b.units + (e.n or 0), b.paid + (e.c or 0)
        deal = true
      end
    end
    if b.baits == 0 and b.units == 0 then return nil end
    b.avg = b.units > 0 and math.floor(b.paid / b.units + 0.5) or nil
    local e = ns.Item.Get(id)
    b.med = e and e.medYesterday or nil
    b.baitLoss = b.med and (b.gone * b.med - b.goneSum) or nil
    b.result = b.med and (b.units * b.med - b.paid - b.baitLoss) or nil
    return b
  end

  -- read only: an item gets its own entry only once a figure is changed
  function Fish.Cfg(id)
    return Fish.DB().items[id] or FISH_DEFAULT
  end

  function Fish.Set(id, key, value)
    local items = Fish.DB().items
    local c = items[id] or { minGain = FISH_DEFAULT.minGain, budget = FISH_DEFAULT.budget }
    c[key] = value
    items[id] = c
    Fish.autoKey = nil -- new figures, new catch: it may be asked for again
    ns.Safe(draw)
  end

  -- The own unit cost (ledger replay: expensive) at most every 30 s per item.
  local costCache = {}
  function Fish.OwnCost(id)
    local c = costCache[id]
    if c and GetTime() - c.t < 30 then return c.v end
    local v
    if ns.Profit and ns.Profit.UnitCost then
      local ok, x = pcall(ns.Profit.UnitCost, id)
      if ok and x and x > 0 then v = x end
    end
    costCache[id] = { v = v, t = GetTime() }
    return v
  end

  -- Diagnostics for "/m4 fisch": counters of what happened this session.
  Fish.stat = { results = 0, asks = 0, autoAsks = 0, quotes = 0, buys = 0, misses = 0 }
  -- The game does not allow the price ask without a click in this client ("Interface-Aktion
  -- fehlgeschlagen", the call silently does nothing): the ask always comes from the player's
  -- click - first click asks, second click buys.
  Fish.autoBlocked = true

  -- The price of our cheapest own offer of the item in the auction house (own rows of the last
  -- search), nil without one.
  function Fish.OwnMin(id)
    -- only what the last search shows: a bait taken before any search saw it stays "not gone"
    -- in the log and would block the asks for good
    local m
    if Fish.rows and Fish.rows.id == id then
      for _, r in ipairs(Fish.rows.list or {}) do
        if (r.own or 0) > 0 and (not m or r.unit < m) then m = r.unit end
      end
    end
    return m
  end

  function Fish.Plan(id)
    local rows = Fish.rows
    if not (id and rows and rows.id == id) then return nil end
    local c = Fish.Cfg(id)
    local e = ns.Item.Get(id)
    local plan = Detail.FishPlan(rows.list, e and e.vendorSell, c.minGain, math.huge, 0) -- no daily budget
    if plan and plan.limit then Fish.lastLimit = { id = id, limit = plan.limit } end
    return plan
  end

  local function inCombat() return InCombatLockdown and InCombatLockdown() and true or false end
  local function ahOpen() return ns.AHSearch and ns.AHSearch.IsOpen() or false end
  local function live() return Big.IsShown() and shownID ~= nil and rangeDef().key == "live" end

  -- "/m4 fisch": what the fishing sees and did (for finding out why nothing is bought)
  function Detail.FishStatus()
    local P, st = "|cffffd100M4 Fischen:|r ", Fish.stat
    print(P .. string.format("Live-Ansicht %s, AH %s, Fischmodus %s, Item %s", live() and "ja" or "nein",
      ahOpen() and "offen" or "zu", ns.FishMode and ns.FishMode() and "an" or "aus", shownID and (ns.ItemName(shownID) or shownID) or "–"))
    print(string.format("  Suchergebnisse: %d (letztes vor %s s) · Preisanfragen: %d (davon automatisch %d) · Antworten: %d · gekauft: %d · verpasst: %d",
      st.results, st.lastResults and string.format("%.1f", GetTime() - st.lastResults) or "–", st.asks, st.autoAsks, st.quotes, st.buys, st.misses))
    local plan = shownID and Fish.Plan(shownID)
    if plan then
      print(string.format("  Markt %s · Fang bis %s · Köder %s (%s) · Fang: %d fremde Stück, kaufbar %d für %s",
        plan.market and money(plan.market) or "–", plan.limit and money(plan.limit) or "–", plan.bait and money(plan.bait) or "–",
        plan.baitLies and "liegt" or "liegt nicht", plan.catch or 0, plan.n or 0, money(plan.sum or 0)))
    else
      print("  kein Plan (noch keine Suche des Items oder kein Markt)")
    end
    local p = Fish.pending
    print(string.format("  Anfrage: %s · automatisch gesperrt: %s · Pause noch %.1f s · letzte Antwort: %s",
      p and (p.state .. " " .. p.n .. " Stück") or "keine", Fish.autoBlocked and "ja (2 Klicks)" or "nein",
      math.max(0, (Fish.cooldown or 0) - GetTime()), st.lastQuote or "–"))
    print("  letzter Spielfehler: " .. (st.lastError or "–"))
  end


  -- Fishing mode: while the live view is shown at the auction house (the fish button is there),
  -- every other auction house query of the addon stands still - the full scan, the sniper, the
  -- 10 s refresh of the auction lists, single searches of other items and the live channel's
  -- sending - so the one search a second of the fished item never waits.
  function ns.FishMode() return live() and ahOpen() or false end
  function ns.FishItem() return ns.FishMode() and shownID or nil end
  -- entering the fishing mode stops what runs: the sniper and a full scan
  function Fish.EnterMode()
    if ns.Sniper and ns.Sniper.IsRunning and ns.Sniper.IsRunning() then ns.Safe(ns.Sniper.Click) end
    if ns.AuctionScan and ns.AuctionScan.Abort then ns.Safe(ns.AuctionScan.Abort) end
  end

  -- A unit of the item in the carried bags: the location of an unlocked stack and the count.
  function Fish.BagSlot(id)
    local c = C_Container or {}
    local numSlots = c.GetContainerNumSlots or GetContainerNumSlots
    local info, idAt = c.GetContainerItemInfo, c.GetContainerItemID or GetContainerItemID
    if not (numSlots and ItemLocation) then return nil, 0 end
    local loc, n = nil, 0
    for _, bag in ipairs(ns.CarriedBags()) do
      for slot = 1, (numSlots(bag) or 0) do
        local i = info and info(bag, slot)
        local got = type(i) == "table" and i.itemID or (idAt and idAt(bag, slot))
        if got == id then
          n = n + (type(i) == "table" and i.stackCount or 1)
          if not loc and not (type(i) == "table" and i.isLocked) then loc = ItemLocation:CreateFromBagAndSlot(bag, slot) end
        end
      end
    end
    return loc, n
  end

  -- A message in the fish button (a few seconds, while nothing else is to show) and the chat.
  function Fish.Note(text)
    Fish.note = { text = text, untilT = GetTime() + 6 }
    print("|cff33ccffm4:|r Fischen: " .. text)
  end

  -- Forgets the quote (cancel: tell the server too); the next one asked by itself waits COOLDOWN.
  -- missed: someone was faster (the cheap units are gone) - nothing bought, no message, only
  -- counted (Fish.missed, in the line under the chart) and a short pause before the next ask.
  function Fish.Drop(cancel, reason, missed)
    local p = Fish.pending
    Fish.pending = nil
    -- no CancelCommoditiesPurchase: the game answers it with error 10 (measured); the next ask
    -- replaces the quote
    if missed then
      Fish.missed = (Fish.missed or 0) + 1
      Fish.cooldown = GetTime() + 1
      -- the rows that showed the catch are stale now (it is gone): forget them and search at
      -- once - else every click would ask for the same sold offer again
      Fish.rows = nil
      Fish.stale = GetTime()
      if p and ns.AHSearch and ns.AHSearch.Request then ns.Safe(ns.AHSearch.Request, p.itemID, nil, true) end
    else
      Fish.cooldown = GetTime() + COOLDOWN
      if reason then Fish.Note(reason) end
    end
    ns.Safe(Fish.Refresh)
  end

  -- Asks the server what plan.n units cost now (StartCommoditiesPurchase: a quote, no buy - the
  -- buy is ConfirmCommoditiesPurchase on the player's click). auto: asked on a new catch without
  -- a click; if the game blocks that (ADDON_ACTION_BLOCKED below) the quote waits for a click.
  -- Measured (fishTrace, 24 Nov): CancelCommoditiesPurchase is answered with AH error 10
  -- (DatabaseError) about 0.1 s later, every time - a quote we do not want is not cancelled
  -- but left: the next ask replaces it.
  function Fish.Ask(plan, auto)
    local api = C_AuctionHouse
    if Fish.pending or not (api and api.StartCommoditiesPurchase) then return end
    local p = { itemID = shownID, n = plan.n, sum = plan.sum, limit = plan.limit, bite = plan.baitLies,
      state = "asking", t = GetTime(), auto = auto, blind = plan.blind }
    Fish.pending = p
    Fish.stat.asks = Fish.stat.asks + 1
    Fish.asking = true -- our own call: the hook below must not take it for Blizzard's dialog
    local ok = pcall(api.StartCommoditiesPurchase, p.itemID, p.n)
    Fish.asking = false
    if not ok then
      if Fish.pending == p then Fish.Drop(false, "Preisanfrage nicht möglich") end
      return
    end
    C_Timer.After(QUOTE_TIMEOUT, function()
      if Fish.pending ~= p or p.state ~= "asking" then return end
      Fish.pending = nil
      Fish.cooldown = GetTime() + COOLDOWN
      if auto then
        -- a quote asked without a click that is silently dropped twice: ask on clicks from now
        Fish.autoMisses = (Fish.autoMisses or 0) + 1
        if Fish.autoMisses >= 2 then Fish.autoBlocked = true end
      else
        Fish.Note("keine Preisantwort – nochmal klicken")
      end
      ns.Safe(Fish.Refresh)
    end)
  end

  -- The fish button (click or "/click M4CompanionFishButton"): confirms a quote, else asks for one.
  function Fish.Click()
    if inCombat() or not (ahOpen() and live()) then return end
    local p = Fish.pending
    if p then
      if p.state == "confirm" and p.itemID == shownID then
        p.state, p.t = "buying", GetTime()
        local ok = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, p.itemID, p.n)
        if not ok then return Fish.Drop(false, "Kauf nicht möglich") end
        C_Timer.After(BUY_TIMEOUT, function()
          if Fish.pending == p and p.state == "buying" then Fish.Drop(false, "keine Antwort auf den Kauf") end
        end)
      end
      return Fish.Refresh()
    end
    -- The cycle: every decision is made on a fresh search (Fish.State), before any post:
    --   an offer of more than one unit at or under K -> "Kaufen" (the click asks the price,
    --     the quote fits -> "Bestätigen", the click buys)
    --   else our bait still in the search -> wait (the live view searches every second)
    --   else -> "Köder setzen": ONE unit at K; the next decision waits for a search sent after
    --     the game confirmed that auction (AUCTION_HOUSE_AUCTION_CREATED)
    local plan = Fish.Plan(shownID)
    local K = Fish.BaitPrice(shownID, plan)
    if not K then return Fish.Refresh() end
    local kind, info, L = Fish.State(shownID, K)
    if kind == "catch" then
      Fish.Dbg(string.format("3 Kauf angefragt: %d Stück bis %s je Stück", info, money(L)))
      Fish.Ask({ n = info, sum = info * L, limit = L, blind = true }, false)
    elseif kind == "bait" then
      local before = Fish.baitSent
      ns.Safe(Fish.Bait, K)
      if Fish.baitSent and Fish.baitSent ~= before then
        Fish.baitK = { id = shownID, k = K } -- the buy limit until the next bait
        Fish.Dbg("1 Köder gesetzt: 1 × " .. money(K) .. " – warte auf „Auktion erstellt“, dann Suche")
        Fish.AwaitBait()
      else
        Fish.Dbg("1 Köder NICHT gesetzt (kein Stück / gesperrt / Spiel lehnt ab)")
      end
    else
      Fish.Dbg(kind == "lies" and ("warte: unser Köder liegt (" .. tostring(info) .. " Stück bis " .. money(Fish.Limit(shownID, K)) .. ")")
        or ("warte: " .. tostring(info)))
    end
    Fish.Refresh()
  end

  -- Debug line in the chat for every step of the cycle (with the second, to read the order).
  function Fish.Dbg(text)
    print(string.format("|cff33ccffm4 Fisch %.1f:|r %s", GetTime() % 1000, text))
  end

  -- From now on only a search SENT after this moment counts; one is sent at once.
  function Fish.StartSearch(why)
    Fish.searchFrom = GetTime()
    Fish.stateKey = nil
    if shownID and ns.AHSearch and ns.AHSearch.Request then
      ns.Safe(ns.AHSearch.Request, shownID, nil, true)
      Fish.Dbg("2 Suche gesendet" .. (why and (" (" .. why .. ")") or ""))
    end
  end
  -- After a post: no decision until the game confirmed the auction and a search sent after
  -- that answered (else the search could miss our new bait and a second one would follow).
  -- No confirmation within 5 s: the post failed - search anyway.
  function Fish.AwaitBait()
    Fish.searchFrom = math.huge
    Fish.stateKey = nil
    local sent = Fish.baitSent
    Fish.baitPostT = sent
    C_Timer.After(5, function()
      if Fish.baitPostT == sent and Fish.searchFrom == math.huge then
        Fish.baitPostT = nil
        Fish.StartSearch("keine Bestätigung nach 5 s")
        ns.Safe(Fish.Refresh)
      end
    end)
  end

  -- The decision on the last search (only one sent after Fish.searchFrom counts):
  --   "catch", n   an offer of more than one foreign unit at or under K; n = all foreign units
  --                at or under K
  --   "lies", own  nothing fits, our bait is still there
  --   "bait"       nothing fits, no bait of ours -> set one
  --   "wait", why  no fresh search yet / bait switched off
  -- The buy limit is the price of the bait we set last (not the price a new bait would get:
  -- that one sits under the cheapest foreign offer, so a fresh undercut would never fit).
  function Fish.Limit(id, K)
    return Fish.baitK and Fish.baitK.id == id and Fish.baitK.k or K
  end
  function Fish.State(id, K)
    K = Fish.Limit(id, K)
    local rows = Fish.rows
    -- also received at least 0.5 s later: an answer to a search sent just before (0.1-0.3 s,
    -- measured) must not pass for the new one
    local from = Fish.searchFrom or 0
    if not (rows and rows.id == id and rows.sent and rows.sent > from and rows.t >= from + 0.5) then
      return "wait", Fish.searchFrom == math.huge and "Köder wird eingestellt …" or "Suche läuft …"
    end
    local n, big, own = 0, false, 0
    for _, r in ipairs(rows.list or {}) do
      -- our bait: own units at or under the bait price (own auctions dearer are sales, not bait)
      if r.unit <= K then own = own + (r.own or 0) end
      local f = math.max(0, (r.qty or 0) - (r.own or 0))
      if r.unit <= K and f > 0 then
        n = n + f
        if f > 1 then big = true end
      end
    end
    if big then return "catch", n, K end
    if own > 0 then return "lies", own end
    if Fish.noBait then return "wait", "kein Angebot > 1 Stück bis " .. money(K) .. " (Köder aus)" end
    return "bait"
  end

  -- The bait price K: from the plan (vendor + 25 %, under the cheapest foreign offer and the
  -- catch limit), else the last one known for the item, else vendor + 25 %.
  function Fish.BaitPrice(id, plan)
    if plan and plan.bait then Fish.lastBait = { id = id, k = plan.bait } return plan.bait end
    if Fish.lastBait and Fish.lastBait.id == id then return Fish.lastBait.k end
    local e = ns.Item.Get(id)
    if e and e.vendorSell and e.vendorSell > 0 then return math.ceil(e.vendorSell * 1.25) end
  end

  -- The bait button: one unit at K for 2 h. The ledger books the post through its own hook.
  function Fish.Bait(price)
    local api = C_AuctionHouse
    if inCombat() or not (ahOpen() and live() and api and api.PostCommodity) then return end
    local plan = Fish.Plan(shownID)
    price = price or (plan and plan.bait)
    if not price then return end
    local loc = Fish.BagSlot(shownID)
    if loc and pcall(api.PostCommodity, loc, FISH_DURATION, 1, price) then
      Fish.baitSent = GetTime()
      -- no second bait before a search has shown this one (fast clicks for a catch are safe)
      Fish.baitAwait = true
      local log = Fish.DB().log
      local own = Fish.OwnCost(shownID)
      -- own: the unit's cost when set (a later cheap buy must not change this bait's loss)
      local e = ns.Item.Get(shownID)
      log[#log + 1] = { k = "bait", i = shownID, t = time(), p = price,
        dep = (e and e.vendorSell or 0) * FISH_DEPOSIT, own = own or (plan and plan.market) }
    end
    Fish.Refresh()
  end

  function Fish.Menu(owner)
    local id = shownID
    if not id then return end
    if MenuUtil and MenuUtil.CreateContextMenu then
      MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Mindestgewinn")
        for _, g in ipairs(FISH_GAINS) do
          root:CreateRadio(math.floor(g * 100 + 0.5) .. " %", function() return math.abs(Fish.Cfg(id).minGain - g) < 1e-6 end,
            function() Fish.Set(id, "minGain", g) end)
        end
      end)
    else
      -- no menu API: a right click steps through the minimum gains
      local cur, nextG = Fish.Cfg(id).minGain, FISH_GAINS[1]
      for k, g in ipairs(FISH_GAINS) do
        if math.abs(cur - g) < 1e-6 then nextG = FISH_GAINS[k % #FISH_GAINS + 1] end
      end
      Fish.Set(id, "minGain", nextG)
    end
  end

  -- enabled / glowing look of a bait or fish button, both button kinds (template or flat)
  local function look(b, enabled, glow, text, tip)
    local fs = rawget(b, "label")
    if fs then fs:SetText(text) else b:SetText(text) end
    b.m4tip = tip
    if enabled then b:Enable() else b:Disable() end
    if enabled then
      setActive(b, glow)
    else
      if b.UnlockHighlight then b:UnlockHighlight() end
      fs = fs or (b.GetFontString and b:GetFontString())
      if fs then fs:SetTextColor(0.5, 0.5, 0.5) end
    end
  end

  -- Line and buttons from the shown item's last search; also drops a quote that no longer
  -- belongs to what is shown (other item, other range).
  function Fish.Refresh()
    if not (ui and ui.fishLine) then return end
    local on = live()
    ui.fishLine:SetShown(on)
    -- the mode starts with the view: stop what runs once
    if on and ahOpen() and not Fish.modeWas then Fish.EnterMode() end
    Fish.modeWas = on and ahOpen()
    ui.bait:SetShown(false) -- one button does it all (Fish.Click)
    if ui.fishReset then ui.fishReset:SetShown(on) end
    if ui.noBait then
      ui.noBait:SetShown(on)
      ui.noBait:SetText(Fish.noBait and "|cffff6b6bKöder: aus|r" or "Köder: an")
    end
    ui.fishBtn:SetShown(on)
    local p = Fish.pending
    if p and p.state ~= "buying" and (not on or p.itemID ~= shownID) then return Fish.Drop(true) end
    ui.fishBtn.blink = false
    if not on then return end
    local id, now = shownID, GetTime()
    local db, c = Fish.DB(), Fish.Cfg(id)
    local plan = Fish.Plan(id)
    local open, combat = ahOpen(), inCombat()
    local G, M = "|cffffd100", ns.Style.MUTED
    -- the figures
    local parts = {}
    if plan and plan.market then
      parts[#parts + 1] = G .. "Markt|r " .. money(plan.market)
      if plan.limit then
        parts[#parts + 1] = string.format("%sFang bis|r %s %s(+%d %%)|r", G, money(plan.limit), M, math.floor(c.minGain * 100 + 0.5))
        parts[#parts + 1] = G .. "Köder|r " .. money(plan.bait) .. " " .. (plan.baitLies and "|cff73adffliegt|r" or (M .. "–|r"))
      else
        parts[#parts + 1] = M .. "keine Fanggrenze (Markt zu billig für den Mindestgewinn)|r"
      end
    elseif not open then
      parts[#parts + 1] = M .. "Markt – nur am Auktionshaus|r"
    elseif plan then
      parts[#parts + 1] = M .. "Markt – unter " .. Detail.FISH_DEPTH .. " fremden Stück im Angebot|r"
    else
      parts[#parts + 1] = M .. "Markt – Suche läuft|r"
    end
    local first = #parts -- the rest goes on a second line
    if (Fish.missed or 0) > 0 then parts[#parts + 1] = G .. "verpasst|r " .. Fish.missed end
    -- today's result (details in the line's tooltip)
    local bal = Fish.Balance(id)
    parts[#parts + 1] = string.format("%sKöder verbrannt|r %d %s(von %d)|r", G, bal and bal.burned or 0, M, bal and bal.baits or 0)
    parts[#parts + 1] = string.format("%sDeals|r %d Stück %s", G, bal and bal.units or 0,
      bal and bal.avg and ("Ø " .. money(bal.avg)) or "")
    local result = bal and bal.result
    if result then
      parts[#parts + 1] = string.format("%sGewinn|r %s%s|r %s(Median gestern %s)|r", G,
        result > 0 and "|cff5fd38d+" or (result < 0 and "|cffff6b6b−" or "±"), money(math.abs(result)), M, money(bal.med))
    elseif bal and bal.units > 0 then
      parts[#parts + 1] = G .. "Gewinn|r " .. M .. "– (kein Median gestern)|r"
    end
    local line1, line2 = {}, {}
    for k, part in ipairs(parts) do
      if k <= first then line1[#line1 + 1] = part else line2[#line2 + 1] = part end
    end
    ui.fishLine.text:SetText(table.concat(line1, "  ·  "))
    ui.fishLine.text2:SetText(table.concat(line2, "  ·  "))
    -- bait: lit for a moment when it is gone (sold, expired, or the market fell under it)
    local lies = plan and plan.baitLies or false
    if Fish.baitWas and Fish.baitWas.id == id and Fish.baitWas.lies and not lies then Fish.baitFlash = now + 3 end
    Fish.baitWas = { id = id, lies = lies }
    local loc, have = Fish.BagSlot(id)
    local text = plan and plan.bait and ("Köder setzen (" .. money(plan.bait) .. ")") or "Köder setzen"
    if not open then
      look(ui.bait, false, false, text, "nur am Auktionshaus")
    elseif combat then
      look(ui.bait, false, false, text, "nicht im Kampf")
    elseif not (plan and plan.bait) then
      look(ui.bait, false, false, text, "noch keine Fanggrenze")
    elseif lies then
      look(ui.bait, false, false, "Köder liegt (" .. money(plan.bait) .. ")", "Ein eigenes Stück zu höchstens " .. money(plan.bait) .. " ist im Angebot.")
    elseif have == 0 then
      look(ui.bait, false, false, "kein Stück in den Taschen", "kein Stück in den Taschen")
    elseif not loc then
      look(ui.bait, false, false, text, "das Stück ist gerade gesperrt")
    elseif Fish.baitSent and now - Fish.baitSent < 5 then
      look(ui.bait, false, false, "Köder wird eingestellt …", nil) -- until the next search shows it
    else
      look(ui.bait, true, Fish.baitFlash ~= nil and now < Fish.baitFlash, text,
        "1 Stück zu " .. money(plan.bait) .. " für 2 h einstellen (Gebühr etwa " .. money(plan.dep) .. ")")
    end
    -- fish: a bite (a catch while our bait lies) blinks
    local note = Fish.note and now < Fish.note.untilT and Fish.note.text or nil
    local bite = plan and plan.baitLies and plan.n > 0
    if p and p.itemID == id then
      if p.state == "asking" then
        look(ui.fishBtn, false, false, "Preis wird angefragt …", nil)
      elseif p.state == "confirm" then
        look(ui.fishBtn, true, true, string.format("4 Bestätigen: %d × = ", p.n) .. money(p.total),
          string.format("%d Stück für %s kaufen (Plan %s)", p.n, money(p.total), money(p.sum)))
        ui.fishBtn.blink = p.bite
      else
        look(ui.fishBtn, false, false, "Kauf läuft …", nil)
      end
    elseif not open then
      look(ui.fishBtn, false, false, "Fischen", "nur am Auktionshaus")
    elseif combat then
      look(ui.fishBtn, false, false, "Fischen", "nicht im Kampf")
    else
      -- the cycle (Fish.Click): 1 bait, 2 search, 3 offer the buy, 4 confirm (pending quote above)
      local K = Fish.BaitPrice(id, plan)
      if not K then
        look(ui.fishBtn, false, false, note or "kein Köderpreis (Händlerpreis unbekannt)", nil)
      else
        local kind, info = Fish.State(id, K)
        local L = Fish.Limit(id, K)
        local last = Fish.lastAnswer and (" · zuletzt " .. money(Fish.lastAnswer) .. " zu teuer") or ""
        if kind == "catch" then
          look(ui.fishBtn, true, true, string.format("3 Kaufen: %d Stück bis ", info) .. money(L), nil)
          ui.fishBtn.blink = true
        elseif kind == "bait" then
          if have == 0 then
            look(ui.fishBtn, false, false, "1 Köder: kein Stück in den Taschen", nil)
          elseif not loc then
            look(ui.fishBtn, false, false, "1 Köder: Stück gerade gesperrt", nil)
          else
            look(ui.fishBtn, true, false, "1 Köder setzen (" .. money(K) .. ")" .. last, nil)
          end
        elseif kind == "lies" then
          look(ui.fishBtn, true, false, note or ("2 Köder liegt – warte auf Angebot bis " .. money(L) .. last), nil)
        else
          look(ui.fishBtn, true, false, note or ("2 " .. tostring(info) .. last), nil)
        end
      end
    end
  end

  -- Every commodity search of the shown item (ours every second, the sniper's, Blizzard's):
  -- read the rows and, on a catch, ask for its price right here - so the button shows
  -- "Bestätigen" before a competitor's click, and one click buys.
  local function readRows(itemID)
    local api = C_AuctionHouse
    local list = {}
    for i = 1, (api.GetNumCommoditySearchResults(itemID) or 0) do
      local r = api.GetCommoditySearchResultInfo(itemID, i)
      if r and r.unitPrice and r.unitPrice > 0 then
        local q = r.quantity or 0
        local own = r.containsOwnerItem and math.min(q, math.max(1, r.numOwnerItems or 0)) or 0
        list[#list + 1] = { unit = r.unitPrice, qty = q, own = own }
      end
    end
    return list
  end

  function Fish.OnResults(itemID)
    local api = C_AuctionHouse
    if not (itemID and itemID == shownID and api and api.GetNumCommoditySearchResults) then return end
    -- sent: when the search these rows answer was sent (the decision counts only searches sent
    -- after the last bait was confirmed)
    Fish.rows = { id = itemID, list = readRows(itemID), t = GetTime(), sent = Fish.lastSent or GetTime() }
    -- debug: the decision on this search (only when it changes)
    if live() and ahOpen() then
      local K = Fish.BaitPrice(itemID, Fish.Plan(itemID))
      if K then
        local kind, info = Fish.State(itemID, K)
        local L = Fish.Limit(itemID, K)
        local own = 0
        for _, r in ipairs(Fish.rows.list) do if r.unit <= L then own = own + (r.own or 0) end end
        local r1 = Fish.rows.list[1]
        local key = kind .. ":" .. tostring(info) .. ":" .. own
        if key ~= Fish.stateKey then
          Fish.stateKey = key
          local what = kind == "catch" and string.format("|cff5fd38dpasst: %d Stück bis %s → 3 Kaufen klicken|r", info, money(L))
            or kind == "lies" and "nichts passt, unser Köder liegt noch → warten"
            or kind == "bait" and "nichts passt, kein Köder von uns → 1 neuer Köder"
            or tostring(info)
          Fish.Dbg(string.format("Suche: günstigste %s × %d, eigene %d → %s",
            r1 and money(r1.unit) or "–", r1 and r1.qty or 0, own, what))
        end
      end
    end
    Fish.stale = nil
    Fish.baitAwait = nil
    -- the first result after setting a bait ends "Köder wird eingestellt"
    if Fish.baitSent and GetTime() - Fish.baitSent > 0.5 then Fish.baitSent = nil end
    -- A set bait that a search no longer shows as an own offer at its price has left the
    -- auction house: taken (sold), or after 2 h expired - counted at once (an undercut bait is
    -- still there: only its price counts, not whether it is in front). One taken before any
    -- search saw it counts after three searches without it.
    local ownAt = {}
    for _, r in ipairs(Fish.rows.list) do
      if (r.own or 0) > 0 then ownAt[r.unit] = true end
    end
    for _, e in ipairs(Fish.DB().log) do
      if e.k == "bait" and e.i == itemID and not e.gone then
        if ownAt[e.p] then
          e.seen = true
        elseif e.seen then
          e.gone = time()
        elseif time() - e.t >= 2 then
          e.misses = (e.misses or 0) + 1
          if e.misses >= 3 then e.gone = time() end
        end
      end
    end
    Fish.stat.results, Fish.stat.lastResults = Fish.stat.results + 1, GetTime()
    if not live() then return end
    local plan = Fish.Plan(itemID)
    local fang = plan and plan.n > 0 or false
    if fang and Fish.hadFang ~= itemID and PlaySound then
      -- a bite while our bait lies: the loud one
      pcall(PlaySound, SOUNDKIT and (plan.baitLies and SOUNDKIT.RAID_WARNING or SOUNDKIT.AUCTION_WINDOW_OPEN)
        or (plan.baitLies and 8959 or 5274))
    end
    Fish.hadFang = fang and itemID or nil
    if not fang then Fish.autoKey = nil end
    if fang and not Fish.pending and not Fish.autoBlocked and not inCombat() and ahOpen()
        and GetTime() >= (Fish.cooldown or 0) then
      -- the same catch is asked for once: after a dropped quote only a click asks again
      local key = itemID .. ":" .. plan.n .. ":" .. plan.sum
      if key ~= Fish.autoKey then
        Fish.autoKey = key
        Fish.stat.autoAsks = Fish.stat.autoAsks + 1
        Fish.Ask(plan, true)
      end
    end
    Fish.Refresh()
  end

  -- Measuring log (ns.db.fishTrace, read from the saved variables afterwards): every auction
  -- house step with a precise time while the live view is open at the auction house - searches
  -- sent (also Blizzard's own) and answered, the throttle's state, clicks with the button's text,
  -- price asks and answers, confirms, purchases, posts and every error text. At most TRACE_MAX
  -- entries (the oldest go). { t = seconds (precise), w = time(), e = event, ... }
  local TRACE_MAX = 20000
  local clockNow = GetTimePreciseSec or GetTime
  function Fish.Trace(event, a, b, c, d, r)
    if not (live() and ahOpen()) then return end
    ns.db.fishTrace = ns.db.fishTrace or {}
    local log = ns.db.fishTrace
    log[#log + 1] = { t = clockNow(), w = time(), e = event, a = a, b = b, c = c, d = d, r = r }
    if #log > TRACE_MAX then table.remove(log, 1) end
  end
  do
    local api = C_AuctionHouse
    local function hook(name, fn)
      if api and type(api[name]) == "function" and hooksecurefunc then
        hooksecurefunc(api, name, function(...) ns.Safe(fn, ...) end)
      end
    end
    local function keyID(k) return type(k) == "table" and k.itemID or k end
    hook("SendSearchQuery", function(itemKey)
      if keyID(itemKey) == shownID then Fish.lastSent = GetTime() end
      Fish.Trace("search_sent", keyID(itemKey))
    end)
    hook("SendBrowseQuery", function() Fish.Trace("browse_sent") end)
    hook("StartCommoditiesPurchase", function(id, n) Fish.Trace("ask_sent", id, n, Fish.pending and Fish.pending.blind and "probe" or "catch") end)
    hook("ConfirmCommoditiesPurchase", function(id, n) Fish.Trace("confirm_sent", id, n) end)
    hook("CancelCommoditiesPurchase", function() Fish.Trace("cancel_sent") end)
    hook("PostCommodity", function(_, dur, n, price) Fish.Trace("post_sent", n, price, dur) end)
  end
  if ns.On then
    ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
      local api = C_AuctionHouse
      local first = api.GetNumCommoditySearchResults and (api.GetNumCommoditySearchResults(itemID) or 0) > 0
        and api.GetCommoditySearchResultInfo(itemID, 1) or nil
      -- r: the three cheapest rows "price:units:own" (own = units of ours in the row), ';'-separated
      local rows = {}
      local num = api.GetNumCommoditySearchResults and api.GetNumCommoditySearchResults(itemID) or 0
      for i = 1, math.min(3, num) do
        local x = api.GetCommoditySearchResultInfo(itemID, i)
        if x then
          local own = x.containsOwnerItem and math.max(1, x.numOwnerItems or 0) or 0
          rows[#rows + 1] = string.format("%d:%d:%d", x.unitPrice or 0, x.quantity or 0, own)
        end
      end
      Fish.Trace("results", itemID, num, first and first.unitPrice, first and (first.containsOwnerItem and 1 or 0),
        table.concat(rows, ";"))
    end)
    for _, ev in ipairs({ "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
        "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
        "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
        "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
      -- not every client knows every event: an unknown one must not break the load
      pcall(ns.On, ev, function(_, a, b) Fish.Trace(ev:lower(), a, b) end)
    end
    ns.On("COMMODITY_PRICE_UPDATED", function(_, unit, total) Fish.Trace("price", unit, total) end)
    ns.On("AUCTION_HOUSE_SHOW_ERROR", function(_, code)
      Fish.Trace("ah_error", code)
      if ns.FishMode() then Fish.Dbg("|cffff6b6bSpiel: AH-Fehler " .. tostring(code) .. "|r") end
    end)
    ns.On("UI_ERROR_MESSAGE", function(_, a, b)
      Fish.Trace("ui_error", a, b)
      if ns.FishMode() then Fish.Dbg("|cffff6b6bSpiel: " .. tostring(b or a) .. "|r") end
    end)
    ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID) Fish.OnResults(itemID) end)
    ns.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, total)
      local p = Fish.pending
      if not (p and p.state == "asking") then return end -- not ours: Blizzard's buy dialog
      total = tonumber(total)
      Fish.stat.quotes = Fish.stat.quotes + 1
      Fish.stat.lastQuote = string.format("%s für %d (Plan %s)", total and money(total) or "?", p.n, money(p.sum))
      if p.blind then
        -- at most the bait price a unit -> "Bestätigen" on the next click; dearer: no buy,
        -- decided again on a new search (a new bait only if no fitting offer and none of ours)
        if not total or total > p.n * p.limit then
          Fish.stat.probes = (Fish.stat.probes or 0) + 1
          Fish.lastAnswer = total and (total / math.max(1, p.n)) or nil
          Fish.Dbg(string.format("3 Preis-Antwort: %s für %d Stück – zu teuer (max %s) → neue Suche",
            total and money(total) or "?", p.n, money(p.n * p.limit)))
          Fish.pending = nil
          Fish.StartSearch()
          ns.Safe(Fish.Refresh)
          return
        end
      end
      local why
      if not total then
        why = "kein Preis erhalten"
      elseif not p.blind and total > p.sum * 1.01 then
        Fish.stat.misses = Fish.stat.misses + 1
        return Fish.Drop(true, nil, true) -- someone bought the cheap ones first
      elseif total > p.n * p.limit then
        why = "über der Fanggrenze: " .. money(total) .. " für " .. p.n .. " Stück"
      end
      if why then return Fish.Drop(true, why) end
      p.state, p.total, p.unit, p.t = "confirm", total, unitPrice, GetTime()
      Fish.Dbg(string.format("3 Preis-Antwort: %s für %d Stück – passt → 4 Bestätigen klicken", money(total), p.n))
      Fish.lastAnswer = nil
      if p.auto then Fish.autoMisses = 0 end
      -- the server's quote runs out after a while anyway: an unclicked one is let go
      C_Timer.After(CONFIRM_TIMEOUT, function()
        if Fish.pending == p and p.state == "confirm" then Fish.Drop(true, "nicht bestätigt – Anfrage verworfen") end
      end)
      Fish.Refresh()
    end)
    ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
      local p = Fish.pending
      if p and p.state == "asking" then
        Fish.Dbg("3 Preis-Antwort: Angebot schon weg → neue Suche")
        Fish.Drop(false, nil, true) -- the offer is gone already
      end
    end)
    ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
      if not ns.FishMode() then return end
      Fish.Dbg("|cff5fd38d4 gekauft|r → neue Suche, dann Entscheidung")
      Fish.StartSearch()
    end)
    ns.On("CHAT_MSG_SYSTEM", function(_, msg)
      if not (shownID and ERR_AUCTION_SOLD_S and type(msg) == "string") then return end
      local name = ns.ItemName(shownID)
      if name and msg == ERR_AUCTION_SOLD_S:format(name) then
        Fish.Trace("bait_sold")
        Fish.Dbg("Spiel: eigene Auktion verkauft")
      end
    end)
    ns.On("AUCTION_HOUSE_AUCTION_CREATED", function()
      Fish.Trace("auction_created")
      if not ns.FishMode() then return end
      -- our bait confirmed: from now on a search counts (it shows the bait if it is still there)
      if Fish.baitPostT and Fish.searchFrom == math.huge and GetTime() - Fish.baitPostT < 5 then
        Fish.baitPostT = nil
        Fish.Dbg("Spiel: Auktion erstellt")
        Fish.StartSearch("nach dem Köder")
        ns.Safe(Fish.Refresh)
      else
        Fish.Dbg("Spiel: Auktion erstellt")
      end
    end)
    ns.On("COMMODITY_PURCHASE_FAILED", function()
      if not ns.FishMode() then return end
      Fish.Dbg("|cffff6b6b4 Kauf fehlgeschlagen|r → neue Suche, dann Entscheidung")
      Fish.StartSearch()
    end)
    ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
      local p = Fish.pending
      if not (p and p.state == "buying") then return end
      Fish.pending = nil
      Fish.stat.buys = Fish.stat.buys + 1
      local db = Fish.DB()
      db.spent = db.spent + (p.total or 0) -- the ledger books the buy itself (Ledger.lua hooks)
      db.log[#db.log + 1] = { k = "catch", i = p.itemID, t = time(), n = p.n, c = p.total or 0 }
      Fish.cooldown = GetTime() + COOLDOWN
      Fish.autoKey = nil
      Fish.Note(string.format("gekauft: %d Stück für %s", p.n, money(p.total or 0)))
      ns.Safe(draw)
    end)
    ns.On("COMMODITY_PURCHASE_FAILED", function()
      if Fish.pending then Fish.Drop(false, "Kauf fehlgeschlagen – Angebot abgelaufen oder weg") end
    end)
    -- the game demands a click for the quote: ask on clicks for the rest of the session
    local function blocked(_, addon, fn)
      if addon ~= ADDON or type(fn) ~= "string" or not fn:find("StartCommoditiesPurchase") then return end
      if not Fish.autoBlocked then Fish.Note("das Spiel verlangt einen Klick für die Preisanfrage – ab jetzt zwei Klicks") end
      Fish.autoBlocked = true
      local p = Fish.pending
      if p and p.state == "asking" then
        Fish.pending = nil
        Fish.cooldown = GetTime() + COOLDOWN
      end
      ns.Safe(Fish.Refresh)
    end
    -- the game's own error text (UI_ERROR_MESSAGE, AUCTION_HOUSE_SHOW_ERROR) while we ask or buy:
    -- kept for "/m4 fisch" and shown in the button - the reason a buy fails
    local function gameError(event, a, b)
      local p = Fish.pending
      if not p then return end
      local text = type(b) == "string" and b or (type(a) == "string" and a) or tostring(a)
      if event == "AUCTION_HOUSE_SHOW_ERROR" and type(a) == "number" then
        local names = Enum and Enum.AuctionHouseError or {}
        for k, v in pairs(names) do if v == a then text = "AH-Fehler " .. k end end
      end
      Fish.stat.lastError = string.format("%s (%s, %d Stück)", tostring(text), p.state, p.n)
      if p.blind and p.state == "asking" then
        -- a probe the game refused: no word, ready for the next click
        Fish.pending = nil
        ns.Safe(Fish.Refresh)
        return
      end
      Fish.Note(tostring(text))
    end
    ns.On("UI_ERROR_MESSAGE", function(_, a, b) gameError("UI_ERROR_MESSAGE", a, b) end)
    ns.On("AUCTION_HOUSE_SHOW_ERROR", function(_, a) gameError("AUCTION_HOUSE_SHOW_ERROR", a) end)
    ns.On("ADDON_ACTION_BLOCKED", blocked)
    ns.On("ADDON_ACTION_FORBIDDEN", blocked)
    ns.On("AUCTION_HOUSE_CLOSED", function()
      Fish.pending, Fish.rows, Fish.hadFang, Fish.autoKey, Fish.baitWas = nil, nil, nil, nil, nil
      ns.Safe(Fish.Refresh)
    end)
  end
  -- Someone else (Blizzard's buy dialog) asks for a quote: the next price events are theirs.
  if C_AuctionHouse and type(C_AuctionHouse.StartCommoditiesPurchase) == "function" and hooksecurefunc then
    hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function()
      if not Fish.asking and Fish.pending and Fish.pending.state ~= "buying" then
        Fish.pending = nil
        ns.Safe(Fish.Refresh)
      end
    end)
  end

  local function buildPage(page)
    ui = { page = page, pool = {}, buttons = {} }
    for kind in pairs(MAKERS) do ui.pool[kind] = {} end
    -- head: icon (item tooltip), name, the figures of the range
    ui.icon = page:CreateTexture(nil, "ARTWORK")
    ui.icon:SetSize(36, 36)
    ui.icon:SetPoint("TOPLEFT", 6, -2)
    local hit = CreateFrame("Button", nil, page)
    hit:SetAllPoints(ui.icon)
    hit:SetScript("OnEnter", function(self)
      if not shownID then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(shownID)
      GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.name = label(page, "GameFontHighlightLarge")
    ui.name:SetPoint("TOPLEFT", ui.icon, "TOPRIGHT", 10, -1)
    ui.name:SetPoint("RIGHT", page, "RIGHT", -400, 0) -- the range buttons are right of it
    ui.name:SetJustifyH("LEFT")
    ui.stats = label(page, "GameFontHighlightSmall")
    ui.stats:SetPoint("TOPLEFT", ui.name, "BOTTOMLEFT", 0, -7)
    ui.stats:SetPoint("RIGHT", page, "RIGHT", -6, 0)
    ui.stats:SetJustifyH("LEFT")
    ui.legend = label(page, "GameFontHighlightSmall")
    ui.legend:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT, -62)
    -- the live figures of the last hour, under the stats
    ui.live = label(page, "GameFontHighlightSmall")
    ui.live:SetPoint("TOPLEFT", ui.stats, "BOTTOMLEFT", 0, -6)
    ui.live:SetPoint("RIGHT", page, "RIGHT", -6, 0)
    ui.live:SetJustifyH("LEFT")
    ui.legend:SetJustifyH("LEFT")
    ui.res = label(page, "GameFontDisableSmall")
    ui.res:SetJustifyH("LEFT") -- placed next to the quantity label once that exists (draw)
    -- the range switch, right in the head
    local right
    for k = #RANGES, 1, -1 do
      local r = RANGES[k]
      local b = button(page, r.button, 62, function()
        ns.db.itemDetail = ns.db.itemDetail or {}
        ns.db.itemDetail.bigRange = r.key
        ns.Safe(draw)
      end)
      if right then
        b:SetPoint("TOPRIGHT", right, "TOPLEFT", -4, 0)
      else
        b:SetPoint("TOPRIGHT", page, "TOPRIGHT", -6, -4)
      end
      ui.buttons[r.key] = b
      right = b
    end
    -- the plot
    local plot = CreateFrame("Frame", nil, page)
    plot:SetPoint("TOPLEFT", LEFT, -TOP)
    plot:SetPoint("BOTTOMRIGHT", -RIGHT, BOTTOM)
    ui.plot = plot
    local bg = plot:CreateTexture(nil, "BACKGROUND", nil, 0)
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.3)
    ui.base = tex("ARTWORK", 0, 1, 1, 1, 0.3)
    ui.base:SetPoint("BOTTOMLEFT")
    ui.base:SetPoint("BOTTOMRIGHT")
    thin(ui.base)
    ui.refLine = tex("ARTWORK", 1, 1, 1, 1, 0.6)
    thin(ui.refLine)
    ui.qty = label(plot, "GameFontDisableSmall")
    ui.empty = label(plot, "GameFontDisable")
    ui.empty:SetPoint("CENTER")
    ui.cursor = tex("OVERLAY", 2, 1, 1, 1, 0.5)
    ui.cursor:SetPoint("TOP")
    ui.cursor:SetPoint("BOTTOM")
    thin(ui.cursor, true)
    ui.cursor:Hide()
    ui.dot = tex("OVERLAY", 3, 1, 1, 1, 1)
    ui.dot:SetSize(5, 5)
    ui.dot:Hide()
    -- hover: OnUpdate only while the mouse is over the plot
    plot:EnableMouse(true)
    local function track(self)
      local x = GetCursorPosition()
      local left = self:GetLeft()
      if not (x and left) then return end
      hover(x / (self:GetEffectiveScale() or 1) - left)
    end
    plot:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", track) end)
    plot:SetScript("OnLeave", function(self)
      self:SetScript("OnUpdate", nil)
      hover(nil)
    end)
    -- bait and fish (live view only): the figures, under them the two buttons
    local fl = CreateFrame("Button", nil, page)
    fl:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", LEFT, 34)
    fl:SetPoint("RIGHT", page, "RIGHT", -6, 0)
    fl:SetHeight(30) -- two lines: market and catch figures, then today's result
    fl.text = label(fl, "GameFontHighlightSmall")
    fl.text:SetPoint("TOPLEFT", fl, "TOPLEFT", 0, 0)
    fl.text:SetPoint("RIGHT", fl, "RIGHT", 0, 0)
    fl.text:SetJustifyH("LEFT")
    fl.text2 = label(fl, "GameFontHighlightSmall")
    fl.text2:SetPoint("TOPLEFT", fl.text, "BOTTOMLEFT", 0, -3)
    fl.text2:SetPoint("RIGHT", fl, "RIGHT", 0, 0)
    fl.text2:SetJustifyH("LEFT")
    fl:RegisterForClicks("RightButtonUp")
    fl:SetScript("OnClick", function(self) ns.Safe(Fish.Menu, self) end)
    fl:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Köder und Fischen")
      GameTooltip:AddLine("Markt: erste Preisstufe mit " .. Detail.FISH_DEPTH .. " fremden Stück davor und darin. Fang bis: was darunter "
        .. "gekauft wird, bringt nach Gebühr und Einstellgebühr den Mindestgewinn. Köder: 1 Stück zu Händlerpreis + 25 % (höchstens 1c unter dem günstigsten fremden Angebot und unter der Fanggrenze).", 1, 1, 1, true)
      -- today's balance of the shown item
      local plan = shownID and Fish.Plan(shownID)
      local bal = shownID and Fish.Balance(shownID)
      if bal then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Heute")
        GameTooltip:AddDoubleLine(string.format("Köder: %d gesetzt, %d verbrannt", bal.baits, bal.burned), "", 1, 1, 1)
        GameTooltip:AddLine("Verbrannt: weggekauft, ohne dass bis zum nächsten Köder ein Deal kam.", 0.6, 0.6, 0.62, true)
        GameTooltip:AddDoubleLine(string.format("Deals: %d Stück%s", bal.units, bal.avg and (" zu Ø " .. money(bal.avg)) or ""),
          money(bal.paid), 1, 1, 1, 1, 1, 1)
        if bal.med then
          GameTooltip:AddDoubleLine("Marktwert (Median gestern " .. money(bal.med) .. ")", money(bal.units * bal.med), 1, 1, 1, 1, 1, 1)
          GameTooltip:AddDoubleLine(string.format("Köder weg: %d × (Median − Köderpreis)", bal.gone),
            "−" .. money(math.abs(bal.baitLoss)), 1, 1, 1, 1, 0.42, 0.42)
          GameTooltip:AddDoubleLine("Gewinn = Marktwert − Deals − Köder", (bal.result >= 0 and "+" or "−") .. money(math.abs(bal.result)),
            1, 0.82, 0, bal.result >= 0 and 0.37 or 1, bal.result >= 0 and 0.83 or 0.42, bal.result >= 0 and 0.55 or 0.42)
          GameTooltip:AddLine("vor Auktionsgebühr", 0.6, 0.6, 0.62)
        end
      end
      GameTooltip:AddLine("Rechtsklick: Mindestgewinn", 0.6, 0.6, 0.62)
      GameTooltip:Show()
    end)
    fl:SetScript("OnLeave", function() GameTooltip:Hide() end)
    fl:Hide()
    ui.fishLine = fl
    ui.bait = button(page, "Köder setzen", 230, function() ns.Safe(Fish.Bait) end)
    ui.bait:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", LEFT, 6)

    -- the fish button has a global name: a macro "/click M4CompanionFishButton" puts it on a key
    local ok, fb = pcall(CreateFrame, "Button", "M4CompanionFishButton", page, "UIPanelButtonTemplate")
    if ok and fb then
      fb:SetSize(340, 22)
      fb:SetText("Fischen")
    else
      fb = ns.Style.Button(page, "Fischen", 340, 22)
      _G.M4CompanionFishButton = fb
    end
    -- Acts on the press: a mouse click comes as down and up, /click as one of the two (the
    -- game's "ActionButtonUseKeyDown" decides) - an up right after an acted down is the same
    -- press and must not act again (it could confirm a quote that just came in).
    fb:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    fb:SetScript("OnClick", function(self, _, down)
      if down then
        self.downSeen = true
      elseif self.downSeen then
        self.downSeen = false
        return
      end
      Fish.Trace("click", self:GetText(), Fish.pending and Fish.pending.state or "-")
      ns.Safe(Fish.Click)
    end)
    fb:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -RIGHT, 6)
    -- "Köder aus": the button only fishes (buys foreign catches), it never sets a bait
    ui.noBait = button(page, "Köder: an", 110, function()
      Fish.noBait = not Fish.noBait
      ns.Safe(Fish.Refresh)
    end)
    ui.noBait:SetPoint("RIGHT", fb, "LEFT", -8, 0)
    -- a fresh fishing session: today's baits and deals (the balance line) start at zero
    ui.fishReset = button(page, "Neue Session", 110, function()
      local db = Fish.DB()
      db.log, db.spent = {}, 0
      Fish.missed = 0
      Fish.Dbg("neue Session – Köder und Deals auf 0")
      ns.Safe(Fish.Refresh)
    end)
    ui.fishReset:SetPoint("RIGHT", ui.noBait, "LEFT", -8, 0)
    -- a bite blinks
    fb:SetScript("OnUpdate", function(self, elapsed)
      if not self.blink then return end
      self.blinkT = (self.blinkT or 0) + elapsed
      if self.blinkT < 0.3 then return end
      self.blinkT = 0
      self.blinkOn = not self.blinkOn
      setActive(self, self.blinkOn)
    end)
    ui.fishBtn = fb
    for _, b in ipairs({ ui.bait, fb }) do
      if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end -- the reason shows on grey
      b:HookScript("OnEnter", function(self)
        if not self.m4tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self.m4tip, 1, 1, 1, true)
        GameTooltip:Show()
      end)
      b:HookScript("OnLeave", function() GameTooltip:Hide() end)
      b:Hide()
    end
  end

  -- The time axis: day changes (line, weekday and date) and hour marks (every 3, 6 or 12
  -- hours, as many as fit), all in German time.
  local function drawAxis(v)
    local hourPx = v.w / (v.span / 3600)
    local hstep = hourPx * 3 >= 34 and 3 or (hourPx * 6 >= 22 and 6 or 12)
    local unit = hstep * 3600
    -- a short range (live view): ticks every 10 minutes (5 under half an hour) with the time
    local short = v.span <= 3 * 3600
    if short then
      unit = v.span <= 300 and 60 or v.span <= 600 and 120 or v.span <= 1800 and 300 or v.span <= 3600 and 600 or 1800
    end
    local bStart, bEnd = berlin(v.axisStart), berlin(v.axisEnd)
    local firstDay
    local b = math.ceil(bStart / unit) * unit
    while b <= bEnd do
      local x = (fromBerlin(b) - v.axisStart) / v.span * v.w
      if x >= 0 and x <= v.w then
        if b % 86400 == 0 then
          local d = take("day")
          d:ClearAllPoints()
          d:SetPoint("TOPLEFT", ui.plot, "TOPLEFT", x, 0)
          d:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", x, -14)
          local fs = take("dayLabel")
          fs:ClearAllPoints()
          fs:SetPoint("TOPLEFT", ui.plot, "BOTTOMLEFT", x + 3, -17)
          fs:SetText((WEEKDAYS[tonumber(date("!%w", b)) + 1] or "") .. " " .. date("!%d.%m.", b))
          firstDay = firstDay or x
        else
          local g = take("vgrid")
          g:ClearAllPoints()
          g:SetPoint("TOPLEFT", ui.plot, "TOPLEFT", x, 0)
          g:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", x, -3)
          local fs = take("hourLabel")
          fs:ClearAllPoints()
          fs:SetPoint("TOP", ui.plot, "BOTTOMLEFT", x, -3)
          fs:SetText(short and date("!%H:%M", b) or date("!%H", b))
        end
      end
      b = b + unit
    end
    -- the day the axis starts in, when its first change leaves room for the label
    if (firstDay or v.w) > 72 then
      local fs = take("dayLabel")
      fs:ClearAllPoints()
      fs:SetPoint("TOPLEFT", ui.plot, "BOTTOMLEFT", 0, -17)
      fs:SetText((WEEKDAYS[tonumber(date("!%w", bStart)) + 1] or "") .. " " .. date("!%d.%m.", bStart))
    end
  end

  -- The day trading windows as bands over the whole height: buy green, sell blue, every day
  -- of the axis (hours of the pool are German time = the PC's clock).
  local function drawBands(v)
    local r = v.rhythm
    if not (r and type(r[1]) == "number" and type(r[2]) == "number") then return end
    local hours = (ns.DayTrade and ns.DayTrade.WINDOW_HOURS or 3) * 3600
    local bStart = berlin(v.axisStart)
    local day = math.floor(bStart / 86400) * 86400 - 86400 -- the day before: a window over midnight
    while day <= berlin(v.axisEnd) do
      for k = 1, 2 do
        local t0 = fromBerlin(day + r[k] * 3600)
        local x0 = math.max(0, (t0 - v.axisStart) / v.span * v.w)
        local x1 = math.min(v.w, (t0 + hours - v.axisStart) / v.span * v.w)
        if x1 > x0 + 0.5 then
          local band = take("band")
          local rgb = k == 1 and BUY_RGB or SELL_RGB
          band:SetColorTexture(rgb[1], rgb[2], rgb[3], 0.09)
          band:ClearAllPoints()
          band:SetPoint("TOPLEFT", ui.plot, "TOPLEFT", x0, 0)
          band:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", x0, 0)
          band:SetWidth(x1 - x0)
        end
      end
      day = day + 86400
    end
  end

  -- Labels in the right margin (R, buy limit, ask, now) at their lines, pushed apart so
  -- none covers another.
  local function placeLabels(list, h)
    local GAP = 12
    table.sort(list, function(a, b) return a.y > b.y end)
    local prev
    for _, l in ipairs(list) do
      l.ly = math.min(l.y, h - 4)
      if prev and l.ly > prev - GAP then l.ly = prev - GAP end
      prev = l.ly
    end
    local minY = 4
    for k = #list, 1, -1 do
      local l = list[k]
      if l.ly < minY then l.ly = minY end
      minY = l.ly + GAP
    end
    for _, l in ipairs(list) do
      local fs = take("refLabel")
      fs:ClearAllPoints()
      fs:SetPoint("LEFT", ui.plot, "BOTTOMRIGHT", 8, l.ly)
      fs:SetText(l.text)
      fs:SetTextColor(l.rgb[1], l.rgb[2], l.rgb[3])
    end
  end

  -- The head: name, the range's figures, how old "jetzt" is and where it is from.
  -- Live figure from the fine points of the last hour (own searches, live channel): how the
  -- supply changes per hour - shrinking, growing or stable.
  local LIVE_WINDOW = 3600
  local function liveText(id)
    local G, M = "|cffffd100", ns.Style.MUTED
    local cut, pts = time() - LIVE_WINDOW, {}
    for _, pt in ipairs(tailOf(id)) do
      if pt.t >= cut and pt.q then pts[#pts + 1] = pt end
    end
    if #pts < 2 or pts[#pts].t - pts[1].t < 300 then
      return G .. "Live 60 min|r  " .. M .. "zu wenig Live-Daten – AH öffnen, das Fenster sucht dann jede Sekunde|r"
    end
    local first, last = pts[1], pts[#pts]
    local hours = (last.t - first.t) / 3600
    local rate = (last.q - first.q) / hours
    local share = last.q > 0 and rate / last.q or 0
    local trend = share <= -0.05 and "|cff5fd38dschwindet|r" or share >= 0.05 and "|cffff6b6bwächst|r" or (M .. "stabil|r")
    -- only the trend: the quantity itself is in the line above ("jetzt … Stück")
    return string.format("%sLive %d min|r   %sAngebot|r %s%s/h %s", G, math.max(5, math.floor((last.t - first.t) / 60 + 0.5)),
      G, rate >= 0 and "+" or "−", count(math.floor(math.abs(rate) + 0.5)), trend)
  end

  local function drawHead(id, e, values, rng)
    local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    local icon = getIcon and getIcon(id) or nil
    ui.icon:SetTexture(icon)
    if icon and icon ~= ui.portrait and win.frame.SetPortraitToAsset then
      pcall(win.frame.SetPortraitToAsset, win.frame, icon)
      ui.portrait = icon
    end
    local name = ns.ItemName(id) or ("#" .. id)
    local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
    local color = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if color and color.hex then name = color.hex .. name .. "|r" end
    -- the data age goes into the title line: the stats line below is full
    local stand = e.dataT and ("  ·  Stand " .. ago(e.dataT) .. " (" .. (SOURCES[e.dataSource] or "?") .. ")") or ""
    ui.name:SetText(name .. "  " .. ns.Style.MUTED .. ns.AuctionHouse.Name() .. "|r"
      .. "|cff999999" .. stand .. "|r")
    local G, SEP = "|cffffd100", "    "
    local parts = { G .. "jetzt|r " .. (e.now and money(e.now) or (ns.Style.MUTED .. "nicht im AH|r"))
      .. ((e.now and e.quantity and e.quantity > 0) and (" · " .. count(e.quantity) .. " Stück") or "") }
    if #values > 0 then
      local lo, hi = values[1], values[1]
      for _, p in ipairs(values) do lo, hi = math.min(lo, p), math.max(hi, p) end
      parts[#parts + 1] = string.format("%sMin|r %s  ·  %sMax|r %s  ·  %sMedian|r %s  %s(%s)|r", G, money(lo), G, money(hi),
        G, money(median(values)), ns.Style.MUTED, rng.label)
    end
    parts[#parts + 1] = G .. "Nachfrage|r " .. (ns.Item.DemandColored(e) or "–")
    local sat, _, satColor = ns.Item.SaturationText(e)
    parts[#parts + 1] = G .. "Sättigung|r " .. (sat and (satColor .. sat .. "|r") or "–")
    ui.stats:SetText(table.concat(parts, SEP))
  end

  draw = function()
    if not (ui and win and win.frame:IsShown() and shownID) then return end
    local id = shownID
    local e = ns.Item.Get(id)
    record(id, e)
    ui.drawnT, ui.drawnNow = e.dataT, e.now
    for kind in pairs(used) do used[kind] = 0 end
    hover(nil)
    ui.view = nil
    local rng = rangeDef()
    for _, r in ipairs(RANGES) do setActive(ui.buttons[r.key], r == rng) end
    local series = Detail.FineSeries(id)
    local axisEnd = time()
    local span = rng.span or (series and series.first and math.max(axisEnd - series.first, 6 * 3600)) or 7 * 86400
    if rng.key == "live" then
      -- live: from the first fine point of the last 20 minutes (at least 2 minutes), so the
      -- points fill the width instead of sticking to the right edge
      local first
      for _, pt in ipairs(tailOf(id)) do
        if pt.t >= axisEnd - rng.span and (not first or pt.t < first) then first = pt.t end
      end
      if first then span = math.max(120, math.min(rng.span, axisEnd - first + 15)) end
    end
    if rng.today then
      -- today: from midnight (the PC's clock = Berlin), at least the last hour
      local d = date("*t", axisEnd)
      span = math.max(3600, axisEnd - time({ year = d.year, month = d.month, day = d.day, hour = 0 }))
    end
    -- the live view makes room under the axis for bait and fish; the height follows from the
    -- page (the plot's own rect is only updated on the next layout)
    local fishing = rng.key == "live"
    local bottomMargin = fishing and BOTTOM_LIVE or BOTTOM
    if ui.bottomMargin ~= bottomMargin then
      ui.bottomMargin = bottomMargin
      ui.plot:SetPoint("BOTTOMRIGHT", -RIGHT, bottomMargin)
    end
    local w, ph = ui.plot:GetWidth(), ui.page:GetHeight()
    local h = (ph and ph > 100) and (ph - TOP - bottomMargin) or (H - 68 - TOP - bottomMargin)
    if not w or w < 50 then w = W - 16 - LEFT - RIGHT end -- before the first layout
    local plan = fishing and Fish.Plan(id) or nil
    local pool = ns.DayTrade and ns.DayTrade.Pool and ns.DayTrade.Pool()
    local v = { id = id, e = e, series = series, axisStart = axisEnd - span, axisEnd = axisEnd, span = span,
      w = w, h = h, vis = {}, tail = {}, rhythm = pool and pool[id] or nil }
    local function X(t) return (t - v.axisStart) / span * w end
    -- the slots on the axis, the live points after the history, their prices
    local values, qmax, zeros = {}, 0, false
    local qmin -- the smallest visible quantity: the bars scale from just under it (changes show)
    if series then
      for i = 1, #series.t0 do
        -- the live view shows only the fine points: an hourly slot would cross it as a diagonal
        if rng.key ~= "live" and series.t1[i] > v.axisStart and series.t0[i] < axisEnd then
          v.vis[#v.vis + 1] = i
          local p, q = series.p[i], series.q[i]
          if p and p > 0 then values[#values + 1] = p elseif p == 0 then zeros = true end
          if q and q > qmax then qmax = q end
          if q and q > 0 and (not qmin or q < qmin) then qmin = q end
        end
      end
    end
    local after = series and series.lastT or -math.huge
    for _, pt in ipairs(tailOf(id)) do
      if pt.t > after and pt.t >= v.axisStart then
        -- a copy: the drawing adds its x, which must not end up in the saved variables
        v.tail[#v.tail + 1] = { t = pt.t, p = pt.p, q = pt.q, src = pt.src }
        if pt.p > 0 then values[#values + 1] = pt.p end
        if pt.q and pt.q > qmax then qmax = pt.q end
        if pt.q and pt.q > 0 and (not qmin or pt.q < qmin) then qmin = pt.q end
      end
    end
    -- the usual quantity: median of the hourly quantities of the last 7 days (whatever range is
    -- shown), drawn as a dotted line in the bar zone - more or less on offer than usual
    local qMed
    if series then
      local qs, from = {}, time() - 7 * 86400
      for i = 1, #series.t0 do
        local q = series.q[i]
        if q and q > 0 and series.t1[i] > from then qs[#qs + 1] = q end
      end
      if #qs >= 6 then
        table.sort(qs)
        local n = #qs
        qMed = n % 2 == 1 and qs[(n + 1) / 2] or math.floor((qs[n / 2] + qs[n / 2 + 1]) / 2 + 0.5)
      end
    end
    if qMed and qmax > 0 then
      -- the scale reaches it, so the bars stand against it
      qmax = math.max(qmax, qMed)
      qmin = math.min(qmin or qMed, qMed)
    end
    drawHead(id, e, values, rng)
    ui.live:SetText(liveText(id))
    Fish.Refresh()
    -- legend and resolution
    local r = v.rhythm
    local legend = "|cffffd100günstigstes Angebot|r   |cffb0b0b0Menge (Balken)|r   |cffffffffR = Marktwert|r"
    if #v.tail > 0 then legend = legend .. "   |cffd9f2ffseit dem Verlauf beobachtet|r" end
    if r and type(r[1]) == "number" and type(r[2]) == "number" then
      legend = legend .. string.format("   |cff5fd38dKauf bis / Kaufzeit %d–%d Uhr|r   |cff73adffZiel / Verkaufszeit %d–%d Uhr|r",
        r[1], (r[1] + (ns.DayTrade.WINDOW_HOURS or 3)) % 24, r[2], (r[2] + (ns.DayTrade.WINDOW_HOURS or 3)) % 24)
    end
    ui.legend:SetText("") -- the lines explain themselves (labels on the right, tooltip on hover)
    ui.res:SetText(series and (series.hourFrom and ("1-h-Werte ab " .. stampFull(series.hourFrom) .. ", davor 2 h") or "2-h-Werte") or "")
    drawAxis(v)
    drawBands(v)
    if #values == 0 then
      ui.empty:SetText(not series and "Keine Verlaufsdaten für dieses Item"
        or (zeros and ("Im Zeitraum (" .. rng.label .. ") nicht im Angebot") or ("Keine Verlaufsdaten im Zeitraum (" .. rng.label .. ")")))
      ui.empty:Show()
      ui.refLine:Hide()
      ui.qty:SetText("")
      finish()
      return
    end
    ui.empty:Hide()
    -- Price scale: outliers (Detail.ChartScale) are cut at the edge with a cap, R and the pool's
    -- lines always fit; whole steps of 1 / 2 / 5 for the grid.
    local cutLow, cutHigh = Detail.ChartScale(values)
    local lo, hi
    for _, p in ipairs(values) do
      if not (cutLow and p < cutLow) and not (cutHigh and p > cutHigh) then
        lo, hi = math.min(lo or p, p), math.max(hi or p, p)
      end
    end
    lo, hi = lo or values[1], hi or values[1]
    -- live: catch limit and bait in the scale, the gap between them and the market is the point
    if plan and plan.limit then lo, hi = math.min(lo, plan.bait), math.max(hi, plan.limit) end
    -- How the price usually behaves: per hour of the day (local time) the median of the hourly
    -- cheapest offers of the 7 days before today (at least 3 days per hour). Drawn as a violet
    -- step line; "jetzt" shows the delta to the usual price of this hour.
    local usual = {}
    if series then
      local today0 = time({ year = tonumber(date("%Y")), month = tonumber(date("%m")), day = tonumber(date("%d")), hour = 0 })
      local from, byHour = today0 - 7 * 86400, {}
      for i = 1, #series.t0 do
        local p, t0, t1 = series.p[i], series.t0[i], series.t1[i]
        -- a slot counts for every hour it covers (1 h slots, or 2 h slots where the history
        -- has no hourly values)
        if p and p > 0 and t0 >= from and t0 < today0 and t1 - t0 <= 2 * 3600 then
          local t = t0
          while t < t1 do
            local hr = tonumber(date("%H", t))
            byHour[hr] = byHour[hr] or {}
            table.insert(byHour[hr], p)
            t = t + 3600
          end
        end
      end
      for hr, ps in pairs(byHour) do
        if #ps >= 3 then
          table.sort(ps)
          local n = #ps
          usual[hr] = n % 2 == 1 and ps[(n + 1) / 2] or math.floor((ps[n / 2] + ps[n / 2 + 1]) / 2 + 0.5)
        end
      end
    end
    local function usualAt(t) return usual[tonumber(date("%H", t))] end
    -- the usual prices over the axis in the scale (the comparison is the point)
    do
      local t = v.axisStart - v.axisStart % 3600
      while t < axisEnd do
        local u = usualAt(t)
        if u then lo, hi = math.min(lo, u), math.max(hi, u) end
        t = t + 3600
      end
    end
    local limit, ask = r and r[3], r and r[4]
    -- the scale follows the prices of the range only (else far reference lines flatten the
    -- curve); R, buy limit and target outside it become arrows on the edge
    local range = hi - lo
    if range <= 0 then range = math.max(1, hi * 0.05) end
    local step = niceStep(range, 5)
    local bottom = math.max(0, math.floor((lo - range * 0.05) / step) * step)
    local top = math.ceil((hi + range * 0.05) / step) * step
    if top <= bottom then top = bottom + step end
    -- the quantity bars in the lowest fifth, prices above them
    local barZone = math.floor(h * 0.2)
    -- bar height: from a base just under the smallest visible quantity to the largest, so a
    -- change of a few percent is visible (the label names the range)
    local qbase = 0
    if qmin and qmax > 0 then
      qbase = qmax > qmin and math.max(0, qmin - (qmax - qmin) * 0.25) or qmax * 0.8
    end
    local function qh(q)
      if qmax <= qbase then return 1 end
      return math.max(1, (barZone - 2) * (q - qbase) / (qmax - qbase))
    end
    local pBottom, pTop = barZone + 8, h - 6
    local function py(p)
      p = math.max(bottom, math.min(top, p))
      return pBottom + (p - bottom) / (top - bottom) * (pTop - pBottom)
    end
    v.py = py
    -- grid and price labels
    for k = 0, math.floor((top - bottom) / step + 0.5) do
      local val = bottom + k * step
      local yy = py(val)
      local g = take("grid")
      g:ClearAllPoints()
      g:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", 0, yy)
      g:SetPoint("BOTTOMRIGHT", ui.plot, "BOTTOMRIGHT", 0, yy)
      local fs = take("yLabel")
      fs:ClearAllPoints()
      fs:SetPoint("RIGHT", ui.plot, "BOTTOMLEFT", -6, yy)
      fs:SetText(axisMoney(val))
    end
    -- quantity bars (own scale: the highest in the range fills the zone)
    for _, i in ipairs(v.vis) do
      local q = series.q[i]
      if q and q > 0 and qmax > 0 then
        local x0, x1 = math.max(0, X(series.t0[i])), math.min(w, X(series.t1[i]))
        if x1 > x0 then
          local bar = take("bar")
          bar:ClearAllPoints()
          bar:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", x0 + 0.5, 1)
          bar:SetSize(math.max(1, x1 - x0 - 1), qh(q))
        end
      end
    end
    -- the live points' quantities: each bar reaches to the next point (or the right edge)
    for k, pt in ipairs(v.tail) do
      if pt.q and pt.q > 0 and qmax > 0 then
        local x0 = math.max(0, X(pt.t))
        local nxt = v.tail[k + 1]
        local x1 = math.min(w, nxt and X(nxt.t) or w)
        local bar = take("tailBar")
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", x0 + 0.5, 1)
        bar:SetSize(math.max(2, x1 - x0 - 1), qh(pt.q))
      end
    end
    -- the usual quantity (median 7 days): a dotted line through the bars
    if qMed and qmax > 0 then dashed(1 + qh(qMed), w, { 1, 1, 1 }, 2, 5) end
    ui.qty:ClearAllPoints()
    ui.qty:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", 4, barZone + 1)
    ui.qty:SetText(qmax > 0 and ("Menge " .. count(qmin or qmax) .. "–" .. count(qmax) .. " Stück"
      .. (qMed and ("   |cffffffff··· üblich " .. count(qMed) .. "|r |cff999999(Median 7 Tage)|r") or "")) or "")
    -- the resolution hint beside it, inside the plot (the head line is full)
    ui.res:ClearAllPoints()
    ui.res:SetPoint("LEFT", ui.qty, "RIGHT", 16, 0)
    -- price line: broken where no snapshot exists, a short dash for a lone slot; sold out as an
    -- orange tick on the base line, cut outliers with a cap on the edge
    local prev
    for _, i in ipairs(v.vis) do
      local p, t0, t1 = series.p[i], series.t0[i], series.t1[i]
      local x = math.max(0, math.min(w, X((t0 + t1) / 2)))
      if p and p > 0 then
        local yy = py(p)
        if prev and prev.t1 == t0 then
          segment(prev.x, prev.y, x, yy, GOLD_RGB)
        else
          segment(x - 1.5, yy, x + 1.5, yy, GOLD_RGB)
        end
        if (cutHigh and p > cutHigh) or (cutLow and p < cutLow) then mark(x, yy, 4, OUT_RGB) end
        prev = { t1 = t1, x = x, y = yy }
      else
        prev = nil
        if p == 0 then
          local m = mark(x, 2.5, 3, OUT_RGB, 0.9)
          m:SetSize(math.max(1, math.min(w, X(t1)) - math.max(0, X(t0)) - 1), 3)
        end
      end
    end
    -- the usual price per hour of the day: a violet step line
    do
      local t = v.axisStart - v.axisStart % 3600
      local prevU
      while t < axisEnd do
        local u = usualAt(t)
        local x0, x1 = math.max(0, X(t)), math.min(w, X(t + 3600))
        if u and x1 > x0 then
          local yy = py(u)
          if prevU then segment(x0, prevU, x0, yy, USUAL_RGB, 0.45) end
          segment(x0, yy, x1, yy, USUAL_RGB, 0.6)
          prevU = yy
        else
          prevU = nil
        end
        t = t + 3600
      end
    end
    -- live tail: lighter points and line, from the curve's end on. Outside the live view many
    -- points fall on a few pixels (a search every second): there one point per TAIL_PX pixels,
    -- the median price of its points, without markers - else the line zigzags in a stripe.
    local last = prev
    local TAIL_PX = 4
    local bucketed = rng.key ~= "live"
    local bucket
    local function flush()
      if not bucket then return end
      local ps = bucket.ps
      table.sort(ps)
      local n = #ps
      local p = n % 2 == 1 and ps[(n + 1) / 2] or (ps[n / 2] + ps[n / 2 + 1]) / 2
      local yy = py(p)
      if last then segment(last.x, last.y, bucket.x, yy, TAIL_RGB, 0.7) end
      last = { x = bucket.x, y = yy }
      bucket = nil
    end
    -- the curve's last point sits in the middle of its slot: live points left of it are drawn
    -- by the curve already (a line back to them would run backwards)
    local curveEnd = prev and prev.x or -1
    for _, pt in ipairs(v.tail) do
      local x = math.max(0, math.min(w, X(pt.t)))
      pt.x = x
      if x < curveEnd then
        -- covered by the curve
      elseif pt.p > 0 then
        if bucketed then
          local slot = math.floor(x / TAIL_PX)
          if bucket and bucket.slot ~= slot then flush() end
          bucket = bucket or { slot = slot, x = (slot + 0.5) * TAIL_PX, ps = {} }
          bucket.ps[#bucket.ps + 1] = pt.p
        else
          local yy = py(pt.p)
          if last then segment(last.x, last.y, x, yy, TAIL_RGB, 0.7) end
          mark(x, yy, 4, TAIL_RGB)
          last = { x = x, y = yy }
        end
      else
        flush()
        mark(x, 2.5, 4, OUT_RGB, 0.9)
        last = nil
      end
    end
    flush()
    -- reference lines and their labels in the right margin
    local labels = {}
    -- a reference outside the scale: no line, its label on the edge with an arrow
    local UP, DOWN = " |TInterface\\Buttons\\Arrow-Up-Up:12:12:0:-2|t", " |TInterface\\Buttons\\Arrow-Down-Up:12:12:0:2|t"
    local function edge(p) return p > top and UP or (p < bottom and DOWN or nil) end
    ui.refLine:Hide()
    if e.ref and e.ref > 0 then
      local arrow = edge(e.ref)
      local yy = py(e.ref)
      if not arrow then
        ui.refLine:ClearAllPoints()
        ui.refLine:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", 0, yy)
        ui.refLine:SetPoint("BOTTOMRIGHT", ui.plot, "BOTTOMRIGHT", 0, yy)
        ui.refLine:Show()
      end
      labels[#labels + 1] = { y = yy, text = "R " .. money(e.ref) .. (arrow or ""), rgb = { 1, 1, 1 } }
    end
    if limit and limit > 0 then
      local arrow = edge(limit)
      if not arrow then dashed(py(limit), w, BUY_RGB) end
      labels[#labels + 1] = { y = py(limit), text = "Kauf " .. money(limit) .. (arrow or ""), rgb = BUY_RGB }
    end
    if ask and ask > 0 then
      local arrow = edge(ask)
      if not arrow then dashed(py(ask), w, SELL_RGB) end
      labels[#labels + 1] = { y = py(ask), text = "Ziel " .. money(ask) .. (arrow or ""), rgb = SELL_RGB }
    end
    -- our own running auctions of the item (every character of the household, from the game's
    -- own auction list, MyAuctions.lua): one pink dashed line per price with the units
    local mine = {}
    for _, key in ipairs(ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or {}) do
      local o = ns.db.owned and ns.db.owned[key]
      for _, a in ipairs(o and o.list or {}) do
        local running = not (a.tl and o.t and o.t + a.tl < time())
        if a.i == id and not a.s and a.u and a.u > 0 and running then
          mine[a.u] = (mine[a.u] or 0) + (a.q or 1)
        end
      end
    end
    for price, q in pairs(mine) do
      local arrow = edge(price)
      if not arrow then dashed(py(price), w, OWN_RGB, 8, 12) end
      labels[#labels + 1] = { y = py(price), text = string.format("Meine %d× %s", q, money(price)) .. (arrow or ""), rgb = OWN_RGB }
    end
    -- bait and fish: catch limit green dashed, bait blue dotted
    if plan and plan.limit then
      dashed(py(plan.limit), w, BUY_RGB)
      labels[#labels + 1] = { y = py(plan.limit), text = "Fang " .. money(plan.limit), rgb = BUY_RGB }
      dashed(py(plan.bait), w, SELL_RGB, 2, 5)
      labels[#labels + 1] = { y = py(plan.bait), text = "Köder " .. money(plan.bait), rgb = SELL_RGB }
    end
    -- the price now as a marker on the right edge
    -- the usual price of this hour, and the delta of the price now to it
    local uNow = usualAt(time())
    if uNow then
      labels[#labels + 1] = { y = py(uNow), text = "üblich " .. money(uNow), rgb = USUAL_RGB }
    end
    if e.now and e.now > 0 then
      mark(w, py(e.now), 7, GOLD_RGB)
      local delta = ""
      if uNow and uNow > 0 then
        local d = e.now / uNow - 1
        delta = string.format(" %s%+d %%|r", d >= 0 and "|cff5fd38d" or "|cffff6b6b", math.floor(d * 100 + 0.5))
      end
      labels[#labels + 1] = { y = py(e.now), text = "jetzt " .. money(e.now) .. delta, rgb = GOLD_RGB }
    end
    placeLabels(labels, h)
    finish()
    ui.view = v
  end

  -- Hover at x pixels from the plot's left edge (nil: mouse left): a live point within 6 px,
  -- else the slot under the mouse; a line, a dot on the price and the game tooltip with time,
  -- price and quantity. The tooltip is rebuilt only when the slot or point changes.
  hover = function(x)
    local v = ui and ui.view
    if not (x and v and x >= 0 and x <= v.w) then
      if ui then
        ui.cursor:Hide()
        ui.dot:Hide()
        if v then v.hoverKey = nil end
        if GameTooltip:GetOwner() == ui.plot then GameTooltip:Hide() end
      end
      return
    end
    local s, pt, slot = v.series, nil, nil
    for k = #v.tail, 1, -1 do
      local c = v.tail[k]
      if c.x and math.abs(c.x - x) <= 6 then pt = c break end
    end
    local t = v.axisStart + x / v.w * v.span
    if not pt and s then
      local lo, hi = 1, #v.vis
      while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local i = v.vis[mid]
        if t < s.t0[i] then hi = mid - 1 elseif t >= s.t1[i] then lo = mid + 1 else slot = i break end
      end
    end
    local key = pt or slot or -math.floor(t / 3600)
    if key == v.hoverKey then return end
    v.hoverKey = key
    local cx, p, q, title, extra
    if pt then
      cx, p, q = pt.x, pt.p, pt.q
      title = stampFull(pt.t)
      extra = "Quelle: " .. (SOURCES[pt.src] or "?")
    elseif slot then
      local t0, t1 = s.t0[slot], s.t1[slot]
      cx = math.max(0, math.min(v.w, ((t0 + t1) / 2 - v.axisStart) / v.span * v.w))
      p, q = s.p[slot], s.q[slot]
      title = stampRange(t0, t1)
      extra = (t1 - t0 > 3600) and "2-h-Wert" or nil
    else
      cx = x
      local h0 = math.floor(t / 3600) * 3600
      title = stampRange(h0, h0 + 3600)
    end
    ui.cursor:ClearAllPoints()
    ui.cursor:SetPoint("TOPLEFT", ui.plot, "TOPLEFT", cx, 0)
    ui.cursor:SetPoint("BOTTOMLEFT", ui.plot, "BOTTOMLEFT", cx, 0)
    ui.cursor:Show()
    if p and p > 0 and v.py then
      ui.dot:ClearAllPoints()
      ui.dot:SetPoint("CENTER", ui.plot, "BOTTOMLEFT", cx, v.py(p))
      ui.dot:Show()
    else
      ui.dot:Hide()
    end
    GameTooltip:SetOwner(ui.plot, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    if cx > v.w / 2 then
      GameTooltip:SetPoint("TOPRIGHT", ui.plot, "TOPLEFT", cx - 12, -8)
    else
      GameTooltip:SetPoint("TOPLEFT", ui.plot, "TOPLEFT", cx + 12, -8)
    end
    GameTooltip:AddLine(title, 1, 1, 1)
    if p and p > 0 then
      GameTooltip:AddDoubleLine("Günstigstes", money(p), 1, 0.82, 0, 1, 1, 1)
      local cmp = ns.Item.RefCompare(p, v.e)
      if cmp then GameTooltip:AddLine(cmp, 0.6, 0.6, 0.62) end
    elseif p == 0 then
      GameTooltip:AddLine("nicht im Angebot", OUT_RGB[1], OUT_RGB[2], OUT_RGB[3])
    else
      GameTooltip:AddLine("keine Daten", 0.6, 0.6, 0.62)
    end
    if q and q > 0 then GameTooltip:AddDoubleLine("Menge", count(q) .. " Stück", 1, 0.82, 0, 1, 1, 1) end
    local r = v.rhythm
    if r and type(r[1]) == "number" then
      local hr = tonumber(date("!%H", berlin(pt and pt.t or (slot and s.t0[slot]) or t)))
      local len = ns.DayTrade.WINDOW_HOURS or 3
      if (hr - r[1]) % 24 < len then GameTooltip:AddLine("Kaufzeit (Tageshandel)", BUY_RGB[1], BUY_RGB[2], BUY_RGB[3]) end
      if (hr - r[2]) % 24 < len then GameTooltip:AddLine("Verkaufszeit (Tageshandel)", SELL_RGB[1], SELL_RGB[2], SELL_RGB[3]) end
    end
    if extra then GameTooltip:AddLine(extra, 0.6, 0.6, 0.62) end
    GameTooltip:Show()
  end

  -- New observations come in bursts (a full scan records every item): one redraw a second at
  -- most, and only when the item's price or its time moved.
  local function soon()
    if pending or not Big.IsShown() then return end
    pending = true
    C_Timer.After(1, function()
      pending = false
      if not Big.IsShown() then return end
      local e = ns.Item.Get(shownID)
      if e.dataT ~= ui.drawnT or e.now ~= ui.drawnNow then
        ui.drawnT, ui.drawnNow = e.dataT, e.now
        ns.Safe(draw)
      end
    end)
  end

  local function create()
    win = ns.NativeWindow.New({ name = NAME, title = "Preisverlauf", icon = "Interface\\Icons\\INV_Misc_Coin_02",
      width = W, height = H })
    local f = win.frame
    f:SetFrameStrata("HIGH") -- like the market data window it opens from, else it would hide behind it
    local pos = ns.db and ns.db.itemDetail and ns.db.itemDetail.bigPos
    if pos then
      f:ClearAllPoints()
      f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end
    f:HookScript("OnDragStop", function(fr)
      local point, _, relPoint, x, yy = fr:GetPoint()
      if point and ns.db then
        ns.db.itemDetail = ns.db.itemDetail or {}
        ns.db.itemDetail.bigPos = { point, relPoint, x, yy }
      end
    end)
    -- every 30 s while shown: the age in the head, the "jetzt" edge and the windows move on
    -- and every second at the auction house: search the item again, so price and quantity move
    -- live (read only; AHSearch keeps the game's throttle and shares it with the sniper, a
    -- search still waiting is not queued twice - the redraw follows the result via Obs.OnRecord)
    f:HookScript("OnShow", function()
      if not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(30, function() ns.Safe(draw) end)
      end
      if not liveTicker and C_Timer and C_Timer.NewTicker then
        liveTicker = C_Timer.NewTicker(0.2, function()
          -- AHSearch keeps the pace (fishing mode: a search every 0.6 s). No search while a
          -- quote or buy of ours is open, and none for 2 s while the last search shows a catch:
          -- the click's price ask must not wait behind a search (the game holds every message
          -- about 0.5 s after the last answer)
          local catchShown = false
          if shownID and Fish.rows and Fish.rows.id == shownID and Fish.rows.t and GetTime() - Fish.rows.t < 2 then
            local K = Fish.BaitPrice(shownID, Fish.Plan(shownID))
            catchShown = K and Fish.State(shownID, K) == "catch" or false
          end
          if shownID and not Fish.pending and not catchShown and ns.AHSearch and ns.AHSearch.IsOpen() then
            local p = Fish.Plan(shownID)
            ns.Safe(ns.AHSearch.Request, shownID, nil, p and p.baitLies or nil)
          end
        end)
      end
    end)
    f:HookScript("OnHide", function()
      if ticker then ticker:Cancel(); ticker = nil end
      if liveTicker then liveTicker:Cancel(); liveTicker = nil end
      if hover then hover(nil) end
      if Fish.pending and Fish.pending.state ~= "buying" then Fish.Drop(true) end
      ns.Safe(Detail.UpdateDetailsButton)
    end)
    win:AddTab({ key = "chart", title = "Preisverlauf", hidden = true, build = buildPage })
    -- new data of the item: own searches and scans (Observations.lua), other players' over the
    -- addon channel (LiveChannel.lua), the end of an own full scan (AuctionScan.lua)
    if ns.Obs and ns.Obs.OnRecord then
      ns.Obs.OnRecord(function(itemID)
        if itemID == shownID then soon() end
        -- searches of any item are kept as fine points too (not the thousands of a full scan)
        if itemID ~= shownID and not (ns.AuctionScan and ns.AuctionScan.Running and ns.AuctionScan.Running()) then
          ns.Safe(record, itemID, ns.Item.Get(itemID))
        end
      end)
    end
    if ns.Live and ns.Live.OnUpdate then ns.Live.OnUpdate(soon) end
    if ns.AuctionScan and ns.AuctionScan.OnDone then ns.AuctionScan.OnDone(soon) end
    ns.AuctionHouse.OnChange(function() if Big.IsShown() then ns.Safe(draw) end end)
    ns.AuctionHouse.OnViewChange(function() if Big.IsShown() then ns.Safe(draw) end end)
    if ns.On then
      ns.On("GET_ITEM_INFO_RECEIVED", function(_, got) if got == shownID and Big.IsShown() then ns.Safe(draw) end end)
    end
  end

  function Big.IsShown() return win ~= nil and win.frame:IsShown() end
  function Big.Shows(id) return Big.IsShown() and id ~= nil and shownID == id end
  function Big.ItemID() return Big.IsShown() and shownID or nil end

  function Big.Show(id)
    if not id then return end
    if not win then create() end
    shownID = id
    win:Show() -- builds the page on the first show
    draw()
    updateDetailsButton()
  end

  function Big.Hide()
    if win then win.frame:Hide() end
  end

  function Big.Toggle(id)
    if Big.Shows(id) then Big.Hide() else Big.Show(id) end
  end

  -- The market data window shows another item (or the same with new data): redraw on it.
  function Big.Follow(id)
    if not (id and Big.IsShown()) then return end
    shownID = id
    draw()
    updateDetailsButton()
  end

  function Big.Refresh() if Big.IsShown() then draw() end end
end

-- Content ------------------------------------------------------------------------------

-- The sniper's current hit for the item, nil if it is none right now.
local function currentHit(id)
  if not (ns.Sniper and ns.Sniper.State) then return nil end
  for _, e in ipairs(ns.Sniper.State().rows) do
    if e.itemID == id and e.hit then return e.hit end
  end
end

-- Offers of the own full scan grouped by unit price, cheapest first, and the scan time.
local function scanLevels(id)
  local list, t = ns.Item.Listings(id)
  if not list or #list == 0 then return nil end
  local levels = {}
  for _, l in ipairs(list) do
    local last = levels[#levels]
    if last and last.unit == l.unit then
      last.count = last.count + l.count
    else
      table.insert(levels, { unit = l.unit, count = l.count })
    end
  end
  return levels, t
end

-- Offers of the newest single search (the shared store of ns.AHSearch or the sniper's list),
-- grouped by price, cheapest first, and its time; nil without one.
local function lastSearch(id)
  local a, ta, b, tb
  if ns.AHSearch and ns.AHSearch.Last then a, ta = ns.AHSearch.Last(id) end
  if ns.Sniper and ns.Sniper.Listings then b, tb = ns.Sniper.Listings(id) end
  if a and (not b or (ta or 0) >= (tb or 0)) then return a, ta end
  return b, tb
end

-- "Einstand eintragen": a cost per unit typed by hand (ns.Profit.SetManualCost), for an item
-- bought before the addon logged purchases. Placed at the y cursor of the cost section.

local function renderBody()
  local Style = ns.Style
  -- Another house than the automatic one is shown (the choice in the head): only its scan.
  -- The search on opening, the last searches and the sniper's hits are the automatic house's.
  local elsewhere = ns.AuctionHouse.Current() ~= ns.AuctionHouse.Auto()
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  frame.icon:SetTexture(getIcon and getIcon(itemID) or nil)
  local name = liveName or ns.ItemName(itemID) or ("#" .. itemID)
  if skin == "blizzard" then
    local getQuality = C_Item and C_Item.GetItemQualityByID
    local q = getQuality and getQuality(itemID)
    local color = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if color and color.hex then name = color.hex .. name .. "|r" end
  end
  frame.name:SetText(name)
  y, used, usedSections, usedMap = 0, 0, 0, 0
  local h = not elsewhere and currentHit(itemID) or nil
  local item = ns.Item(itemID)

  -- 1. Why it is a hit (only while the item is one)
  if h and h.recipe then
    -- Watched recipe (Sniper.RecipeHit): bought to learn or to keep, not price-stair resale.
    section("Warum Treffer: Rezept")
    line("Rezept für", (h.profession or "?") .. (h.skill and h.skill > 0 and (" " .. h.skill) or ""))
    if h.product and h.product > 0 then line("Ergibt", ns.ItemName(h.product) or ("#" .. h.product)) end
    line("Kaufen", string.format("%dx ab %s  (bis %s)", h.units, money(h.best), money(h.buyUpTo)))
    line(h.usualLabel or "Marktwert gestern", h.usual and money(h.usual) or "unbekannt")
    if h.usual and h.best < h.usual then
      line("Darunter", GREEN .. money(h.usual - h.best) .. "|r  " .. Style.MUTED
        .. string.format("(%d %% zu %s)", math.floor((h.best / h.usual - 1) * 100 + 0.5), h.usualLabel or "Marktwert gestern") .. "|r")
    end
    line("Treffer seit", ago(h.firstSeen or time()))
  elseif h then
    section("Warum Treffer")
    line("Kaufen", string.format("%dx bis %s  (zus. %s)", h.units, money(h.buyUpTo), money(h.cost)))
    line("Einstellen zu", money(h.sellAt) .. "  " .. Style.MUTED .. (h.sellSource or "") .. "|r")
    line("Obergrenze (" .. (h.capLabel or "Marktwert gestern") .. ")", h.cap and money(h.cap) or "–")
    line("Erwarteter Gewinn", GREEN .. "+" .. money(h.profit) .. "|r  " .. Style.MUTED .. "nach 5 % Gebühr|r")
    if h.days then
      line("Verkauft in", "ca. " .. Detail.Days(h.days) .. " Tagen  " .. Style.MUTED .. string.format("(%s / Tag, %s)|r",
        Detail.Days(h.perDay), h.perDaySource or ""))
    end
    line("Treffer seit", ago(h.firstSeen or time()))
  end

  -- 2. Price history: the last 48 hours hourly or the last 7 days (switch on the title row)
  local view = chartView()
  section(VIEWS[view].title)
  if not chart then chart = createChart() end
  chart:ClearAllPoints()
  chart:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -y)
  chart:SetPoint("RIGHT", body, "RIGHT", -4, 0)
  drawChart(chart, ns.Item.History(itemID, VIEWS[view].hourly), h and h.buyUpTo, h and h.sellAt, view)
  y = y + CHART_H + 20

  -- 3. Market figures (ns.Item)
  section("Markt  " .. Style.MUTED .. "(" .. ns.AuctionHouse.Name() .. ")|r")
  local fresh = not elsewhere and live and live.itemID == itemID and live
  local now = item.now
  if fresh and fresh.state == "done" then
    local cheapest = fresh.offers[1]
    now = cheapest and cheapest.unit or nil
  end
  -- red when below the median of yesterday and of the 7 days (selling now goes under value)
  local nowText = now and money(now) or (Style.MUTED .. "nicht im AH|r")
  if now and item.medYesterday and item.med7 and now < item.medYesterday and now < item.med7 then
    nowText = "|cffff6b6b" .. nowText .. "|r"
  end
  line("AH jetzt", nowText)
  line("Marktwert heute", item.medToday and money(item.medToday) or "–")
  line("Marktwert gestern", item.medYesterday and money(item.medYesterday) or "–")
  line("Marktwert 7 Tage", item.med7 and money(item.med7) or "–")
  local trend = ns.Item.TrendText(item)
  if trend and item.trend then
    if item.trend <= -0.03 then trend = "|cffff6b6b" .. trend .. "|r"
    elseif item.trend >= 0.03 then trend = GREEN .. trend .. "|r" end
  end
  line("Trend", trend or "–")
  -- saturation: are offers above the cheapest bought too (cloud, 7 days)
  local satText, _, satColor = ns.Item.SaturationText(item)
  line("Sättigung", satText and (satColor .. satText .. "|r") or "–")
  line("Nachfrage", ns.Item.DemandColored(item) or "–")
  line("Angebot AH", string.format("%s Angebote  ·  %s Stück", count(item.offers), count(item.quantity)))
  -- How old the figures above are: the search on opening, else the newest source.
  local dataText
  if fresh and fresh.state == "searching" then
    dataText = Style.ACCENT .. "suche …|r"
  elseif fresh and fresh.state == "done" then
    dataText = time() - fresh.t < 60 and "gerade gesucht" or ("gesucht " .. ago(fresh.t))
  elseif item.dataT then
    dataText = (fresh and fresh.state == "failed" and (Style.MUTED .. "Suche ohne Antwort · |r") or "") .. ago(item.dataT)
  end
  line("Daten", dataText or (Style.MUTED .. "keine aus dem AH " .. ns.AuctionHouse.Name() .. "|r"))

  -- 3b. What one unit cost the player (ns.Profit.UnitCost) and the room left to undercut.
  local cost = nil
  local costSource
  if ns.Profit and ns.Profit.UnitCost then cost, costSource = ns.Profit.UnitCost(itemID) end
  section("Einkauf")
  if not cost then
    line("Einkauf / Stk.", Style.MUTED .. "unbekannt|r")
  else
    if costSource == "Beute" then
      line("Einkauf / Stk.", "Beute")
    else
      line("Einkauf / Stk.", money(math.floor(cost + 0.5)))
      -- lost deposits of this item's cancelled / expired auctions raise it (Profit.LostDepositPerUnit)
      local lostShare = ns.Profit.LostDepositPerUnit and ns.Profit.LostDepositPerUnit(itemID) or 0
      line("Minimalpreis", money(ns.Profit.BreakEven(cost + lostShare)))
    end
    local other
    if fresh and fresh.state == "done" then
      for _, o in ipairs(fresh.offers) do
        if not o.own then other = o.unit break end
      end
    else
      other = item.now
    end
    if other then
      local room = math.floor((other - 1) * 0.95 - cost)
      line("Luft beim Unterbieten", room >= 0 and (GREEN .. money(room) .. "|r")
        or ("|cffff6b6b-" .. money(-room) .. "|r"))
    end
  end

  -- 4. Price stair: offers of the sniper's last search, else of the own full scan; left out
  -- without either. With a hit: bought levels green, the level sold under highlighted.
  -- The search started on opening wins: "suche …" while it runs, then "gerade gesucht".
  local levels, t, from
  if fresh and fresh.state == "done" then
    levels, t = fresh.offers, fresh.t
    from = time() - t < 60 and "gerade gesucht" or ("letzte Suche " .. ago(t))
  elseif not elsewhere then
    levels, t = lastSearch(itemID)
    if levels then from = "letzte Suche " .. ago(t) end
  end
  local mark = h and levels -- hit markers only on the levels of a search
  if not levels then
    levels, t = scanLevels(itemID)
    from = levels and ("Scan " .. ago(t or time()))
  end
  if fresh and fresh.state == "searching" then
    from = "suche …" .. (from and ("  ·  " .. from) or "")
  elseif fresh and fresh.state == "failed" then
    from = "Suche ohne Antwort" .. (from and ("  ·  " .. from) or "")
  end
  if from then section("Preistreppe") end
  if fresh and fresh.state == "searching" and not levels then
    line(Style.ACCENT .. "suche …|r", "")
  elseif levels and #levels == 0 then
    line("keine Angebote", "")
  elseif levels then
    local MAX = 9
    for i = 1, math.min(MAX, #levels) do
      local l = levels[i]
      local price, amount = money(l.unit), count(l.count) .. " Stück"
      if l.own then
        price = price .. Style.MUTED .. "  eigenes|r"
      elseif mark and l.unit <= h.buyUpTo then
        price, amount = GREEN .. price .. "  kaufen|r", GREEN .. amount .. "|r"
      elseif mark and l.unit == h.level then
        price = Style.ACCENT .. price .. "  einstellen knapp darunter|r"
      end
      line(price, amount)
    end
    if #levels > MAX then line(Style.MUTED .. string.format("+%d weitere Preisstufen", #levels - MAX) .. "|r", "") end
  end

  -- 4b. Where it drops (ns.ItemDrops, Crafting.lua): creature, chance, level and zone; a click
  -- on a creature with a known place sets the map waypoint.
  local drops, dropCount = ns.ItemDrops and ns.ItemDrops(itemID, 4)
  if drops then
    section("Fundorte (Drop)")
    for _, d in ipairs(drops) do
      local top = y
      line(d.text, d.right)
      if d.sub ~= "" then
        line(Style.MUTED .. "   " .. d.sub .. "|r", d.loc and (Style.ACCENT .. "Karte|r") or "")
      end
      if d.loc then mapButton(top, y - top, d.loc) end
    end
    if (dropCount or 0) > #drops then
      line(Style.MUTED .. string.format("und %d weitere", dropCount - #drops) .. "|r", "")
    end
  end

  -- 5. Crafting (same recipe choice as the tooltip), with a button to the recipe in "Alle Produkte"
  local craft = ns.CraftInfo and ns.CraftInfo(itemID)
  local openPid, openItem
  if craft then
    section("Herstellung")
    line("Herstellkosten / Stück", money(math.floor(craft.cost + 0.5)))
    line("Rezept", craft.prof .. " · " .. craft.source)
    openPid, openItem = craft.pid, itemID
  end

  -- 6. Recipe items (at the end, below the market): what the recipe teaches, what making it costs and brings (Crafting.lua).
  local teach = ns.RecipeTeachInfo and ns.RecipeTeachInfo(itemID)
  if teach then
    local t = teach.teaches
    local function m(c) return money(math.floor(c + 0.5)) end
    section("Rezept")
    line("Beruf", t.profession .. (t.skill and (" ab " .. t.skill) or ""))
    local missing = teach.missing and (ORANGE .. "kein Preis: " .. (ns.ItemName(teach.missing) or "?") .. "|r")
    line(t.product and "Herstellkosten / Stück" or "Material", teach.cost and m(teach.cost) or missing or "–")
    if t.product then
      -- the product's market value (R, Marktwert gestern); the profit below is after the AH cut
      local ref = teach.product and teach.product.ref
      line("Marktwert / Stück", ref and m(ref) or (m(teach.value) .. (teach.onAH and "" or ("  " .. Style.MUTED .. "Händler|r"))))
      if teach.profit then
        line("Gewinn / Stück", (teach.profit >= 0 and (GREEN .. "+") or "|cffff6b6b-") .. m(math.abs(teach.profit)) .. "|r")
      end
      local p = teach.product
      line("Nachfrage (Produkt)", ns.Item.DemandColored(p) or "–")
      local pt = ns.Item.TrendText(p)
      if pt and p.trend then
        if p.trend <= -0.03 then pt = "|cffff6b6b" .. pt .. "|r"
        elseif p.trend >= 0.03 then pt = GREEN .. pt .. "|r" end
      end
      line("Trend (Produkt)", pt or "–")
    end
    if t.product and t.pid and ns.RecipeData and ns.RecipeData[t.pid] then openPid, openItem = t.pid, t.product end
  end
  -- "Im Beruf zeigen": the recipe in "Alle Produkte" (Crafting.lua), right-aligned under the lines
  if not recipeButton then
    local ok, b = pcall(CreateFrame, "Button", nil, body, "UIPanelButtonTemplate")
    if ok and b then
      b:SetSize(130, 20)
      b:SetText("Im Beruf zeigen")
      b:SetScript("OnClick", function(self)
        if self.pid and ns.Products and ns.Products.ShowItem then ns.Safe(ns.Products.ShowItem, self.pid, self.item) end
      end)
      recipeButton = b
    end
  end
  if recipeButton then
    recipeButton.pid, recipeButton.item = openPid, openItem
    recipeButton:ClearAllPoints()
    if openPid and ns.Products and ns.Products.ShowItem then
      y = y + 6
      recipeButton:SetPoint("TOPRIGHT", body, "TOPRIGHT", -2, -y)
      recipeButton:Show()
      y = y + 22
    else
      recipeButton:Hide()
    end
  end

  -- "Beobachten" / "Entfernen": the item on the overlay's watch list (a click there opens the
  -- big chart), at the very bottom
  if not watchButton then
    local ok, b = pcall(CreateFrame, "Button", nil, body, "UIPanelButtonTemplate")
    if ok and b then
      b:SetSize(130, 20)
      b:SetScript("OnClick", function()
        if itemID and ns.Watch then ns.Watch.Toggle(itemID) end
        render()
      end)
      watchButton = b
    end
  end
  if watchButton then
    watchButton:ClearAllPoints()
    if itemID and ns.Watch then
      watchButton:SetText(ns.Watch.Has(itemID) and "Entfernen" or "Beobachten")
      y = y + 8
      watchButton:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -y)
      watchButton:Show()
      y = y + 22
    else
      watchButton:Hide()
    end
  end

  for i = used + 1, #lines do lines[i].label:Hide(); lines[i].value:Hide() end
  for i = usedSections + 1, #sections do sections[i].text:Hide(); sections[i].rule:Hide() end
  for i = usedMap + 1, #mapButtons do mapButtons[i]:Hide() end
  body:SetSize(contentWidth(), math.max(1, y + 6))
  if scroll.UpdateBar then scroll.UpdateBar() end
end

-- The window on the house of the choice in its head (AuctionHouse.Chooser).
render = function()
  if not frame or not frame:IsShown() or not itemID then return end
  if frame.house then frame.house.Update() end
  local house = frame.house and frame.house.Selected() or nil
  ns.AuctionHouse.WithView(house, renderBody)
  -- the big chart follows the item shown here (and redraws with its new data)
  if Big.Follow then ns.Safe(Big.Follow, itemID) end
end

-- Window ----------------------------------------------------------------------------

local FRAME_NAME = "M4CompanionItemDetail"

local function savePosition()
  local point, _, relPoint, x, yy = frame:GetPoint()
  if not (point and ns.db) then return end
  ns.db.itemDetail = ns.db.itemDetail or {}
  ns.db.itemDetail.pos = { point, relPoint, x, yy }
end

-- The AH panel to dock at: the Selling panel, else the auction house frame; nil when closed.
local function dockAnchor()
  local sell = ns.Selling and ns.Selling.Frame and ns.Selling.Frame()
  if sell and sell:IsShown() then return sell end
  local ah = AuctionHouseFrame
  if ah and ah.IsShown and ah:IsShown() then return ah end
  -- the profession window (Alt+click on a recipe or reagent there)
  local pf = rawget(_G, "ProfessionsFrame") or rawget(_G, "TradeSkillFrame")
  if pf and pf.IsShown and pf:IsShown() then return pf end
end

-- Docks right of `anchor` (or the current AH panel), else places the own window.
place = function(anchor)
  anchor = anchor or dockAnchor()
  docked = anchor
  -- a docked window closes with the window it docks at (own windows: hooked once)
  if anchor and rawget(anchor, "m4Native") and not rawget(anchor, "m4DetailHook") then
    anchor.m4DetailHook = true
    anchor:HookScript("OnHide", function(f) if docked == f then Detail.Hide() end end)
  end
  frame:ClearAllPoints()
  if anchor and skin == "blizzard" and (anchor == AuctionHouseFrame or rawget(anchor, "m4Native")
      or anchor == rawget(_G, "ProfessionsFrame") or anchor == rawget(_G, "TradeSkillFrame")) then
    -- right on the auction house frame's edge, same height: reads as part of it
    frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", -2, 0)
    frame:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", -2, 0)
  elseif anchor then
    frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    frame:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 4, 0)
  else
    frame:SetHeight(FREE_HEIGHT)
    local pos = ns.db and ns.db.itemDetail and ns.db.itemDetail.pos
    if pos then
      frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
      frame:SetPoint("CENTER", UIParent, "CENTER", 260, 40)
    end
  end
end

local function create()
  local Style = ns.Style
  frame = CreateFrame("Frame", FRAME_NAME, UIParent)
  frame:SetWidth(WIDTH)
  frame:SetFrameStrata("HIGH")
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  -- Two looks on child layers below the content: the own flat panel and a native Blizzard
  -- frame (applySkin shows one of them).
  frame.m4deco = CreateFrame("Frame", nil, frame)
  frame.m4deco:SetAllPoints()
  Style.Panel(frame.m4deco, 30)
  local okB, blizz = pcall(CreateFrame, "Frame", nil, frame, "ButtonFrameTemplate")
  if not okB or not blizz then okB, blizz = pcall(CreateFrame, "Frame", nil, frame, "BasicFrameTemplateWithInset") end
  if okB and blizz then
    blizz:SetAllPoints()
    if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, blizz) end
    if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, blizz) end
    local closeB = rawget(blizz, "CloseButton")
    if type(closeB) == "table" then closeB:SetScript("OnClick", function() Detail.Hide() end) end
    local container = rawget(blizz, "TitleContainer")
    local title = rawget(blizz, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
    if type(title) == "table" then title:SetText("Marktdaten") end
    if type(rawget(blizz, "Inset")) == "table" then
      blizz.Inset:ClearAllPoints()
      blizz.Inset:SetPoint("TOPLEFT", 4, -64)
      blizz.Inset:SetPoint("BOTTOMRIGHT", -6, 6)
    end
    blizz:Hide()
    frame.blizzdeco = blizz
  end
  -- ESC closes the window (Blizzard's CloseSpecialWindows).
  if UISpecialFrames then tinsert(UISpecialFrames, FRAME_NAME) end
  frame:SetScript("OnHide", function() origin = nil end)
  local close = Style.Close(frame, function() Detail.Hide() end)
  close:SetPoint("TOPRIGHT", -4, -4)
  frame.close = close
  -- Head: icon and name, item tooltip on hover; dragging it moves the own window.
  local head = CreateFrame("Button", nil, frame)
  head:SetPoint("TOPLEFT", 6, -4)
  head:SetPoint("RIGHT", frame, "RIGHT", -32, 0)
  head:SetHeight(24)
  frame.icon = head:CreateTexture(nil, "ARTWORK")
  frame.icon:SetSize(20, 20)
  frame.icon:SetPoint("LEFT", 2, 0)
  frame.name = Style.Text(head, 14)
  frame.name:SetPoint("LEFT", frame.icon, "RIGHT", 6, 0)
  frame.name:SetPoint("RIGHT", head, "RIGHT", 0, 0)
  frame.name:SetJustifyH("LEFT")
  head:SetScript("OnEnter", function(self)
    if not itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    GameTooltip:Show()
  end)
  head:SetScript("OnLeave", function() GameTooltip:Hide() end)
  head:RegisterForDrag("LeftButton")
  head:SetScript("OnDragStart", function()
    if not docked then frame:StartMoving() end
  end)
  head:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    if not docked then ns.Safe(savePosition) end
  end)
  frame.head = head
  -- right in the head: which auction house the figures are of (green = automatic, red = chosen)
  frame.house = ns.AuctionHouse.Chooser(frame, 104, function() render() end)
  -- the house chosen in another window: this one follows
  ns.AuctionHouse.OnViewChange(function() if frame:IsShown() then ns.Safe(render) end end)
  scroll, body = Style.Scroll(frame)
  frame:Hide()
end

-- Shows the look of `skin` and lays out head and list for it.
local function applySkin()
  local blizz = skin == "blizzard" and frame.blizzdeco ~= nil
  frame.m4deco:SetShown(not blizz)
  frame.close:SetShown(not blizz)
  if frame.blizzdeco then frame.blizzdeco:SetShown(blizz) end
  -- content above the decoration layers
  local base = frame:GetFrameLevel() or 1
  frame.m4deco:SetFrameLevel(base)
  if frame.blizzdeco then frame.blizzdeco:SetFrameLevel(base) end
  frame.head:SetFrameLevel(base + 5)
  scroll:SetFrameLevel(base + 5)
  frame.house:SetFrameLevel(base + 6)
  frame.house:ClearAllPoints()
  if scroll.thumb then
    if blizz then
      scroll.thumb:SetColorTexture(0.85, 0.68, 0.2, 0.8)
      scroll.track:SetColorTexture(0, 0, 0, 0.35)
    else
      scroll.thumb:SetColorTexture(unpack(ns.Style.C.accent))
      scroll.track:SetColorTexture(1, 1, 1, 0.04)
    end
  end
  frame.head:ClearAllPoints()
  scroll:ClearAllPoints()
  if blizz then
    frame.house:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -33)
    frame.head:SetPoint("TOPLEFT", 12, -32)
    frame.head:SetPoint("RIGHT", frame.house, "LEFT", -8, 0)
    frame.head:SetHeight(28)
    frame.icon:SetSize(24, 24)
    frame.name:SetFontObject(GameFontHighlightLarge)
    scroll:SetPoint("TOPLEFT", 14, -72)
    scroll:SetPoint("BOTTOMRIGHT", -14, 14)
  else
    frame.house:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -4)
    frame.head:SetPoint("TOPLEFT", 6, -4)
    frame.head:SetPoint("RIGHT", frame.house, "LEFT", -8, 0)
    frame.head:SetHeight(24)
    frame.icon:SetSize(20, 20)
    frame.name:SetFontObject(ns.Style.Font(14))
    scroll:SetPoint("TOPLEFT", 8, -36)
    scroll:SetPoint("BOTTOMRIGHT", -14, 8)
  end
end

-- Item id from an id, an item link or an item string; nil otherwise.
local function toID(item)
  if type(item) == "number" then return item end
  if type(item) == "string" then return tonumber(item:match("item:(%d+)")) end
end

-- Opens the detail of the item (docked at the auction house or as a window of its own).
--   opts.anchor  dock right of this frame instead of the current AH panel
--   opts.origin  "sniper" when opened from the sniper list
--   opts.house   the auction house to show ("A"/"N"/"H"); nil: the automatic one
-- Searches the item now when the auction house is open (ns.AHSearch); the answer re-renders.
-- Full auction house key of an item link with a random suffix ("… des Bären"): the plain item
-- id would find only the variant without suffix. nil for links without one.
local function keyFromLink(link)
  if type(link) ~= "string" then return nil end
  local id, suffix = link:match("item:(%d+):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")
  id, suffix = tonumber(id), tonumber(suffix)
  if not (id and suffix and suffix ~= 0) then return nil end
  local api = C_AuctionHouse
  if not (api and api.MakeItemKey) then return nil end
  local level = GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(link) or 0
  local ok, key = pcall(api.MakeItemKey, id, level or 0, suffix)
  return ok and key or nil
end
Detail.KeyFromLink = keyFromLink


local function searchLive(id)
  local AHSearch = ns.AHSearch
  if not (AHSearch and AHSearch.IsOpen and AHSearch.IsOpen()) then live = nil; return end
  if live and live.itemID == id and live.state == "searching" then return end
  local my = { itemID = id, state = "searching" }
  live = my
  local accepted = AHSearch.Request(id, function(offers)
    if live ~= my then return end
    my.state, my.offers, my.t = offers and "done" or "failed", offers, time()
    render()
  end, true, liveKey)
  if not accepted and live == my then live = nil end
end

function Detail.Show(item, opts)
  local id = toID(item)
  if not id then return end
  opts = opts or {}
  if not frame then create() end
  itemID, origin = id, opts.origin
  liveKey = opts.itemKey or keyFromLink(item)
  liveName = nil
  if type(item) == "string" then liveName = item:match("|h%[(.-)%]|h") end
  if not liveName and liveKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
    local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, liveKey)
    liveName = ok and info and info.itemName or nil
  end
  if live and live.itemID == id then live = nil end -- a new variant searches again
  skin = opts.skin or "blizzard" -- the native look everywhere (the own look stays selectable)
  -- the house: the caller's (the ledger's market search passes its choice), else automatic
  frame.house.Select(opts.house)
  applySkin()
  place(opts.anchor)
  frame:Show()
  searchLive(id)
  render()
end

-- Click on a sniper hit: opens the detail next to `parent` (the Selling panel); a second click
-- on the same item closes it.
-- origin: the panel mode it was opened from ("sniper" default, "mine"); it closes when the
-- panel switches to another mode (Detail.HideSniper).
function Detail.Toggle(id, parent, from)
  if frame and frame:IsShown() and itemID == id then return Detail.Hide() end
  Detail.Show(id, { anchor = parent, origin = from or "sniper" })
end

function Detail.Hide()
  if frame then frame:Hide() end
  itemID, origin, live = nil, nil, nil
end

-- Closes the window only if it was opened from the sniper list (leaving the sniper mode).
-- Closes a window opened from a panel mode, unless that mode is `keep` (the current one).
-- Windows opened by Alt+click (no origin) stay.
function Detail.HideSniper(keep)
  if origin and origin ~= keep then Detail.Hide() end
end

function Detail.IsShown() return frame ~= nil and frame:IsShown() end
function Detail.Origin() return frame and frame:IsShown() and origin or nil end
function Detail.ItemID() return frame and frame:IsShown() and itemID or nil end

function Detail.Refresh() render() end

-- Alt+left click without other modifiers.
function Detail.IsAltClick()
  return IsAltKeyDown and IsAltKeyDown() and not (IsShiftKeyDown and IsShiftKeyDown())
    and not (IsControlKeyDown and IsControlKeyDown()) or false
end

-- For the addon's item tables: opens the detail on Alt+click and returns true; returns false
-- otherwise, so the table keeps its normal click behaviour.
-- Alt+click on an item: its detail. anchor: the window the click came from (it docks there
-- instead of the auction house or profession window), e.g. a NativeWindow.
function Detail.AltClick(item, anchor)
  local id = toID(item)
  if not id or not Detail.IsAltClick() then return false end
  ns.Safe(Detail.Show, id, anchor and { anchor = anchor } or nil)
  return true
end

-- /m4 item <link | name | id>: the item id, or nil and a message.
function Detail.Resolve(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "Item fehlt: /m4 item <Item-Link, Name oder ID>" end
  local id = toID(text) or tonumber(text)
  if id then return id end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local link = getInfo and select(2, getInfo(text))
  id = toID(link)
  if id then return id end
  -- Names the addon ships (Data_ItemNames.lua): exact first, else one unique partial match.
  local want = text:lower()
  local partial = {}
  for itemId, name in pairs(ns.ItemNames or {}) do
    local lower = name:lower()
    if lower == want then return itemId end
    if lower:find(want, 1, true) then table.insert(partial, itemId) end
  end
  if #partial == 1 then return partial[1] end
  if #partial > 1 then
    table.sort(partial, function(a, b) return ns.ItemNames[a] < ns.ItemNames[b] end)
    local names = {}
    for i = 1, math.min(5, #partial) do names[i] = ns.ItemNames[partial[i]] end
    return nil, string.format("%d Items passen zu „%s“: %s%s", #partial, text, table.concat(names, ", "),
      #partial > 5 and ", …" or "")
  end
  return nil, "Item nicht gefunden: " .. text
end

function Detail.Open(text)
  local id, err = Detail.Resolve(text)
  if id then return Detail.Show(id) end
  print("|cffffd100M4:|r " .. err)
end

-- Alt+left click on any item of the game UI (bags, bank, character, loot, chat links,
-- Blizzard's auction house lists): a post hook, the original keeps running untouched.
-- Both paths below can see the same click: open once.
local lastID, lastAt = nil, 0
local function openOnce(id, link)
  local now = GetTime and GetTime() or 0
  if id == lastID and now - lastAt < 0.5 then return end
  lastID, lastAt = id, now
  ns.Safe(Detail.Show, link or id) -- the link keeps a random suffix
end

if hooksecurefunc and HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", function(link)
    if type(link) ~= "string" or not Detail.IsAltClick() then return end
    local button = GetMouseButtonClicked and GetMouseButtonClicked()
    if button and button ~= "LeftButton" then return end
    local id = toID(link)
    if id then openOnce(id, link) end
  end)
end

-- Blizzard's auction house lists do not go through HandleModifiedItemClick. Every item the
-- game shows a tooltip for can be opened instead: Alt+left click while the game tooltip
-- shows an item (GLOBAL_MOUSE_DOWN only observes the click, nothing is intercepted).
-- A recipe's tooltip embeds the tooltip of what it makes, and GameTooltip:GetItem() then names
-- that product. So the first item set on the tooltip is remembered too, and of the candidates
-- the one whose name is the tooltip's title wins.
local tooltipFirst = nil
if GameTooltip and GameTooltip.HookScript then
  GameTooltip:HookScript("OnTooltipCleared", function() tooltipFirst = nil end)
  if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      if tooltip == GameTooltip and not tooltipFirst and data and data.id then tooltipFirst = data.id end
    end)
  else
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
      if tooltipFirst then return end
      local _, link = tooltip:GetItem()
      tooltipFirst = toID(link)
    end)
  end
end

function Detail.TooltipItem()
  if not (GameTooltip and GameTooltip:IsShown() and GameTooltip.GetItem) then return nil end
  local _, link = GameTooltip:GetItem()
  local id = toID(link)
  local titleLine = _G.GameTooltipTextLeft1
  local title = titleLine and titleLine.GetText and titleLine:GetText()
  if title and tooltipFirst and tooltipFirst ~= id then
    if ns.ItemName(tooltipFirst) == title then return tooltipFirst end
    if id and ns.ItemName(id) == title then return id end
  end
  return tooltipFirst or id
end

if CreateFrame then
  local watcher = CreateFrame("Frame")
  if pcall(watcher.RegisterEvent, watcher, "GLOBAL_MOUSE_DOWN") then
    watcher:SetScript("OnEvent", function(_, _, button)
      if button ~= "LeftButton" or not Detail.IsAltClick() then return end
      local id = Detail.TooltipItem()
      local _, link = GameTooltip and GameTooltip.GetItem and GameTooltip:GetItem()
      if id then openOnce(id, toID(link) == id and link or nil) end
    end)
  end
end

if ns.On then
  -- The auction house opens: an open own window docks at it (after the Selling panel exists).
  ns.On("AUCTION_HOUSE_SHOW", function()
    if not C_Timer then return end
    C_Timer.After(0.3, function()
      if frame and frame:IsShown() and not docked then ns.Safe(place); ns.Safe(render) end
    end)
  end)
  -- It closes: a docked window closes with it.
  -- The profession window closes: a window docked at it closes with it.
  ns.On("TRADE_SKILL_CLOSE", function()
    local pf = rawget(_G, "ProfessionsFrame") or rawget(_G, "TradeSkillFrame")
    if docked and docked == pf then Detail.Hide() end
  end)
  ns.On("AUCTION_HOUSE_CLOSED", function()
    if docked and not rawget(docked, "m4Native") then Detail.Hide() end -- own windows stay
  end)
  -- The name arrives from the server after the window opened.
  ns.On("GET_ITEM_INFO_RECEIVED", function(_, id)
    if id == itemID then render() end
  end)
end

-- Another auction house opened: the automatic choice moved, the figures follow.
ns.AuctionHouse.OnChange(function() if render then render() end end)
