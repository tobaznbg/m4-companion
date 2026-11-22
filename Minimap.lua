-- Minimap: round button at the minimap edge (like other addons), draggable around it.
-- Left click: m4-companion window; right click: trading ledger. The tooltip shows how
-- current the data is. Position saved in ns.db.minimap.angle.
local ADDON, ns = ...

local RADIUS_PAD = 5
local button

local function place()
  local angle = math.rad(ns.db.minimap.angle or 210)
  local r = (Minimap:GetWidth() / 2) + RADIUS_PAD
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function create()
  ns.db.minimap = ns.db.minimap or {}
  if ns.db.minimap.hide then return end
  button = CreateFrame("Button", "M4CompanionMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER")
  bg:SetColorTexture(0.08, 0.08, 0.09, 1)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(22, 22)
  icon:SetPoint("CENTER")
  icon:SetTexture("Interface\\AddOns\\m4-companion\\media\\emblem")
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  button:SetScript("OnClick", function(_, mouse)
    -- for now (pilot): left click the ledger window in Blizzard's look, right click the main window
    if mouse == "RightButton" then
      if ns.MainUI then ns.Safe(ns.MainUI.Toggle) else ns.Safe(ns.PlannerUI.Toggle) end
    elseif IsShiftKeyDown() and ns.ShoppingList then
      ns.Safe(ns.ShoppingList.Toggle) -- also for a character without the profession (bank)
    elseif ns.TradeBook then
      ns.Safe(ns.TradeBook.Toggle)
    elseif ns.MainUI then
      ns.Safe(ns.MainUI.Toggle)
    end
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      place()
    end)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("m4-companion")
    GameTooltip:AddLine(ns.Status.Text(), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Linksklick: Handelsbuch  ·  Rechtsklick: Fenster", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Shift+Linksklick: Einkaufsliste", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  place()
end

ns.OnReady(function() ns.Safe(create) end)

-- Live strip (test, 22 Nov 2026): a band of ROWS lines of cells right under the minimap's zone bar, for a later
-- live channel (the companion app would read it). Each cell is a shade of the frame's gold:
-- 8 steps per color channel above a gold base (9 bits a cell), so to the eye it stays a gold
-- frame line. Calm: it only changes while data goes out (the dummy "sends" for half a second
-- every few seconds). Off by default; /m4 strip toggles (ns.db.ui.liveStrip). Pixel exact:
-- one cell = CELL x CELL physical pixels, whatever the UI scale.
local CELL, ROWS, STEPS = 3, 2, 8
local GOLD = { 196, 156, 64 } -- base gold (0..255), the shades go up to +STEPS-1 per channel
local strip

local function physicalPixel(frame)
  local _, height = GetPhysicalScreenSize()
  return 768 / height / frame:GetEffectiveScale()
end

local function setShade(t, r, g, b)
  t:SetColorTexture((GOLD[1] + r) / 255, (GOLD[2] + g) / 255, (GOLD[3] + b) / 255, 1)
end

local function createStrip()
  local cluster = rawget(_G, "MinimapCluster")
  local anchor = (type(cluster) == "table" and (rawget(cluster, "BorderTop") or rawget(cluster, "ZoneTextButton")))
    or rawget(_G, "MinimapZoneTextButton") or rawget(_G, "Minimap")
  if not anchor then return nil end
  local f = CreateFrame("Frame", "M4CompanionLiveStrip", UIParent)
  f:SetFrameStrata("HIGH")
  local px = physicalPixel(f)
  -- as wide as the zone bar
  local width = (anchor:GetWidth() or 160) * anchor:GetEffectiveScale() / f:GetEffectiveScale()
  local cols = math.max(16, math.floor(width / (CELL * px)))
  f:SetSize(cols * CELL * px, ROWS * CELL * px)
  f:SetPoint("TOP", anchor, "BOTTOM", 0, -px)
  f.cells = {}
  for r = 1, ROWS do
    for c = 1, cols do
      local t = f:CreateTexture(nil, "ARTWORK")
      t:SetSize(CELL * px, CELL * px)
      t:SetPoint("TOPLEFT", (c - 1) * CELL * px, -(r - 1) * CELL * px)
      if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true); t:SetTexelSnappingBias(0) end
      setShade(t, 0, 0, 0)
      f.cells[#f.cells + 1] = t
    end
  end
  -- dummy: half a second of "data" every four seconds, still in between
  local clock, tick = 0, 0
  f:SetScript("OnUpdate", function(self, dt)
    clock, tick = clock + dt, tick + dt
    if tick < 0.1 then return end
    tick = 0
    local sending = (clock % 4) < 0.5
    for _, t in ipairs(self.cells) do
      if sending then
        setShade(t, math.random(0, STEPS - 1), math.random(0, STEPS - 1), math.random(0, STEPS - 1))
      else
        setShade(t, 0, 0, 0)
      end
    end
  end)
  return f
end

local function showStrip(on)
  if on and not strip then strip = createStrip() end
  if strip then strip:SetShown(on) end
end

function ns.ToggleLiveStrip()
  ns.db.ui = ns.db.ui or {}
  ns.db.ui.liveStrip = not ns.db.ui.liveStrip
  showStrip(ns.db.ui.liveStrip)
  print("|cff33ccffm4:|r Live-Streifen " .. (ns.db.ui.liveStrip and "an" or "aus"))
end

ns.On("PLAYER_ENTERING_WORLD", function()
  if ns.db and ns.db.ui and ns.db.ui.liveStrip then ns.Safe(showStrip, true) end
end)
