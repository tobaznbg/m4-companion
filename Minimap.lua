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

-- Live strip (test, 22 Nov 2026): a band of cells right under the minimap's zone bar that the
-- companion app reads off the screen (tools: m4-companion cmd/m4-strip). Each cell is a shade of
-- the frame's gold: GOLD + 0..7 per color channel, so to the eye it stays a gold band.
--   cell 1  reference: GOLD + (0, 0, 0)        cell 2  reference: GOLD + (7, 7, 7)
--   cell 3… one byte each: r = bits 7..5, g = bits 4..2, b = bits 1..0 + 4 * phase
--           (phase flips with every new packet; a reader seeing mixed phases saw a torn frame)
--   packet  0xA5, sequence, length, payload…, checksum (sum of sequence..payload mod 256)
-- Payload now: the player's position - map id (2 bytes), x and y (0..65535 each, 2 bytes), facing
-- (0..255). Sent only when it changes; otherwise the band stands still. Off by default;
-- /m4 strip toggles (ns.db.ui.liveStrip). Pixel exact: a cell = CELL x CELL physical pixels.
local CELL, ROWS = 3, 2
-- Switched off (22 Nov 2026): the test worked (112 packets, none lost); kept for later, but
-- neither /m4 strip nor a stored setting can show it while this is false.
local LIVE_STRIP_ENABLED = false
local GOLD = { 196, 156, 64 } -- base gold (0..255); the shades go up to +7 per channel
local strip
local seq, phase, lastPayload = 0, 0, nil

local function physicalPixel(frame)
  local _, height = GetPhysicalScreenSize()
  return 768 / height / frame:GetEffectiveScale()
end

local function setShade(t, r, g, b)
  t:SetColorTexture((GOLD[1] + r) / 255, (GOLD[2] + g) / 255, (GOLD[3] + b) / 255, 1)
end

local function u16(v) v = math.max(0, math.min(65535, math.floor(v + 0.5))); return math.floor(v / 256), v % 256 end

-- The player's position as payload bytes, or nil.
local function positionPayload()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return nil end
  local x, y = pos:GetXY()
  local facing = GetPlayerFacing and GetPlayerFacing() or 0
  local m1, m2 = u16(mapID)
  local x1, x2 = u16((x or 0) * 65535)
  local y1, y2 = u16((y or 0) * 65535)
  return { m1, m2, x1, x2, y1, y2, math.floor((facing or 0) / (2 * math.pi) * 255 + 0.5) % 256 }
end

local function draw(f, bytes)
  setShade(f.cells[1], 0, 0, 0)
  setShade(f.cells[2], 7, 7, 7)
  for k = 3, #f.cells do
    local b = bytes[k - 2] or 0
    setShade(f.cells[k], math.floor(b / 32), math.floor(b / 4) % 8, b % 4 + 4 * phase)
  end
end

local function send(f, payload)
  if #payload > #f.cells - 6 then return end
  seq, phase = (seq + 1) % 256, 1 - phase
  local bytes, sum = { 0xA5, seq, #payload }, seq + #payload
  for _, b in ipairs(payload) do bytes[#bytes + 1] = b; sum = sum + b end
  bytes[#bytes + 1] = sum % 256
  draw(f, bytes)
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
      f.cells[#f.cells + 1] = t
    end
  end
  draw(f, {})
  -- ten times a second: a new packet when the position changed, else the band stands still
  local tick = 0
  f:SetScript("OnUpdate", function(self, dt)
    tick = tick + dt
    if tick < 0.1 then return end
    tick = 0
    local p = positionPayload()
    if not p then return end
    local key = table.concat(p, ",")
    if key ~= lastPayload then
      lastPayload = key
      send(self, p)
    end
  end)
  return f
end

local function showStrip(on)
  if on and not strip then strip = createStrip() end
  if strip then strip:SetShown(on) end
end

function ns.ToggleLiveStrip()
  if not LIVE_STRIP_ENABLED then
    print("|cff33ccffm4:|r Der Live-Streifen ist abgeschaltet.")
    return
  end
  ns.db.ui = ns.db.ui or {}
  ns.db.ui.liveStrip = not ns.db.ui.liveStrip
  showStrip(ns.db.ui.liveStrip)
  print("|cff33ccffm4:|r Live-Streifen " .. (ns.db.ui.liveStrip and "an" or "aus"))
end

ns.On("PLAYER_ENTERING_WORLD", function()
  if LIVE_STRIP_ENABLED and ns.db and ns.db.ui and ns.db.ui.liveStrip then ns.Safe(showStrip, true) end
end)
