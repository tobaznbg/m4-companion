-- Boxenstopp: "Dr. med. Porzellans Boxenstopp-Planer", a satirical assistant in the ledger window
-- (side tab under "Marktsuche"). Plans the toilet breaks around a play session the min-max way:
-- coffee before, the big stop before the pull, short stops at the game's natural breaks (flight
-- paths, loading screens, full scans), a snack and a "second wave" in long sessions, plus tips.
-- Only with the switch "Min-Max-Optimierung" (ns.db.settings.minMax, Einstellungen); off, the tab
-- is not there. Inputs in ns.db.boxenstopp (the start time is not kept: auto = next quarter hour).
-- Satire with a grain of real medicine, not medical advice. Dedicated to Nspi, the king of the
-- min-maxers.
local ADDON, ns = ...

local B = {}
ns.Boxenstopp = B

B.ICON = "Interface\\Icons\\Ability_Rogue_Sprint" -- the sprint to the loo

local GREEN, RED, YELLOW, MUTED = "|cff5fd38d", "|cffff6b6b", "|cffffd100", "|cff999999"

function B.Enabled()
  return (ns.db and ns.db.settings and ns.db.settings.minMax == true) and true or false
end

-- Drinks: minutes between pee breaks and the doctor's comment.
local DRINKS = {
  { key = "water", label = "Wasser", every = 120, risk = 0 },
  { key = "coffee", label = "Kaffee", every = 90, risk = 1 },
  { key = "energy", label = "Energy", every = 75, risk = 1 },
  { key = "beer", label = "Bier", every = 60, risk = 2 },
}
local MODES = {
  { key = "casual", label = "Casual" },
  { key = "raid", label = "Raid" },
  { key = "hardcore", label = "Hardcore" },
}
local START_NOTE = {
  casual = "Darm leer, Blase leer, Fokus voll. So sieht ein Min-Maxer aus.",
  raid = "Ab dem ersten Pull gibt es kein „/afk 2 min“ mehr. Der Raidleiter merkt sich alles.",
  hardcore = "Ein Tod ist endgültig. Ein voller Darm im Elitegebiet auch.",
}
-- Where a pee break costs no play time, per mode (rotating).
local SPOTS = {
  casual = {
    "Beim Flugpunkt-Flug: 2 Minuten Flug = 2 Minuten Klo",
    "Während der AH-Vollscan läuft – der braucht dich eh nicht",
    "Im Ladebildschirm (alte Festplatte? Dann reicht's sogar für mehr)",
    "Wenn im Gildenchat das Drama beginnt – du verpasst nichts",
    "Beim Geistheiler: tot sein kostet ohnehin Zeit, nutz sie",
    "Aufstehen, zehn Schritte: die Venen danken (Thrombose-Prophylaxe)",
  },
  raid = {
    "Zwischen zwei Bossen – NIE im Trash",
    "Während der Raidleiter die Taktik erklärt (du kennst sie eh … oder?)",
    "Beim Loot-Verteilen – außer es ist dein Item",
    "Wenn der Heiler Mana trinkt: sein Drink, dein Boxenstopp",
  },
  hardcore = {
    "Nur in der Stadt oder im Gasthaus – nie mit Mobs in Aggro-Reichweite",
    "Beim Flugpunkt-Flug (Flugpunkte sind sicher. Meistens.)",
    "Im Gasthaus: Ruhebonus für dich und deine Blase",
  },
}

local TIPS = {
  "Kaffee 20–40 Minuten vor der Session: Koffein und das warme Getränk regen die Darmbewegung an – bei etwa jedem Dritten deutlich spürbar. So kommt der große Boxenstopp, bevor der Pull kommt.",
  "Der gastrokolische Reflex: Nach dem Essen zieht der Dickdarm an. Wer vor der Session isst, plant den Stopp 15–30 Minuten danach ein – nicht mitten im Bosskampf.",
  "Hockhaltung schlägt Thron: Ein kleiner Hocker unter den Füßen streckt den Winkel im Enddarm. Weniger Pressen, schneller fertig – ein echter Tempo-Buff.",
  "Kein Handy aufs Klo. Wer scrollt, sitzt deutlich länger – und langes Sitzen mit Pressen fördert Hämorrhoiden. Der Debuff „Eingeschlafene Beine“ (−100 % Bewegungstempo) gibt's gratis dazu.",
  "Ballaststoffe + Wasser = Durchsatz. Haferflocken, Vollkorn, Leinsamen oder Flohsamen machen den Stuhl weicher und voluminöser: kurze, planbare Stopps statt Belagerungszustand.",
  "Nie zurückhalten! Wer den Drang immer wieder ignoriert, trainiert dem Darm das Melden ab – das Ergebnis heißt Verstopfung. Zurückhalten ist ein Bug, kein Feature.",
  "Gleiche Uhrzeit, jeden Tag: Der Darm liebt Routine. Behandle den Morgen-Stopp wie eine Daily-Quest – irgendwann kommt er ganz von allein.",
  "Kaffee und Energy-Drinks sind leicht harntreibend, Alkohol bremst das Hormon ADH richtig aus. Bier verkürzt den Pinkel-Cooldown also massiv – und senkt nebenbei deine DPS.",
  "Nicht weniger trinken, um weniger zu müssen! Wassermangel bringt Kopfschmerzen, schlechte Konzentration und harten Stuhl. Lieber regelmäßig kleine Schlucke als ein Liter auf ex vor dem Invite.",
  "Alle 60 Minuten aufstehen ist gut für Rücken und Venen. Der Klo-Gang ist der perfekte Anlass: zwei Buffs, ein Klick.",
  "Hände waschen: 20 Sekunden mit Seife. Deine Tastatur ist ohnehin ein Biotop – mach es nicht schlimmer.",
  "Flugpunkte sind die natürlichen Boxenstopps des Spiels. Langer Flug? Abheben, aufstehen, zurück zur Landung.",
  "Vor dem Raid-Invite: Blase leer, Darm leer, Wasserflasche voll. Der Raidleiter vergisst vieles – aber nie, wer beim Pull AFK war.",
  "Scharfes Essen und fettige Pizza direkt vor der Session sind ein Glücksspiel mit hohem Einsatz. Wer gewinnen will, isst langweilig.",
  "Joghurt, Kefir, Sauerkraut: Ein entspannter Darm ist ein berechenbarer Darm. Und berechenbar ist alles, was ein Min-Maxer will.",
  "Dauert es länger als zehn Minuten: aufstehen, bewegen, später wiederkommen. Sitzen und Hoffen ist keine Taktik.",
}
local DISCLAIMER = "Satire von Dr. med. Porzellan (fiktiv). Kein medizinischer Rat – bei echten Beschwerden "
  .. "zum echten Arzt, nicht zum Heiler der Gilde."

local KIND_ICON = {
  meal = "Interface\\Icons\\INV_Misc_Food_02",
  coffee = "Interface\\Icons\\INV_Drink_04",
  big = "Interface\\Icons\\Ability_Rogue_Sprint",
  pee = "Interface\\Icons\\INV_Drink_07",
  start = "Interface\\Icons\\Ability_Warrior_BattleShout",
  snack = "Interface\\Icons\\INV_Misc_Food_14",
  wave = "Interface\\Icons\\Spell_Nature_Earthquake",
  stop = "Interface\\Icons\\Spell_Nature_Sleep",
}

-- Saved inputs; the start is only for this session (nil = next quarter hour).
local start
local function state()
  ns.db.boxenstopp = ns.db.boxenstopp or {}
  local s = ns.db.boxenstopp
  s.hours = s.hours or 4
  s.drink = s.drink or "coffee"
  s.mode = s.mode or "casual"
  if s.coffee == nil then s.coffee = true end
  if s.meal == nil then s.meal = false end
  return s
end

local function find(list, key)
  for i, x in ipairs(list) do if x.key == key then return x, i end end
  return list[1], 1
end

local function nowMin()
  local d = date("*t")
  return d.hour * 60 + d.min
end
local function nextQuarter() return (math.ceil((nowMin() + 1) / 15) * 15) % 1440 end
local function startMin() return start or nextQuarter() end
local function clock(m)
  m = math.floor(m) % 1440
  return string.format("%02d:%02d", math.floor(m / 60), m % 60)
end
local function hoursText(h)
  local s = (h == math.floor(h)) and string.format("%d", h) or string.format("%.1f", h):gsub("%.", ",")
  return s .. " Std."
end

-- The plan: rows { t = minutes from the start, kind, title, note } and the figures.
local function plan()
  local s = state()
  local dur = math.floor(s.hours * 60 + 0.5)
  local drink = find(DRINKS, s.drink)
  local rows = {}
  local function add(t, kind, title, note) rows[#rows + 1] = { t = t, kind = kind, title = title, note = note } end

  if s.meal then
    add(-60, "meal", "Mahlzeit, ballaststoffreich",
      "Haferflocken, Vollkorn, Obst: mehr Volumen, kürzere Durchlaufzeit. Startet den gastrokolischen Reflex.")
  end
  if s.coffee then
    add(-40, "coffee", "Kaffee trinken",
      "Koffein + warmes Getränk wecken den Darm – bei rund jedem Dritten schon nach 20–30 Minuten.")
  end
  local bigMin
  if s.coffee then
    bigMin = 6
    add(-15, "big", "Großer Boxenstopp", "Reflex aktiv, Erfolgschance hoch. Fußbank unter die Füße (Hockhaltung), Handy bleibt draußen.")
  elseif s.meal then
    bigMin = 8
    add(-15, "big", "Großer Boxenstopp", "Reflex nach dem Essen, Erfolgschance mittel. Ein Kaffee dazu wäre der Pro-Move.")
  else
    bigMin = 12
    add(-15, "big", "Großer Boxenstopp (Versuch)", "Ohne Kaffee oder Essen: Erfolgschance mäßig. Pressen kostet Zeit und ist medizinisch keine gute Idee.")
  end
  add(-3, "pee", "Blase leeren", "Auch wenn's nicht drückt: volle Haltezeit ab dem Start.")
  add(0, "start", "Session-Start", START_NOTE[s.mode])

  -- long sessions: a snack in the middle and the second wave after it
  local mid
  local inSession = 0
  if dur >= 300 then
    mid = math.floor(dur / 2 / 15 + 0.5) * 15
    add(mid, "snack", "Snack + großes Glas Wasser",
      "Nüsse oder Banane statt Chips: kein Zucker-Crash und kein Fettfinger-Debuff auf der Tastatur.")
    add(mid + 25, "wave", "Zweite Welle (falls sie kommt)",
      "Nach dem Essen meldet sich der Darm wieder: dann hingehen, nicht aufschieben.")
    inSession = inSession + 5 + 6
  end

  -- pee breaks: coffee before shortens the cooldown (unless the drink is coffee anyway)
  local every = drink.every - ((s.coffee and drink.key ~= "coffee") and 15 or 0)
  local spots = SPOTS[s.mode] or SPOTS.casual
  local pees, t = 0, every
  while t <= dur - 20 do
    if not (mid and t >= mid - 30 and t <= mid + 45) then
      pees = pees + 1
      add(t, "pee", "Pinkelpause (2 Min.)", spots[(pees - 1) % #spots + 1])
      inSession = inSession + 2
    end
    t = t + every
  end
  add(dur, "stop", "Session-Ende", "Letzter Gang, Hände waschen, Tastatur abwischen. Nachbesprechung auf dem Thron erlaubt.")
  table.sort(rows, function(a, b) return a.t < b.t end)

  -- figures
  local eff = dur > 0 and (1 - inSession / dur) or 1
  local rank
  if eff >= 0.985 then rank = "|cffff8000Mythisch|r – der Darm läuft nach Zeitplan"
  elseif eff >= 0.97 then rank = "|cffa335eeHeroisch|r – fast perfekt"
  elseif eff >= 0.95 then rank = "|cff0070ddNormal|r – solide Blasen-Rotation"
  else rank = "|cff1eff00Casual-Blase|r – Bier weg, Wasser her" end
  local risk = drink.risk + ((s.coffee or s.meal) and 0 or 2) + (dur >= 360 and 1 or 0) + (s.mode == "raid" and 1 or 0)
  local riskText
  if risk <= 1 then riskText = GREEN .. "niedrig|r"
  elseif risk <= 2 then riskText = YELLOW .. "mittel|r"
  else riskText = RED .. "hoch|r " .. MUTED .. "(Notfall-AFK im Bosskampf möglich)|r" end

  return rows, {
    dur = dur, inSession = inSession, before = bigMin + 2, pees = pees, eff = eff, rank = rank, risk = riskText,
  }
end

-- Widgets --------------------------------------------------------------------------------------

local function card(page, w, x, y, width, height, title)
  local c = CreateFrame("Frame", nil, page)
  c:SetSize(width, height)
  c:SetPoint("TOPLEFT", w.frame, "TOPLEFT", x, y)
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetAtlas("Profession-overview-Card")
  c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  c.Title:SetPoint("TOPLEFT", 20, -16)
  c.Title:SetText(title)
  return c
end

local function button(parent, text, width, fn)
  local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
  if not ok or not b then
    b = CreateFrame("Button", nil, parent)
    b:SetNormalFontObject("GameFontNormalSmall")
  end
  b:SetSize(width, 20)
  b:SetText(text)
  b:SetScript("OnClick", fn)
  return b
end

local function rule(parent, y)
  local r = parent:CreateTexture(nil, "ARTWORK")
  r:SetColorTexture(1, 0.82, 0, 0.25)
  r:SetHeight(1)
  r:SetPoint("TOPLEFT", 20, y)
  r:SetPoint("TOPRIGHT", -24, y)
  return r
end

-- Label left, "<  value  >" right.
local function stepper(parent, y, label, onStep)
  local l = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  l:SetPoint("TOPLEFT", 22, y)
  l:SetText(label)
  local minus = button(parent, "<", 24, function() onStep(-1) end)
  minus:SetPoint("TOPLEFT", 128, y + 4)
  local v = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v:SetPoint("LEFT", minus, "RIGHT", 4, 0)
  v:SetWidth(86)
  v:SetJustifyH("CENTER")
  local plus = button(parent, ">", 24, function() onStep(1) end)
  plus:SetPoint("LEFT", v, "RIGHT", 4, 0)
  return v
end

local function check(parent, y, label, get, set)
  local ok, c = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
  if not ok or not c then c = CreateFrame("CheckButton", nil, parent) end
  c:SetSize(24, 24)
  c:SetPoint("TOPLEFT", 16, y + 6)
  local l = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  l:SetPoint("LEFT", c, "RIGHT", 2, 0)
  l:SetText(label)
  c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  function c.Update() c:SetChecked(get() and true or false) end
  return c
end

-- The page ------------------------------------------------------------------------------------

function B.Build(page, w)
  local refresh

  -- left: inputs, the doctor's tip, the disclaimer
  local left = card(page, w, 5, -30, 290, 558, "Deine Session")
  local startV = stepper(left, -48, "Session-Start", function(d)
    start = (startMin() + d * 15) % 1440
    refresh()
  end)
  local durV = stepper(left, -76, "Dauer", function(d)
    local s = state()
    s.hours = math.max(1, math.min(12, s.hours + d * 0.5))
    refresh()
  end)
  local drinkV = stepper(left, -104, "Getränk", function(d)
    local s = state()
    local _, i = find(DRINKS, s.drink)
    s.drink = DRINKS[(i - 1 + d) % #DRINKS + 1].key
    refresh()
  end)
  local modeV = stepper(left, -132, "Modus", function(d)
    local s = state()
    local _, i = find(MODES, s.mode)
    s.mode = MODES[(i - 1 + d) % #MODES + 1].key
    refresh()
  end)
  local coffee = check(left, -162, "Kaffee 40 Min. vorher (Pro-Move)",
    function() return state().coffee end, function(on) state().coffee = on; refresh() end)
  local meal = check(left, -188, "Mahlzeit 1 Std. vorher",
    function() return state().meal end, function(on) state().meal = on; refresh() end)

  rule(left, -218)
  local docIcon = left:CreateTexture(nil, "ARTWORK")
  docIcon:SetSize(32, 32)
  docIcon:SetPoint("TOPLEFT", 22, -230)
  docIcon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
  local docName = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  docName:SetPoint("TOPLEFT", docIcon, "TOPRIGHT", 10, -2)
  docName:SetText("Dr. med. Porzellan rät:")
  local docSub = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  docSub:SetPoint("TOPLEFT", docName, "BOTTOMLEFT", 0, -2)
  docSub:SetText("Fachärzt*in für Boxenstopp-Medizin")
  local tip = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  tip:SetPoint("TOPLEFT", 22, -274)
  tip:SetWidth(246)
  tip:SetJustifyH("LEFT")
  tip:SetJustifyV("TOP")
  tip:SetSpacing(2)
  local tipNo = math.random(#TIPS)
  local counter = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  local function showTip()
    tip:SetText(TIPS[tipNo])
    counter:SetText(string.format("Tipp %d / %d", tipNo, #TIPS))
  end
  local nextTip = button(left, "Nächster Tipp", 110, function()
    tipNo = tipNo % #TIPS + 1
    showTip()
  end)
  nextTip:SetPoint("BOTTOMLEFT", 20, 62)
  -- the dedication: a crown (the group leader's) and the king of the min-maxers
  local dedication = left:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  dedication:SetPoint("BOTTOMLEFT", 22, 94)
  dedication:SetWidth(246)
  dedication:SetJustifyH("LEFT")
  dedication:SetText("|TInterface\\GroupFrame\\UI-Group-LeaderIcon:14:14|t  Gewidmet |cffff8000Nspi|r, dem König der Min-Maxer")
  counter:SetPoint("LEFT", nextTip, "RIGHT", 12, 0)
  local disclaimer = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  disclaimer:SetPoint("BOTTOMLEFT", 22, 18)
  disclaimer:SetWidth(246)
  disclaimer:SetJustifyH("LEFT")
  disclaimer:SetText(DISCLAIMER)
  showTip()

  -- right: the plan (time line), live line on top, figures below
  local right = card(page, w, 289, -30, 378, 558, "Optimaler Boxenstopp-Plan")
  local live = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  live:SetPoint("TOPLEFT", 22, -38)
  live:SetWidth(336)
  live:SetJustifyH("LEFT")
  local h1 = right:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h1:SetPoint("TOPLEFT", 24, -60)
  h1:SetText("Uhrzeit")
  local h2 = right:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h2:SetPoint("TOPLEFT", 82, -60)
  h2:SetText("Boxenstopp")
  rule(right, -74)

  local setRows
  local okB, box = pcall(CreateFrame, "Frame", nil, right, "WowScrollBoxList")
  local okS, bar = pcall(CreateFrame, "EventFrame", nil, right, "MinimalScrollBar")
  if okB and okS and CreateScrollBoxListLinearView and ScrollUtil and CreateDataProvider then
    box:SetPoint("TOPLEFT", 16, -78)
    box:SetPoint("BOTTOMRIGHT", -30, 130)
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(40)
    view:SetElementInitializer("Frame", function(row, r)
      if not row.m4 then
        row.m4 = {}
        row.m4.icon = row:CreateTexture(nil, "ARTWORK")
        row.m4.icon:SetSize(20, 20)
        row.m4.icon:SetPoint("TOPLEFT", 4, -4)
        row.m4.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.m4.time:SetPoint("TOPLEFT", 30, -8)
        row.m4.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.m4.title:SetPoint("TOPLEFT", 66, -4)
        row.m4.title:SetWidth(264)
        row.m4.title:SetJustifyH("LEFT")
        row.m4.title:SetWordWrap(false)
        row.m4.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.m4.note:SetPoint("TOPLEFT", row.m4.title, "BOTTOMLEFT", 0, -2)
        row.m4.note:SetWidth(264)
        row.m4.note:SetHeight(22)
        row.m4.note:SetJustifyH("LEFT")
        row.m4.note:SetJustifyV("TOP")
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
          if not self.data then return end
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetText(self.data.title)
          GameTooltip:AddLine(self.data.note, 1, 1, 1, true)
          GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      end
      row.data = r
      row.m4.icon:SetTexture(KIND_ICON[r.kind])
      row.m4.icon:SetDesaturated(r.done and true or false)
      row.m4.time:SetText((r.done and MUTED or "") .. r.clock .. (r.done and "|r" or ""))
      local title = r.title
      if r.done then title = MUTED .. title .. "  (erledigt)|r"
      elseif r.next then title = title .. "  " .. GREEN .. "← als Nächstes|r" end
      row.m4.title:SetText(title)
      row.m4.note:SetText(r.note or "")
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    setRows = function(rows) box:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition) end
  else
    local fallback = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fallback:SetPoint("TOPLEFT", 22, -82)
    fallback:SetWidth(336)
    fallback:SetJustifyH("LEFT")
    setRows = function(rows)
      local lines = {}
      for _, r in ipairs(rows) do lines[#lines + 1] = r.clock .. "  " .. r.title end
      fallback:SetText(table.concat(lines, "\n"))
    end
  end

  -- figures under the plan
  local bottomRule = right:CreateTexture(nil, "ARTWORK")
  bottomRule:SetColorTexture(1, 0.82, 0, 0.25)
  bottomRule:SetHeight(1)
  bottomRule:SetPoint("BOTTOMLEFT", 20, 124)
  bottomRule:SetPoint("BOTTOMRIGHT", -24, 124)
  local LABELS = { "Klo-Zeit vor der Session", "Klo-Zeit während der Session", "Reine Zockzeit", "Notfall-Risiko", "Min-Max-Rang" }
  local values = {}
  for i, text in ipairs(LABELS) do
    local l = right:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    l:SetPoint("BOTTOMLEFT", 22, 124 - i * 18 - 2)
    l:SetText(text)
    local v = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -26, 124 - i * 18 - 2)
    v:SetJustifyH("RIGHT")
    values[i] = v
  end

  refresh = function()
    local s = state()
    startV:SetText(clock(startMin()) .. (start and "" or (MUTED .. " (auto)|r")))
    durV:SetText(hoursText(s.hours))
    drinkV:SetText(find(DRINKS, s.drink).label)
    modeV:SetText(find(MODES, s.mode).label)
    coffee.Update()
    meal.Update()

    local rows, fig = plan()
    -- live: how far the start is from now (a start more than 12 h away is meant for the other day)
    local now = nowMin()
    local diff = startMin() - now
    if diff < -720 then diff = diff + 1440 elseif diff > 720 then diff = diff - 1440 end
    local nextRow
    for _, r in ipairs(rows) do
      r.clock = clock(startMin() + r.t)
      local delta = diff + r.t
      r.done = delta < 0
      if not r.done and not nextRow then nextRow, r.next = r, true end
      r.delta = delta
    end
    if not nextRow then
      live:SetText(MUTED .. "Jetzt " .. clock(now) .. "  ·  Session vorbei – ab ins Bett, die Blase hat Feierabend.|r")
    elseif nextRow.delta <= 5 then
      live:SetText("Jetzt " .. clock(now) .. "  ·  " .. RED .. "JETZT: " .. nextRow.title .. "!|r")
    else
      local d = nextRow.delta
      local inText = d >= 60 and string.format("%d:%02d Std.", math.floor(d / 60), d % 60) or (d .. " Min.")
      live:SetText("Jetzt " .. clock(now) .. "  ·  Nächstes: " .. YELLOW .. nextRow.title .. "|r in " .. inText)
    end
    setRows(rows)

    values[1]:SetText(fig.before .. " Min. " .. MUTED .. "(kostet keine Spielzeit)|r")
    values[2]:SetText(fig.inSession .. " Min. " .. MUTED .. string.format("(%d Pinkelpausen)", fig.pees) .. "|r")
    local play = fig.dur - fig.inSession
    values[3]:SetText(string.format("%d:%02d Std.  ", math.floor(play / 60), play % 60)
      .. GREEN .. string.format("%.1f %%", fig.eff * 100):gsub("%.", ",", 1) .. "|r")
    values[4]:SetText(fig.risk)
    values[5]:SetText(fig.rank)
  end

  -- the live line and the done marks follow the clock while the page shows
  local elapsed = 0
  page:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 15 then return end
    elapsed = 0
    ns.Safe(refresh)
  end)
  function page.Refresh()
    elapsed = 0
    refresh()
  end
end
