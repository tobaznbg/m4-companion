-- LiveChannel: what a player sees at the auction house reaches every other addon user of the
-- realm at once, over a hidden chat channel with addon messages - between the hourly cloud
-- snapshots and before the cloud merges the observations (Observations.lua, ns.AHObs).
--
-- Channel: CHANNEL_NAME, joined some seconds after login (after the game's own channels, so it
-- never takes their numbers), removed from every chat window, its notices filtered out. Any
-- failure stays silent: the player's chat is never touched beyond that.
--
-- Message (prefix PREFIX, at most MAX_MESSAGE bytes, one house per message):
--   "O|<house>|<t>|<entry>|<entry>..."
--   entry = "<itemID>,<m>,<q>,<n>,<d>[,<age>]"
--   house  cloud house id (Obs.OpenHouseID)       t  time() of the newest entry
--   m q n d  as in Observations.lua (cheapest per unit, units, offers, "price:units;..." up to 8)
--   age    seconds the entry is older than t (left out when 0)
--
-- Sending: every own observation (search: Obs.OnRecord, full scan: AuctionScan.OnDone) becomes a
-- candidate when it is newer than what the channel said about the item and differs noticeably
-- from the newest state everybody already has (m other, or q / n more than 10 % off). A candidate
-- waits a random 0-20 s; when someone else sends the same state (price within 1 %) or a newer
-- one meanwhile, it is dropped - one sender per observation. A full scan is broadcast at most
-- once per house every 10 minutes and only its FULLSCAN_MAX most relevant changes. The queue is
-- sent from a token bucket (1 message/s, burst 5), slower after the game throttles, never in
-- combat.
--
-- Receiving: strict validation (numbers, lengths, price levels, a house of the realm group,
-- t at most 2 h old and 5 min ahead, m within R/3..R*3), at most SENDER_ITEMS items per sender
-- every 10 minutes. Senders' names live only in this session's rate limit - never shown, never
-- saved. Accepted entries: ns.Live.items[house][itemID] = { t, m, q, n, d } (newest only, this
-- session), one more source of Item.Get (dataSource "live").
local ADDON, ns = ...

local Live = {}
ns.Live = Live

local CHANNEL_NAME = "m4cdata"
local PREFIX = "M4L1"
local MAX_MESSAGE = 250          -- SendAddonMessage takes 255 bytes; some room left
local MAX_ENTRIES = 20           -- entries per message
local JOIN_DELAY = 8             -- seconds after login before joining
local JOIN_TRIES = 5
local MAX_CHANNELS = 10          -- the game's limit of joined channels
local MAX_AGE = 2 * 3600         -- older entries are refused (and not sent)
local MAX_AHEAD = 5 * 60         -- entries from the future (clock skew) up to this
local DELAY_MAX = 20             -- random wait of a candidate, seconds
local SAME_PRICE = 0.01          -- "the same state" for suppression
local CHANGE = 0.10              -- q / n change that counts
local PLAUSIBLE = 3              -- m within R / 3 .. R * 3
local FULLSCAN_EVERY = 10 * 60   -- one full scan broadcast per house and client
local FULLSCAN_MAX = 400         -- items of one full scan broadcast
local QUEUE_MAX = 1000           -- items waiting to be sent
local RATE, BURST, RATE_MIN = 1, 5, 0.2 -- messages per second
local SENDER_WINDOW, SENDER_ITEMS = 10 * 60, 3000

Live.CHANNEL, Live.PREFIX = CHANNEL_NAME, PREFIX
Live.items = {}                  -- [house][itemID] = { t, m, q, n, d, recv }

local stats = { sentMsgs = 0, sentItems = 0, recvMsgs = 0, recvItems = 0, dropped = 0, droppedItems = 0,
  suppressed = 0, throttled = 0, failed = 0, errors = 0 }
local reasons = {}               -- reason -> count of refused messages / entries
local sent = {}                  -- [house][itemID] = { t, m, q, n }: what this client sent
local pending = {}               -- "house:item" -> { h, id, t, m, due, created }
local ready, readySet = {}, {}   -- send queue of { h, id }, in order
local senders = {}               -- sender -> { start, count } (session only, never saved)
local lastFull = {}              -- [house] = time() of the last full scan broadcast
local listeners = {}
local channelIndex, joinTries = nil, 0
local joinWaitUntil = 0          -- clock() until which joining waits for the game's channels
local tokens, rate = BURST, RATE

local function now() return time() end
local function clock() return GetTime and GetTime() or now() end
local function refuse(reason, n)
  reasons[reason] = (reasons[reason] or 0) + (n or 1)
end

-- Encoding --------------------------------------------------------------------------------

-- One entry of an observation { t, m, q, n, d } of itemID, age seconds older than the message.
local function entry(itemID, o, age)
  local text = string.format("%d,%d,%d,%d,%s", itemID, o.m, o.q or 0, o.n or 0, o.d or "")
  if age and age > 0 then text = text .. "," .. age end
  return text
end

-- A message of one house from a list { { id, o }... } (o = { t, m, q, n, d }); takes entries in
-- order while they fit and returns the message and how many it took (0: none fits). Price levels
-- of an entry that does not fit even alone are cut from the dear end.
function Live.Encode(house, list)
  local taken, newest = {}, nil
  local message
  for i, item in ipairs(list) do
    if i > MAX_ENTRIES then break end
    local t = math.max(newest or 0, item.o.t)
    local parts = {}
    for k, it in ipairs(taken) do parts[k] = entry(it.id, it.o, t - it.o.t) end
    local o = item.o
    local text = entry(item.id, o, t - o.t)
    local head = string.format("O|%d|%d|", house, t)
    local body = table.concat(parts, "|")
    local function size(e) return #head + #body + (body ~= "" and 1 or 0) + #e end
    if size(text) > MAX_MESSAGE and #taken == 0 then
      -- one entry alone too long (cannot happen with 8 levels of sane numbers): fewer levels
      local d = o.d or ""
      while size(text) > MAX_MESSAGE and d ~= "" do
        d = d:match("^(.*);[^;]*$") or ""
        o = { t = o.t, m = o.m, q = o.q, n = o.n, d = d }
        text = entry(item.id, o, t - o.t)
      end
      item = { id = item.id, o = o }
    end
    if size(text) > MAX_MESSAGE then break end
    taken[#taken + 1] = item
    newest = t
    message = head .. body .. (body ~= "" and "|" or "") .. text
  end
  return message, #taken
end

-- Price levels "p:u;p:u" of an entry with cheapest m, units q, offers n: at most 8, strictly
-- ascending, the first one m, together no more units than q and no more levels than offers.
local function validLevels(d, m, q, n)
  if d == "" then return true end
  if #d > 8 * 18 then return false end
  local count, prev, units = 0, nil, 0
  for part in (d .. ";"):gmatch("([^;]*);") do
    local p, u = part:match("^(%d+):(%d+)$")
    if not p or #p > 10 or #u > 7 then return false end
    p, u = tonumber(p), tonumber(u)
    if p <= 0 or (prev and p <= prev) or (not prev and p ~= m) then return false end
    prev, count, units = p, count + 1, units + u
    if count > 8 then return false end
  end
  return count <= n and units <= q
end

-- A message -> house, { { id, t, m, q, n, d }... }; nil and a reason when anything is off (the
-- whole message is refused then: a sender that writes one bad entry is not trusted with the rest).
function Live.Parse(text, at)
  if type(text) ~= "string" or #text > 255 then return nil, "length" end
  local house, t, rest = text:match("^O|(%d+)|(%d+)|(.+)$")
  if not house or #house > 6 or #t > 10 then return nil, "format" end
  house, t = tonumber(house), tonumber(t)
  at = at or now()
  local list, seen = {}, {}
  for part in (rest .. "|"):gmatch("([^|]*)|") do
    if #list >= MAX_ENTRIES then return nil, "format" end
    local id, m, q, n, d, tail = part:match("^(%d+),(%d+),(%d+),(%d+),([%d:;]*)(.*)$")
    if not id or #id > 7 or #m > 10 or #q > 7 or #n > 7 then return nil, "format" end
    local age = 0
    if tail ~= "" then
      local a = tail:match("^,(%d+)$")
      if not a or #a > 5 then return nil, "format" end
      age = tonumber(a)
    end
    id, m, q, n = tonumber(id), tonumber(m), tonumber(q), tonumber(n)
    local et = t - age
    if id <= 0 or m <= 0 or n <= 0 then return nil, "values" end
    if not validLevels(d, m, q, n) then return nil, "levels" end
    if at - et > MAX_AGE or et - at > MAX_AHEAD then return nil, "age" end
    if seen[id] then return nil, "format" end
    seen[id] = true
    list[#list + 1] = { id = id, t = et, m = m, q = q, n = n, d = d }
  end
  if #list == 0 then return nil, "format" end
  return house, list
end

-- Whether observation o differs noticeably from state b (both { m, q, n }).
function Live.Differs(o, b)
  if not b then return true end
  if o.m ~= b.m then return true end
  local function off(x, y)
    if not y then return x ~= nil end
    return math.abs((x or 0) - y) > CHANGE * math.max(y, 1)
  end
  return off(o.q, b.q) or off(o.n, b.n)
end

-- State ------------------------------------------------------------------------------------

function Live.Get(house, itemID)
  local h = house and Live.items[house]
  return h and h[itemID] or nil
end

-- Time of the newest live entry of a house, nil without.
function Live.NewestT(house)
  local best
  for _, e in pairs(house and Live.items[house] or {}) do
    if not best or e.t > best then best = e.t end
  end
  return best
end

-- fn() runs after live entries arrived, at most once a second.
function Live.OnUpdate(fn) table.insert(listeners, fn) end

local notifyAt, notifyPending = -10, false
local function notify()
  if notifyPending then return end
  notifyPending = true
  local wait = math.max(0, notifyAt + 1 - clock())
  C_Timer.After(wait, function()
    notifyPending = false
    notifyAt = clock()
    for _, fn in ipairs(listeners) do ns.Safe(fn) end
  end)
end

-- Cloud house ids the addon reads: the realm group's three houses and every house with data.
local function knownHouses()
  local known = {}
  local AH = ns.AuctionHouse
  for _, key in ipairs(AH and AH.KEYS or {}) do
    local id = tonumber(AH.CloudID(key))
    if id then known[id] = key end
  end
  for id in pairs(ns.AHData or {}) do
    if known[id] == nil then known[id] = false end
  end
  return known
end

-- The newest state everybody already has of the item: the channel, this client's own sends, the
-- players' observations of the cloud, the cloud snapshot. { t, m, q, n } or nil.
local function baseline(h, id)
  local best
  local function take(t, m, q, n)
    if type(t) == "number" and type(m) == "number" and (not best or t > best.t) then
      best = { t = t, m = m, q = q, n = n }
    end
  end
  local l = Live.Get(h, id)
  if l then take(l.t, l.m, l.q, l.n) end
  local s = sent[h] and sent[h][id]
  if s then take(s.t, s.m, s.q, s.n) end
  local p = ns.AHObs and type(ns.AHObs[h]) == "table" and type(ns.AHObs[h].items) == "table" and ns.AHObs[h].items[id]
  if type(p) == "table" then take(p[1], p[2], p[3], p[4]) end
  local c = ns.AHData and ns.AHData[h]
  local row = type(c) == "table" and type(c.items) == "table" and c.items[id]
  if type(row) == "table" and ns.Item and ns.Item.Epoch then take(ns.Item.Epoch(c.updated), row[1], row[8], row[7]) end
  return best
end

-- The own observation of the item (Observations.lua), nil without.
local function own(h, id)
  local items = ns.db and ns.db.obs and ns.db.obs[h]
  local o = items and items[id]
  return type(o) == "table" and type(o.t) == "number" and type(o.m) == "number" and o or nil
end

-- Whether the own observation o of the item is worth sending now: newer than what the channel
-- said and this client sent, not too old, noticeably different from what everybody has.
local function worth(h, id, o)
  if now() - o.t > MAX_AGE - 300 then return false end
  local l, s = Live.Get(h, id), sent[h] and sent[h][id]
  if (l and l.t >= o.t) or (s and s.t >= o.t) then return false end
  return Live.Differs(o, baseline(h, id))
end

-- Sending ----------------------------------------------------------------------------------

local function enqueue(h, id)
  local key = h .. ":" .. id
  if readySet[key] then return end
  if #ready >= QUEUE_MAX then
    local old = table.remove(ready, 1)
    readySet[old.h .. ":" .. old.id] = nil
    stats.droppedItems = stats.droppedItems + 1
  end
  ready[#ready + 1] = { h = h, id = id }
  readySet[key] = true
end

-- A candidate: waits DELAY_MAX at most, then goes to the queue unless someone was faster.
local function candidate(h, id)
  local o = own(h, id)
  if not (o and worth(h, id, o)) then return false end
  local key = h .. ":" .. id
  if pending[key] or readySet[key] then return true end
  pending[key] = { h = h, id = id, t = o.t, m = o.m, due = clock() + math.random() * DELAY_MAX, created = clock() }
  return true
end
Live.Candidate = candidate

-- Due candidates: dropped when the channel brought the same state (price within 1 %, heard
-- after the candidate was made) or a newer one, else queued.
local function promote()
  local t = clock()
  for key, c in pairs(pending) do
    if c.due <= t then
      pending[key] = nil
      local o = own(c.h, c.id)
      local l = Live.Get(c.h, c.id)
      local same = l and l.recv and l.recv >= c.created and o and math.abs(l.m - o.m) <= SAME_PRICE * o.m
      if not o or same or (l and l.t > o.t) or not worth(c.h, c.id, o) then
        stats.suppressed = stats.suppressed + 1
      else
        enqueue(c.h, c.id)
      end
    end
  end
end

local SAR = Enum and Enum.SendAddonMessageResult or {}

-- Sends one message from the head of the queue: the items of the first item's house that fit.
local function sendOne()
  local first = ready[1]
  if not first then return end
  local h = first.h
  local list, idx = {}, {}
  for i, r in ipairs(ready) do
    if r.h == h then
      local o = own(r.h, r.id)
      if o and now() - o.t <= MAX_AGE - 300 then
        list[#list + 1] = { id = r.id, o = { t = o.t, m = o.m, q = o.q, n = o.n, d = o.d } }
      end
      idx[#idx + 1] = i
      if #list >= MAX_ENTRIES then break end
    end
  end
  local message, count = Live.Encode(h, list)
  -- which queue positions are done: the stale ones and the sent ones (in list order)
  local done, used = {}, 0
  for _, i in ipairs(idx) do
    local r = ready[i]
    local o = own(r.h, r.id)
    local stale = not (o and now() - o.t <= MAX_AGE - 300)
    if stale then done[i] = true
    elseif used < count then done[i] = true; used = used + 1 end
  end
  local result
  if message then
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, "CHANNEL", channelIndex)
    result = ok and res or "error"
    if result == "error" then stats.errors = stats.errors + 1 end
  end
  local throttled = result == false or (SAR.AddonMessageThrottle and result == SAR.AddonMessageThrottle)
    or (SAR.ChannelThrottle and result == SAR.ChannelThrottle)
  if message and throttled then
    -- the game said slow down: keep the items, wait longer
    stats.throttled = stats.throttled + 1
    rate, tokens = math.max(RATE_MIN, rate * 0.5), 0
    for i in pairs(done) do
      local o = own(ready[i].h, ready[i].id)
      if o and now() - o.t <= MAX_AGE - 300 then done[i] = nil end
    end
  elseif message and (result == nil or result == true or result == SAR.Success or result == 0) then
    stats.sentMsgs, stats.sentItems = stats.sentMsgs + 1, stats.sentItems + count
    rate = math.min(RATE, rate + 0.05)
    sent[h] = sent[h] or {}
    for k = 1, count do
      local o = list[k].o
      sent[h][list[k].id] = { t = o.t, m = o.m, q = o.q, n = o.n }
    end
  elseif message then
    -- refused for another reason (channel gone, bad message): drop it, look at the channel
    stats.failed = stats.failed + 1
    if SAR.InvalidChannel and result == SAR.InvalidChannel then channelIndex = nil end
  end
  for i = #ready, 1, -1 do
    if done[i] then
      readySet[ready[i].h .. ":" .. ready[i].id] = nil
      table.remove(ready, i)
    end
  end
end

local function joined()
  local ok, id = pcall(GetChannelName, CHANNEL_NAME)
  id = ok and tonumber(id) or 0
  channelIndex = id > 0 and id or nil
  return channelIndex
end

local lastTick
local function tick()
  local t = clock()
  local dt = lastTick and (t - lastTick) or 0
  lastTick = t
  tokens = math.min(BURST, tokens + dt * rate)
  promote()
  if #ready == 0 or not channelIndex then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if tokens >= 1 then
    tokens = tokens - 1
    sendOne()
  end
end

-- Own observations ------------------------------------------------------------------------

-- A search the player saw (recorded = written to ns.db.obs).
local function onRecord(itemID, _, recorded)
  if not recorded then return end
  local h = ns.Obs and ns.Obs.OpenHouseID()
  if h then candidate(h, itemID) end
end

-- A finished full scan: its observations (s = 1, t = the scan's time) of every house that has a
-- fresh scan not broadcast yet; the FULLSCAN_MAX most relevant changes, day trading items first.
local function onScanDone()
  local AH = ns.AuctionHouse
  for _, key in ipairs(AH.KEYS) do
    local h = tonumber(AH.CloudID(key))
    local data = AH.Peek(key)
    local t = data and data.currentT
    local items = h and ns.db and ns.db.obs and ns.db.obs[h]
    if items and t and now() - t < 300 and (not lastFull[h] or now() - lastFull[h] >= FULLSCAN_EVERY) then
      lastFull[h] = now()
      local cloud = ns.AHData and ns.AHData[h]
      local pool = type(cloud) == "table" and type(cloud.rhythm) == "table" and cloud.rhythm or {}
      local list = {}
      for id, o in pairs(items) do
        if type(o) == "table" and o.s == ns.Obs.SCAN and o.t == t and type(o.m) == "number" and worth(h, id, o) then
          local b = baseline(h, id)
          local change = b and b.m and b.m > 0 and math.abs(o.m / b.m - 1) or 0
          list[#list + 1] = { id = id, pool = pool[id] and 1 or 0, change = change }
        end
      end
      table.sort(list, function(a, b)
        if a.pool ~= b.pool then return a.pool > b.pool end
        return a.change > b.change
      end)
      for i = 1, math.min(#list, FULLSCAN_MAX) do candidate(h, list[i].id) end
    end
  end
end

-- Receiving --------------------------------------------------------------------------------

local function isMe(sender)
  local me = UnitName and UnitName("player")
  if not me or type(sender) ~= "string" then return false end
  return sender == me or sender:match("^([^%-]+)") == me
end

-- The R of an item at a house (Item.Get on that house), nil without.
local function reference(key, id)
  if not (key and ns.Item and ns.AuctionHouse.WithView) then return nil end
  local ok, e = pcall(ns.AuctionHouse.WithView, key, ns.Item.Get, id)
  return ok and e and e.ref or nil
end

-- Whether a message came over our channel: the event names its number (localID) and name; a
-- client that names neither is trusted on the prefix.
local function ourChannel(localID, name)
  local index = joined()
  if type(localID) == "number" and localID > 0 and index and localID == index then return true end
  if type(name) == "string" and name ~= "" then return name:lower():find(CHANNEL_NAME, 1, true) ~= nil end
  return not (type(localID) == "number" and localID > 0)
end

-- Returns the number of accepted entries (nil and a reason when the message was refused).
function Live.Receive(text, sender, at)
  at = at or now()
  local house, list = Live.Parse(text, at)
  if not house then return nil, list end
  local known = knownHouses()
  if known[house] == nil then return nil, "house" end
  -- rate limit per sender (session only)
  local s = senders[sender]
  if not s or at - s.start >= SENDER_WINDOW then
    s = { start = at, count = 0 }
    senders[sender] = s
  end
  if s.count + #list > SENDER_ITEMS then return nil, "rate" end
  s.count = s.count + #list
  local key = known[house] or nil
  local items = Live.items[house] or {}
  local accepted = 0
  for _, e in ipairs(list) do
    local ref = reference(key, e.id)
    if ref and ref > 0 and (e.m < ref / PLAUSIBLE or e.m > ref * PLAUSIBLE) then
      refuse("plausible")
    else
      local old = items[e.id]
      if not old or e.t > old.t then
        items[e.id] = { t = e.t, m = e.m, q = e.q, n = e.n, d = e.d, recv = clock() }
        accepted = accepted + 1
      elseif e.t == old.t then
        old.recv = clock() -- the same state again: counts as heard for suppression
      end
    end
  end
  Live.items[house] = items
  return accepted
end

local function onAddon(_, prefix, text, distribution, sender, _, _, localID, name)
  if prefix ~= PREFIX or distribution ~= "CHANNEL" then return end
  if isMe(sender) or not ourChannel(localID, name) then return end
  local ok, accepted, reason = pcall(Live.Receive, text, sender or "?")
  stats.recvMsgs = stats.recvMsgs + 1
  if not ok then
    stats.errors, stats.lastError = stats.errors + 1, tostring(accepted)
  elseif not accepted then
    stats.dropped = stats.dropped + 1
    refuse(reason or "?")
  else
    stats.recvItems = stats.recvItems + accepted
    if accepted > 0 then notify() end
  end
end

-- Old entries and senders go (the cloud snapshot is newer by then anyway).
local function prune()
  local t = now()
  for house, items in pairs(Live.items) do
    for id, e in pairs(items) do
      if t - e.t > MAX_AGE then items[id] = nil end
    end
    if next(items) == nil then Live.items[house] = nil end
  end
  for name, s in pairs(senders) do
    if t - s.start >= SENDER_WINDOW then senders[name] = nil end
  end
end

-- Channel ----------------------------------------------------------------------------------

-- Out of every chat window: nothing of the channel is ever shown.
local function hide()
  local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
  if not remove then return end
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local f = _G["ChatFrame" .. i]
    if f then pcall(remove, f, CHANNEL_NAME) end
  end
end

-- Join/leave/owner notices and any text in the channel are filtered out.
local function filter(_, _, _, _, _, channelString, _, _, _, _, channelBaseName)
  for _, v in ipairs({ channelBaseName, channelString }) do
    if type(v) == "string" and v:lower():find(CHANNEL_NAME, 1, true) then return true end
  end
  return false
end

local function channelCount()
  local ok, list = pcall(function() return { GetChannelList() } end)
  return ok and math.floor(#list / 3) or 0
end

local function join()
  if joined() then hide() return end
  if joinTries >= JOIN_TRIES then return end
  -- the game's channels first (General has number 1), and a free slot
  local okG, general = pcall(GetChannelName, 1)
  if (not okG or (tonumber(general) or 0) == 0) and joinTries == 0 and clock() < joinWaitUntil then
    C_Timer.After(5, join)
    return
  end
  if channelCount() >= MAX_CHANNELS then return end
  joinTries = joinTries + 1
  local fn = JoinTemporaryChannel or JoinChannelByName
  if fn then pcall(fn, CHANNEL_NAME) end
  C_Timer.After(2, function()
    if joined() then hide() end
  end)
end

-- Status for "/m4 live" (counts only, no names).
function Live.Stats()
  local p = 0
  for _ in pairs(pending) do p = p + 1 end
  local r = {}
  for k, v in pairs(stats) do r[k] = v end
  r.joined, r.index, r.queue, r.pending, r.rate = joined() ~= nil, channelIndex, #ready, p, rate
  local houses, entries = 0, 0
  for _, items in pairs(Live.items) do
    houses = houses + 1
    for _ in pairs(items) do entries = entries + 1 end
  end
  r.houses, r.entries = houses, entries
  r.reasons = {}
  for k, v in pairs(reasons) do r.reasons[k] = v end
  r.combat = InCombatLockdown and InCombatLockdown() or false
  return r
end

-- Wiring ------------------------------------------------------------------------------------

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
if ChatFrame_AddMessageEventFilter then
  for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL",
      "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
    pcall(ChatFrame_AddMessageEventFilter, event, filter)
  end
end

if ns.On then
  ns.On("CHAT_MSG_ADDON", onAddon)
  local started = false
  ns.On("PLAYER_ENTERING_WORLD", function()
    if started then return end
    started = true
    joinWaitUntil = clock() + 60
    C_Timer.After(JOIN_DELAY, function() pcall(join) end)
    C_Timer.NewTicker(0.25, function()
      local ok, err = pcall(tick)
      if not ok then stats.errors, stats.lastError = stats.errors + 1, tostring(err) end
    end)
    -- kicked, left by hand, channel limit: look again now and then (JOIN_TRIES in all)
    C_Timer.NewTicker(60, function()
      pcall(function()
        if not joined() then join() end
        prune()
      end)
    end)
  end)
  -- a channel change (another addon, the player) may put it into a window again
  ns.On("CHANNEL_UI_UPDATE", function() if channelIndex then pcall(hide) end end)
end
if ns.Obs and ns.Obs.OnRecord then
  ns.Obs.OnRecord(function(...)
    local ok, err = pcall(onRecord, ...)
    if not ok then stats.errors, stats.lastError = stats.errors + 1, tostring(err) end
  end)
end
if ns.OnReady then
  ns.OnReady(function()
    if ns.AuctionScan and ns.AuctionScan.OnDone then
      ns.AuctionScan.OnDone(function()
        local ok, err = pcall(onScanDone)
        if not ok then stats.errors, stats.lastError = stats.errors + 1, tostring(err) end
      end)
    end
  end)
end
