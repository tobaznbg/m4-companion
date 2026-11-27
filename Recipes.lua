-- Recipes: reads the open profession window through the retail trade skill API
-- and stores every recipe (difficulty, skill-ups, reagents, output) in the saved
-- variables. Stage 2 builds on this data; for now it also documents which API
-- functions the Forever client actually provides.
local ADDON, ns = ...

local Recipes = {}
ns.Recipes = Recipes

local SCAN_DELAY = 0.5 -- seconds; the list fires several updates while opening

local function apiAvailability()
  local api = C_TradeSkillUI or {}
  local names = {
    "GetAllRecipeIDs", "GetRecipeInfo", "GetRecipeSchematic", "GetBaseProfessionInfo",
    "GetChildProfessionInfo", "GetTradeSkillLine", "GetRecipeNumReagents",
    "GetRecipeReagentInfo", "GetRecipeReagentItemLink", "GetRecipeItemLink",
    "GetRecipeOutputItemData", "GetRecipeNumItemsProduced", "GetCategoryInfo",
    "IsTradeSkillReady", "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting",
  }
  local result = {}
  for _, name in ipairs(names) do
    result[name] = type(api[name]) == "function"
  end
  return result
end

local function professionInfo()
  local api = C_TradeSkillUI
  if api.GetBaseProfessionInfo then
    local ok, info = pcall(api.GetBaseProfessionInfo)
    if ok and type(info) == "table" then
      return info.professionName, info.skillLevel, info.maxSkillLevel, info.professionID
    end
  end
  if api.GetTradeSkillLine then
    local ok, id, name, rank, max = pcall(api.GetTradeSkillLine)
    if ok then return name, rank, max, id end
  end
  return nil
end

local function itemIdFromLink(link)
  return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function readReagents(recipeID)
  local api = C_TradeSkillUI
  local reagents = {}

  -- Dragonflight-style schematic.
  if api.GetRecipeSchematic then
    local ok, schematic = pcall(api.GetRecipeSchematic, recipeID, false)
    if ok and type(schematic) == "table" and schematic.reagentSlotSchematics then
      for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local first = slot.reagents and slot.reagents[1]
        if first and first.itemID then
          table.insert(reagents, { i = first.itemID, n = slot.quantityRequired })
        end
      end
      local output = schematic.outputItemID
      local minQ, maxQ = schematic.quantityMin, schematic.quantityMax
      return reagents, output, minQ, maxQ, "schematic"
    end
  end

  -- Shadowlands-style per-reagent functions.
  if api.GetRecipeNumReagents and api.GetRecipeReagentInfo then
    local ok, count = pcall(api.GetRecipeNumReagents, recipeID)
    if ok and count then
      for index = 1, count do
        local _, _, needed = api.GetRecipeReagentInfo(recipeID, index)
        local link = api.GetRecipeReagentItemLink and api.GetRecipeReagentItemLink(recipeID, index)
        table.insert(reagents, { i = itemIdFromLink(link), n = needed })
      end
    end
    local output = api.GetRecipeItemLink and itemIdFromLink(api.GetRecipeItemLink(recipeID))
    local minQ, maxQ
    if api.GetRecipeNumItemsProduced then
      minQ, maxQ = api.GetRecipeNumItemsProduced(recipeID)
    end
    return reagents, output, minQ, maxQ, "legacy"
  end

  return reagents, nil, nil, nil, "none"
end

function Recipes.Scan()
  local api = C_TradeSkillUI
  if not api or not api.GetAllRecipeIDs then return end
  if api.IsTradeSkillLinked and api.IsTradeSkillLinked() then return end
  if api.IsNPCCrafting and api.IsNPCCrafting() then return end

  local profName, rank, maxRank, profID = professionInfo()
  local scan = {
    t = time(),
    profession = profName,
    professionID = profID,
    rank = rank,
    max = maxRank,
    api = apiAvailability(),
    recipes = {},
  }

  for _, recipeID in ipairs(api.GetAllRecipeIDs() or {}) do
    local info = api.GetRecipeInfo and api.GetRecipeInfo(recipeID)
    if type(info) == "table" then
      local reagents, output, minQ, maxQ, source = readReagents(recipeID)
      scan.recipes[recipeID] = {
        name = info.name,
        learned = info.learned,
        fav = info.favorite or nil, -- the star in the profession window (Shop.lua)
        icon = info.icon, -- the recipe's icon (enchantments have no product to show)
        diff = info.relativeDifficulty,
        ups = info.numSkillUps,
        cat = info.categoryID,
        skill = info.skillLineAbilityID,
        out = output,
        qmin = minQ,
        qmax = maxQ,
        src = source,
        r = reagents,
        -- Raw difficulty-related fields, in case Forever uses classic-style values.
        raw = {
          difficulty = info.difficulty,
          craftable = info.craftable,
          disabled = info.disabled,
          type = info.type,
        },
      }
    end
  end

  -- The window can report an empty name while it is still loading: no scan without one.
  if type(profName) == "string" and profName ~= "" then
    ns.db.recipes = ns.db.recipes or {}
    ns.db.recipes[ns.CharKey() .. ":" .. profName] = scan
    Recipes.SnapshotPrices(scan)
    -- the skill may have changed (a skill-up while crafting): windows that plan follow
    for _, fn in ipairs(Recipes.listeners) do ns.Safe(fn, scan) end
  end
end

-- fn(scan) after every stored scan (PlanWindow: plan from the new skill).
Recipes.listeners = {}
function Recipes.OnScanned(fn) table.insert(Recipes.listeners, fn) end

-- Stores current auction and vendor-sell prices for every reagent and product,
-- so the path planner can also run outside the game.
function Recipes.SnapshotPrices(scan)
  ns.db.prices = ns.db.prices or {}
  local now = time()
  local function store(itemID)
    if not itemID then return end
    ns.db.prices[itemID] = {
      n = ns.ItemName(itemID),
      ah = ns.Item(itemID).now,
      vs = ns.Item(itemID).vendorSell,
      t = now,
    }
  end
  for _, recipe in pairs(scan.recipes) do
    store(recipe.out)
    for _, reagent in ipairs(recipe.r or {}) do
      store(reagent.i)
    end
  end
end

local pending = false
local function scheduleScan()
  if pending then return end
  pending = true
  C_Timer.After(SCAN_DELAY, function()
    pending = false
    ns.Safe(Recipes.Scan)
  end)
end

ns.On("TRADE_SKILL_SHOW", scheduleScan)
ns.On("TRADE_SKILL_LIST_UPDATE", scheduleScan)

-- Scans stored without a profession name ("Name-Realm:") by older versions are dropped:
-- the cloud sync rejects them, and the next scan of the window stores the named one.
if ns.OnReady then
  ns.OnReady(function()
    for key in pairs(ns.db.recipes or {}) do
      if type(key) == "string" and key:sub(-1) == ":" then ns.db.recipes[key] = nil end
    end
  end)
end
