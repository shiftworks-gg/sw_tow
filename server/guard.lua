---Checks shared by every server action: rate limits, distances and entity validation.
---The client only sends intentions; nothing it sends is trusted without these checks.
local config = require 'config'
local util = require 'shared.util'

local guard = {}
local lastAction = {}

---False when the player repeats an action faster than config.limits allows. Callers answer with
---'common.wait', so the player reads "try again in a moment" instead of a generic failure.
---@param src integer
---@param action string
---@return boolean
function guard.rate(src, action)
    local now = GetGameTimer()
    local limit = config.limits[action] or config.limits.default
    local actions = lastAction[src]
    if not actions then
        actions = {}
        lastAction[src] = actions
    end
    if actions[action] and now - actions[action] < limit then return false end
    actions[action] = now
    return true
end

---@param src integer
function guard.forget(src)
    lastAction[src] = nil
end

---@param src integer
---@return vector3?
function guard.coords(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return end
    return GetEntityCoords(ped)
end

---@param src integer
---@param point vector3
---@param maxDistance number
---@return boolean
function guard.near(src, point, maxDistance)
    local coords = guard.coords(src)
    return coords ~= nil and #(coords - point) <= maxDistance
end

---Resolves a network id sent by a client to an existing vehicle.
---@param netId any
---@return integer?
function guard.vehicle(netId)
    if not util.isInteger(netId) then return end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return end
    return entity
end

---@param vehicle integer
---@return boolean
function guard.isEmpty(vehicle)
    for seat = -1, 15 do
        if GetPedInVehicleSeat(vehicle, seat) ~= 0 then return false end
    end
    return true
end

---Players (server ids) sitting in a vehicle.
---@param vehicle integer
---@return integer[]
function guard.occupants(vehicle)
    local players = {}
    for seat = -1, 15 do
        local ped = GetPedInVehicleSeat(vehicle, seat)
        if ped ~= 0 and IsPedAPlayer(ped) then
            players[#players + 1] = NetworkGetEntityOwner(ped)
        end
    end
    return players
end

---Spots handed out but not filled yet: a vehicle is spawning there. Spawning waits for the game,
---so two players asking at the same moment would both see the spot empty without this.
---@type table<string, boolean>
local reservedSpots = {}

---Nothing parked within 3 m and nobody standing within 2 m.
---@param coords vector3
---@return boolean
function guard.spotClear(coords)
    if lib.getClosestVehicle(coords, 3.0, true) then return false end
    local peds = GetAllPeds()
    for i = 1, #peds do
        if #(GetEntityCoords(peds[i]) - coords) < 2.0 then return false end
    end
    return true
end

---Takes the first clear spot of a list and holds it until `release` is called (after the vehicle
---exists, or the spawn failed).
---@param group string what the spots are for, e.g. 'trucks' or 'release:davis'
---@param spots vector4[]
---@return vector4? spot, fun()? release
function guard.takeSpot(group, spots)
    for i, spot in ipairs(spots) do
        local key = group .. ':' .. i
        if not reservedSpots[key] and guard.spotClear(spot.xyz) then
            reservedSpots[key] = true
            return spot, function() reservedSpots[key] = nil end
        end
    end
end

return guard
