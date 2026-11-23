-- Status: how current the data is, the same line everywhere (windows, minimap tooltip).
--   cloud   time of the collector's newest snapshot in the data file of the current
--           auction house (AuctionHouse.CloudData().updated)
--   scan    time of the own full scan of the current auction house (AuctionHouse.Peek().currentT)
local ADDON, ns = ...

local Status = {}
ns.Status = Status

Status.STALE = 2 * 3600   -- older than this: shown in orange

-- UTC "2026-11-17T09:18:56Z" -> epoch seconds.
local function epoch(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
  if not y then return nil end
  local now = time()
  local offset = now - time(date("!*t", now))
  return time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
    min = tonumber(mi), sec = tonumber(s), isdst = false }) + offset
end

local function ago(t)
  local m = math.floor((time() - t) / 60)
  if m < 60 then return string.format("vor %d Min.", math.max(0, m)) end
  local h = math.floor(m / 60)
  if h < 48 then return string.format("vor %d Std.", h) end
  return string.format("vor %d Tagen", math.floor(h / 24))
end

-- Times of the cloud data and the own scan (epoch seconds or nil).
function Status.Times()
  local house = ns.AuctionHouse.CloudData()
  local scan = ns.AuctionHouse.Peek()
  return house and epoch(house.updated), scan and scan.currentT
end

-- "Daten 14:18 (vor 23 Min.) · Scan 14:30"; orange when the newest is older than STALE.
function Status.Text()
  local cloud, scan = Status.Times()
  if not cloud and not scan then return "|cffffb547Keine Marktdaten|r" end
  local parts = {}
  if cloud then table.insert(parts, "Daten " .. date("%H:%M", cloud) .. " (" .. ago(cloud) .. ")") end
  if scan then table.insert(parts, "Scan " .. date("%H:%M", scan) .. " (" .. ns.AuctionHouse.Name() .. ")") end
  local newest = math.max(cloud or 0, scan or 0)
  local text = table.concat(parts, "  ·  ")
  if time() - newest > Status.STALE then text = "|cffffb547" .. text .. "|r" end
  return text
end
