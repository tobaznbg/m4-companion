-- PlanWindow: "Planer" - the skill path of a crafting profession up to 300 in the profession
-- window's look: the third side tab of the profession window of this addon (Berufsübersicht /
-- Alle Produkte / Planer, Crafting.lua), for the profession chosen there - also one no household
-- character has (from 1, skill data). The tab "Planer" under Blizzard's profession window opens
-- it for the open profession. Not for gathering professions.
--   left   "Gesamter Plan" on top, then the steps in sections by rank (Lehrling … Fachmann),
--          the trainer visits (learn the next rank) as entries of their own
--   right  a step: how its recipe is learned, its reagents (need / household stock / missing /
--          cost) and its money; a trainer visit: rank, character level, trainer with map
--          button; "Gesamter Plan": the balance of the whole path and where it ends
-- Buttons put a step, its rank section or the whole plan on the shopping list (ShoppingList.lua).
--
-- The path is the skill planner's (Costs.Plan + Planner.Steps), computed like MainUI's
-- "Skill-Planer" page (same AH setting). It is cached and only computed again when the filter
-- changes, the window opens or new prices arrive (AuctionScan.OnDone), not on a click in the list.
-- Filter (ns.db.ui): planStart "rank" (from the own skill, default) / "one" (from 1, for
-- friends and twinks), planWay "dynamic" (default) / "standard".
local ADDON, ns = ...

local Plan = {}
ns.PlanWindow = Plan

local MAX_ROWS = 12
local RIGHT_EDGE = 24
local GREEN, RED, MUTED, ORANGE = "|cff5fd38d", "|cffff6b6b", "|cff999999", "|cffffb547"
local DONE = { 0.5, 0.5, 0.5 } -- steps below the own skill (plan from 1)
local PLAN_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local RANK_ICON = "Interface\\Icons\\INV_Misc_Book_11"
local ALL_ICON = "Interface\\Icons\\INV_Scroll_03"
-- gathering professions (and fishing) have no recipes to level with
local NO_PLANNER = { [393] = true, [186] = true, [182] = true, [356] = true }
local SECTIONS = {
  { rank = "Lehrling", title = "Lehrling (1–75)" },
  { rank = "Geselle", title = "Geselle (75–150)" },
  { rank = "Experte", title = "Experte (150–225)" },
  { rank = "Fachmann", title = "Fachmann (225–300)" },
}
local WAY_LABEL = { trainer = "Lehrer", vendor = "Händler", limited = "Händler (begrenzt)", rep = "Ruf-Händler",
  favor = "Händlergunst", ah = "Muster im AH (Gelegenheit)", cond = "Händler (Bedingung)", unknown = "Händler" }
local START = { { key = "rank", label = "Ab meinem Skill" }, { key = "one", label = "Komplett ab 1" } }
local WAYS = { { key = "dynamic", label = "Dynamisch" }, { key = "standard", label = "Standard" } }

local window, split, pid
local cache -- the computed plan of pid with the current filter (see compute)
local dirty = true

local function maxSkill() return ns.Planner and ns.Planner.MAX_SKILL or 300 end
local function money(c) return ns.FormatMoney(math.floor((c or 0) + 0.5), true) end
-- A net cost: spent money plain, a gain green with "+".
local function net(c)
  c = math.floor((c or 0) + 0.5)
  if c < 0 then return GREEN .. "+" .. money(-c) .. " Gewinn|r" end
  return money(c)
end
local function itemIcon(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end
local function qualityName(id, name)
  local q = id and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  if q == nil and id and GetItemInfo then q = select(3, GetItemInfo(id)) end
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  return c and c.hex and (c.hex .. name .. "|r") or name
end
local function ui()
  ns.db.ui = ns.db.ui or {}
  return ns.db.ui
end
local function startKey() return ui().planStart == "one" and "one" or "rank" end
local function wayKey() return ui().planWay == "standard" and "standard" or "dynamic" end
-- Sales count at the merchant's price only (decided 20 Nov 2026: no auction income planned in)
local function ahCap() return 0 end

-- Section (1..4) of a skill level and of a rank name.
local function sectionOf(skill)
  if skill < 75 then return 1 elseif skill < 150 then return 2 elseif skill < 225 then return 3 end
  return 4
end
local function sectionOfRank(name)
  for i, s in ipairs(SECTIONS) do if s.rank == name then return i end end
  return 1
end

-- Shopping-list count of a segment: the items its expected crafts make.
local function segmentItems(seg)
  -- material is bought with the buffer on yellow/green points (Planner.BufferedCrafts)
  local crafts = ns.Planner.BufferedCrafts and ns.Planner.BufferedCrafts(seg) or seg.crafts
  return math.ceil(math.ceil(crafts) * (seg.recipe.qty or 1) - 0.001)
end

-- The plan ----------------------------------------------------------------------------------

-- { pid, why ("nodata"/"noscan"/"max"/"noway"), prof, ctx, srcs, rank, from, way, result,
--   steps, sections = { [1..4] = { segments… } } }
local function compute(professionID)
  local out = { pid = professionID }
  -- whose skill and recipes: the own character's, else the household's best (ns.ProfessionKnower),
  -- so a bank character plans for the crafter
  local knower = ns.ProfessionKnower and ns.ProfessionKnower(professionID)
  out.knower = knower
  local prof, why = ns.Costs.Profession(professionID, knower)
  if not prof then out.why = why or "nodata" return out end
  prof.ctx = ns.Costs.Context()
  out.prof, out.ctx = prof, prof.ctx
  out.srcs = ns.RecipeSources and ns.RecipeSources[professionID]
  out.rank = prof.rank or 0
  local from = startKey() == "one" and 1 or math.max(1, out.rank)
  out.from, out.way = from, wayKey()
  if from >= maxSkill() then out.why = "max" return out end
  local result
  local pin = ui().planPins and ui().planPins[professionID]
  if pin and pin.way == out.way and pin.start == startKey() then
    -- the kept plan: same steps, today's costs (Planner.Replay)
    local candidates = ns.Costs.Candidates(prof, out.way)
    local segments, total, reached = ns.Planner.Replay(candidates, pin.segs, from)
    if #segments > 0 then
      local need, made = ns.Planner.Shopping(segments)
      result = { segments = segments, total = total, reached = reached, need = need, made = made, scarce = {}, pinned = pin }
    end
  end
  result = result or ns.Costs.Plan(prof, from, maxSkill(), ahCap(), out.way)
  out.result = result
  if not result.segments then out.why = "noway" return out end
  -- the own cap counts only when planning from the own skill range (as MainUI does)
  local max = prof.max
  if not (max and from <= max and from >= max - 75) then max = nil end
  out.steps = ns.Planner.Steps(result.segments, from, max)
  return out
end

-- Reagent lines of a need table (Planner.Shopping): { itemID, need, have, missing, unit,
-- scarce, parts } by what is still to buy, then the intermediates made on the way (made = crafts).
local function materialLines(need, made, scarce)
  local list = {}
  for itemID, count in pairs(need or {}) do
    local have, parts = ns.ShoppingList.Holdings(itemID)
    local unit = ns.Costs.BuyMany(itemID, count)
    list[#list + 1] = { itemID = itemID, need = count, have = math.min(have, count), stock = have,
      missing = math.max(0, count - have), unit = unit, scarce = scarce and scarce[itemID], parts = parts }
  end
  table.sort(list, function(a, b)
    local ca, cb = a.missing * (a.unit or 0), b.missing * (b.unit or 0)
    if ca ~= cb then return ca > cb end
    if a.need ~= b.need then return a.need > b.need end
    return a.itemID < b.itemID
  end)
  local made2 = {}
  for itemID, m in pairs(made or {}) do
    local have, parts = ns.ShoppingList.Holdings(itemID)
    made2[#made2 + 1] = { itemID = itemID, need = m.count, have = math.min(have, m.count), stock = have, missing = 0,
      crafts = m.crafts, maker = m.recipe and m.recipe.name, parts = parts }
  end
  table.sort(made2, function(a, b) return a.itemID < b.itemID end)
  for _, l in ipairs(made2) do list[#list + 1] = l end
  return list
end

-- Money of material lines: market value of what is taken from stock, what is still to buy and
-- how many lines have no price.
local function lineSums(lines)
  local have, buy, noPrice = 0, 0, 0
  for _, l in ipairs(lines) do
    if not l.crafts then
      if l.unit then
        have, buy = have + l.have * l.unit, buy + l.missing * l.unit
      elseif l.missing > 0 then
        noPrice = noPrice + 1
      end
    end
  end
  return have, buy, noPrice
end

-- Sums of segments: learning and sales (the planner's expected values).
local function segmentSums(segs)
  local learn, income = 0, 0
  for _, seg in ipairs(segs) do learn, income = learn + (seg.learned or 0), income + (seg.income or 0) end
  return learn, income
end

-- The money of a plan or step: material (what the reagent lines are worth: from stock plus
-- still to buy, so "davon vorhanden" and "noch zu kaufen" add up to it), learning, sales, net.
local function balance(lines, segs)
  local have, buy, noPrice = lineSums(lines)
  local learn, income = segmentSums(segs)
  return { have = have, buy = buy, noPrice = noPrice, material = have + buy, learn = learn, income = income,
    net = have + buy + learn - income }
end

-- The whole plan's reagent lines and balance (cached with the plan; the stock is read again
-- when the plan is computed again).
local function overview(st)
  if not st.overview then
    local r = st.result
    local need, made = ns.Planner.Shopping(r.segments, true) -- with the buffer, for buying
    local lines = materialLines(need, made, r.scarce)
    st.overview = { lines = lines, balance = balance(lines, r.segments) }
  end
  return st.overview
end

-- List entries of the plan ("Gesamter Plan", then the sections with their steps).
local function planEntries(st)
  local out = {}
  st.sections = {}
  if not st.steps then return out end
  out[1] = { key = "all", name = "Gesamter Plan", value = net(overview(st).balance.net), all = true }
  local lists = {}
  local function put(idx, e)
    lists[idx] = lists[idx] or {}
    table.insert(lists[idx], e)
  end
  local maxCap = st.prof.max or 0
  if st.from <= 1 then
    -- the profession itself (Lehrling) comes from the trainer first
    put(1, { key = "rank:Lehrling", name = "Lehrling beim Lehrer lernen", value = MUTED .. "Beginn|r",
      rankStep = { at = 0, name = "Lehrling", cap = 75, level = ns.Planner.RANKS[1].level }, section = 1,
      color = maxCap >= 75 and DONE or nil })
  end
  local cur = sectionOf(st.from)
  for i, step in ipairs(st.steps) do
    if step.rank then
      local idx = sectionOfRank(step.rank.name)
      cur = math.max(cur, idx)
      put(idx, { key = "rank:" .. step.rank.name, name = step.rank.name .. " beim Lehrer lernen",
        value = MUTED .. "bei " .. step.rank.at .. "|r", rankStep = step.rank, section = idx,
        color = maxCap >= step.rank.cap and DONE or nil })
    else
      local seg, c = step.seg, step.seg.recipe
      -- a segment after a trainer visit belongs to the new rank
      local idx = math.max(cur, sectionOf(seg.from))
      cur = idx
      st.sections[idx] = st.sections[idx] or {}
      table.insert(st.sections[idx], seg)
      put(idx, { key = "seg:" .. i, name = c.name or "?", itemID = c.out, seg = seg, section = idx,
        value = MUTED .. seg.from .. "–" .. seg.to .. "|r  ×" .. math.ceil(seg.crafts),
        locked = not c.learned, color = seg.to <= st.rank and DONE or nil })
    end
  end
  for idx = 1, #SECTIONS do
    if lists[idx] then
      out[#out + 1] = { key = "h:" .. idx, header = SECTIONS[idx].title }
      for _, e in ipairs(lists[idx]) do out[#out + 1] = e end
    end
  end
  return out
end

-- Shopping list ------------------------------------------------------------------------------

-- The pattern a step buys (vendor or auction house, not a trainer), for the shopping list.
local function patternOf(c)
  local how = c.how
  if c.learned or not how or how.way == "trainer" or how.way == "learned" then return nil end
  local o = how.option or {}
  local srcs = ns.RecipeSources and ns.RecipeSources[pid]
  local entry = srcs and srcs.recipes and srcs.recipes[c.id]
  local npc = o.npc and { name = o.npc[1], zone = o.npc[2], x = o.npc[3], y = o.npc[4] } or nil
  return { rid = c.id, pid = pid, item = o.item or (entry and entry.item), name = c.name, way = how.way,
    price = c.learnCost, npc = npc }
end

-- Keeps the whole current plan of the profession (the steps it goes), so buying for it does not
-- change it: stock valued at its sale price would otherwise make the path shift.
local function pinPlan()
  local r = cache and cache.result
  if not (pid and r and r.segments) or r.pinned then return end
  local segs = {}
  for _, seg in ipairs(r.segments) do segs[#segs + 1] = { id = seg.recipe.id, from = seg.from, to = seg.to } end
  ui().planPins = ui().planPins or {}
  ui().planPins[pid] = { way = cache.way, start = startKey(), t = time(), segs = segs }
  dirty = true
end

local function toShoppingList(segs, select)
  pinPlan()
  if C_Timer and Plan.Refresh then C_Timer.After(0, function() ns.Safe(Plan.Refresh) end) end
  local added, skipped, first, patterns = 0, 0, nil, 0
  for _, seg in ipairs(segs or {}) do
    local c = seg.recipe
    -- the pattern to buy first (vendor / auction house), then the step's material
    local p = patternOf(c)
    if p and ns.ShoppingList.AddPattern and ns.ShoppingList.AddPattern(p) then patterns = patterns + 1 end
    if c.out and ns.ShoppingList.Add(c.id, segmentItems(seg), true) then -- replaces an earlier count
      added = added + 1
      first = first or c.id
    else
      skipped = skipped + 1
    end
  end
  if added > 0 then
    print(string.format("|cff33ccffm4:|r %d %s auf die Einkaufsliste gelegt%s%s.", added, added == 1 and "Rezept" or "Rezepte",
      patterns > 0 and string.format(", dazu %d %s", patterns, patterns == 1 and "Muster" or "Muster") or "",
      skipped > 0 and string.format(" (%d ohne Produkt übersprungen)", skipped) or ""))
    ns.ShoppingList.Show(select and first or nil)
  else
    print("|cff33ccffm4:|r Diese Rezepte stellen keine Items her – nichts auf die Einkaufsliste gelegt.")
  end
end

-- The card ------------------------------------------------------------------------------------

local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end
local function searchAH(itemID)
  if not ahOpen() then return end
  if AuctionHouseFrameDisplayMode then AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
  C_Timer.After(0.1, function() if ns.Deals and ns.Deals.Search then ns.Safe(ns.Deals.Search, itemID) end end)
end

local function button(parent, text, width, onClick)
  local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
  if not ok or not b then b = CreateFrame("Button", nil, parent) end
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function mapButton(c)
  local b = CreateFrame("Button", nil, c)
  b:SetSize(16, 16)
  b:SetNormalTexture("Interface\\Icons\\INV_Misc_Map_01")
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Auf der Karte anzeigen")
    local loc = rawget(self, "loc")
    if loc then GameTooltip:AddLine(string.format("%s, %s %.1f / %.1f", loc.name or "", loc.zone, loc.x, loc.y), 1, 1, 1) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self) ns.Safe(ns.ShowOnMap, rawget(self, "loc")) end)
  b:Hide()
  return b
end

-- Columns from the right edge (right end of each), as in the shopping list.
local COST_W = 86
local COLS = { { "Brauche", COST_W + 80 }, { "Habe", COST_W + 44 }, { "Fehlt", COST_W + 12 } }
local SUM_LABELS = 8
local INFO_LINES = 9

local function buildCard(c)
  local NW = ns.NativeWindow
  local v = NW.CardHead(c)
  v.card = c
  -- an info block under the head: "Erlernen:" (step), the trainer (visit), where the way ends
  v.InfoHead = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.InfoHead:SetPoint("TOPLEFT", v.Icon, "BOTTOMLEFT", 0, -16)
  v.InfoHead:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
  v.InfoHead:SetJustifyH("LEFT")
  v.InfoHead:SetWordWrap(false)
  v.info, v.maps = {}, {}
  for i = 1, INFO_LINES do
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", i == 1 and v.InfoHead or v.info[i - 1], "BOTTOMLEFT", 0, i == 1 and -5 or -4)
    fs:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE - 20, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    v.info[i] = fs
    local b = mapButton(c)
    b:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE + 2, 0)
    b:SetPoint("TOP", fs, "TOP", 0, 3)
    v.maps[i] = b
  end
  -- the reagent table
  v.Head:SetText("Reagenzien:")
  v.colHeads = {}
  for i, col in ipairs(COLS) do
    local h = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE - col[2], 0)
    h:SetPoint("TOP", v.Head, "TOP", 0, 0)
    h:SetText(col[1])
    v.colHeads[i] = h
  end
  v.costHead = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.costHead:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
  v.costHead:SetPoint("TOP", v.Head, "TOP", 0, 0)
  v.costHead:SetText("Kosten")
  v.rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, c)
    row:SetHeight(18)
    row:SetPoint("TOPLEFT", v.Head, "BOTTOMLEFT", -2, -4 - (i - 1) * 18)
    row:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE + 4, 0)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(16, 16)
    row.Icon:SetPoint("LEFT", 2, 0)
    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 5, 0)
    row.Name:SetPoint("RIGHT", row, "RIGHT", -(COLS[1][2] + 4 + 46), 0) -- ends before "Brauche"
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row.cells = {}
    for j, col in ipairs(COLS) do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("RIGHT", row, "RIGHT", -(col[2] + 4), 0)
      fs:SetJustifyH("RIGHT")
      row.cells[j] = fs
    end
    row.Cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Cost:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.Cost:SetJustifyH("RIGHT")
    row:SetScript("OnEnter", function(self)
      local l = rawget(self, "line")
      if not l then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(l.itemID)
      GameTooltip:AddLine(" ")
      for _, p in ipairs(l.parts or {}) do GameTooltip:AddDoubleLine("bei " .. p[1], tostring(p[2]), 1, 1, 1, 1, 1, 1) end
      if l.crafts then
        GameTooltip:AddLine(string.format("%d× selbst herstellen (%s), Material in den Zeilen darüber", l.crafts, l.maker or "?"), 0.37, 0.83, 0.55)
      end
      if l.scarce then GameTooltip:AddLine("Im AH knapp: mehr gebraucht als angeboten", 1, 0.42, 0.42) end
      if l.missing > 0 and ahOpen() then GameTooltip:AddLine("Klick: im AH suchen", 0.31, 0.76, 0.63) end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
      local l = rawget(self, "line")
      if not l then return end
      if ns.NativeWindow.AltClick(l.itemID, self) then return end
      searchAH(l.itemID)
    end)
    row:Hide()
    v.rows[i] = row
  end
  v.more = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  -- the sums: gold labels, values at the right edge, a line before the last one shown
  v.sums = {}
  for i = 1, SUM_LABELS do
    local l = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local val = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
    val:SetPoint("TOP", l, "TOP", 0, 0)
    val:SetJustifyH("RIGHT")
    v.sums[i] = { label = l, value = val }
  end
  v.Line = c:CreateTexture(nil, "ARTWORK")
  v.Line:SetColorTexture(1, 0.82, 0, 0.25)
  v.Line:SetHeight(1)
  -- buttons at the card's bottom
  v.StepButton = button(c, "Schritt auf die Einkaufsliste", 194, function()
    local seg = rawget(v, "seg")
    if seg then toShoppingList({ seg }, true) end
  end)
  v.StepButton:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 18, 14)
  v.SectionButton = button(c, "Abschnitt auf die Einkaufsliste", 194, function()
    local idx = rawget(v, "section")
    if idx and cache and cache.sections then toShoppingList(cache.sections[idx], false) end
  end)
  v.SectionButton:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -18, 14)
  v.PlanButton = button(c, "Ganzen Plan auf die Einkaufsliste", 230, function()
    if cache and cache.result and cache.result.segments then toShoppingList(cache.result.segments, false) end
  end)
  v.PlanButton:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 18, 14)
  -- the kept plan (put on the shopping list) stays until this is clicked
  v.ReplanButton = button(c, "Neu planen", 120, function()
    if pid and ui().planPins then ui().planPins[pid] = nil end
    dirty = true
    Plan.Refresh() -- refresh is defined further down
  end)
  v.ReplanButton:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -18, 14)
  return v
end

local function hideAll(v)
  for _, part in ipairs({ v.Icon, v.Ring, v.Name, v.Sub, v.Head, v.InfoHead, v.costHead, v.more, v.Line,
    v.StepButton, v.SectionButton, v.PlanButton, v.ReplanButton }) do part:Hide() end
  for _, h in ipairs(v.colHeads) do h:Hide() end
  for i, fs in ipairs(v.info) do fs:Hide(); v.maps[i]:Hide(); v.maps[i].loc = nil end
  for _, row in ipairs(v.rows) do row:Hide(); row.line = nil end
  for _, s in ipairs(v.sums) do s.label:Hide(); s.value:Hide() end
  v.seg, v.section = nil, nil
end

-- The head: icon, name, the small line.
local function setHead(v, icon, itemID, name, sub)
  v.Icon:SetTexture(icon)
  v.itemID = itemID
  v.Name:SetText(name)
  v.Sub:SetText(sub or "")
  for _, part in ipairs({ v.Icon, v.Ring, v.Name, v.Sub }) do part:Show() end
end

-- The info block: a gold title and lines { text, loc }; returns the last shown region.
local function setInfo(v, title, lines)
  if not title or not lines or #lines == 0 then return v.Icon, -20 end
  v.InfoHead:SetText(title)
  v.InfoHead:Show()
  local last = v.InfoHead
  for i, fs in ipairs(v.info) do
    local line = lines[i]
    if line then
      fs:SetText(line.text)
      fs:Show()
      last = fs
      local b = v.maps[i]
      b.loc = line.loc
      b:SetShown(line.loc ~= nil)
    end
  end
  return last, -16
end

-- The reagent table under `anchor`, at most `max` rows; returns the last shown region.
local function setTable(v, anchor, gap, lines, max)
  v.Head:ClearAllPoints()
  v.Head:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap)
  v.Head:Show()
  v.costHead:Show()
  for _, h in ipairs(v.colHeads) do h:Show() end
  local last = v.Head
  for i, l in ipairs(lines) do
    local row = v.rows[i]
    if not row or i > max then break end
    row.line = l
    row.Icon:SetTexture(itemIcon(l.itemID))
    row.Name:SetText((ns.ItemName(l.itemID) or ("#" .. l.itemID)) .. (l.crafts and (MUTED .. "  herst.|r") or ""))
    row.cells[1]:SetText(tostring(l.need))
    row.cells[2]:SetText((l.have >= l.need and GREEN or "") .. l.have .. (l.have >= l.need and "|r" or ""))
    if l.crafts then
      row.cells[3]:SetText(MUTED .. "–|r")
      row.Cost:SetText(MUTED .. l.crafts .. "× herstellen|r")
    elseif l.missing <= 0 then
      row.cells[3]:SetText(GREEN .. "–|r")
      row.Cost:SetText(MUTED .. "–|r")
    else
      row.cells[3]:SetText(RED .. l.missing .. "|r")
      row.Cost:SetText(l.unit and (money(l.missing * l.unit) .. (l.scarce and (RED .. " knapp|r") or ""))
        or (RED .. "kein Preis|r"))
    end
    row:Show()
    last = row
  end
  local hidden = #lines - math.min(#lines, max, #v.rows)
  v.more:ClearAllPoints()
  v.more:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 2, -4)
  v.more:SetText(hidden > 0 and string.format("… und %d weitere", hidden) or "")
  v.more:SetShown(hidden > 0)
  if #lines == 0 then
    v.more:SetText(MUTED .. "keine Reagenzien|r")
    v.more:Show()
    return v.more
  end
  return hidden > 0 and v.more or last
end

-- The sums { { label, value }… } under `anchor`, a line before the last one.
local function setSums(v, anchor, list)
  for i, s in ipairs(v.sums) do
    local item = list[i]
    if item then
      s.label:SetText(item[1])
      s.value:SetText(item[2])
      s.label:ClearAllPoints()
      local gap = (i == #list and #list > 1) and 7 or 0
      s.label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -14 - (i - 1) * 14 - gap)
      s.label:Show()
      s.value:Show()
    end
  end
  if #list > 1 then
    v.Line:ClearAllPoints()
    v.Line:SetPoint("BOTTOMLEFT", v.sums[#list].label, "TOPLEFT", 0, 3)
    v.Line:SetPoint("RIGHT", v.card, "RIGHT", -RIGHT_EDGE + 2, 0)
    v.Line:Show()
  end
end

-- "Lehrer (Experte): Name, Zone 41,4 / 42,6" with its map place.
local function trainerLine(t, rankName)
  if not t then return { text = "Lehrer (" .. rankName .. "): " .. MUTED .. "unbekannt|r" } end
  local coords = t.x and t.y and (" " .. (string.format("%.1f / %.1f", t.x, t.y):gsub("%.", ","))) or ""
  return { text = string.format("Lehrer (%s): %s, %s%s", rankName, t.npc or "?", t.zone or "?", coords),
    loc = t.x and { name = t.npc, zone = t.zone, x = t.x, y = t.y } or nil }
end

-- How the plan learns a step's recipe, then every way the sources know.
local function learnLines(st, c)
  local how = c.how or {}
  local lines = {}
  local o = how.option or {}
  local what = WAY_LABEL[how.way] or "Muster"
  if how.way == "favor" then
    what = what .. " " .. tostring(o.favor or 0)
  elseif (c.learnCost or 0) > 0 then
    what = what .. " · " .. money(c.learnCost)
  end
  lines[1] = { text = ORANGE .. "Im Plan: " .. what .. "|r" }
  local src = ns.Products and ns.Products.SourceLines and ns.Products.SourceLines(st.pid, c.id)
  if src then
    for _, l in ipairs(src) do lines[#lines + 1] = l end
  elseif how.way == "trainer" then
    local rank = how.rank or ns.Planner.RankFor(c.learnAt or 0).name
    if c.artisan then rank = "Fachmann" end
    lines[#lines + 1] = trainerLine(ns.Planner.Trainer(st.srcs, rank, st.ctx and st.ctx.faction), rank)
  end
  return lines
end

-- One line per recipe where the way ends: what would give the next points (a vendor with its
-- map place first, else an auction offer, a quest or a drop).
local function missingLine(m)
  local head = string.format("%s (ab %d): ", m.name or "?", m.learnAt or 0)
  local ah
  for _, o in ipairs(m.options or {}) do
    if o.npc then
      return { text = head .. (WAY_LABEL[o.way] or "Händler") .. ": " .. o.npc[1] .. " (" .. (o.npc[2] or "?") .. ")"
        .. ((o.cost or 0) > 0 and (" – " .. money(o.cost)) or "") .. (o.why and (MUTED .. " – " .. o.why .. "|r") or ""),
        loc = o.npc[3] and { name = o.npc[1], zone = o.npc[2], x = o.npc[3], y = o.npc[4] } or nil }
    end
    if o.way == "ah" and not ah then ah = "im AH für " .. money(o.cost) end
  end
  return { text = head .. (ah or (m.quest and ("Quest „" .. m.quest .. "“")) or (m.drop and "nur Drop") or "keine Quelle bekannt") }
end

local function showOverview(v, st)
  local r = st.result
  local profName = st.prof.name or "Beruf"
  local data = ns.RecipeData and ns.RecipeData[st.pid]
  local nSteps = #r.segments
  setHead(v, data and data.icon or ALL_ICON, nil, "Gesamter Plan",
    string.format("%s · Skill %d bis %d · %s · %d %s", profName, st.from, r.reached,
      st.way == "dynamic" and "dynamischer Weg" or "Standard-Weg", nSteps, nSteps == 1 and "Schritt" or "Schritte")
    .. (r.pinned and (" · " .. GREEN .. "festgehalten " .. date("%d.%m. %H:%M", r.pinned.t) .. "|r") or ""))
  local info
  if r.reached < maxSkill() then
    info = {}
    for i, m in ipairs(r.missing or {}) do
      if i > 6 then break end
      info[#info + 1] = missingLine(m)
    end
    if #info == 0 then info[1] = { text = MUTED .. "Keine Rezepte bekannt, die hier noch Punkte geben.|r" } end
  end
  local anchor, gap = setInfo(v, info and (ORANGE .. string.format("Der Weg endet bei Skill %d – es fehlen Rezepte:", r.reached) .. "|r"), info)
  local ov = overview(st)
  local b = ov.balance
  v.Head:SetText("Material gesamt:")
  local last = setTable(v, anchor, gap, ov.lines, math.max(4, MAX_ROWS - (info and #info + 1 or 0)))
  setSums(v, last, {
    { "Material gesamt", money(b.material) },
    { "davon vorhanden (Haushalt)", b.have > 0 and (GREEN .. money(b.have) .. "|r") or money(0) },
    { "Noch zu kaufen", (b.buy > 0 and money(b.buy) or (GREEN .. "nichts – alles da|r"))
      .. (b.noPrice > 0 and (RED .. " + " .. b.noPrice .. " ohne Preis|r") or "") },
    { "Lernkosten", money(b.learn) },
    { "Rückfluss (Verkauf)", GREEN .. money(b.income) .. "|r" },
    { "Erreichter Skill", (r.reached < maxSkill() and ORANGE or GREEN) .. r.reached .. " / " .. maxSkill() .. "|r" },
    { "Kosten netto", net(b.net) },
  })
  v.PlanButton:Show()
  v.ReplanButton:SetShown(r.pinned ~= nil)
end

local function showRank(v, st, rank, section)
  local level = rank.level or 0
  local ctx = st.ctx or {}
  local t = ns.Planner.Trainer(st.srcs, rank.name, ctx.faction)
  setHead(v, RANK_ICON, nil, rank.name .. " beim Lehrer lernen",
    rank.at > 0 and string.format("bei Skill %d · danach bis %d", rank.at, rank.cap)
      or string.format("den Beruf lernen · bis %d", rank.cap))
  local lines = {}
  local levelText = "Charakterstufe: ab " .. level
  if ctx.level and ctx.level < level then
    levelText = levelText .. RED .. string.format(" – du bist Stufe %d", ctx.level) .. "|r"
  end
  lines[#lines + 1] = { text = levelText }
  if t and t.skill and t.skill > 0 then lines[#lines + 1] = { text = "Ab Skill: " .. t.skill } end
  lines[#lines + 1] = trainerLine(t, rank.name)
  if st.prof.max and st.prof.max >= rank.cap then lines[#lines + 1] = { text = GREEN .. "Schon gelernt.|r" } end
  setInfo(v, "Rang:", lines)
  v.section = section
  v.SectionButton:SetShown(cache and cache.sections and cache.sections[section] ~= nil)
end

local function showStep(v, st, seg, section)
  local c = seg.recipe
  local crafts = math.ceil(seg.crafts)
  local icon = itemIcon(c.out) or (GetSpellTexture and GetSpellTexture(c.id)) or PLAN_ICON
  local sub = string.format("Skill %d bis %d · ca. %d× herstellen", seg.from, seg.to, crafts)
  local buffered = math.ceil(ns.Planner.BufferedCrafts(seg))
  if buffered > crafts then sub = sub .. string.format(" · Material für %d×", buffered) end
  if (c.qty or 1) > 1 then sub = sub .. string.format(" (ergibt ca. %d)", segmentItems(seg)) end
  setHead(v, icon, c.out, qualityName(c.out, c.name or "?"), sub)
  local anchor, gap = v.Icon, -20
  local info = not c.learned and learnLines(st, c) or nil
  if info then anchor, gap = setInfo(v, "Erlernen:", info) end
  local need, made = ns.Planner.Shopping({ seg }, true) -- with the buffer, for buying
  local lines = materialLines(need, made, st.result.scarce)
  v.Head:SetText("Reagenzien:")
  local last = setTable(v, anchor, gap, lines, math.max(4, MAX_ROWS - (info and #info + 1 or 0)))
  local b = balance(lines, { seg })
  setSums(v, last, {
    { "Material", money(b.material) },
    { "davon noch zu kaufen", (b.buy > 0 and money(b.buy) or (GREEN .. "nichts – alles da|r"))
      .. (b.noPrice > 0 and (RED .. " + " .. b.noPrice .. " ohne Preis|r") or "") },
    { "Lernkosten", money(b.learn) },
    { "Rückfluss (Verkauf)", GREEN .. money(b.income) .. "|r" },
    { "Kosten netto", net(b.net) },
  })
  v.seg, v.section = seg, section
  v.StepButton:SetShown(c.out ~= nil)
  v.SectionButton:Show()
end

local function show(entry, c)
  if not rawget(c, "m4Plan") then c.m4Plan = buildCard(c) end
  local v = c.m4Plan
  hideAll(v)
  local st = cache
  if not (entry and not entry.header and st and st.steps) then return end
  if entry.all then
    showOverview(v, st)
  elseif entry.rankStep then
    showRank(v, st, entry.rankStep, entry.section)
  elseif entry.seg then
    showStep(v, st, entry.seg, entry.section)
  end
end

-- Window ----------------------------------------------------------------------------------------

local MESSAGES = {
  nodata = "Für diesen Beruf fehlen noch Skilldaten.",
  noscan = "Berufsfenster einmal öffnen,\ndann plant m4-companion den Weg.",
  max = "Skill 300 erreicht – nichts mehr zu planen.\nFilter „Komplett ab 1“ zeigt den ganzen Weg.",
  noway = "Kein Weg gefunden – für manche Zutaten fehlen Preise.\nIm AH einmal scannen.",
}

local function refresh()
  if not (window and split and pid) then return end
  local pin = ui().planPins and ui().planPins[pid]
  local key = table.concat({ pid, startKey(), wayKey(), ahCap(), pin and pin.t or 0 }, ":")
  if dirty or not cache or cache.key ~= key then
    cache = compute(pid)
    cache.key = key
    dirty = false
  end
  local data = ns.RecipeData and ns.RecipeData[pid]
  local name = (cache.prof and cache.prof.name) or (data and data.name)
  local f = window.frame
  local who = cache.knower and cache.knower ~= ns.CharKey()
    and string.format(" (für %s %d)", cache.knower:match("^[^-]+") or cache.knower, cache.rank or 0) or ""
  if f.SetTitle then pcall(f.SetTitle, f, "Planer" .. (name and (" – " .. name) or "") .. who) end
  if data and data.icon and f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, data.icon) end
  split.SetEntries(planEntries(cache))
  if split.empty then split.empty:SetText(cache.steps and "" or (MESSAGES[cache.why] or MESSAGES.nodata)) end
end
Plan.Refresh = refresh

local function setFilter(field, key)
  ui()[field] = key
  refresh()
end

-- The tab in the profession window of this addon (Crafting.lua, createProducts): as wide as the
-- shopping list there (room for the reagent names next to four columns).
function Plan.AddTo(w)
  local NW = ns.NativeWindow
  window = w
  window:AddTab({ key = "plan", title = "Planer", icon = PLAN_ICON, width = 760,
    visible = function() return pid ~= nil and Plan.ForProfession(pid) end, build = function(page)
    split = NW.Split(page, {
      onSelect = show,
      filter = { groups = {
        { title = "Start", options = START, get = startKey, set = function(key) setFilter("planStart", key) end },
        { title = "Weg", options = WAYS, get = wayKey, set = function(key) setFilter("planWay", key) end },
      } },
    })
  end, onShow = function() refresh() end })
end

-- Whether a profession gets the planner (crafting professions; not gathering or fishing).
function Plan.ForProfession(professionID)
  return professionID == nil or not NO_PLANNER[professionID]
end

-- The profession the window shows (Products.Show sets it): the plan follows.
function Plan.SetProfession(professionID)
  if professionID ~= pid then dirty = true end
  pid = professionID
end

-- Whether the planner tab is the one showing.
local function planShown()
  return window ~= nil and window.frame:IsShown() and window.current == "plan"
end
Plan.Shown = planShown

-- Shows the planner for a profession (default: the open one); computes the plan anew.
function Plan.Show(professionID)
  local open = ns.Products and ns.Products.OpenProfessionID and ns.Products.OpenProfessionID()
  dirty = true
  if ns.Products and ns.Products.Show then ns.Products.Show(professionID or open or pid, "plan") end
end

-- The tab under Blizzard's window: closes the planner, unless it shows another profession.
function Plan.Toggle(professionID)
  local open = ns.Products and ns.Products.OpenProfessionID and ns.Products.OpenProfessionID()
  professionID = professionID or open
  if planShown() and (not professionID or professionID == pid) then
    window.frame:Hide()
  else
    Plan.Show(professionID)
  end
end

-- Selects the list entry with that key ("all", "seg:<n>", "rank:<name>") in the open window.
function Plan.Select(key)
  if split and split.Select then split.Select(key) end
end

function Plan.Frame() return window and window.frame end
function Plan.Current() return cache end -- for tests
function Plan.Entries() return cache and planEntries(cache) or {} end -- for tests

-- New live prices: the plan is computed again (the open window right away).
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function()
      dirty = true
      if window and window.frame:IsShown() then ns.Safe(refresh) end
    end)
  end
end)

-- A new profession scan (the skill rose while crafting): plan from the new skill. A kept plan
-- stays kept, its done points fall away (Planner.Replay).
local lastRank
if ns.Recipes and ns.Recipes.OnScanned then
  ns.Recipes.OnScanned(function(scan)
    if not (planShown() and pid and scan.professionID == pid) then return end
    if scan.rank == lastRank then return end
    lastRank = scan.rank
    dirty = true
    ns.Safe(refresh)
  end)
end

-- Bags change (bought, crafted, taken from the bank): the card's stock follows, the plan stays.
local pending = false
ns.On("BAG_UPDATE_DELAYED", function()
  if pending or not (planShown() and split) then return end
  pending = true
  C_Timer.After(0.5, function()
    pending = false
    if cache then cache.overview = nil end
    ns.Safe(split.Rebuild)
  end)
end)
