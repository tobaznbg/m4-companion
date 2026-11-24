-- SniperUI: page "Sniper" in the main window: its settings (adjustable, ns.Deals.Settings),
-- its state and session figures, the watch list it searches and the latest hits/buys.
-- The sniper itself runs at the auction house (panel on the right, "Start").
local ADDON, ns = ...

local Style
local ROW = 22
local GREEN, ORANGE, MUTED = "|cff5fd38d", "|cffffb547", "|cff99999e"

local function money(c) return ns.FormatMoney(c or 0, true) end

local DEMAND_STEPS = { { 1, "niedrig" }, { 10, "mittel" }, { 50, "hoch" }, { 200, "sehr hoch" } } -- units per day
-- Maximalpreis steps: no limit, 1g..25g by 1g, then by 2g up to 100g, then by 5g up to 5000g.
local MAX_PRICE_STEPS = { 0 }
do
  local GOLD = 10000
  for g = 1, 25 do table.insert(MAX_PRICE_STEPS, g * GOLD) end
  for g = 26, 100, 2 do table.insert(MAX_PRICE_STEPS, g * GOLD) end
  for g = 105, 5000, 5 do table.insert(MAX_PRICE_STEPS, g * GOLD) end
end

-- "+4 % steigt" (green) / "-12 % fällt" (red) / sideways muted; "–" without data (ns.Item).
local function trendText(itemID)
  local e = ns.Item(itemID)
  local text = ns.Item.TrendText(e)
  if not text then return MUTED .. "–|r" end
  if e.trend and e.trend >= 0.03 then return GREEN .. text .. "|r" end
  if e.trend and e.trend <= -0.03 then return "|cffff6b6b" .. text .. "|r" end
  return MUTED .. text .. "|r"
end

local function demandLabel(v)
  local label = "kaum"
  for _, step in ipairs(DEMAND_STEPS) do if v >= step[1] then label = step[2] end end
  return label
end

local function card(parent, title)
  local c = CreateFrame("Frame", nil, parent)
  Style.Solid(c, { 1, 1, 1, 0.03 }):SetAllPoints()
  Style.Border(c)
  local t = Style.Text(c, 12)
  t:SetPoint("TOPLEFT", 10, -8)
  t:SetText(title)
  t:SetTextColor(unpack(Style.C.muted))
  return c
end

-- One adjustable value: label, value text, − and + buttons.
local function stepper(parent, y, label, show, minus, plus)
  local l = Style.Text(parent, 12)
  l:SetPoint("TOPLEFT", 10, y)
  l:SetText(label)
  local v = Style.Text(parent, 12)
  v:SetPoint("TOPRIGHT", -66, y)
  v:SetJustifyH("RIGHT")
  local m = Style.Button(parent, "–", 24, 18, function() ns.Safe(minus) end)
  m:SetPoint("TOPRIGHT", -36, y + 2)
  local p = Style.Button(parent, "+", 24, 18, function() ns.Safe(plus) end)
  p:SetPoint("TOPRIGHT", -8, y + 2)
  return function() v:SetText(show()) end
end

-- One on/off value: label, a button showing "an"/"aus" that flips it.
local function toggle(parent, y, label, get, flip)
  local l = Style.Text(parent, 12)
  l:SetPoint("TOPLEFT", 10, y)
  l:SetText(label)
  local b = Style.Button(parent, "", 52, 18, function() ns.Safe(flip) end)
  b:SetPoint("TOPRIGHT", -8, y + 2)
  return function() b.label:SetText(get() and (GREEN .. "an|r") or (MUTED .. "aus|r")) end
end

-- Scrollable list with item icon and item tooltip per row.
local function itemList(parent, columns)
  local scroll, body = Style.Scroll(parent)
  local rows = {}
  local list = {}
  function list:Set(entries, width)
    body:SetSize(width, math.max(1, #entries * ROW))
    for i, e in ipairs(entries) do
      local r = rows[i]
      if not r then
        r = CreateFrame("Frame", nil, body)
        r:SetHeight(ROW)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
        r:SetPoint("RIGHT", body, "RIGHT")
        local stripe = Style.Solid(r, Style.C.row)
        stripe:SetAllPoints()
        stripe:SetShown(i % 2 == 0)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(ROW - 6, ROW - 6)
        r.icon:SetPoint("LEFT", 4, 0)
        r.cells = {}
        local x = 0
        for c = #columns, 1, -1 do
          local fs = Style.Text(r, 12)
          if c == 1 then
            fs:SetPoint("LEFT", ROW + 2, 0)
            fs:SetPoint("RIGHT", r, "RIGHT", -x - 6, 0)
            fs:SetJustifyH("LEFT")
          else
            fs:SetPoint("RIGHT", r, "RIGHT", -x - 6, 0)
            fs:SetWidth(columns[c] - 8)
            fs:SetJustifyH("RIGHT")
            x = x + columns[c]
          end
          r.cells[c] = fs
        end
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
          if not self.itemID then return end
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetItemByID(self.itemID)
          GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Alt+click: item detail window (ItemDetail.lua).
        r:SetScript("OnMouseUp", function(self, button)
          if button == "LeftButton" and self.itemID and ns.ItemDetail then
            ns.Safe(ns.ItemDetail.AltClick, self.itemID)
          end
        end)
        rows[i] = r
      end
      r.itemID = e.itemID
      local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
      r.icon:SetTexture(e.itemID and getIcon and getIcon(e.itemID) or nil)
      for c, fs in ipairs(r.cells) do fs:SetText(e[c] or "") end
      r:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
  end
  list.scroll = scroll
  return list
end

local function build(page, width, height)
  Style = ns.Style
  local Deals, Sniper = ns.Deals, ns.Sniper
  local PAD, GAP = 16, 12
  local leftW = 360
  local rightW = width - 2 * PAD - leftW - GAP

  -- Settings ---------------------------------------------------------------------
  local settings = card(page, "Einstellungen")
  settings:SetPoint("TOPLEFT", PAD, -PAD)
  settings:SetSize(leftW, 346)
  local function set(key, v) Deals.Set(key, v) end
  local updates = {}
  local function S() return Deals.Settings() end
  table.insert(updates, stepper(settings, -34, "Vorauswahl bis (Anteil vom Wert)",
    function() return string.format("%d %%", math.floor(S().maxShare * 100 + 0.5)) end,
    function() set("maxShare", math.max(0.2, S().maxShare - 0.05)) end,
    function() set("maxShare", math.min(0.9, S().maxShare + 0.05)) end))
  table.insert(updates, stepper(settings, -60, "Mindestgewinn pro Treffer",
    function() return money(S().minProfit) end,
    function() set("minProfit", math.max(500, S().minProfit - 500)) end,
    function() set("minProfit", S().minProfit + 500) end))
  local function stepDemand(key, dir)
    local cur, idx = S()[key], 1
    for i, step in ipairs(DEMAND_STEPS) do if cur >= step[1] then idx = i end end
    idx = math.max(1, math.min(#DEMAND_STEPS, idx + dir))
    set(key, DEMAND_STEPS[idx][1])
  end
  table.insert(updates, stepper(settings, -86, "Nachfrage für Treffer mindestens",
    function() return demandLabel(S().minDemand) end,
    function() stepDemand("minDemand", -1) end, function() stepDemand("minDemand", 1) end))
  table.insert(updates, stepper(settings, -112, "Nachfrage für Beobachtungsliste",
    function() return demandLabel(S().watchMinDemand) end,
    function() stepDemand("watchMinDemand", -1) end, function() stepDemand("watchMinDemand", 1) end))
  table.insert(updates, stepper(settings, -138, "Beobachtungsliste höchstens",
    function() return string.format("%d Items", S().watchMax) end,
    function() set("watchMax", math.max(25, S().watchMax - 25)) end,
    function() set("watchMax", math.min(400, S().watchMax + 25)) end))
  -- Price stair (Deals.Staircase): how fast the bought units must sell, and the gap.
  table.insert(updates, stepper(settings, -164, "Verkauft in höchstens",
    function() return string.format("%d %s", S().sellDays, S().sellDays == 1 and "Tag" or "Tagen") end,
    function() set("sellDays", math.max(1, S().sellDays - 1)) end,
    function() set("sellDays", math.min(7, S().sellDays + 1)) end))
  table.insert(updates, stepper(settings, -190, "Mindestabstand zum Einstellpreis",
    function() return string.format("%d %%", math.floor(S().minGap * 100 + 0.5)) end,
    function() set("minGap", math.max(0.05, S().minGap - 0.05)) end,
    function() set("minGap", math.min(0.4, S().minGap + 0.05)) end))
  -- Watched recipes (Data_RecipeWatch.lua): own category on top of the watch list.
  table.insert(updates, toggle(settings, -216, "Rezepte beobachten",
    function() return S().recipeWatch end, function() set("recipeWatch", not S().recipeWatch) end))
  table.insert(updates, stepper(settings, -242, "Rezepte kaufen bis (vom Marktwert gestern)",
    function() return string.format("%d %%", math.floor(S().recipeMax * 100 + 0.5)) end,
    function() set("recipeMax", math.max(0.5, S().recipeMax - 0.05)) end,
    function() set("recipeMax", math.min(2, S().recipeMax + 0.05)) end))
  local function stepMaxPrice(dir)
    local current, index = S().maxPrice, 1
    for i, step in ipairs(MAX_PRICE_STEPS) do
      if current >= step then index = i end
    end
    index = math.max(1, math.min(#MAX_PRICE_STEPS, index + dir))
    set("maxPrice", MAX_PRICE_STEPS[index])
  end
  table.insert(updates, stepper(settings, -268, "Maximalpreis pro Item",
    function() return S().maxPrice == 0 and "Kein Limit" or money(S().maxPrice) end,
    function() stepMaxPrice(-1) end, function() stepMaxPrice(1) end))
  -- Falling items (Deals.Falling): left out from this fall on, "aus" keeps them.
  -- strict -> lenient: only rising, from -1 %, ... -30 %, off ("−" makes it stricter)
  local FALL_STEPS = { -1, 0.01, 0.03, 0.05, 0.10, 0.15, 0.20, 0.30, 0 }
  local function stepFall(dir)
    local cur, idx = S().fallLimit or 0, #FALL_STEPS
    for i, v in ipairs(FALL_STEPS) do if math.abs(v - cur) < 1e-9 then idx = i end end
    set("fallLimit", FALL_STEPS[math.max(1, math.min(#FALL_STEPS, idx + dir))])
  end
  table.insert(updates, stepper(settings, -294, "Fallende Items auslassen ab",
    function()
      local v = S().fallLimit or 0
      if v < 0 then return "nur steigende" end
      return v == 0 and "aus" or string.format("−%d %%", math.floor(v * 100 + 0.5))
    end,
    function() stepFall(-1) end, function() stepFall(1) end))
  local reset = Style.Button(settings, "Standard", 80, 18, function()
    ns.db.settings.sniper = nil
  end)
  reset:SetPoint("BOTTOMRIGHT", -8, 8)
  local hint = Style.Text(settings, 11)
  hint:SetPoint("BOTTOMLEFT", 10, 11)
  hint:SetTextColor(unpack(Style.C.muted))
  hint:SetText("Gilt ab der nächsten Sniper-Runde")

  -- State and session ----------------------------------------------------------------
  local state = card(page, "Status")
  state:SetPoint("TOPLEFT", settings, "BOTTOMLEFT", 0, -GAP)
  state:SetSize(leftW, 150)
  local lines = {}
  for i = 1, 5 do
    local l = Style.Text(state, 12)
    l:SetPoint("TOPLEFT", 10, -30 - (i - 1) * ROW)
    l:SetPoint("RIGHT", -10, 0)
    l:SetJustifyH("LEFT")
    lines[i] = l
  end

  -- Latest hits and buys ------------------------------------------------------------
  local logCard = card(page, "Letzte Treffer und Käufe")
  logCard:SetPoint("TOPLEFT", state, "BOTTOMLEFT", 0, -GAP)
  logCard:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", PAD, PAD)
  logCard:SetWidth(leftW)
  local log = itemList(logCard, { 0, 70, 90 })
  log.scroll:SetPoint("TOPLEFT", 1, -28)
  log.scroll:SetPoint("BOTTOMRIGHT", -10, 4)

  -- Watch list ---------------------------------------------------------------------
  local watchCard = card(page, "Beobachtungsliste")
  watchCard:SetPoint("TOPLEFT", settings, "TOPRIGHT", GAP, 0)
  watchCard:SetPoint("BOTTOMLEFT", logCard, "BOTTOMRIGHT", GAP, 0)
  watchCard:SetWidth(rightW)
  local watchInfo = Style.Text(watchCard, 11)
  watchInfo:SetPoint("TOPRIGHT", -10, -9)
  watchInfo:SetTextColor(unpack(Style.C.muted))
  -- Column heads at the same right-aligned offsets as the list's cells (itemList).
  local WATCH_COLS = { 0, 95, 80, 70, 95 }
  local WATCH_HEADS = { "", "Marktwert gestern", "Vorauswahl", "Nachfrage", "Trend" }
  do
    local x = 0
    for c = #WATCH_COLS, 2, -1 do
      local h = Style.Text(watchCard, 11)
      h:SetPoint("TOPRIGHT", watchCard, "TOPRIGHT", -x - 6 - 11, -28) -- 11: room of the scroll bar
      h:SetWidth(WATCH_COLS[c] - 8)
      h:SetJustifyH("RIGHT")
      h:SetTextColor(unpack(Style.C.muted))
      h:SetText(WATCH_HEADS[c])
      x = x + WATCH_COLS[c]
    end
  end
  local watch = itemList(watchCard, WATCH_COLS)
  watch.scroll:SetPoint("TOPLEFT", 1, -46)
  watch.scroll:SetPoint("BOTTOMRIGHT", -10, 4)

  local obj = {}
  function obj:Refresh()
    for _, u in ipairs(updates) do u() end
    local s = ns.db.sniper and ns.db.sniper.session
    local running = Sniper and Sniper.IsRunning and Sniper.IsRunning()
    lines[1]:SetText(running and (GREEN .. "Läuft|r am Auktionshaus") or (MUTED .. "Aus|r – am Auktionshaus rechts im Reiter „Sniper“ starten"))
    if s then
      lines[2]:SetText(string.format("Sitzung seit %s: %d Runden", date("%d.%m. %H:%M", s.start or time()), s.rounds or 0))
      lines[3]:SetText(string.format("Treffer %d  ·  gekauft %d Stück für %s", s.hits or 0, s.bought or 0, money(s.spent)))
      lines[4]:SetText("Erwarteter Gewinn der Käufe: " .. GREEN .. money(s.expected) .. "|r")
      lines[5]:SetText(string.format("Weg, bevor du kaufen konntest: %d", s.gone or 0))
    else
      lines[2]:SetText(MUTED .. "Noch keine Sitzung|r")
      for i = 3, 5 do lines[i]:SetText("") end
    end

    local set = Deals.Settings()
    local candidates = Sniper and Sniper.WatchCandidates and Sniper.WatchCandidates() or {}
    local entries = {}
    for _, c in ipairs(candidates) do
      local limit = c.ref * set.maxShare
      if set.maxPrice > 0 then limit = math.min(limit, set.maxPrice) end
      table.insert(entries, { ns.ItemName(c.itemID) or ("#" .. c.itemID), money(c.ref),
        money(limit), demandLabel(c.demand), trendText(c.itemID), itemID = c.itemID })
    end
    local recipes = Sniper and Sniper.RecipeItems and Sniper.RecipeItems() or {}
    local known = {}
    for _, e in ipairs(entries) do known[e.itemID] = true end
    for _, itemID in ipairs(recipes) do
      if not known[itemID] then
        local r = ns.RecipeWatch[itemID]
        local limit = Sniper.RecipeLimit(itemID)
        local usual = Sniper.RecipeUsual(itemID)
        table.insert(entries, { ORANGE .. "Rezept|r  " .. (ns.ItemName(itemID) or ("#" .. itemID)),
          usual and money(usual) or (MUTED .. "–|r"), limit and money(limit) or (MUTED .. "jedes|r"),
          r.skill and ("Skill " .. r.skill) or "", trendText(itemID), itemID = itemID })
      end
    end
    watch:Set(entries, rightW - 12)
    watchInfo:SetText(string.format("%d Items + %d Rezepte  ·  gesucht wird, was du dir leisten kannst",
      #candidates, #recipes))

    local events = {}
    local logList = ns.db.sniper and ns.db.sniper.log or {}
    for i = #logList, math.max(1, #logList - 40), -1 do
      local e = logList[i]
      if e.k == "hit" or e.k == "buy" then
        table.insert(events, { (e.k == "buy" and (GREEN .. "Kauf|r  ") or (ORANGE .. "Treffer|r  "))
          .. (ns.ItemName(e.i) or ("#" .. tostring(e.i))), date("%H:%M", e.t or 0),
          e.c and money(e.c) or (e.p and money(e.p) or ""), itemID = e.i })
      end
    end
    log:Set(events, leftW - 12)
  end
  page:SetScript("OnShow", function() obj:Refresh() end)
  -- Settings change often while the page is open: refresh after each click.
  page:HookScript("OnMouseUp", function() obj:Refresh() end)
  for _, child in ipairs({ settings:GetChildren() }) do
    if child.HookScript then child:HookScript("OnClick", function() obj:Refresh() end) end
  end
  obj:Refresh()
  return obj
end

local function register()
  if ns.MainUI and ns.MainUI.RegisterPage then
    ns.MainUI.RegisterPage("sniper", "Sniper", build, { after = "market" })
  end
end
register()
