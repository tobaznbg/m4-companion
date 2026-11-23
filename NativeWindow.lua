-- NativeWindow: a window in Blizzard's own look, built from the profession window's parts, for
-- any addon page that should look native (first user: the ledger, TradeBook.lua).
--
--   local w = ns.NativeWindow.New{ name = "M4Thing", title = "Titel", icon = "Interface\\Icons\\…",
--     width = 760, height = 560 }
--   w:AddTab{ key = "overview", title = "Übersicht", icon = "…", build = function(page, w) … end,
--     onShow = function(page, w) … end }   -- page: a frame filling the content area
--   w:SelectTab(key); w:Show(); w:Toggle(); w.frame
--
-- Building blocks for pages:
--   ns.NativeWindow.Split(page, { entries = { { header = "…" } | { name, icon, … } },
--       onSelect = function(entry, card) … end })  -> split = { list, card, SetEntries(entries) }
--     left Blizzard's recipe list (search box, filter, category and recipe rows), right the recipe
--     card (border and background of the profession window's form)
--     entry fields: value (right in the row), marker ("down": red arrow, "coin": one gold coin),
--     coins (1..3 gold coins left of the name), coinsHot (them deep orange), color ({ r, g, b } of the name), locked (Blizzard's lock icon), itemID
--     (tooltip, Alt+click market data);
--     opts.filter = { options = { { key, label }… }, get(), set(key) }: Blizzard's filter button
--       (several radio groups: opts.filter = { groups = { { title, options, get, set }… } })
--   ns.NativeWindow.CardHead(layer) -> { Icon, Name, Sub, Head, itemID }: the card's head (icon in
--     a ring, name, a small line, "Kennzahlen:"); the icon shows the item tooltip of .itemID
--   ns.NativeWindow.Panel(parent, title)  -> an inset panel with a gold title (overview pages)
--   ns.NativeWindow.Figures(parent, anchor, labels) -> { values = { fontstring… }, SetWidth(w) }
--     gold labels left, values right-aligned; a line before the last row
-- The profession templates live in a load-on-demand part of the UI: New loads it.
local ADDON, ns = ...

local NW = {}
ns.NativeWindow = NW
NW.__index = NW

local function try(objType, parent, template, name)
  local ok, f = pcall(CreateFrame, objType, name, parent, template)
  return ok and f or nil
end

local function loadProfessions()
  if rawget(_G, "ProfessionsFrame") then return end
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if load then pcall(load, "Blizzard_Professions") end
end

function NW.New(opts)
  loadProfessions()
  local self = setmetatable({ tabs = {}, order = {} }, NW)
  local f = try("Frame", UIParent, "PortraitFrameTemplate", opts.name)
    or try("Frame", UIParent, "ButtonFrameTemplate", opts.name) or CreateFrame("Frame", opts.name, UIParent)
  self.frame = f
  f.m4Native = true -- ItemDetail docks at it (Alt+click from inside: NW.AltClick)
  f:SetSize(opts.width or 673, opts.height or 594) -- the profession window's size
  self.baseWidth = opts.width or 673 -- def.width of a tab widens the window while it shows
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:Hide()
  if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
  if f.SetPortraitToAsset then
    pcall(f.SetPortraitToAsset, f, opts.icon)
  else
    local container = rawget(f, "PortraitContainer")
    local portrait = rawget(f, "portrait") or (type(container) == "table" and rawget(container, "portrait"))
    if type(portrait) == "table" and SetPortraitToTexture then pcall(SetPortraitToTexture, portrait, opts.icon) end
  end
  if f.SetTitle then
    pcall(f.SetTitle, f, opts.title or "")
  else
    local container = rawget(f, "TitleContainer")
    local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
    if type(title) == "table" then title:SetText(opts.title or "") end
  end
  local inset = rawget(f, "Inset")
  if type(inset) == "table" then inset:Hide() end
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
  f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)
  if opts.name and UISpecialFrames then tinsert(UISpecialFrames, opts.name) end
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  -- the profession window's page background
  local bg = f:CreateTexture(nil, "BACKGROUND", nil, -3)
  bg:SetPoint("TOPLEFT", 3, -21)
  bg:SetPoint("BOTTOMRIGHT", -3, 3)
  bg:SetAtlas("Profession-Background-Template2")
  self.background = bg
  -- the overview pages' background (Blizzard's "Berufe" overview), shown per tab
  local obg = f:CreateTexture(nil, "BACKGROUND", nil, -2)
  obg:SetPoint("TOPLEFT", 2, -21)
  obg:SetPoint("BOTTOMRIGHT", -2, 2)
  obg:SetAtlas("Profession-Background-Overview")
  obg:Hide()
  self.overviewBackground = obg
  -- the content area the pages fill
  local area = CreateFrame("Frame", nil, f)
  area:SetPoint("TOPLEFT", 8, -60)
  area:SetPoint("BOTTOMRIGHT", -8, 8)
  self.area = area
  return self
end

-- A side tab and its page (built on first selection).
function NW:AddTab(def)
  local f = self.frame
  local i = #self.order + 1
  -- def.hidden: a page without a side tab (a window with one page)
  local t = not def.hidden and (try("CheckButton", f, "LargeSideTabButtonTemplate") or try("Button", f, "LargeSideTabButtonTemplate")
    or try("Frame", f, "LargeSideTabButtonTemplate"))
  if t then
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", f, "TOPRIGHT", -2, -40 - (i - 1) * 60)
    local icon = rawget(t, "Icon")
    if type(icon) == "table" then icon:SetTexture(def.icon) end
    if t.HasScript and t:HasScript("OnClick") then
      t:SetScript("OnClick", function() self:SelectTab(def.key) end)
    else
      t:EnableMouse(true)
      t:SetScript("OnMouseUp", function() self:SelectTab(def.key) end)
    end
    t:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
      GameTooltip:SetText(def.title)
      GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    t:Show()
  end
  self.tabs[def.key] = { def = def, button = t }
  self.order[i] = def.key
  if def.visible then self:UpdateTabs() end
end

-- def.visible = function: the tab shows only while it returns true. UpdateTabs shows and hides
-- those tabs and closes the side tabs up; a hidden current tab falls back to the first one.
local function tabShown(tab) return not tab.def.visible or (tab.def.visible() and true or false) end

function NW:UpdateTabs()
  local n = 0
  for _, key in ipairs(self.order) do
    local tab = self.tabs[key]
    local shown = tabShown(tab)
    n = n + 1
    if tab.button then
      tab.button:ClearAllPoints()
      tab.button:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", -2, -40 - (n - 1) * 60)
      tab.button:SetShown(shown)
    end
    if not shown then n = n - 1 end
  end
  local cur = self.current and self.tabs[self.current]
  if cur and not tabShown(cur) and self.order[1] then self:SelectTab(self.order[1]) end
end

function NW:SelectTab(key)
  local tab = self.tabs[key]
  if not tab or not tabShown(tab) then return end
  for k, other in pairs(self.tabs) do
    if other.page then other.page:SetShown(k == key) end
    local sel = other.button and rawget(other.button, "SelectedTexture")
    if type(sel) == "table" then sel:SetShown(k == key) end
    if other.button and other.button.SetChecked then pcall(other.button.SetChecked, other.button, k == key) end
  end
  if not tab.page then
    tab.page = CreateFrame("Frame", nil, self.area)
    tab.page:SetAllPoints(self.area)
    if tab.def.build then ns.Safe(tab.def.build, tab.page, self) end
  end
  tab.page:Show()
  self.frame:SetWidth(tab.def.width or self.baseWidth)
  self.overviewBackground:SetShown(tab.def.overview and true or false)
  self.background:SetShown(not tab.def.overview)
  self.current = key
  if tab.def.onShow then ns.Safe(tab.def.onShow, tab.page, self) end
end

function NW:Show()
  self.frame:Show()
  self.frame:Raise()
  if not self.current and self.order[1] then self:SelectTab(self.order[1]) end
end

function NW:Toggle()
  if self.frame:IsShown() then self.frame:Hide() else self:Show() end
end

-- Pages ------------------------------------------------------------------------------------

-- Gold labels, values right-aligned (width set with SetWidth), a line before the last row.
function NW.Figures(parent, anchor, labels, opts)
  opts = opts or {}
  local out = { values = {}, labels = {} }
  local step = opts.step or 16
  for i, text in ipairs(labels) do
    local l = parent:CreateFontString(nil, "OVERLAY", opts.labelFont or "GameFontNormalSmall")
    local extra = (i == #labels and opts.line ~= false and #labels > 1) and 8 or 0
    l:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(opts.gap or 10) - (i - 1) * step - extra)
    l:SetText(text)
    local v = parent:CreateFontString(nil, "OVERLAY", opts.valueFont or "GameFontHighlightSmall")
    v:SetPoint("TOPLEFT", l, "TOPLEFT", 0, 0)
    v:SetJustifyH("RIGHT")
    out.labels[i], out.values[i] = l, v
    if extra > 0 then
      local line = parent:CreateTexture(nil, "ARTWORK")
      line:SetColorTexture(1, 0.82, 0, 0.25)
      line:SetHeight(1)
      line:SetPoint("BOTTOMLEFT", l, "TOPLEFT", 0, 4)
      out.line = line
    end
  end
  function out.SetWidth(w)
    for _, v in ipairs(out.values) do v:SetWidth(w) end
    if out.line then out.line:SetWidth(w) end
  end
  return out
end

-- Overview building blocks, measured from Blizzard's "Berufe" overview in this client --------

-- A wide card (664x142, "Profession-overview-Card") at y below the window's top.
function NW.WideCard(window, page, y)
  local c = CreateFrame("Frame", nil, page)
  c:SetSize(664, 142)
  c:SetPoint("TOPLEFT", window.frame, "TOPLEFT", 5, y)
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetAtlas("Profession-overview-Card")
  c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  c.Title:SetPoint("TOPLEFT", 20, -16)
  return c
end

-- A tall card (225x275, generic overview card art) - three of them in a row.
function NW.TallCard(window, page, index, atlas, below)
  local c = CreateFrame("Frame", nil, page)
  c:SetSize(225, 275)
  if index == 1 then
    c:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, 4)
  else
    c:SetPoint("TOPLEFT", below, "TOPRIGHT", -6, 0)
  end
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetAtlas(atlas)
  c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  c.Title:SetPoint("TOP", 0, -20)
  return c
end

-- An icon slot like the overview's profession buttons: 40x40 icon, slot frame, name and a
-- second line (NewSubSpellFont).
function NW.Slot(parent, icon, name, sub)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(40, 40)
  s.Icon = s:CreateTexture(nil, "BORDER")
  s.Icon:SetAllPoints()
  s.Icon:SetTexture(icon)
  local frameTex = s:CreateTexture(nil, "OVERLAY")
  frameTex:SetAllPoints()
  frameTex:SetAtlas("Professions-Slot-Frame")
  s.Name = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  s.Name:SetPoint("TOPLEFT", s, "TOPRIGHT", 8, -4)
  s.Name:SetText(name or "")
  s.Sub = s:CreateFontString(nil, "OVERLAY", rawget(_G, "NewSubSpellFont") and "NewSubSpellFont" or "GameFontHighlightSmall")
  s.Sub:SetPoint("TOPLEFT", s.Name, "BOTTOMLEFT", 0, -2)
  s.Sub:SetText(sub or "")
  return s
end

-- A progress bar like the overview's skill bar (background, fill, frame, text in the middle).
-- fill: an atlas of the skill bar fill ("Skillbar_Fill_Flipbook_<Profession>").
function NW.Bar(parent, width, fill)
  local b = CreateFrame("Frame", nil, parent)
  b:SetSize(width, 18)
  local bg = b:CreateTexture(nil, "ARTWORK", nil, 1)
  bg:SetPoint("TOPLEFT", 0, 0)
  bg:SetSize(width, 23)
  bg:SetAtlas("Profession-ProgressBar-BG")
  b.Fill = b:CreateTexture(nil, "ARTWORK", nil, 2)
  b.Fill:SetPoint("TOPLEFT", 2, -3)
  b.Fill:SetHeight(18)
  b.Fill:SetAtlas(fill or "Skillbar_Fill_Flipbook_Leatherworking")
  local fr = b:CreateTexture(nil, "ARTWORK", nil, 3)
  fr:SetPoint("TOPLEFT", 0, 0)
  fr:SetSize(width, 23)
  fr:SetAtlas("Profession-ProgressBar-frame")
  b.Text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.Text:SetPoint("CENTER", 0, -2)
  function b.Set(share, text)
    share = math.max(0, math.min(1, share or 0))
    b.Fill:SetWidth(math.max(1, (width - 4) * share))
    b.Fill:SetShown(share > 0)
    b.Text:SetText(text or "")
  end
  return b
end

-- An inset panel with a gold title (for pages that are not overviews).
function NW.Panel(parent, title)
  local p = try("Frame", parent, "InsetFrameTemplate") or CreateFrame("Frame", nil, parent)
  local bg = p:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetPoint("TOPLEFT", 3, -3)
  bg:SetPoint("BOTTOMRIGHT", -3, 3)
  bg:SetColorTexture(0, 0, 0, 0.25)
  if title then
    p.Title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.Title:SetPoint("TOPLEFT", 14, -12)
    p.Title:SetText(title)
  end
  return p
end

-- Left Blizzard's recipe list, right the recipe card.
-- Alt+click on an item inside an own window: the market data window docks at that window.
function NW.AltClick(itemID, region)
  local f = region
  while f and not rawget(f, "m4Native") and f.GetParent do f = f:GetParent() end
  return ns.ItemDetail and ns.ItemDetail.AltClick(itemID, f and rawget(f, "m4Native") and f or nil) or false
end

-- 1 to 3 gold coins left of a row's name, slightly overlapping (the profession window's coin,
-- more of them the more a recipe pays: ns.CoinCount). The name moves right by the extra coins,
-- so the stack stays inside the row. Set(n, anchor, hot): the coins sit left of anchor (default
-- the name, e.g. the skill-up arrow when it shows); hot tints them deep orange (high demand on
-- top); n = 0 hides them and puts the name back.
local COIN, COIN_STEP = "Interface\\MoneyFrame\\UI-GoldIcon", 7
function NW.Coins(parent, label)
  local st = { tex = {} }
  for i = 1, 3 do
    local t = parent:CreateTexture(nil, "OVERLAY", nil, 4 - i) -- the front coin on top
    t:SetSize(11, 11)
    t:SetTexture(COIN)
    t:Hide()
    st.tex[i] = t
  end
  local base -- the name's own left anchor, read once
  function st.Set(n, anchor, hot)
    if type(label) == "table" and not base and label.GetPoint then
      local p, rel, rp, x, y = label:GetPoint(1)
      if p == "LEFT" or p == "TOPLEFT" or p == "BOTTOMLEFT" then base = { p, rel, rp, x or 0, y or 0 } end
    end
    if base then label:SetPoint(base[1], base[2], base[3], base[4] + math.max(0, n - 1) * COIN_STEP, base[5]) end
    anchor = anchor or label
    for i, t in ipairs(st.tex) do
      t:ClearAllPoints()
      if type(anchor) == "table" then t:SetPoint("RIGHT", anchor, "LEFT", -4 - (i - 1) * COIN_STEP, 0) end
      if hot then t:SetVertexColor(1, 0.45, 0.05) else t:SetVertexColor(1, 1, 1) end
      t:SetShown(i <= n and type(anchor) == "table")
    end
  end
  return st
end

-- The card's head: icon in a ring, name, a small line under it, "Kennzahlen:" below the icon.
-- The icon shows the tooltip of head.itemID; Alt+click opens its market data window.
function NW.CardHead(layer)
  local d = {}
  d.Icon = layer:CreateTexture(nil, "ARTWORK")
  d.Icon:SetSize(44, 44)
  d.Icon:SetPoint("TOPLEFT", 22, -22)
  local okMask, mask = pcall(layer.CreateMaskTexture, layer)
  if okMask and mask then
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(d.Icon)
    d.Icon:AddMaskTexture(mask)
  end
  local ring = layer:CreateTexture(nil, "OVERLAY")
  ring:SetSize(60, 60)
  ring:SetPoint("CENTER", d.Icon, "CENTER", 0, 0)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetTexCoord(0, 0.6, 0, 0.6)
  d.Ring = ring
  d.Name = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  d.Name:SetPoint("LEFT", d.Icon, "RIGHT", 14, 6)
  d.Name:SetPoint("RIGHT", layer, "RIGHT", -20, 0)
  d.Name:SetJustifyH("LEFT")
  d.Name:SetWordWrap(true) -- long names on two lines instead of cut
  if d.Name.SetMaxLines then d.Name:SetMaxLines(2) end
  d.Sub = layer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.Sub:SetPoint("TOPLEFT", d.Name, "BOTTOMLEFT", 0, -3)
  d.Sub:SetPoint("RIGHT", layer, "RIGHT", -20, 0)
  d.Sub:SetJustifyH("LEFT")
  d.Head = layer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  d.Head:SetPoint("TOPLEFT", d.Icon, "BOTTOMLEFT", 0, -20)
  d.Head:SetText("Kennzahlen:")
  local b = CreateFrame("Button", nil, layer)
  b:SetAllPoints(d.Icon)
  b:SetScript("OnEnter", function(self)
    if not d.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(d.itemID)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function()
    if d.itemID then NW.AltClick(d.itemID, layer) end
  end)
  return d
end

function NW.Split(page, opts)
  local split = { selected = nil, collapsed = {} }
  -- folded: explicit state per header key, else opts.folded (true: all categories start folded)
  local function isFolded(k)
    local v = split.collapsed[k]
    if v == nil then return opts.folded and true or false end
    return v
  end
  local list = try("Frame", page, "ProfessionsRecipeListTemplate") or try("Frame", page, "InsetFrameTemplate")
  list:ClearAllPoints()
  list:SetPoint("TOPLEFT", 0, -4)
  list:SetPoint("BOTTOMLEFT", 0, 0)
  list:SetWidth(opts.listWidth or 304)
  split.list = list
  local card = CreateFrame("Frame", nil, page)
  card:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
  card:SetPoint("BOTTOMRIGHT", 0, 0)
  local cardBg = card:CreateTexture(nil, "BACKGROUND")
  cardBg:SetAllPoints()
  cardBg:SetAtlas(opts.cardAtlas or "Profession-background-card-leatherworking")
  local cardBorder = card:CreateTexture(nil, "BORDER")
  cardBorder:SetAllPoints()
  cardBorder:SetAtlas("common-insideframe")
  split.card = card

  local box, bar = rawget(list, "ScrollBox"), rawget(list, "ScrollBar")
  -- opts.footer = height: room under the list for a summary (split.footer); the scroll box ends above it
  if opts.footer and type(box) == "table" then
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -35)
    box:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -20, opts.footer)
    if type(bar) == "table" then
      bar:ClearAllPoints()
      bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 0, 0)
      bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 0, 0)
    end
    local footer = CreateFrame("Frame", nil, list)
    footer:SetPoint("BOTTOMLEFT", list, "BOTTOMLEFT", 8, 6)
    footer:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -8, 6)
    footer:SetHeight(opts.footer - 8)
    local rule = footer:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 0.82, 0, 0.25)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 4, 0)
    rule:SetPoint("TOPRIGHT", -4, 0)
    split.footer = footer
  end
  if type(box) == "table" and CreateScrollBoxListLinearView and ScrollUtil and CreateDataProvider then
    local view = CreateScrollBoxListLinearView()
    view:SetElementFactory(function(factory, data)
      if data.header then
        factory("ProfessionsRecipeListCategoryTemplate", function(button)
          local text = rawget(button, "ButtonText") or rawget(button, "Label")
          if type(text) == "table" then text:SetText(data.header) end
          local rank = rawget(button, "RankBar") -- the profession's skill bar of a category
          if type(rank) == "table" and rank.Hide then rank:Hide() end
          -- a click folds the category in and out (state per header key), like the profession list
          local folded = isFolded(data.key or data.header)
          local collapse = rawget(button, "CollapseButton")
          if type(collapse) == "table" and collapse.UpdateCollapsedState then pcall(collapse.UpdateCollapsedState, collapse, folded) end
          button:SetScript("OnEnter", nil)
          button:SetScript("OnLeave", nil)
          button:SetScript("OnClick", function()
            local k = data.key or data.header
            split.collapsed[k] = not isFolded(k)
            -- opts.selectHeaders: a category is an entry of its own (its card shows on click)
            if opts.selectHeaders then split.selected = data end
            if split.Rebuild then split.Rebuild() end
          end)
        end)
      else
        factory("ProfessionsRecipeListRecipeTemplate", function(button)
          local label = rawget(button, "Label")
          if type(label) == "table" then label:SetText(data.name) end
          -- a value right in the row (e.g. an area's profit), small and right-aligned
          if not button.m4Value then
            button.m4Value = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            button.m4Value:SetPoint("RIGHT", button, "RIGHT", -6, 0)
            button.m4Value:SetJustifyH("RIGHT")
          end
          button.m4Value:SetText(data.value or "")
          -- data.marker = "down": a red arrow where the profession list shows its skill-up arrow
          if not button.m4Marker then
            button.m4Marker = button:CreateTexture(nil, "OVERLAY")
            button.m4Marker:SetSize(14, 14)
            button.m4Marker:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
            button.m4Marker:SetVertexColor(1, 0.25, 0.2)
          end
          if type(label) == "table" then
            button.m4Marker:ClearAllPoints()
            button.m4Marker:SetPoint("RIGHT", label, "LEFT", -2, -1)
          end
          button.m4Marker:SetShown(data.marker == "down")
          -- data.coins = 1..3 (or marker "coin" = 1): gold coins left of the name, how much it pays
          if not button.m4Coins then button.m4Coins = NW.Coins(button, label) end
          button.m4Coins.Set(data.coins or (data.marker == "coin" and 1) or 0, nil, data.coinsHot)
          if type(label) == "table" and label.SetTextColor then
            -- the template's own color unless the entry brings one (buttons are recycled)
            if not button.m4LabelColor and label.GetTextColor then button.m4LabelColor = { label:GetTextColor() } end
            local c = data.color or button.m4LabelColor
            if c then label:SetTextColor(c[1], c[2], c[3]) end
          end
          -- the name ends before the value (cut with "…" instead of running into it)
          if type(label) == "table" then
            local vw = (data.value and data.value ~= "") and ((button.m4Value:GetStringWidth() or 0) + 14) or 6
            label:SetPoint("RIGHT", button, "RIGHT", -vw, 0)
            if label.SetWordWrap then label:SetWordWrap(false) end
          end
          for _, key in ipairs({ "SkillUps", "LockedIcon", "Count" }) do
            local part = rawget(button, key)
            if type(part) == "table" and part.Hide then part:Hide() end
          end
          -- data.locked: Blizzard's lock of the recipe list (a recipe not learned yet)
          local lock = rawget(button, "LockedIcon")
          if data.locked and type(lock) == "table" and lock.Show then lock:Show() end
          local selected = rawget(button, "SelectedOverlay")
          if type(selected) == "table" then selected:SetShown(split.selected == data) end
          button:SetScript("OnEnter", function(b)
            local h = rawget(b, "HighlightOverlay")
            if type(h) == "table" then h:Show() end
            if data.itemID then
              GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
              GameTooltip:SetItemByID(data.itemID)
              GameTooltip:Show()
            end
          end)
          button:SetScript("OnLeave", function(b)
            local h = rawget(b, "HighlightOverlay")
            if type(h) == "table" then h:Hide() end
            GameTooltip:Hide()
          end)
          button:SetScript("OnClick", function()
            -- Alt+click: the item's market data window, like everywhere
            if data.itemID and NW.AltClick(data.itemID, button) then return end
            split.selected = data
            box:ForEachFrame(function(other)
              local o = rawget(other, "SelectedOverlay")
              if type(o) == "table" then o:SetShown(other == button) end
            end)
            if opts.onSelect then ns.Safe(opts.onSelect, data, card) end
          end)
        end)
      end
    end)
    view:SetElementExtentCalculator(function(_, data) return data.header and 25 or 20 end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  end
  -- The search box filters the entries by name (a header stays when one of its entries does).
  local all, query = {}, ""
  local function filtered()
    if query ~= "" and opts.search then return opts.search(query) or {} end
    local out, header, folded = {}, nil, false
    for _, e in ipairs(all) do
      if e.header then
        header = e
        folded = isFolded(e.key or e.header)
        if query == "" then out[#out + 1] = e; header = nil end
      elseif query == "" or (e.name or ""):lower():find(query, 1, true) then
        if header then out[#out + 1] = header; header = nil end
        if not folded then out[#out + 1] = e end
      end
    end
    return out
  end
  local function show(keepSelection)
    local list = filtered()
    if type(box) == "table" and box.SetDataProvider and CreateDataProvider then
      box:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    end
    local still = false
    for _, e in ipairs(list) do
      if keepSelection and split.selected and e.key and e.key == split.selected.key then
        split.selected, still = e, true
        break
      end
    end
    if not still then
      split.selected = nil
      for _, e in ipairs(list) do
        if opts.selectHeaders or not e.header then split.selected = e break end
      end
    end
    if opts.onSelect then ns.Safe(opts.onSelect, split.selected, card) end
  end
  function split.SetEntries(entries)
    all = entries or {}
    show(true)
  end
  function split.Rebuild() show(true) end
  -- selects the entry with that key (when it is in the list) and shows it
  function split.Select(key)
    split.selected = { key = key }
    show(true)
  end
  local search = rawget(list, "SearchBox")
  if type(search) == "table" and search.HookScript then
    search:HookScript("OnTextChanged", function(edit)
      query = (edit:GetText() or ""):lower()
      show(true)
    end)
  end
  local filter = rawget(list, "FilterDropdown") or rawget(list, "FilterButton")
  if type(filter) == "table" then
    -- one group ({ options, get, set }) or several ({ groups = { { title, options, get, set }… } })
    local f = opts.filter
    local groups = f and (f.groups or { f })
    if f and filter.SetupMenu then
      filter:SetupMenu(function(_, root)
        for gi, g in ipairs(groups) do
          if gi > 1 and root.CreateDivider then root:CreateDivider() end
          if g.title and root.CreateTitle then root:CreateTitle(g.title) end
          for _, o in ipairs(g.options) do
            root:CreateRadio(o.label, function() return g.get() == o.key end, function() g.set(o.key) end)
          end
        end
      end)
      -- Blizzard's reset button next to the filter (a non-default filter): not used here
      local reset = rawget(filter, "ResetButton")
      if type(reset) == "table" and reset.Hide then reset:Hide() end
    elseif f then
      local g = groups[1]
      filter:SetScript("OnClick", function()
        for i, o in ipairs(g.options) do
          if o.key == g.get() then g.set(g.options[i % #g.options + 1].key) break end
        end
      end)
    elseif filter.Hide then
      filter:Hide()
    end
  end
  split.empty = card:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  split.empty:SetPoint("CENTER")
  if opts.entries then split.SetEntries(opts.entries) end
  return split
end
