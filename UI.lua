-- UI: small movable window showing the running session, plus slash commands.
-- All user-facing text is German (the client runs deDE).
local ADDON, ns = ...

local UI = {}
ns.UI = UI

local KIND_LABELS = {
  skinning = "Häuten",
  mining = "Bergbau",
  herbalism = "Kräuter",
  fishing = "Angeln",
  loot = "Beute",
}

local TOP_ITEMS = 15
local BUTTON_ROW = 26 -- height reserved for the Start/Stop/Reset buttons
local PADDING = 10
local frame, text

local WIDTH = 290
local HEADER = 26

local function createFrame()
  local Style = ns.Style
  frame = CreateFrame("Frame", "M4CompanionFrame", UIParent)
  frame:SetSize(WIDTH, 190)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.db.ui.pos = { point, relPoint, x, y }
  end)
  Style.Panel(frame, HEADER)

  local pos = ns.db.ui.pos
  if pos then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 120)
  end

  local brand = Style.Text(frame, 13)
  brand:SetPoint("TOPLEFT", PADDING, -7)
  brand:SetText(Style.ACCENT .. "m4|r-companion")

  local berufe = Style.Button(frame, "Berufe", 64, 18, function() ns.PlannerUI.Toggle() end)
  berufe:SetPoint("TOPRIGHT", -5, -4)

  text = frame:CreateFontString(nil, "OVERLAY")
  text:SetFontObject(Style.Font(12))
  text:SetPoint("TOPLEFT", PADDING, -(HEADER + 8))
  text:SetWidth(WIDTH - 2 * PADDING)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetSpacing(2)

  -- Session controls along the bottom edge.
  local controls = {
    { "Start", Style.C.accent, function()
        ns.Tracker.Start()
        print("|cffffd100M4:|r neue Sitzung gestartet.")
      end },
    { "Stop", { 1, 0.71, 0.28 }, function()
        ns.Tracker.Stop()
        print("|cffffd100M4:|r Tracker gestoppt – es wird nichts mehr gezählt.")
      end },
    { "Reset", nil, function()
        ns.Tracker.Reset()
        print("|cffffd100M4:|r Sitzung verworfen.")
      end },
  }
  local bw = math.floor((WIDTH - 2 * PADDING - 2 * 6) / 3)
  for index, def in ipairs(controls) do
    local b = Style.Button(frame, def[1], bw, 20, function() ns.Safe(def[3]); ns.Safe(UI.Refresh) end, def[2])
    b:SetPoint("BOTTOMLEFT", PADDING + (index - 1) * (bw + 6), 8)
  end

  local elapsed = 0
  frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 1 then return end
    elapsed = 0
    ns.Safe(UI.Refresh)
  end)
end

local function sortedItems(session)
  local list = {}
  for itemID, entry in pairs(session.items) do
    table.insert(list, { id = itemID, n = entry.n, v = entry.v })
  end
  table.sort(list, function(a, b) return a.v > b.v end)
  return list
end

-- Show the text and grow/shrink the window to fit it.
local function setLines(lines)
  text:SetText(table.concat(lines, "\n"))
  frame:SetHeight(math.ceil(text:GetStringHeight()) + HEADER + 8 + PADDING + BUTTON_ROW + 6)
end

local function characterLines(lines)
  local char = ns.Tracker.Character()
  if not char then return end

  local _, classFile = UnitClass("player")
  local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  local name = char.name or UnitName("player") or "?"
  if color and color.colorStr then
    name = "|c" .. color.colorStr .. name .. "|r"
  end
  table.insert(lines, string.format("%s  ·  %s %d  ·  %s",
    name, char.className or char.class or "", UnitLevel("player") or char.level or 0, char.faction or ""))
  table.insert(lines, "Gold: " .. ns.FormatMoney(GetMoney()))

  for _, prof in ipairs(char.professions or {}) do
    local rank, max = prof.rank or 0, prof.max or 0
    local note = ""
    if max > 0 and rank >= max then
      note = "  |cffff8800Limit – Lehrer!|r"
    end
    table.insert(lines, string.format("  %s  |cffffffff%d / %d|r%s", prof.name, rank, max, note))
  end
  table.insert(lines, " ")
end

function UI.Refresh()
  if not frame or not frame:IsShown() then return end
  local lines = {}

  if not (ns.AuctionScan and ns.AuctionScan.HasData()) then
    table.insert(lines, "|cffffaa00Noch kein AH-Scan – Auktionshaus öffnen (scannt von selbst) oder /m4 scan|r")
  end

  characterLines(lines)

  local session = ns.Tracker.Current()
  if not session or session.char ~= ns.CharKey() then
    table.insert(lines, ns.Tracker.IsTracking() and "Noch keine Sitzung – einfach looten oder häuten."
      or "|cffffb547Tracker gestoppt.|r Mit Start geht es los.")
    setLines(lines)
    return
  end
  if session.stopped or not ns.Tracker.IsTracking() then
    table.insert(lines, "|cffd8c9a3Sitzung|r  |cffffb547gestoppt|r")
  else
    table.insert(lines, "|cffd8c9a3Sitzung|r  |cff4fc2a1läuft|r")
  end

  local zoneNames = {}
  for _, name in pairs(session.zones) do
    if name then table.insert(zoneNames, name) end
  end
  table.insert(lines, "Gebiet: " .. (table.concat(zoneNames, ", ")))

  local gph = ns.Tracker.GoldPerHour(session)
  table.insert(lines, string.format("Zeit: %s   Gold/h: |cff00ff00%s|r",
    ns.FormatDuration(ns.Tracker.Duration(session)),
    gph and ns.FormatMoney(gph) or "–"))
  local xph = ns.Tracker.XPPerHour(session)
  if xph then
    local missing = UnitXPMax("player") - UnitXP("player")
    table.insert(lines, string.format("XP/h: |cffffffff%s|r   Level-Up in: |cffffffff%s|r",
      BreakUpLargeNumbers and BreakUpLargeNumbers(math.floor(xph)) or tostring(math.floor(xph)),
      ns.FormatDuration(missing / xph * 3600)))
  end
  table.insert(lines, string.format("Items: %s   Gold: %s",
    ns.FormatMoney(session.value), ns.FormatMoney(session.money)))

  local kinds = {}
  for kind, count in pairs(session.kinds) do
    table.insert(kinds, (KIND_LABELS[kind] or kind) .. " " .. count)
  end
  if #kinds > 0 then
    table.insert(lines, table.concat(kinds, "   "))
  end

  local items = sortedItems(session)
  for i = 1, math.min(TOP_ITEMS, #items) do
    local item = items[i]
    table.insert(lines, string.format("  %dx %s  |cffaaaaaa%s|r",
      item.n, ns.ItemName(item.id), ns.FormatMoney(item.v)))
  end
  if session.unpriced > 0 then
    table.insert(lines, string.format("|cffffaa00%d Items ohne Preis (AH scannen)|r", session.unpriced))
  end

  setLines(lines)
end

function UI.SetShown(shown)
  ns.db.ui.shown = shown
  if not frame then createFrame() end
  frame:SetShown(shown)
  if shown then UI.Refresh() end
end

-- The farming tracker window is hidden for now (to be rebuilt); "/cf farm" still opens it.

SLASH_M4COMPANION1 = "/cf"
SLASH_M4COMPANION2 = "/m4"
SlashCmdList.M4COMPANION = function(msg)
  local raw = strtrim(msg or "")
  msg = raw:lower()
  local cmd, rest = raw:match("^(%S+)%s*(.-)$")
  if cmd and cmd:lower() == "item" then
    -- /m4 item <link, name or id>: the item detail window. Keeps the case of names and links.
    ns.Safe(ns.ItemDetail.Open, rest)
  elseif msg == "neu" or msg == "new" then
    ns.Tracker.Start()
    print("|cffffd100M4:|r neue Sitzung gestartet.")
    UI.SetShown(true)
  elseif msg == "scan" then
    ns.Safe(ns.AuctionScan.Start)
  elseif cmd and (cmd:lower() == "suche" or cmd:lower() == "markt") then
    -- /m4 suche [Text]: the ledger's market search
    if ns.TradeBook then ns.Safe(ns.TradeBook.ShowSearch, rest) end
  elseif msg == "klo" or msg == "boxenstopp" then
    -- /m4 klo: the toilet break planner (only with "Min-Max-Optimierung" in the settings)
    if not (ns.TradeBook and ns.TradeBook.ShowBoxenstopp()) then
      print("|cffffd100M4:|r Der Boxenstopp-Planer ist aus: Einstellungen → Min-Max-Optimierung.")
    end
  elseif msg == "buch" then
    if ns.TradeBook then ns.Safe(ns.TradeBook.Toggle) end
  elseif msg == "strip" then
    if ns.ToggleLiveStrip then ns.Safe(ns.ToggleLiveStrip) end
  elseif msg == "quellen" then
    if ns.SourceLog then ns.Safe(ns.SourceLog.Summary) end
  elseif msg == "liste" then
    if ns.ShoppingList then ns.Safe(ns.ShoppingList.Toggle) end
  elseif msg == "berufe" or msg == "b" then
    ns.PlannerUI.Toggle()
  elseif msg == "handel" or msg == "h" then
    ns.PlannerUI.Show("ledger")
  elseif msg == "farm" then
    UI.SetShown(not (frame and frame:IsShown()))
  elseif msg == "hilfe" or msg == "help" then
    print("|cffffd100M4:|r /m4 – Fenster, /m4 handel – Handelsbuch, /m4 suche [Name] – Marktsuche, /m4 scan – AH-Vollscan, /m4 farm – Farm-Tracker, /m4 item <Link/Name/ID> – Item-Details (oder Alt+Klick aufs Item)")
  else
    if ns.MainUI then ns.MainUI.Toggle() else ns.PlannerUI.Toggle() end
  end
end
