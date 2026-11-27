-- Shop: "Marktschreier" - the own shop prices of the recipes marked as favourite (the star in the
-- profession window, Recipes.Scan: fav) and an advert for the trade chat built from them.
--   per recipe either / or (decided 27 Nov 2026), with a fixed price entered by hand:
--     "own" "meine Mats":  the crafter brings the material, the price is the whole price
--     "tip" "Taschengeld": the customer brings it and pays the price as pocket money (no
--                          price: "deine Mats + Taschengeld", the customer decides)
--     nil   not offered
--   the material cost (ns.RecipeEconomics) shows beside them as a help
--   the advert, plain text (no links): the intro text, then "Waffe - Feurige Waffe 25g" /
--   "… deine Mats + 5g Taschengeld" per offered recipe (names without "Verzauberkunst:"), then
--   the own closing text (suffix), split into messages of at most 255 characters; "Handelschat" posts the next
--   one to the trade channel, "Schreien (/y)" yells it (one per click: a hardware event per
--   message).
-- Per recipe also a sale name (label, e.g. "FEURIGE WAFFE"): the advert uses it instead of the
-- recipe's name.
-- Stored account-wide: ns.db.shop = { intro, suffix, channel, prices = { [recipeID] = { mode, price, label } } }.
-- Opened by the tab "Marktschreier" under the profession window (Crafting.lua) and
-- "/m4 marktschreier" (or "/m4 laden").
local ADDON, ns = ...

local Shop = {}
ns.Shop = Shop
Shop.ICON = "Interface\\Icons\\INV_Misc_Horn_01" -- the crier's horn

local MAX_MESSAGE = 255
local ROW_H = 46
local DEFAULT_INTRO = "Biete an:"
local MUTED, RED, GREEN = "|cff999999", "|cffff6b6b", "|cff5fd38d"

local window, page, rows, scrollChild, preview, introBox, suffixBox, emptyText
local sendButtons = {} -- "Handelschat" and "Schreien (/y)"
local sendIndex = 1
local scanning = false -- refresh runs Recipes.Scan itself: its listener then does not refresh again

local function db()
  ns.db.shop = ns.db.shop or {}
  local s = ns.db.shop
  s.prices = s.prices or {}
  if s.intro == nil then s.intro = DEFAULT_INTRO end
  -- the first version kept two prices { own, mats }: one mode with its price
  for _, p in pairs(s.prices) do
    if p.mode == nil and (p.own or p.mats) then
      p.mode, p.price = p.own and "own" or "tip", p.own or p.mats
      p.own, p.mats = nil, nil
    end
  end
  return s
end

local MODES = { "own", "tip" }
local MODE_LABEL = { own = "meine Mats", tip = "Taschengeld" }

-- Money ---------------------------------------------------------------------------------------

-- Plain text for the chat (no coin textures): "5g 20s", "80s", "15c".
function Shop.MoneyText(c)
  c = math.floor((c or 0) + 0.5)
  local g, s, k = math.floor(c / 10000), math.floor(c % 10000 / 100), c % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if k > 0 or #parts == 0 then parts[#parts + 1] = k .. "c" end
  return table.concat(parts, " ")
end

-- Copper from what was typed: "5g 20s", "5g", "20s", "50c", "5,5" / "5.5" (a bare number is
-- gold). nil for an empty or unreadable text.
function Shop.ParseMoney(text)
  text = strtrim((text or ""):lower())
  if text == "" then return nil end
  local bare = text:gsub(",", ".")
  if tonumber(bare) then return math.floor(tonumber(bare) * 10000 + 0.5) end
  local total, found = 0, false
  for num, unit in text:gmatch("(%d+)%s*([gsck]?)") do
    local n = tonumber(num)
    if unit == "g" or unit == "" then total = total + n * 10000
    elseif unit == "s" then total = total + n * 100
    else total = total + n end
    found = true
  end
  return found and total or nil
end

-- Favourites ----------------------------------------------------------------------------------

-- The favourite recipes of the own character's professions: { id, name, prof, out, cost,
-- noPrice } sorted by profession and name.
function Shop.Favorites()
  local prefix = ns.CharKey() .. ":"
  local list = {}
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.recipes then
      for id, r in pairs(scan.recipes) do
        if r.fav then
          local e = ns.RecipeEconomics and ns.RecipeEconomics(id)
          list[#list + 1] = { id = id, name = r.name or ("Rezept " .. id), prof = scan.profession or "", out = r.out,
            cost = e and (e.cost or e.partial), noPrice = e and e.noPrice, icon = r.icon }
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.prof ~= b.prof then return a.prof < b.prof end
    return a.name < b.name
  end)
  return list
end

-- The recipe's name as plain text for the chat (no links, decided 27 Nov 2026), short: without
-- a profession in front ("Verzauberkunst: Waffe - Feurige Waffe" -> "Waffe - Feurige Waffe").
local PROFESSION_PREFIX = { "Verzauberkunst", "Verzaubern", "Enchanting", "Enchant" }
local function shortName(fav)
  local name = fav.name or ""
  for _, prefix in ipairs(PROFESSION_PREFIX) do
    local rest = name:match("^" .. prefix .. "%s*:%s*(.+)$")
    if rest then return rest end
  end
  return name
end

-- The advert as chat messages (each at most 255 characters); the recipes without a price are
-- left out.
function Shop.Messages()
  local s = db()
  local parts = {}
  for _, fav in ipairs(Shop.Favorites()) do
    local p = s.prices[fav.id]
    -- the own sale name ("FEURIGE WAFFE") when one is set, else the short recipe name
    local name = p and p.label and strtrim(p.label) ~= "" and strtrim(p.label) or shortName(fav)
    -- "meine Mats" needs a price; "Taschengeld" goes without one too
    if p and p.mode == "own" and p.price then
      parts[#parts + 1] = name .. " " .. Shop.MoneyText(p.price)
    elseif p and p.mode == "tip" then
      parts[#parts + 1] = name .. " deine Mats + "
        .. (p.price and (Shop.MoneyText(p.price) .. " ") or "") .. "Taschengeld"
    end
  end
  local messages = {}
  if #parts == 0 then return messages end
  -- the intro opens the first message; recipes are joined with ", " and never cut
  local intro = strtrim(s.intro or "")
  local current, hasPart = intro, false
  for _, part in ipairs(parts) do
    local candidate
    if not hasPart then
      candidate = current == "" and part or (current .. " " .. part)
    else
      candidate = current .. ", " .. part
    end
    if hasPart and #candidate > MAX_MESSAGE then
      messages[#messages + 1] = current
      current = part
    else
      current = candidate
    end
    hasPart = true
  end
  -- the closing text (own words: whisper me, where to find me …) ends the last message
  local suffix = strtrim(s.suffix or "")
  if suffix ~= "" then
    if #current + 1 + #suffix > MAX_MESSAGE then
      messages[#messages + 1] = current
      current = suffix
    else
      current = current .. " " .. suffix
    end
  end
  if current ~= "" then messages[#messages + 1] = current end
  return messages
end

-- The trade channel's number and name ("Handel - Stadt" / "Trade - City"), nil when not joined.
local function tradeChannel()
  if not GetChannelList then return nil end
  local list = { GetChannelList() }
  for i = 1, #list, 3 do
    local id, name = list[i], list[i + 1]
    if type(name) == "string" and (name:find("^Handel") or name:find("^Trade")) then return id, name end
  end
  return nil
end

-- Where the advert goes: "trade" (default) or "yell" (ns.db.shop.channel).
local function channelKey() return db().channel == "yell" and "yell" or "trade" end

-- Window --------------------------------------------------------------------------------------

local function hex(r, g, b)
  return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- A message as the chat window shows it: "[2. Handel - Stadt] [Name]: …" or "[Name] schreit: …",
-- in the chat type's color (the player's own chat settings), the name in the class color.
local function chatLine(msg)
  local yell = channelKey() == "yell"
  local id, cname = tradeChannel()
  local info = ChatTypeInfo and (yell and ChatTypeInfo.YELL or (id and ChatTypeInfo["CHANNEL" .. id]) or ChatTypeInfo.CHANNEL)
  local color = info and info.r and hex(info.r, info.g, info.b) or (yell and "|cffff4040" or "|cffffc0c0")
  local name = UnitName and UnitName("player") or "Du"
  local class = UnitClass and select(2, UnitClass("player"))
  local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  local who = (cc and hex(cc.r, cc.g, cc.b) or "") .. name .. "|r" .. color
  -- the links end with |r: the text after them goes on in the chat color
  local body = msg:gsub("|r", "|r" .. color)
  if yell then return color .. "[" .. who .. "] schreit: " .. body .. "|r" end
  return color .. "[" .. (id or 2) .. ". " .. (cname or "Handel - Stadt") .. "] [" .. who .. "]: " .. body .. "|r"
end

local function refreshPreview()
  if not preview then return end
  local messages = Shop.Messages()
  if sendIndex > #messages then sendIndex = 1 end
  if #messages == 0 then
    preview:SetText(MUTED .. "Noch nichts im Angebot – oben bei deinen Favoriten „meine Mats“ (mit Preis) oder „Taschengeld“ wählen.|r")
  else
    local lines = {}
    for i, m in ipairs(messages) do
      local head = string.format("Nachricht %d von %d  ·  %d/%d Zeichen", i, #messages, #m, MAX_MESSAGE)
      if i == sendIndex then head = "|cffffd100" .. head .. "  ·  wird als Nächstes gesendet|r" else head = MUTED .. head .. "|r" end
      lines[#lines + 1] = head
      lines[#lines + 1] = chatLine(m)
      if i < #messages then lines[#lines + 1] = " " end
    end
    preview:SetText(table.concat(lines, "\n"))
  end
  local yell = channelKey() == "yell"
  for _, b in ipairs(sendButtons) do
    if b.channel then
      -- the channel switch: the chosen one lit
      local on = b.channel == channelKey()
      b:SetText((on and "|cffffd100" or MUTED) .. b.label .. "|r")
      if on then b:LockHighlight() else b:UnlockHighlight() end
    else
      b:SetEnabled(#messages > 0)
      b:SetText((yell and "Schreien" or "In den Handelschat")
        .. (#messages > 1 and string.format(" (%d/%d)", sendIndex, #messages) or ""))
    end
  end
end

local function moneyBox(parent, width)
  local ok, box = pcall(CreateFrame, "EditBox", nil, parent, "InputBoxTemplate")
  if not ok then box = CreateFrame("EditBox", nil, parent) end
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetFontObject(ChatFontNormal)
  box:SetJustifyH("RIGHT")
  return box
end

-- WoW's money input (as at the auction house): a gold box and a silver box, each with its
-- coin; no copper. Returns { gold, silver, Get() copper or nil (both empty), Set(copper),
-- HasFocus() }; onCommit(copper) after Enter or leaving a box.
local function moneyInput(parent, onCommit)
  local m = {}
  local function box(width, letters)
    local b = moneyBox(parent, width)
    b:SetNumeric(true)
    b:SetMaxLetters(letters)
    return b
  end
  local function coin(texture)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetSize(13, 13)
    t:SetTexture(texture)
    return t
  end
  m.silverIcon = coin("Interface\\MoneyFrame\\UI-SilverIcon")
  m.silverIcon:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
  m.silver = box(28, 2)
  m.silver:SetPoint("RIGHT", m.silverIcon, "LEFT", -3, 0)
  m.goldIcon = coin("Interface\\MoneyFrame\\UI-GoldIcon")
  m.goldIcon:SetPoint("RIGHT", m.silver, "LEFT", -8, 0)
  m.gold = box(56, 6)
  m.gold:SetPoint("RIGHT", m.goldIcon, "LEFT", -3, 0)
  function m.Get()
    local g, s = tonumber(m.gold:GetText() or ""), tonumber(m.silver:GetText() or "")
    if not g and not s then return nil end
    return (g or 0) * 10000 + math.min(99, s or 0) * 100
  end
  function m.Set(c)
    if not c then
      m.gold:SetText("")
      m.silver:SetText("")
      return
    end
    local g, s = math.floor(c / 10000), math.floor(c % 10000 / 100)
    m.gold:SetText(g > 0 and tostring(g) or "")
    m.silver:SetText(s > 0 and tostring(s) or "")
  end
  function m.HasFocus() return m.gold:HasFocus() or m.silver:HasFocus() end
  for _, b in ipairs({ m.gold, m.silver }) do
    b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) -- focus lost commits
    b:SetScript("OnEditFocusLost", function() onCommit(m.Get()) end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  end
  m.gold:SetScript("OnTabPressed", function() m.silver:SetFocus() end)
  return m
end

-- The price entered for a recipe (copper, nil: none); a price on a recipe not offered yet
-- offers it with my mats.
local function setPrice(id, copper)
  local s = db()
  local p = s.prices[id] or {}
  p.price = copper and copper > 0 and copper or nil
  if p.price and not p.mode then p.mode = "own" end
  if p.mode or p.price or p.label then s.prices[id] = p else s.prices[id] = nil end
  sendIndex = 1
end

-- The offer switch: not offered -> meine Mats -> Taschengeld -> not offered (the price stays).
local function nextMode(id)
  local s = db()
  local p = s.prices[id] or {}
  local nxt
  if p.mode == nil then nxt = MODES[1]
  elseif p.mode == MODES[1] then nxt = MODES[2] end
  p.mode = nxt
  s.prices[id] = (p.mode or p.price or p.label) and p or nil
  sendIndex = 1
end

-- Text and color of the switch.
local function modeText(p)
  if p and p.mode then return (p.mode == "own" and GREEN or "|cffffd100") .. MODE_LABEL[p.mode] .. "|r" end
  return MUTED .. "– nicht –|r"
end

local function row(i)
  rows[i] = rows[i] or (function()
    local r = CreateFrame("Frame", nil, scrollChild)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
    local bg = r:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
    -- two lines: the recipe's name on top, its sale name under it; the rest centered right
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(32, 32)
    r.icon:SetPoint("LEFT", 6, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, 1)
    r.name:SetWidth(300)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.cost = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.cost:SetPoint("RIGHT", r, "RIGHT", -270, 0)
    r.cost:SetJustifyH("RIGHT")
    -- the offer switch (meine Mats / Taschengeld / not offered) and the one price
    local okM, mode = pcall(CreateFrame, "Button", nil, r, "UIPanelButtonTemplate")
    if not okM then mode = CreateFrame("Button", nil, r) end
    mode:SetSize(120, 20)
    mode:SetPoint("RIGHT", r, "RIGHT", -142, 0)
    if GameFontHighlightSmall then mode:SetNormalFontObject(GameFontHighlightSmall) end
    mode:SetScript("OnClick", function()
      if not r.fav then return end
      nextMode(r.fav.id)
      mode:SetText(modeText(db().prices[r.fav.id]))
      refreshPreview()
    end)
    mode:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_TOP")
      GameTooltip:SetText("Angebot")
      GameTooltip:AddLine("Klick wechselt: meine Mats (Preis inkl. Material) → Taschengeld (Kunde bringt die Mats) → nicht anbieten.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    mode:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.mode = mode
    -- the sale name: replaces the recipe's name in the advert; grey hint while empty
    local labelTitle = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labelTitle:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, 1)
    labelTitle:SetText("Verkaufsname:")
    r.label = moneyBox(r, 200)
    r.label:SetHeight(18)
    r.label:SetJustifyH("LEFT")
    r.label:SetMaxLetters(40)
    r.label:SetPoint("LEFT", labelTitle, "RIGHT", 10, 0)
    r.hint = r.label:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.hint:SetPoint("LEFT", 2, 0)
    r.hint:SetPoint("RIGHT", -2, 0)
    r.hint:SetJustifyH("LEFT")
    r.hint:SetWordWrap(false)
    local function hint()
      r.hint:SetShown((r.label:GetText() or "") == "" and not r.label:HasFocus())
    end
    r.label:SetScript("OnTextChanged", function(b, userInput)
      hint()
      if not (userInput and r.fav) then return end
      local s = db()
      local p = s.prices[r.fav.id] or {}
      local text = strtrim(b:GetText() or "")
      p.label = text ~= "" and text or nil
      s.prices[r.fav.id] = (p.mode or p.price or p.label) and p or nil
      refreshPreview()
    end)
    r.label:SetScript("OnEditFocusGained", hint)
    r.label:SetScript("OnEditFocusLost", hint)
    r.label:SetScript("OnEnterPressed", function(b) b:ClearFocus() end)
    r.label:SetScript("OnEscapePressed", function(b) b:ClearFocus() end)
    r.label:SetScript("OnTabPressed", function() r.price.gold:SetFocus() end)
    r.updateHint = hint
    r.price = moneyInput(r, function(copper)
      if not r.fav then return end
      setPrice(r.fav.id, copper)
      local p = db().prices[r.fav.id]
      if not r.price.HasFocus() then r.price.Set(p and p.price) end
      r.mode:SetText(modeText(p))
      refreshPreview()
    end)
    -- Tab from the silver box: the next recipe's gold box
    r.price.silver:SetScript("OnTabPressed", function()
      local nxt = rows[i + 1] and rows[i + 1]:IsShown() and rows[i + 1].price
      if nxt then rows[i + 1].label:SetFocus() else r.price.silver:ClearFocus() end
    end)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(f)
      if f.fav and f.fav.out then
        GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(f.fav.out)
        GameTooltip:Show()
      end
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return r
  end)()
  return rows[i]
end

local function refresh(rescan)
  if not page then return end
  -- on opening with the profession window open: read the stars anew (a favourite just set)
  local pf = rawget(_G, "ProfessionsFrame")
  if rescan and type(pf) == "table" and pf:IsShown() and ns.Recipes and ns.Recipes.Scan then
    scanning = true
    ns.Safe(ns.Recipes.Scan)
    scanning = false
  end
  local s = db()
  local favs = Shop.Favorites()
  local fmt = function(c) return ns.FormatMoney(c, true) end
  for i, fav in ipairs(favs) do
    local r = row(i)
    r.fav = fav
    -- the product's icon, else the recipe's own (enchantments: stored by the scan)
    local icon = fav.out and ((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(fav.out)
      or fav.icon or (GetSpellTexture and GetSpellTexture(fav.id)) or "Interface\\Icons\\INV_Misc_QuestionMark"
    r.icon:SetTexture(icon)
    r.name:SetText(shortName(fav) .. "  " .. MUTED .. fav.prof .. "|r")
    if fav.cost and not fav.noPrice then
      r.cost:SetText(MUTED .. fmt(fav.cost) .. "|r")
    elseif fav.noPrice then
      r.cost:SetText((fav.cost and fav.cost > 0 and (MUTED .. fmt(fav.cost) .. "|r ") or "") .. RED .. "+ " .. fav.noPrice .. " ohne Preis|r")
    else
      r.cost:SetText(MUTED .. "–|r")
    end
    local p = s.prices[fav.id]
    r.mode:SetText(modeText(p))
    if not r.price.HasFocus() then r.price.Set(p and p.price) end
    if not r.label:HasFocus() then r.label:SetText(p and p.label or "") end
    r.hint:SetText(shortName(fav))
    r.updateHint()
    r:Show()
  end
  for i = #favs + 1, #rows do rows[i]:Hide(); rows[i].fav = nil end
  scrollChild:SetHeight(math.max(1, #favs * ROW_H))
  emptyText:SetShown(#favs == 0)
  if not introBox:HasFocus() then introBox:SetText(s.intro or "") end
  if not suffixBox:HasFocus() then suffixBox:SetText(s.suffix or "") end
  refreshPreview()
end
Shop.Refresh = refresh

local function build(p)
  page = p
  rows = {}
  -- the head centered in the window's grey band above the page (the page starts under it):
  -- the title, the help behind an "i" (tooltip)
  local head = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  head:SetPoint("CENTER", p, "TOP", -12, 20)
  head:SetText("Ladenpreise deiner Favoriten")
  local help = CreateFrame("Button", nil, p)
  help:SetSize(18, 18)
  help:SetPoint("LEFT", head, "RIGHT", 6, 0)
  local helpIcon = help:CreateTexture(nil, "ARTWORK")
  helpIcon:SetAllPoints()
  helpIcon:SetTexture("Interface\\FriendsFrame\\InformationIcon")
  help:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetText("Ladenpreise")
    GameTooltip:AddLine("Favoriten: der Stern beim Rezept im Berufsfenster.", 1, 1, 1, true)
    GameTooltip:AddLine("Angebot: meine Mats (Preis inkl. Material) oder Taschengeld (der Kunde bringt die Mats).", 1, 1, 1, true)
    GameTooltip:AddLine("Verkaufsname: steht im Chat statt des Rezeptnamens.", 1, 1, 1, true)
    GameTooltip:AddLine("Preis in Gold und Silber.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  help:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- the column heads: a dark table head bar over the list
  local bar = CreateFrame("Frame", nil, p)
  bar:SetPoint("TOPLEFT", 8, -6)
  bar:SetPoint("TOPRIGHT", -8, -6)
  bar:SetHeight(20)
  local barBg = bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints()
  barBg:SetColorTexture(0, 0, 0, 0.4)
  local barLine = bar:CreateTexture(nil, "ARTWORK")
  barLine:SetColorTexture(1, 0.82, 0, 0.3)
  barLine:SetHeight(1)
  barLine:SetPoint("BOTTOMLEFT")
  barLine:SetPoint("BOTTOMRIGHT")

  -- the list under it
  local list = CreateFrame("Frame", nil, p)
  list:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)
  list:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -2)
  list:SetHeight(236) -- five recipes
  -- column heads over their fields (bar x = row x - 26 for the scroll bar): Material right-
  -- aligned like its amounts, Angebot and Preis centered over the switch and the coin boxes
  local function colHead(text, point, x)
    local fs = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint(point, bar, "RIGHT", x, 0)
    fs:SetText(text)
  end
  local nameHead = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  nameHead:SetPoint("LEFT", bar, "LEFT", 46, 0)
  nameHead:SetText("Rezept")
  colHead("Material", "RIGHT", -296)
  colHead("Angebot", "CENTER", -228)
  colHead("Preis", "CENTER", -98)

  local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")
  if not ok then scroll = CreateFrame("ScrollFrame", nil, list) end
  scroll:SetPoint("TOPLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", -26, 0)
  scrollChild = CreateFrame("Frame", nil, scroll)
  scrollChild:SetSize(1, 1)
  scroll:SetScrollChild(scrollChild)
  scroll:SetScript("OnSizeChanged", function(sf, w) scrollChild:SetWidth(w) end)
  scrollChild:SetWidth(700)
  emptyText = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  emptyText:SetPoint("CENTER")
  emptyText:SetText("Keine Favoriten – im Berufsfenster beim Rezept den Stern setzen.")

  -- the advert
  local rule = p:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(1, 0.82, 0, 0.25)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -8)
  rule:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", -4, -8)
  local introLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  introLabel:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 2, -12)
  introLabel:SetText("Einleitung:")
  -- intro and closing text; the preview follows every key typed, stored as typed
  local function textBox(width, field)
    local b = moneyBox(p, width)
    b:SetJustifyH("LEFT")
    b:SetMaxLetters(120)
    b:SetScript("OnTextChanged", function(self, userInput)
      if not userInput then return end
      db()[field] = self:GetText() or ""
      sendIndex = 1
      refreshPreview()
    end)
    b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return b
  end
  introBox = textBox(260, "intro")
  introBox:SetPoint("LEFT", introLabel, "RIGHT", 12, 0)
  local suffixLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  suffixLabel:SetPoint("LEFT", introBox, "RIGHT", 18, 0)
  suffixLabel:SetText("Schluss:")
  suffixBox = textBox(280, "suffix")
  suffixBox:SetPoint("LEFT", suffixLabel, "RIGHT", 12, 0)
  suffixBox:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText("Schluss")
    GameTooltip:AddLine("Dein eigener Text am Ende, z. B. „/w me – stehe an der Bank“.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  suffixBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local function button(label, width)
    local okB, b = pcall(CreateFrame, "Button", nil, p, "UIPanelButtonTemplate")
    if not okB then b = CreateFrame("Button", nil, p) end
    b:SetSize(width, 22)
    b.label = label
    b:SetText(label)
    sendButtons[#sendButtons + 1] = b
    return b
  end

  -- the channel: Handelschat or /y (one choice for preview and sending)
  local channelLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  channelLabel:SetPoint("TOPLEFT", introLabel, "BOTTOMLEFT", 0, -16)
  channelLabel:SetText("Posten in:")
  local last
  for _, c in ipairs({ { "trade", "Handelschat" }, { "yell", "Schreien (/y)" } }) do
    local b = button(c[2], 120)
    b.channel = c[1]
    b:SetPoint("LEFT", last or channelLabel, "RIGHT", last and 6 or 12, 0)
    b:SetScript("OnClick", function()
      db().channel = c[1]
      refreshPreview()
    end)
    last = b
  end

  -- the preview: like the chat window (dark box, chat font and colors)
  local box = CreateFrame("Frame", nil, p)
  box:SetPoint("TOPLEFT", channelLabel, "BOTTOMLEFT", -2, -28) -- room for its title under the switch
  box:SetPoint("RIGHT", p, "RIGHT", -14, 0)
  box:SetPoint("BOTTOM", p, "BOTTOM", 0, 44)
  local bg = box:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }) do
    local l = box:CreateTexture(nil, "BORDER")
    l:SetColorTexture(1, 0.82, 0, 0.25)
    l:SetHeight(1)
    l:SetPoint(edge[1])
    l:SetPoint(edge[2])
  end
  local boxTitle = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  boxTitle:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 2, 3)
  boxTitle:SetText("Vorschau – so steht es im Chat:")
  preview = box:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
  preview:SetPoint("TOPLEFT", 8, -8)
  preview:SetPoint("RIGHT", box, "RIGHT", -8, 0)
  preview:SetJustifyH("LEFT")
  preview:SetJustifyV("TOP")
  preview:SetWordWrap(true)
  preview:SetSpacing(2)

  -- send: the marked message to the chosen channel, then the next one (one per click)
  local send = button("In den Handelschat", 200)
  send:SetHeight(24)
  send:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -14, 10)
  send:SetScript("OnClick", function()
    local messages = Shop.Messages()
    local msg = messages[sendIndex]
    if not msg then return end
    if channelKey() == "yell" then
      SendChatMessage(msg, "YELL")
    else
      local channel = tradeChannel()
      if not channel then
        print("|cff33ccffm4:|r Du bist nicht im Handelschat (nur in Hauptstädten) – oder „Schreien (/y)“ wählen.")
        return
      end
      SendChatMessage(msg, "CHANNEL", nil, channel)
    end
    sendIndex = sendIndex % #messages + 1
    refreshPreview()
  end)
  send:SetScript("OnEnter", function(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    GameTooltip:SetText("Senden")
    GameTooltip:AddLine("Ein Klick sendet die markierte Nachricht, bei mehreren Nachrichten danach die nächste.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  send:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Requests -----------------------------------------------------------------------------------
-- Every whisper is a request (decided 27 Nov 2026): a green chat bubble right of the window
-- shows the open ones; a click opens the list beside it with per request "In Arbeit",
-- "Erledigt", "Ablehnen" (only the state; nothing is whispered back). Open ones on top, then
-- the done ones, the declined ones at the bottom under "Abgelehnt". A click on the name
-- whispers the player. Further whispers of a player with an open request go into it.
-- ns.db.shop.requests = { { from, text, t, status = "neu"/"arbeit"/"erledigt"/"abgelehnt" }… },
-- newest first; finished ones older than a day are dropped.
local MAX_STORED = 30
local LIST_H = 6 * 78 -- room for the rows in the list (as high as the window)
local STATUS = {
  neu = { "neu", "|cff5fd38d" },
  arbeit = { "in Arbeit", "|cffffd100" },
  erledigt = { "erledigt", MUTED },
  abgelehnt = { "abgelehnt", MUTED },
}
local bubble, panel

local function requests()
  local s = db()
  s.requests = s.requests or {}
  local keep = {}
  for _, r in ipairs(s.requests) do
    local done = r.status == "erledigt" or r.status == "abgelehnt"
    if not (done and time() - (r.t or 0) > 86400) then keep[#keep + 1] = r end
  end
  s.requests = keep
  return keep
end

local function openCount()
  local n = 0
  for _, r in ipairs(requests()) do
    if r.status == "neu" or r.status == "arbeit" then n = n + 1 end
  end
  return n
end

local function ago(t)
  local s = math.max(0, time() - (t or 0))
  if s < 60 then return "gerade" end
  if s < 3600 then return string.format("vor %d min", math.floor(s / 60)) end
  return string.format("vor %d h", math.floor(s / 3600))
end

local refreshRequests

local function requestRow(i)
  panel.rows = panel.rows or {}
  local row = panel.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, panel) -- placed by refreshRequests
  row:SetHeight(74)
  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.05)
  -- the name: a click whispers the player
  row.name = CreateFrame("Button", nil, row)
  row.name:SetPoint("TOPLEFT", 6, -4)
  row.name:SetSize(150, 16)
  row.nameText = row.name:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.nameText:SetAllPoints()
  row.nameText:SetJustifyH("LEFT")
  row.name:SetScript("OnClick", function()
    if row.req and ChatFrame_SendTell then ChatFrame_SendTell(row.req.from) end
  end)
  row.name:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText("Anflüstern")
    GameTooltip:Show()
  end)
  row.name:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.state:SetPoint("TOPRIGHT", -6, -6)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("TOPLEFT", 6, -22)
  row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetJustifyV("TOP")
  row.text:SetHeight(26)
  row.text:SetWordWrap(true)
  if row.text.SetMaxLines then row.text:SetMaxLines(2) end
  row.buttons = {}
  local x = 0
  for _, b in ipairs({ { "arbeit", "In Arbeit", 80 }, { "erledigt", "Erledigt", 72 }, { "abgelehnt", "Ablehnen", 76 } }) do
    local ok, btn = pcall(CreateFrame, "Button", nil, row, "UIPanelButtonTemplate")
    if not ok then btn = CreateFrame("Button", nil, row) end
    btn:SetSize(b[3], 18)
    btn:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6 + x, 4)
    if GameFontHighlightSmall then btn:SetNormalFontObject(GameFontHighlightSmall) end
    btn:SetText(b[2])
    btn:SetScript("OnClick", function()
      if not row.req then return end
      row.req.status = b[1]
      row.req.t = row.req.status == "arbeit" and row.req.t or time()
      refreshRequests()
    end)
    row.buttons[b[1]] = btn
    x = x + b[3] + 4
  end
  panel.rows[i] = row
  return row
end

refreshRequests = function()
  if not bubble then return end
  local list = requests()
  local open = openCount()
  bubble:SetShown(#list > 0)
  bubble.count:SetText(open > 0 and tostring(open) or "")
  bubble.icon:SetVertexColor(open > 0 and 0.35 or 0.6, open > 0 and 1 or 0.6, open > 0 and 0.45 or 0.6)
  if open > 0 then bubble.glow:Play() else bubble.glow:Stop() end
  if not (panel and panel:IsShown()) then return end
  -- order: open (newest first), then done, then the declined ones under their own heading
  local rank = { neu = 1, arbeit = 1, erledigt = 2, abgelehnt = 3 }
  local sorted = {}
  for _, r in ipairs(list) do sorted[#sorted + 1] = r end
  table.sort(sorted, function(a, b)
    local ra, rb = rank[a.status] or 1, rank[b.status] or 1
    if ra ~= rb then return ra < rb end
    return (a.t or 0) > (b.t or 0)
  end)
  local y, used, headShown = panel.rowsTop or -48, 0, false
  local bottom = (panel.rowsTop or -48) - LIST_H
  for _, req in ipairs(sorted) do
    if req.status == "abgelehnt" and not headShown then
      if y - 22 - 74 < bottom then break end
      panel.declinedHead:ClearAllPoints()
      panel.declinedHead:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, y - 4)
      panel.declinedHead:Show()
      headShown = true
      y = y - 22
    end
    if y - 74 < bottom then break end
    used = used + 1
    local row = requestRow(used)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)
    row:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    row.req = req
    local st = STATUS[req.status] or STATUS.neu
    local done = req.status == "erledigt" or req.status == "abgelehnt"
    row.nameText:SetText((done and MUTED or "") .. (Ambiguate and Ambiguate(req.from, "short") or req.from)
      .. (done and "|r" or ""))
    row.state:SetText(st[2] .. st[1] .. "|r  " .. MUTED .. ago(req.t) .. "|r")
    row.text:SetText((done and MUTED or "") .. (req.text or "") .. (done and "|r" or ""))
    for key, btn in pairs(row.buttons) do btn:SetEnabled(req.status ~= key) end
    row:Show()
    y = y - 78
  end
  if not headShown then panel.declinedHead:Hide() end
  for i = used + 1, #(panel.rows or {}) do
    panel.rows[i].req = nil
    panel.rows[i]:Hide()
  end
  panel.empty:SetShown(#list == 0)
end
Shop.RefreshRequests = function() ns.Safe(refreshRequests) end

local function createRequests()
  local f = window.frame
  -- the bubble: right of the window, under its top edge
  bubble = CreateFrame("Button", nil, f)
  bubble:SetSize(40, 40)
  bubble:SetPoint("TOPLEFT", f, "TOPRIGHT", 2, -60)
  bubble.icon = bubble:CreateTexture(nil, "ARTWORK")
  bubble.icon:SetAllPoints()
  bubble.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-Chat-Up")
  bubble:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  bubble.count = bubble:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  bubble.count:SetPoint("BOTTOMRIGHT", -2, 2)
  -- a slow pulse while requests are open
  local ag = bubble:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(1)
  a:SetToAlpha(0.45)
  a:SetDuration(0.8)
  bubble.glow = ag
  bubble:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetText("Anfragen")
    GameTooltip:AddLine(string.format("%d offen – Klick zeigt die Whispers.", openCount()), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  bubble:SetScript("OnLeave", function() GameTooltip:Hide() end)
  bubble:SetScript("OnClick", function()
    panel:SetShown(not panel:IsShown())
    refreshRequests()
  end)
  bubble:Hide()

  -- the list beside the window
  local ok, p = pcall(CreateFrame, "Frame", nil, f, "BasicFrameTemplateWithInset")
  if not ok then p = CreateFrame("Frame", nil, f) end
  panel = p
  p:SetSize(300, 58 + LIST_H)
  p:SetPoint("TOPLEFT", bubble, "TOPRIGHT", 4, 20)
  p:SetFrameStrata(f:GetFrameStrata())
  if not ok then
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)
  end
  local title = rawget(p, "TitleText") or p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not rawget(p, "TitleText") then title:SetPoint("TOP", 0, -6) end
  title:SetText("Anfragen")
  p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  p.empty:SetPoint("TOP", 0, -60)
  p.empty:SetText("Keine Anfragen")
  p.declinedHead = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  p.declinedHead:SetText("Abgelehnt")
  p.declinedHead:Hide()
  -- finished ones away
  local okC, clear = pcall(CreateFrame, "Button", nil, p, "UIPanelButtonTemplate")
  if not okC then clear = CreateFrame("Button", nil, p) end
  clear:SetSize(90, 18)
  clear:SetPoint("TOPLEFT", 8, -26)
  clear:SetText("Aufräumen")
  if GameFontHighlightSmall then clear:SetNormalFontObject(GameFontHighlightSmall) end
  clear:SetScript("OnClick", function()
    local keep = {}
    for _, r in ipairs(requests()) do
      if r.status == "neu" or r.status == "arbeit" then keep[#keep + 1] = r end
    end
    db().requests = keep
    refreshRequests()
  end)
  clear:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText("Erledigte und abgelehnte entfernen")
    GameTooltip:Show()
  end)
  clear:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- the rows start under the clear button
  p.rowsTop = -48
  p:Hide()
  refreshRequests()
end

-- Every whisper is a request (or more text of an open one of that player).
ns.On("CHAT_MSG_WHISPER", function(_, text, sender)
  if not sender then return end
  local list = requests()
  for _, r in ipairs(list) do
    if r.from == sender and (r.status == "neu" or r.status == "arbeit") then
      r.text = (r.text or "") .. " · " .. (text or "")
      r.t = time()
      Shop.RefreshRequests()
      return
    end
  end
  table.insert(list, 1, { from = sender, text = text or "", t = time(), status = "neu" })
  while #list > MAX_STORED do table.remove(list) end
  Shop.RefreshRequests()
end)

local function create()
  local NW = ns.NativeWindow
  window = NW.New({ name = "M4CompanionShop", title = "Marktschreier", icon = Shop.ICON, width = 760 })
  window:AddTab({ key = "shop", title = "Marktschreier", hidden = true, build = build, onShow = function()
    refresh(true)
    Shop.RefreshRequests() -- the "vor x min" of the requests
  end })
  local function sync() if ns.Products and ns.Products.SyncTab then ns.Products.SyncTab() end end
  window.frame:HookScript("OnShow", sync)
  window.frame:HookScript("OnHide", sync)
  ns.Safe(createRequests)
end

function Shop.Show()
  if not window then create() end
  window:Show()
  window:SelectTab("shop")
end

function Shop.Toggle()
  if window and window.frame:IsShown() then window.frame:Hide() else Shop.Show() end
end

function Shop.Frame() return window and window.frame end

-- A star set or taken while the window is open (the profession list updates, Recipes.Scan):
-- the list follows.
if ns.Recipes and ns.Recipes.OnScanned then
  ns.Recipes.OnScanned(function()
    if window and window.frame:IsShown() and page and not scanning then ns.Safe(refresh) end
  end)
end
