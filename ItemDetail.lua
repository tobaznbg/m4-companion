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
local ADDON, ns = ...

local Detail = {}
ns.ItemDetail = Detail
ns.SniperDetail = Detail -- old name, kept for callers that still use it

local WIDTH = 340
local FREE_HEIGHT = 560 -- height as a window of its own (docked it follows the anchor)
local LINE = 16
local CHART_H = 96
local GREEN, ORANGE = "|cff5fd38d", "|cffffb547"

local frame, body, scroll, itemID
local recipeButton -- "Im Beruf zeigen" under the crafting / recipe lines
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
  -- Segment switch "48 h | 7 Tage" on the section's title row, right above the chart.
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
      b:SetPoint("BOTTOMRIGHT", c.plot, "TOPRIGHT", 0, 5)
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
  local satText, satPct, satColor = ns.Item.SaturationText(item)
  line("Sättigung", satText and (satColor .. satText .. "|r  " .. Style.MUTED
    .. string.format("(%d %% bis +5 %% verkauft)", satPct) .. "|r") or "–")
  local demand = ns.Item.DemandText(item)
  line("Nachfrage", demand or "–")
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
      local demand = ns.Item.DemandText(p)
      line("Nachfrage (Produkt)", demand or "–")
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
