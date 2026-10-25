---Abandoned vehicles: a vehicle a player drove, then left standing with nobody nearby for
---config.abandoned.minutes, becomes a call. Parked traffic the game spawns is never flagged,
---because only vehicles seen with a player at the wheel are tracked.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local util = require 'shared.util'
local shift = require 'server.shift'
local calls = require 'server.calls'

local cfg = config.abandoned

---@class SwTracked
---@field coords vector3
---@field since integer os.time() when it last moved or had a player nearby

---@type table<integer, SwTracked> entity -> tracking
local tracked = {}

local function playerPositions()
    local positions = {}
    for _, id in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(id)
        if ped ~= 0 then positions[#positions + 1] = GetEntityCoords(ped) end
    end
    return positions
end

local function playerNearby(coords, positions)
    for i = 1, #positions do
        if #(positions[i] - coords) <= cfg.playerRadius then return true end
    end
    return false
end

local function ignored(vehicle, coords)
    local state = Entity(vehicle).state
    if state['sw_tow:company'] or state['sw_tow:contract'] or state['sw_tow:towedBy'] then return true end
    for _, zone in ipairs(cfg.ignoreZones) do
        if util.inZone(coords, zone) then return true end
    end
    return false
end

local function isOwned(vehicle)
    return integrations.garage.getVehicleId(vehicle, framework.getPlate(vehicle)) ~= nil
end

---Tracking runs all the time (a vehicle driven before anyone clocked in still counts);
---calls are only created while someone is on shift.
local function scan()
    local now = os.time()
    local positions = playerPositions()
    local canCall = next(shift.all()) ~= nil
    local open = calls.count(function(call) return call.type == 'abandoned' end)

    for _, vehicle in ipairs(GetAllVehicles()) do
        local driver = GetPedInVehicleSeat(vehicle, -1)
        local coords = GetEntityCoords(vehicle)
        if driver ~= 0 and IsPedAPlayer(driver) then
            tracked[vehicle] = { coords = coords, since = now }
        else
            local entry = tracked[vehicle]
            if entry then
                if #(coords - entry.coords) > 3.0 or playerNearby(coords, positions) then
                    entry.coords, entry.since = coords, now
                elseif canCall and now - entry.since >= cfg.minutes * 60 and open < cfg.maxOpen
                    and not calls.hasVehicle(vehicle) and not ignored(vehicle, coords)
                    and (cfg.owned or not isOwned(vehicle)) then
                    calls.add({
                        type = 'abandoned',
                        plate = framework.getPlate(vehicle),
                        vehicle = vehicle,
                        coords = coords,
                        message = locale('abandoned.message', cfg.minutes),
                        payFactor = cfg.payFactor,
                    })
                    open = open + 1
                    tracked[vehicle] = nil
                end
            end
        end
    end

    for vehicle in pairs(tracked) do
        if not DoesEntityExist(vehicle) then tracked[vehicle] = nil end
    end
end

if cfg.enabled then
    CreateThread(function()
        while true do
            Wait(cfg.scanInterval * 1000)
            local ok, err = pcall(scan)
            if not ok then lib.print.error(err) end
        end
    end)
end
