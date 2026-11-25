-- Planner: cheapest expected path from one skill level to another.
-- Pure logic without game API calls, so it also runs outside the game (tools/plan.lua).
--
-- Model
--   chance(skill)  orange 1, yellow/green (grey - skill) / (grey - yellow), grey 0
--   net(recipe)    reagent cost - resale value of the product (negative = profit)
--   segment        using one recipe from skill a to b costs
--                  learnCost + sum over s in [a, b) of net / chance(s)
--   path           dynamic programming over skill levels picks the cheapest
--                  chain of segments from `from` to `to`.
local ADDON, ns = ...

local Planner = {}
ns.Planner = Planner

-- Skill-up chance at the given skill; colors = { orange, yellow, green, grey }.
function Planner.Chance(colors, skill)
  local yellow, grey = colors[2], colors[4]
  if skill >= grey then return 0 end
  if skill < yellow then return 1 end
  if grey == yellow then return 0 end
  return (grey - skill) / (grey - yellow)
end

-- Recipes that need a profession specialization (Data_Skill.lua marks them with `spec`;
-- this list covers the older leatherworking data); left out of plans unless learned.
Planner.SPECIALIZATION = {
  [10650] = true, [10619] = true, [10630] = true, [10632] = true, [10621] = true,
}
-- Trainer recipes learned at 200 or later are taught by the Artisan (Fachmann) trainer.
Planner.ARTISAN_FROM = 200
Planner.MAX_SKILL = 300

-- Classic ranks: the cap each one lifts the skill to and the character level it needs.
-- Reaching a cap, the next rank has to be learned at the trainer before skill goes on.
Planner.RANKS = {
  { cap = 75, name = "Lehrling", level = 5 },
  { cap = 150, name = "Geselle", level = 10 },
  { cap = 225, name = "Experte", level = 20 },
  { cap = 300, name = "Fachmann", level = 35 },
}

-- The rank that has to be learned at `cap` (to go beyond it), or nil at the end.
function Planner.NextRank(cap)
  for _, rank in ipairs(Planner.RANKS) do
    if rank.cap > cap then return rank end
  end
end

-- Source codes of a recipe ("2+16"): exact codes, so "16" is not "6".
--   2 drop, 4 quest, 5 vendor, 6 trainer, ...
local function hasSource(source, code)
  if type(source) ~= "string" then return false end
  for part in source:gmatch("[^+]+") do
    if part == code then return true end
  end
  return false
end

-- Reputation standings by their German names (standingID 1..8).
Planner.STANDING = { ["Hasserfüllt"] = 1, ["Feindselig"] = 2, ["Unfreundlich"] = 3, ["Neutral"] = 4,
  ["Freundlich"] = 5, ["Wohlwollend"] = 6, ["Respektvoll"] = 7, ["Ehrfürchtig"] = 8 }

-- The two ways of the skill planner.
--   standard  only what is certain and available right away: recipes already learned,
--             trainers, vendors with an unlimited offer and no reputation/favor condition
--   dynamic   additionally limited vendor patterns, reputation vendors (when the character
--             has the standing), Merchant's Favor patterns (when there is enough favor) and
--             tradeable patterns on offer at the auction house right now ("Gelegenheit")
-- Random drops are never part of a way.
Planner.WAYS = { standard = true, dynamic = true }

-- A pattern counts as an auction house opportunity only if its offer is not far above
-- its usual price (one overpriced listing is no opportunity).
Planner.AH_PATTERN_OVER_REF = 1.5

-- Character context for the ways: { faction = "A"/"H", level, favor (Merchant's Favor,
-- nil if unknown), standing(factionName) -> standingID or nil (unknown) }.
local function factionOk(f, ctx)
  return f == nil or f == "B" or not (ctx and ctx.faction) or f == ctx.faction
end

-- Acquisition options of one recipe from its RecipeSources entry: list of
--   { way = "vendor"/"limited"/"rep"/"favor"/"ah"/"cond"/"unknown", cost (copper), npc,
--     classic, stock, favor, rep = { faction, standing }, level, note,
--     usable (the character can use it now, in the dynamic way), standard (also in the
--     standard way), why (text when not usable) }
-- Options of the other faction are left out.
function Planner.Options(entry, npcs, ctx, patternPrice)
  local list = {}
  if not entry then return list end
  ctx = ctx or {}
  for _, s in ipairs(entry) do
    local npc = s[2] and s[2] > 0 and npcs and npcs[s[2]] or nil
    if factionOk(npc and npc[5], ctx) then
      local o = { way = s[1], cost = s[3] or 0, npc = npc, classic = s.c == 1, stock = s.stock, favor = s.favor,
        rep = s.rf and { faction = s.rf, standing = s.rs } or nil, level = s.lv, note = s.note }
      local why
      if o.level and ctx.level and ctx.level < o.level then
        why = "ab Charakterstufe " .. o.level
      end
      if o.rep and not why then
        local have = ctx.standing and ctx.standing(o.rep.faction)
        local need = Planner.STANDING[o.rep.standing] or 8
        if not have then
          why = "Ruf " .. o.rep.faction .. " " .. o.rep.standing .. " nötig (Stand unbekannt)"
        elseif have < need then
          why = "Ruf " .. o.rep.faction .. " " .. o.rep.standing .. " nötig"
        end
      end
      if o.way == "favor" and not why then
        if not ctx.favor then
          why = o.favor .. " Händlergunst nötig (Stand unbekannt)"
        elseif ctx.favor < (o.favor or 0) then
          why = string.format("%d Händlergunst nötig (du hast %d)", o.favor or 0, ctx.favor)
        end
      end
      if o.way == "cond" then why = o.note or "Bedingung" end
      if o.way == "unknown" or not npc then why = why or "Händler nicht bekannt" end
      o.why = why
      o.usable = why == nil and o.way ~= "unknown" and o.way ~= "cond"
      o.standard = o.usable and o.way == "vendor"
      table.insert(list, o)
    end
  end
  -- A tradeable pattern on offer at the auction house right now.
  local price = entry.item and patternPrice and patternPrice(entry.item)
  if price then
    table.insert(list, { way = "ah", cost = price, item = entry.item, usable = true, standard = false })
  end
  return list
end

-- Cheapest option the way allows, or nil.
local function bestOption(options, way)
  local best
  for _, o in ipairs(options) do
    if (way == "standard" and o.standard) or (way == "dynamic" and o.usable) then
      if not best or o.cost < best.cost or (o.cost == best.cost and o.standard and not best.standard) then
        best = o
      end
    end
  end
  return best
end
Planner.BestOption = bestOption

-- How a recipe is learned in a way, or nil: { way = "learned"/"trainer"/<option way>,
-- cost, option, rank }.
--   d          color/learn data (Data_Skill)
--   src        RecipeSources entry or nil; srcs the profession's RecipeSources or nil
function Planner.Acquire(recipe, d, src, srcs, way, ctx, patternPrice)
  if recipe.learned then return { way = "learned", cost = 0 } end
  local startRecipe = (d[7] == nil or d[7] == "") and (d[1] or 99) <= 1 and (d[5] or 0) <= 75
  if hasSource(d[7], "6") or startRecipe or (src and src.t) then
    return { way = "trainer", cost = d[6] or 0, rank = src and src.rank, start = startRecipe or (src and src.auto == 1) }
  end
  if not srcs then return nil end  -- no source data: only learned and trainer recipes
  local option = bestOption(Planner.Options(src, srcs.npcs, ctx, patternPrice), way)
  if option then return { way = option.way, cost = option.cost, option = option } end
end

-- Recipes with a cooldown of days besides the transmutations (spell ID -> German name).
Planner.COOLDOWN = {
  [18560] = "Mondstoff", -- Tailoring, several days
}
local cooldownNames = {} -- name -> spell ID (recipe scans are not keyed by spell ID)
for spellID, name in pairs(Planner.COOLDOWN) do cooldownNames[name] = spellID end

local function cooldownRecipe(recipe, recipeID)
  -- Transmutations (Forever: 1 hour, Arcanite ~2 days) and Mooncloth (several days) have a
  -- cooldown: they cannot be crafted dozens of times in a row, so they are no way to raise
  -- the skill. Planner.Cooldowns lists them as "on the side, whenever it is ready".
  if recipeID and Planner.COOLDOWN[recipeID] then return true end
  local name = recipe.name
  return name ~= nil and (cooldownNames[name] ~= nil or name:find("^Transmutieren") ~= nil) or false
end

-- Cooldown recipes that give points somewhere between `from` and `to`: worth crafting
-- whenever the cooldown is ready, but not part of the way. Only Planner.COOLDOWN: the many
-- transmutations would crowd the plan (they stay left out of the way, as before).
-- { id, spell (spell ID, for its cooldown), name, out, reagents, learned, learnAt, upTo (grey
-- from) }... sorted by learn level.
function Planner.Cooldowns(scanRecipes, data, from, to)
  local list = {}
  for recipeID, recipe in pairs(scanRecipes or {}) do
    local d = data[recipeID]
    local spell = Planner.COOLDOWN[recipeID] and recipeID or cooldownNames[recipe.name or ""]
    if d and spell and (d[4] or 0) > from and (d[5] or d[1] or 0) < to then
      table.insert(list, { id = recipeID, spell = spell, name = recipe.name, out = recipe.out, reagents = recipe.r,
        learned = recipe.learned and true or false, learnAt = d[5] or d[1] or 0, upTo = d[4] })
    end
  end
  table.sort(list, function(a, b)
    if a.learnAt ~= b.learnAt then return a.learnAt < b.learnAt end
    return a.id < b.id
  end)
  return list
end

-- Text for one cooldown recipe (Planner.Cooldowns), for the planner views.
function Planner.CooldownText(c)
  -- short: the plan window's info lines do not wrap
  if not c.learned then
    return string.format("%s ab %d lernen, dann wenn bereit (Abklingzeit, bis %d)", c.name or "?", c.learnAt, c.upTo or 0)
  end
  return string.format("%s, sobald bereit (Abklingzeit, Punkte bis %d)", c.name or "?", c.upTo or 0)
end

-- Builds the list of candidate recipes.
--   scanRecipes   recipes as stored by Recipes.Scan
--   data          color/learn table (ns.Data.Leatherworking)
--   buyCost(id)   copper per unit to obtain a reagent, or nil if unknown
--   vendorSell(id) copper per unit a merchant pays for the product (0 if none)
--   ahSell(id)    copper per unit after auction cut, or nil if no auction price
--   opts          true: every recipe (profit views); nil: learned and trainer recipes;
--                 or a table { way = "standard"/"dynamic", sources = RecipeSources of the
--                 profession (nil: learned and trainer only), ctx = character context,
--                 patternPrice(itemID) = copper of a pattern on offer now or nil,
--                 rank = current skill (learned recipes count from their learn level up
--                 to it) }
-- Reagents the profession makes itself from cheaper material (leather from scraps) are
-- costed as crafted: candidate.made[itemID] = maker candidate; Planner.Shopping expands them.
function Planner.Candidates(scanRecipes, data, buyCost, vendorSell, ahSell, opts)
  local all = opts == true
  if type(opts) ~= "table" then opts = {} end
  local way = opts.way or "standard"
  local srcs = opts.sources
  local list, skipped = {}, {}
  -- Eligible recipes with how they are learned.
  local eligible = {}
  for recipeID, recipe in pairs(scanRecipes) do
    local d = data[recipeID]
    local special = d and (Planner.SPECIALIZATION[recipeID] or d.spec) and not recipe.learned and not all
    if d and (recipe.out or recipe.noOutput) and not special and not cooldownRecipe(recipe, recipeID) then
      local how
      if all then
        how = Planner.Acquire(recipe, d, srcs and srcs.recipes[recipeID], srcs, "dynamic", opts.ctx, opts.patternPrice)
          or { way = "pattern", cost = d[6] or 0 }
      else
        how = Planner.Acquire(recipe, d, srcs and srcs.recipes[recipeID], srcs, way, opts.ctx, opts.patternPrice)
      end
      if how then
        local learnAt = d[5] or d[1] or 0
        -- Start recipes (orange from 0) come with the profession; their d[5] is no learn level.
        if how.start or ((d[1] or 99) <= 1 and (d[5] or 0) <= 75) then learnAt = 0 end
        if recipe.learned then learnAt = math.min(learnAt, opts.rank or 0) end
        eligible[recipeID] = { recipe = recipe, d = d, how = how, learnAt = learnAt }
      end
    end
  end
  -- Makers of intermediate products: cheapest eligible recipe per product.
  local makers = {}
  for recipeID, e in pairs(eligible) do
    local out = e.recipe.out
    if out and #(e.recipe.r or {}) > 0 and e.how.way ~= "ah" then
      local m = makers[out]
      if not m or e.learnAt < m.learnAt then makers[out] = { id = recipeID, e = e, learnAt = e.learnAt } end
    end
  end
  local makeCost = {}
  local function unitCost(itemID, atSkill, depth)
    local buy = buyCost(itemID)
    local m = makers[itemID]
    if m and depth < 3 and m.learnAt <= atSkill then
      local cost = 0
      for _, reagent in ipairs(m.e.recipe.r or {}) do
        local u = reagent.i and unitCost(reagent.i, atSkill, depth + 1)
        if not u then cost = nil; break end
        cost = cost + u * (reagent.n or 1)
      end
      if cost then
        local qty = ((m.e.recipe.qmin or 1) + (m.e.recipe.qmax or m.e.recipe.qmin or 1)) / 2
        cost = cost / qty
        if not buy or cost < buy then
          makeCost[itemID] = m
          return cost, m
        end
      end
    end
    return buy
  end

  for recipeID, e in pairs(eligible) do
    local recipe, d, how = e.recipe, e.d, e.how
    local cost, missing, made = 0, nil, nil
    for _, reagent in ipairs(recipe.r or {}) do
      local unit, maker = nil, nil
      if reagent.i then unit, maker = unitCost(reagent.i, e.learnAt, 0) end
      if not unit then
        missing = reagent.i
        break
      end
      if maker and maker.id ~= recipeID then
        made = made or {}
        made[reagent.i] = maker.id
      end
      cost = cost + unit * (reagent.n or 1)
    end
    if missing then
      table.insert(skipped, { id = recipeID, name = recipe.name, missing = missing })
    else
      local produced = ((recipe.qmin or 1) + (recipe.qmax or recipe.qmin or 1)) / 2
      local vendorValue = recipe.out and (vendorSell(recipe.out) or 0) * produced or 0
      local auction = recipe.out and ahSell(recipe.out) or nil
      local ahValue = math.max(vendorValue, (auction or 0) * produced)
      local trainer = how.way == "trainer"
      table.insert(list, {
        id = recipeID,
        name = recipe.name,
        learned = recipe.learned and true or false,
        learnAt = e.learnAt,
        artisan = trainer and (d[5] or d[1] or 0) >= Planner.ARTISAN_FROM or nil,
        learnCost = how.cost or 0,
        how = how,
        colors = { d[1], d[2], d[3], d[4] },
        cost = cost,
        vendorValue = vendorValue,
        ahValue = ahValue,
        hasAuction = auction ~= nil,
        needsPattern = not recipe.learned and not trainer,
        source = d[7],
        reagents = recipe.r,
        made = made,
        out = recipe.out,
        qty = produced,
      })
    end
  end
  -- Maker links point at candidate tables (for the shopping list).
  local byID = {}
  for _, c in ipairs(list) do byID[c.id] = c end
  for _, c in ipairs(list) do
    if c.made then
      for itemID, makerID in pairs(c.made) do c.made[itemID] = byID[makerID] end
    end
  end
  return list, skipped
end

-- Recipes that are not part of a way but would give points at `skill`: what is missing to
-- use them (the honest list where a way ends). { name, id, learnAt, colors, options }...
-- sorted by learn level. Drop- and quest-only recipes carry drop/quest flags.
function Planner.Missing(scanRecipes, data, srcs, ctx, skill, way, patternPrice)
  local list = {}
  if not srcs then return list end
  for recipeID, recipe in pairs(scanRecipes) do
    local d = data[recipeID]
    if d and (recipe.out or recipe.noOutput) and not recipe.learned and not cooldownRecipe(recipe, recipeID)
        and not (Planner.SPECIALIZATION[recipeID] or d.spec)
        and (d[5] or d[1] or 0) <= skill and (d[4] or 0) > skill then
      local src = srcs.recipes[recipeID]
      if not Planner.Acquire(recipe, d, src, srcs, way, ctx, patternPrice) then
        table.insert(list, { id = recipeID, name = recipe.name, learnAt = d[5] or d[1], colors = { d[1], d[2], d[3], d[4] },
          options = Planner.Options(src, srcs.npcs, ctx, patternPrice), drop = src and src.d == 1,
          quest = src and src.q })
      end
    end
  end
  -- Most useful first: a vendor usable in the dynamic way, then an auction house offer,
  -- then a vendor with a condition, then the rest (quests, drops); within that the one that
  -- stays skill-giving longest.
  local function score(m)
    local best = 0
    for _, o in ipairs(m.options) do
      if o.usable then best = math.max(best, o.way == "ah" and 3 or 4)
      elseif o.npc then best = math.max(best, 2) end
    end
    if best == 0 and m.quest then best = 1 end
    return best
  end
  for _, m in ipairs(list) do m.score = score(m) end
  table.sort(list, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.colors[4] ~= b.colors[4] then return a.colors[4] > b.colors[4] end
    if a.learnAt ~= b.learnAt then return a.learnAt > b.learnAt end
    return a.id < b.id
  end)
  return list
end

-- Trainer of a rank for the character's faction: { rank, skill, level, npc, zone, x, y, faction } or nil.
function Planner.Trainer(srcs, rankName, faction)
  for _, t in ipairs(srcs and srcs.trainers or {}) do
    if t[1] == rankName and (t[8] == "B" or not faction or t[8] == faction) then
      return { rank = t[1], skill = t[2], level = t[3], npc = t[4], zone = t[5], x = t[6], y = t[7], faction = t[8] }
    end
  end
end

-- Rank whose trainer teaches recipes learned at `learnAt`.
function Planner.RankFor(learnAt)
  if learnAt >= Planner.ARTISAN_FROM then return Planner.RANKS[4] end
  if learnAt > 150 then return Planner.RANKS[3] end
  if learnAt > 75 then return Planner.RANKS[2] end
  return Planner.RANKS[1]
end

-- Recipes of a SkillData entry (ns.SkillData[professionID]) in the shape of a recipe
-- scan, so Planner.Candidates takes them with the entry's recipes as color/learn data:
--   Planner.Candidates(Planner.SkillRecipes(skill, scan), skill.recipes, ...)
-- Reagents, product and names come from SkillData; whether a recipe is learned from the
-- character's own scan (scan.recipes keyed by the same spell IDs), if there is one.
-- Recipes without a product (enchantments) are kept: they only cost material.
function Planner.SkillRecipes(skill, scan)
  local own = scan and scan.recipes or {}
  local list = {}
  for spellID, d in pairs(skill and skill.recipes or {}) do
    local reagents = {}
    local r = d.r or {}
    for i = 1, #r - 1, 2 do
      table.insert(reagents, { i = r[i], n = r[i + 1] })
    end
    local mine = own[spellID]
    list[spellID] = {
      name = d.name or (mine and mine.name) or ("Rezept " .. spellID),
      learned = mine and mine.learned or false,
      out = d.out,
      noOutput = d.out == nil and #reagents > 0 or nil,
      qmin = d.qty or 1,
      qmax = d.qty or 1,
      r = reagents,
    }
  end
  return list
end

-- Switching recipes costs effort (another trip, other material, another stack to sell):
-- each segment is charged SWITCH_BASE plus SWITCH_CRAFTS crafts of its material, and a
-- segment shorter than MIN_SEGMENT points twice that, so the path does not hop between
-- recipes for one or two points (guides use one recipe for 10-30 points). The charge
-- only steers the choice; costs shown are the real ones.
Planner.SWITCH_BASE = 1000
Planner.SWITCH_CRAFTS = 3
Planner.MIN_SEGMENT = 5
-- Time counts a little (decided 20 Nov 2026): every expected craft is charged CRAFT_CHARGE
-- copper in the choice, so a path with far fewer crafts wins when it costs only a bit more.
-- Steering only, like the switch charge; costs shown are the real ones.
Planner.CRAFT_CHARGE = 100
-- Buying for yellow/green points (the chance scatters a lot): BUFFER more crafts' material
-- (decided 20 Nov 2026). Orange points are exact. Costs stay the expected ones.
Planner.BUFFER = 0.15

-- Crafts to buy material for: the orange points exactly, the rest with the buffer.
function Planner.BufferedCrafts(seg)
  local colors = seg.recipe and seg.recipe.colors
  if not colors then return seg.crafts end
  local orange = 0
  for s = seg.from, seg.to - 1 do
    if Planner.Chance(colors, s) >= 1 then orange = orange + 1 end
  end
  return orange + math.max(0, seg.crafts - orange) * (1 + Planner.BUFFER)
end

-- Cheapest path from skill `from` to `to`.
--   ahCap  how many units of one product can be sold at the auction price;
--          everything beyond goes to a vendor (0 = vendor only).
--   opts   { switch = false } turns the switch charge off (tests)
-- Returns ordered segments:
--   { recipe, from, to, crafts, cost (net, incl. learning), spend (reagents), back (sales) },
-- the real total cost and the skill reached.
function Planner.Path(candidates, from, to, ahCap, opts)
  ahCap = ahCap or 0
  local switch = not (opts and opts.switch == false)
  local best, back = {}, {}
  -- Recipes already used on the best path to each skill level. Learning cost and
  -- the limited auction sales may only count once per recipe; without this the
  -- search splits one recipe into many short segments to collect them repeatedly.
  local used = {}
  best[from] = 0
  used[from] = {}
  for s = from, to - 1 do
    if best[s] then
      for _, c in ipairs(candidates) do
        if s >= c.learnAt then
          local firstUse = not used[s][c.id]
          local cap = firstUse and ahCap or 0
          local acc, crafts, spend, income = (firstUse and c.learnCost or 0), 0, 0, 0
          for t = s + 1, to do
            local p = Planner.Chance(c.colors, t - 1)
            if p <= 0 then break end
            local step = 1 / p
            local atAuction = math.max(0, math.min(step, cap - crafts))
            local value = atAuction * c.ahValue + (step - atAuction) * c.vendorValue
            crafts = crafts + step
            spend = spend + step * c.cost
            income = income + value
            acc = acc + step * c.cost - value
            local total = best[s] + acc
            if switch then
              local charge = Planner.SWITCH_BASE + Planner.SWITCH_CRAFTS * math.max(0, c.cost)
              if t - s < Planner.MIN_SEGMENT and t < to then charge = charge * 3 end
              total = total + charge + Planner.CRAFT_CHARGE * crafts
            end
            if best[t] == nil or total < best[t] then
              best[t] = total
              back[t] = { from = s, recipe = c, crafts = crafts, cost = acc, spend = spend, income = income,
                          learned = firstUse and c.learnCost or 0 }
              local set = {}
              for id in pairs(used[s]) do set[id] = true end
              set[c.id] = true
              used[t] = set
            end
          end
        end
      end
    end
  end
  -- Without a full path, stop at the highest skill that can be reached.
  if best[to] == nil then
    local reached
    for t = to - 1, from + 1, -1 do
      if best[t] then reached = t; break end
    end
    if not reached then return nil end
    to = reached
  end

  local segments, t = {}, to
  while t > from do
    local b = back[t]
    table.insert(segments, 1, {
      recipe = b.recipe, from = b.from, to = t, crafts = b.crafts,
      cost = b.cost, spend = b.spend, income = b.income, learned = b.learned,
    })
    t = b.from
  end

  -- Merge consecutive segments of the same recipe (learning is charged once).
  local merged = {}
  for _, seg in ipairs(segments) do
    local last = merged[#merged]
    if last and last.recipe == seg.recipe then
      last.to = seg.to
      last.crafts = last.crafts + seg.crafts
      last.cost = last.cost + seg.cost
      last.learned = last.learned + seg.learned
      last.spend = last.spend + seg.spend
      last.income = last.income + seg.income
    else
      table.insert(merged, seg)
    end
  end
  local total = 0
  for _, seg in ipairs(merged) do total = total + seg.cost end
  return merged, total, to
end

-- A path kept by the player (PlanWindow "Plan festhalten"): the same recipes and skill ranges
-- again, costed with today's candidates instead of searching a new path. pinned = { { id, from,
-- to }… }; skill below `from` is done (cut off). Returns segments (as Planner.Path), the total
-- and the skill reached (a recipe no longer among the candidates ends the path there).
function Planner.Replay(candidates, pinned, from)
  local byID = {}
  for _, c in ipairs(candidates) do byID[c.id] = c end
  local segments, total, reached, learnedOnce = {}, 0, from, {}
  for _, p in ipairs(pinned or {}) do
    local a, b = math.max(p.from, from), p.to
    if b > a then
      local c = byID[p.id]
      if not c or a ~= reached then break end
      local crafts = 0
      for t = a, b - 1 do
        local chance = Planner.Chance(c.colors, t)
        if chance <= 0 then b = t break end
        crafts = crafts + 1 / chance
      end
      if b <= a then break end
      local learned = learnedOnce[c.id] and 0 or (c.learnCost or 0)
      learnedOnce[c.id] = true
      local spend, income = crafts * c.cost, crafts * c.vendorValue
      local seg = { recipe = c, from = a, to = b, crafts = crafts, spend = spend, income = income, learned = learned,
        cost = spend - income + learned }
      segments[#segments + 1] = seg
      total, reached = total + seg.cost, b
    end
  end
  return segments, total, reached
end

-- Profit of one craft, for making gold rather than levelling.
--   safe       products go to a vendor
--   potential  products sell at the current auction price (after cut)
-- A recipe is flagged when either value clears the thresholds:
--   safe      any profit at all, because a vendor always buys
--   potential at least `minProfit` copper and `minMargin` of the material cost
function Planner.Profit(candidates, minProfit, minMargin)
  local rows = {}
  for _, c in ipairs(candidates) do
    local safe = c.vendorValue - c.cost
    local potential = c.ahValue - c.cost
    local margin = c.cost > 0 and potential / c.cost or math.huge
    table.insert(rows, {
      recipe = c,
      safe = safe,
      potential = potential,
      margin = margin,
      safeDeal = safe > 0,
      potentialDeal = c.hasAuction and potential >= minProfit and margin >= minMargin,
    })
  end
  table.sort(rows, function(a, b) return a.potential > b.potential end)
  return rows
end

-- Total reagents to buy/bring for a path (buffer: with Planner.BUFFER on yellow/green points):
-- { [itemID] = count }, and the intermediate
-- products made on the way: { [itemID] = { recipe = maker candidate, count, crafts } }.
-- Products of earlier segments are used up first (Feueröl from the oil segment goes into
-- the later elixirs); made reagents are expanded into their own material.
function Planner.Shopping(segments, buffer)
  local need, made, stock = {}, {}, {}
  local function add(c, crafts, depth)
    for _, reagent in ipairs(c.reagents or {}) do
      local count = reagent.n * crafts
      local fromStock = math.min(count, stock[reagent.i] or 0)
      if fromStock > 0 then
        stock[reagent.i] = stock[reagent.i] - fromStock
        count = count - fromStock
      end
      local maker = c.made and c.made[reagent.i]
      if count <= 0 then
        -- covered by earlier products
      elseif maker and depth < 3 then
        local m = made[reagent.i] or { recipe = maker, count = 0, crafts = 0 }
        made[reagent.i] = m
        local makerCrafts = math.ceil(count / (maker.qty or 1))
        m.count, m.crafts = m.count + count, m.crafts + makerCrafts
        add(maker, makerCrafts, depth + 1)
        local extra = makerCrafts * (maker.qty or 1) - count
        if extra > 0 then stock[reagent.i] = (stock[reagent.i] or 0) + extra end
      else
        need[reagent.i] = (need[reagent.i] or 0) + count
      end
    end
  end
  for _, seg in ipairs(segments) do
    -- buffer: material for the buffered crafts (Planner.BufferedCrafts), for buying
    local crafts = math.ceil(buffer and Planner.BufferedCrafts(seg) or seg.crafts)
    add(seg.recipe, crafts, 0)
    local out = seg.recipe.out
    if out then stock[out] = (stock[out] or 0) + math.floor(crafts * (seg.recipe.qty or 1)) end
  end
  return need, made
end

-- Path segments with the trainer visits in between, for display:
--   { rank = { at, name, cap, level } }  learn the next rank at skill `at`
--   { seg = segment }                    a segment of Planner.Path
-- `max` is the character's current skill cap (nil: not known, e.g. the profession is not
-- learned yet; then every cap from `from` on needs a visit).
function Planner.Steps(segments, from, max)
  local steps = {}
  local caps = {}
  for _, rank in ipairs(Planner.RANKS) do
    if rank.cap < Planner.MAX_SKILL and rank.cap >= from and (not max or rank.cap >= max) then
      table.insert(caps, rank.cap)
    end
  end
  local nextCap = 1
  local function notice(at)
    local rank = Planner.NextRank(at)
    table.insert(steps, { rank = { at = at, name = rank.name, cap = rank.cap, level = rank.level } })
  end
  for _, seg in ipairs(segments or {}) do
    -- A segment that goes beyond a cap (or starts right at it) needs the next rank first.
    while caps[nextCap] and seg.to > caps[nextCap] do
      notice(caps[nextCap])
      nextCap = nextCap + 1
    end
    table.insert(steps, { seg = seg })
  end
  return steps
end
