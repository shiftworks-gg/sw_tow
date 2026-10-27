---Cargo on company trucks. The worker's client animates the winch or the hook; the server decides
---whether a vehicle may be loaded and keeps the record of what each truck carries.
---
---State bags on the truck (replicated):
---  sw_tow:cargo = netId of the loaded vehicle
---  sw_tow:winch = { target = netId, phase = 'pulling'|'secured'|'lowering' } (flatbed only)
---State bag on the cargo: sw_tow:towedBy = netId of the truck
local config = require 'config'
local framework = require 'bridge.loader'
local guard = require 'server.guard'
local log = require 'server.log'
local shift = require 'server.shift'
local calls = require 'server.calls'

local tow = {}

---@class SwCargo
---@field target integer entity
---@field method 'flatbed'|'hook'
---@field secured boolean
---@field lowering boolean? the worker is unloading it; inside a yard that hands it over
---@field pickup vector3
---@field pickedAt integer os.time()

---@type table<integer, SwCargo> truck entity -> cargo
local cargo = {}

---@param truck integer
---@return SwCargo?
function tow.get(truck)
    local record = cargo[truck]
    if record and not DoesEntityExist(record.target) then
        tow.clear(truck)
        return
    end
    return record
end

---@param truck integer
function tow.clear(truck)
    local record = cargo[truck]
    cargo[truck] = nil
    if DoesEntityExist(truck) then
        local state = Entity(truck).state
        state:set('sw_tow:cargo', nil, true)
        state:set('sw_tow:winch', nil, true)
    end
    if record and DoesEntityExist(record.target) then
        Entity(record.target).state:set('sw_tow:towedBy', nil, true)
    end
end

---The worker's own company truck, if they are close to it.
---@param src integer
---@param truckNet any
---@return integer? truck, SwShift? current
local function ownTruck(src, truckNet)
    local current = shift.get(src)
    local truck = guard.vehicle(truckNet)
    if not current or not truck or current.truck ~= truck then return end
    -- With the ramps down the vehicle (and the worker next to it) can stand some 25 m from the
    -- truck's centre: 10 m of winch range behind 6 m of ramps behind half a truck.
    if not guard.near(src, GetEntityCoords(truck), 35.0) then return end
    return truck, current
end

---Unknown classes (addon models the framework has no data for) are allowed.
---@return boolean allowed, string? errorKey
local function classAllowed(src, vehicle)
    local class = framework.getVehicleClass(GetEntityModel(vehicle))
    if class == nil then return true end
    if config.blockedClasses[class] then return false, 'tow.not_towable' end
    -- Without this, an empty police car at a scene could be towed off and deleted as street clutter.
    if config.orderOnlyClasses[class] and not calls.acceptedFor(src, vehicle) then return false, 'tow.needs_order' end
    return true
end

lib.callback.register('sw_tow:server:attach', function(src, truckNet, targetNet)
    if not guard.rate(src, 'attach') then return false end
    local truck, current = ownTruck(src, truckNet)
    local target = guard.vehicle(targetNet)
    if not truck or not current or not target or target == truck then
        log.warn(src, 'attach', 'invalid truck or target')
        return false
    end
    if tow.get(truck) then return false, 'tow.already_loaded' end
    if Entity(target).state['sw_tow:towedBy'] or Entity(target).state['sw_tow:company'] then
        return false, 'tow.not_towable'
    end
    if not guard.isEmpty(target) then return false, 'tow.occupied' end
    local allowed, errorKey = classAllowed(src, target)
    if not allowed then return false, errorKey end

    local range = current.method == 'flatbed' and config.flatbed.winchRange + 22.0 or config.hook.range + 6.0
    if #(GetEntityCoords(target) - GetEntityCoords(truck)) > range then
        log.warn(src, 'attach', 'target too far from the truck')
        return false
    end

    cargo[truck] = {
        target = target,
        method = current.method,
        secured = current.method == 'hook',
        pickup = GetEntityCoords(target),
        pickedAt = os.time(),
    }
    local truckState = Entity(truck).state
    truckState:set('sw_tow:cargo', targetNet, true)
    if current.method == 'flatbed' then
        truckState:set('sw_tow:winch', { target = targetNet, phase = 'pulling' }, true)
    end
    Entity(target).state:set('sw_tow:towedBy', truckNet, true)
    log.info(src, 'attach', framework.getPlate(target))
    return true
end)

lib.callback.register('sw_tow:server:secured', function(src, truckNet)
    local truck = ownTruck(src, truckNet)
    local record = truck and tow.get(truck)
    if not truck or not record or record.method ~= 'flatbed' or record.secured then return false end
    if #(GetEntityCoords(record.target) - GetEntityCoords(truck)) > 6.0 then
        log.warn(src, 'secured', 'cargo is not on the bed')
        return false
    end
    record.secured = true
    record.lowering = nil
    Entity(truck).state:set('sw_tow:winch', { target = NetworkGetNetworkIdFromEntity(record.target), phase = 'secured' }, true)
    return true
end)

lib.callback.register('sw_tow:server:lowering', function(src, truckNet)
    local truck = ownTruck(src, truckNet)
    local record = truck and tow.get(truck)
    if not truck or not record then return false end
    if record.method == 'flatbed' then
        -- Not secured while it comes down: no delivery mid-unload, and it can be strapped again if
        -- it does not come down.
        record.secured = false
        record.lowering = true
        Entity(truck).state:set('sw_tow:winch', { target = NetworkGetNetworkIdFromEntity(record.target), phase = 'lowering' }, true)
    end
    return true
end)

---Flatbed ramps up or down. Every client builds its own ramps from the state bag.
lib.callback.register('sw_tow:server:ramps', function(src, truckNet, down)
    if not guard.rate(src, 'ramps') then return false end
    local truck = ownTruck(src, truckNet)
    if not truck or Entity(truck).state['sw_tow:method'] ~= 'flatbed' then return false end
    Entity(truck).state:set('sw_tow:ramps', down == true or nil, true)
    return true
end)

lib.callback.register('sw_tow:server:detach', function(src, truckNet)
    local truck = ownTruck(src, truckNet)
    if not truck or not cargo[truck] then return false end
    tow.clear(truck)
    return true
end)

shift.onEnd(function(src)
    local current = shift.get(src)
    if current and current.truck then tow.clear(current.truck) end
end)

AddEventHandler('entityRemoved', function(entity)
    if cargo[entity] then
        tow.clear(entity)
        return
    end
    for truck, record in pairs(cargo) do
        if record.target == entity then
            tow.clear(truck)
            return
        end
    end
end)

return tow
