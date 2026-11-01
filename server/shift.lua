---Shifts and company trucks. A shift is server state; the player's `sw_tow:shift` state bag mirrors
---it so clients can show the right options without asking the server.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local guard = require 'server.guard'
local log = require 'server.log'

local shift = {}

---@class SwShift
---@field citizenid string
---@field startedAt integer
---@field deliveries integer
---@field earned integer
---@field truck integer? entity
---@field method 'flatbed'|'hook'?

---@type table<integer, SwShift>
local shifts = {}
---@type table<integer, integer> truck entity -> worker src
local truckOwner = {}
local listeners = {}

---Called with the worker's src whenever a shift ends.
---@param cb fun(src: integer)
function shift.onEnd(cb)
    listeners[#listeners + 1] = cb
end

---@param src integer
---@return SwShift?
function shift.get(src)
    return shifts[src]
end

---@return table<integer, SwShift>
function shift.all()
    return shifts
end

---@param truck integer
---@return integer? src
function shift.ownerOfTruck(truck)
    return truckOwner[truck]
end

local function nearOffice(src)
    return guard.near(src, config.office.coords.xyz, 4.0)
end

local function hasJob(src)
    local job = framework.getJob(src)
    return job ~= nil and job.name == config.job
end

local function deleteTruck(src)
    local current = shifts[src]
    local truck = current and current.truck
    if not current or not truck then return end
    truckOwner[truck] = nil
    current.truck, current.method = nil, nil
    if DoesEntityExist(truck) then framework.deleteVehicle(truck) end
end

---@param src integer
---@param reason string
function shift.stop(src, reason)
    if not shifts[src] then return end
    for i = 1, #listeners do listeners[i](src) end
    deleteTruck(src)
    shifts[src] = nil
    Player(src).state:set('sw_tow:shift', false, true)
    log.info(src, 'shift_end', reason)
end

lib.callback.register('sw_tow:server:clockIn', function(src)
    if shifts[src] then return false end
    if not guard.rate(src, 'clock') then return false, 'common.wait' end
    if not hasJob(src) then return false, 'shift.wrong_job' end
    if not nearOffice(src) then
        log.warn(src, 'clock_in', 'not at the office')
        return false
    end
    local citizenid = framework.getCitizenId(src)
    if not citizenid then return false end

    shifts[src] = { citizenid = citizenid, startedAt = os.time(), deliveries = 0, earned = 0 }
    framework.setDuty(src, true)
    Player(src).state:set('sw_tow:shift', true, true)
    log.info(src, 'shift_start', framework.getName(src))
    return true
end)

lib.callback.register('sw_tow:server:clockOut', function(src)
    if not shifts[src] or not nearOffice(src) then return false end
    shift.stop(src, 'clocked out')
    framework.setDuty(src, false)
    return true
end)

local function freePlate()
    for _ = 1, 20 do
        local plate = ('%s%04d'):format(config.garage.platePrefix, math.random(0, 9999)):sub(1, 8)
        local taken = false
        local vehicles = GetAllVehicles()
        for i = 1, #vehicles do
            if framework.getPlate(vehicles[i]) == plate then taken = true break end
        end
        if not taken then return plate end
    end
end

lib.callback.register('sw_tow:server:takeTruck', function(src, index)
    local current = shifts[src]
    if not current then return false end
    if not guard.rate(src, 'takeTruck') then return false, 'common.wait' end
    local option = type(index) == 'number' and config.garage.vehicles[index]
    if not option then return false end
    if current.truck and DoesEntityExist(current.truck) then return false, 'garage.already_out' end
    if not nearOffice(src) then
        log.warn(src, 'take_truck', 'not at the office')
        return false
    end
    if lib.getClosestVehicle(config.garage.spawn.xyz, 3.0, true) then return false, 'garage.spot_busy' end

    local plate = freePlate()
    if not plate then return false end
    local ok, netId, truck = pcall(framework.spawnVehicle, option.model, config.garage.spawn, { plate = plate })
    if not ok or not truck or truck == 0 then
        log.warn(src, 'take_truck', ('spawn failed: %s'):format(tostring(netId)))
        return false
    end
    -- The worker may have left while the truck was spawning.
    if shifts[src] ~= current then
        framework.deleteVehicle(truck)
        return false
    end

    current.truck, current.method = truck, option.method
    truckOwner[truck] = src
    local state = Entity(truck).state
    state:set('sw_tow:company', current.citizenid, true)
    state:set('sw_tow:method', option.method, true)
    integrations.keys.give(src, truck)
    log.info(src, 'take_truck', ('%s %s'):format(option.model, plate))
    return true, netId
end)

lib.callback.register('sw_tow:server:returnTruck', function(src)
    local current = shifts[src]
    if not current or not current.truck or not DoesEntityExist(current.truck) then return false end
    if #(GetEntityCoords(current.truck) - config.garage.spawn.xyz) > config.garage.returnDistance then
        return false, 'garage.too_far'
    end
    if Entity(current.truck).state['sw_tow:cargo'] then return false, 'garage.has_cargo' end
    deleteTruck(src)
    return true
end)

---"End shift" from the calls menu: with a truck, once it is back at the truck spot with nothing on
---it (the truck is handed in); without one, anywhere.
lib.callback.register('sw_tow:server:endShift', function(src)
    local current = shifts[src]
    if not current then return false end
    if not guard.rate(src, 'clock') then return false, 'common.wait' end
    local truck = current.truck
    if truck and DoesEntityExist(truck) then
        if Entity(truck).state['sw_tow:cargo'] then return false, 'garage.has_cargo' end
        local at = GetEntityCoords(truck)
        if #(at - config.garage.spawn.xyz) > config.garage.returnDistance or not guard.near(src, at, 15.0) then
            return false, 'garage.too_far'
        end
    end
    shift.stop(src, truck and 'ended, truck returned' or 'ended')
    framework.setDuty(src, false)
    return true
end)

framework.onPlayerUnload(function(src) shift.stop(src, 'logged out') end)

framework.onJobUpdate(function(src, job)
    if shifts[src] and (not job or job.name ~= config.job) then shift.stop(src, 'job changed') end
end)

AddEventHandler('playerDropped', function()
    local src = source
    shift.stop(src, 'dropped')
    guard.forget(src)
end)

---Our own deletions forget the truck first, so this only runs when the game or another resource
---removed it. The worker's client may still show it: it is told, so a new one can be taken at once
---instead of every action failing on a truck the server no longer knows.
AddEventHandler('entityRemoved', function(entity)
    local src = truckOwner[entity]
    if not src then return end
    truckOwner[entity] = nil
    local current = shifts[src]
    if not current or current.truck ~= entity then return end
    current.truck, current.method = nil, nil
    local owner = NetworkGetEntityOwner(entity)
    log.warn(src, 'truck_lost', ('company truck removed by the game or another resource (network owner %s)')
        :format(owner and owner > 0 and ('player ' .. owner) or 'server'))
    TriggerClientEvent('sw_tow:client:truckLost', src)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for src in pairs(shifts) do
        deleteTruck(src)
        Player(src).state:set('sw_tow:shift', false, true)
    end
end)

return shift
