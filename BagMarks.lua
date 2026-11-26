-- BagMarks: small markers on the bag slots of the game's own bag windows.
--   quest items  violet tint and "Q"
--   sell on AH   green "AH"
--   sell to vendor  beige "H"
-- Items can't be hidden by an addon; marking is what is possible.
local ADDON, ns = ...

local QUEST_CLASS = 12
local COLORS = {
  quest = { 0.62, 0.38, 0.95 },
  AH = { 0.37, 0.83, 0.55 },
  vendor = { 0.85, 0.79, 0.64 },
}

local function marker(button)
  if button.cfMark then return button.cfMark end
  local m = {}
  m.tint = button:CreateTexture(nil, "OVERLAY", nil, 6)
  m.tint:SetAllPoints()
  m.tint:SetColorTexture(COLORS.quest[1], COLORS.quest[2], COLORS.quest[3], 0.28)
  m.text = button:CreateFontString(nil, "OVERLAY")
  m.text:SetFont("Fonts\\ARIALN.TTF", 11, "OUTLINE")
  m.text:SetPoint("TOPLEFT", 2, -2)
  button.cfMark = m
  return m
end

local function isQuestItem(bag, slot, itemID)
  if C_Container and C_Container.GetContainerItemQuestInfo then
    local q = C_Container.GetContainerItemQuestInfo(bag, slot)
    if q and (q.isQuestItem or q.questID) then return true end
  end
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  return getInstant and select(6, getInstant(itemID)) == QUEST_CLASS
end

local function markButton(button)
  if not button or not button.GetBagID then return end
  local bag, slot = button:GetBagID(), button:GetID()
  local info = bag and slot and C_Container.GetContainerItemInfo(bag, slot)
  local m = marker(button)
  m.tint:Hide()
  m.text:SetText("")
  if not info or not info.itemID then return end
  -- Reduced-UI (settings, main window): no markers on the bag slots.
  if ns.db.settings and ns.db.settings.reducedUI then return end
  if isQuestItem(bag, slot, info.itemID) then
    m.tint:Show()
    m.text:SetText("Q")
    m.text:SetTextColor(unpack(COLORS.quest))
    return
  end
  local entry = { n = info.stackCount or 1, q = info.quality, bound = info.isBound, loot = info.hasLoot }
  local action = ns.Inventory.Advise(info.itemID, entry)
  if action == "AH" then
    m.text:SetText("AH")
    m.text:SetTextColor(unpack(COLORS.AH))
  elseif action == "Händler" then
    m.text:SetText("H")
    m.text:SetTextColor(unpack(COLORS.vendor))
  end
end

local function markFrame(frame)
  if not frame or not frame:IsShown() then return end
  if frame.EnumerateValidItems then
    for _, button in frame:EnumerateValidItems() do ns.Safe(markButton, button) end
  elseif frame.Items then
    for _, button in ipairs(frame.Items) do ns.Safe(markButton, button) end
  end
end

local function containerFrames()
  local frames = {}
  if ContainerFrameCombinedBags then table.insert(frames, ContainerFrameCombinedBags) end
  for i = 1, (NUM_CONTAINER_FRAMES or 13) do
    local f = _G["ContainerFrame" .. i]
    if f then table.insert(frames, f) end
  end
  return frames
end

local function markAll()
  for _, frame in ipairs(containerFrames()) do markFrame(frame) end
end

-- Redraws the markers of the open bags (after the Reduced-UI switch).
ns.BagMarks = { Refresh = function() ns.Safe(markAll) end }

local hooked = false
local function hook()
  if hooked then return end
  hooked = true
  for _, frame in ipairs(containerFrames()) do
    if frame.UpdateItems then
      hooksecurefunc(frame, "UpdateItems", function(self) ns.Safe(markFrame, self) end)
    end
    frame:HookScript("OnShow", function(self) C_Timer.After(0, function() ns.Safe(markFrame, self) end) end)
  end
end

ns.On("PLAYER_ENTERING_WORLD", function() ns.Safe(hook) end)
ns.On("BAG_UPDATE_DELAYED", function() C_Timer.After(0.1, function() ns.Safe(markAll) end) end)
ns.On("QUEST_LOG_UPDATE", function() C_Timer.After(0.1, function() ns.Safe(markAll) end) end)
