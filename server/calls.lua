---Tow calls. A call names one vehicle; accepting it gives the worker the right to impound that
---vehicle at the yard. Owned vehicles can only be called in by their owner (no griefing).
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local guard = require 'server.guard'
local log = require 'server.log'
local shift = require 'server.shift'

local calls = {}

---@class SwCall
---@field id integer
---@field type 'player'
---@field caller integer src
---@field plate string
---@field vehicle integer entity
---@field coords vector3
---@field message string
---@field createdAt integer
---@field status 'open'|'accepted'
---@field worker integer? src
---@field acceptedAt integer?

---@type table<integer, SwCall>
local active = {}
local nextId = 0
local lastCall = {}

local function notify(src, key, kind, ...)
    TriggerClientEvent('sw_tow:client:notify', src, locale(key, ...), kind)
end

local function count()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

---What workers see in the call list. Never includes caller identity beyond the street.
---@param call SwCall
local function summary(call)
    return {
        id = call.id,
        type = call.type,
        plate = call.plate,
        coords = call.coords,
        message = call.message,
        age = os.time() - call.createdAt,
        status = call.status,
        mine = false,
    }
end

local function broadcast()
    for src in pairs(shift.all()) do
        TriggerClientEvent('sw_tow:client:callsChanged', src)
    end
end

---@param id integer
---@param reasonKey string? locale key sent to the caller
local function remove(id, reasonKey)
    local call = active[id]
    if not call then return end
    active[id] = nil
    if reasonKey then notify(call.caller, reasonKey, 'inform') end
    if call.worker then TriggerClientEvent('sw_tow:client:callClosed', call.worker, id) end
    broadcast()
end

---Creates a call for the vehicle the player is in or drove last.
---@param src integer
---@param message string?
---@return boolean ok, string? errorKey
function calls.create(src, message)
    if not guard.rate(src, 'call') then return false end
    local now = os.time()
    if lastCall[src] and now - lastCall[src] < config.calls.cooldown then return false, 'calls.cooldown' end
    for _, call in pairs(active) do
        if call.caller == src then return false, 'calls.already_open' end
    end
    if count() >= config.calls.maxOpen then return false, 'calls.busy' end

    local ped = GetPlayerPed(src)
    local vehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if vehicle == 0 then vehicle = GetVehiclePedIsIn(ped, true) end
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'calls.no_vehicle' end
    if #(GetEntityCoords(vehicle) - GetEntityCoords(ped)) > config.calls.vehicleRange then return false, 'calls.no_vehicle' end
    if Entity(vehicle).state['sw_tow:company'] then return false, 'calls.no_vehicle' end

    local plate = framework.getPlate(vehicle)
    local vehicleId = integrations.garage.getVehicleId(vehicle, plate)
    if vehicleId then
        local owned = integrations.garage.getVehicle(vehicleId)
        if owned and owned.owner ~= framework.getCitizenId(src) then return false, 'calls.not_owner' end
    end

    nextId = nextId + 1
    active[nextId] = {
        id = nextId,
        type = 'player',
        caller = src,
        plate = plate,
        vehicle = vehicle,
        coords = GetEntityCoords(vehicle),
        message = type(message) == 'string' and message:sub(1, 120) or '',
        createdAt = now,
        status = 'open',
    }
    lastCall[src] = now
    log.info(src, 'call_created', ('#%d %s'):format(nextId, plate))
    broadcast()
    for worker in pairs(shift.all()) do notify(worker, 'calls.new', 'inform', plate) end
    return true
end

---@param src integer
function calls.cancelByCaller(src)
    for id, call in pairs(active) do
        if call.caller == src then
            remove(id)
            notify(src, 'calls.cancelled', 'inform')
            return true
        end
    end
    return false
end

---The accepted call this worker has for a vehicle, if any.
---@param src integer
---@param vehicle integer
---@return SwCall?
function calls.acceptedFor(src, vehicle)
    for _, call in pairs(active) do
        if call.worker == src and call.status == 'accepted' and call.vehicle == vehicle then return call end
    end
end

---@param id integer
function calls.complete(id)
    remove(id, 'calls.completed')
end

lib.callback.register('sw_tow:server:listCalls', function(src)
    if not shift.get(src) then return {} end
    local list = {}
    for _, call in pairs(active) do
        if call.status == 'open' or call.worker == src then
            local item = summary(call)
            item.mine = call.worker == src
            list[#list + 1] = item
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end)

lib.callback.register('sw_tow:server:acceptCall', function(src, id)
    if not shift.get(src) or not guard.rate(src, 'call') then return false end
    local call = type(id) == 'number' and active[id]
    if not call or call.status ~= 'open' then return false, 'calls.taken' end
    for _, other in pairs(active) do
        if other.worker == src then return false, 'calls.one_at_a_time' end
    end
    call.status, call.worker, call.acceptedAt = 'accepted', src, os.time()
    notify(call.caller, 'calls.accepted', 'success', framework.getName(src))
    log.info(src, 'call_accepted', ('#%d'):format(id))
    broadcast()
    return true, call.coords
end)

lib.callback.register('sw_tow:server:dropCall', function(src, id)
    local call = type(id) == 'number' and active[id]
    if not call or call.worker ~= src then return false end
    call.status, call.worker, call.acceptedAt = 'open', nil, nil
    notify(call.caller, 'calls.reopened', 'inform')
    broadcast()
    return true
end)

lib.addCommand(config.calls.command, {
    help = locale('calls.command_help'),
    params = { { name = 'message', type = 'longString', help = locale('calls.message_help'), optional = true } },
}, function(src, args)
    local ok, errorKey = calls.create(src, args.message)
    notify(src, ok and 'calls.created' or (errorKey or 'common.failed'), ok and 'success' or 'error')
end)

lib.addCommand(config.calls.cancelCommand, { help = locale('calls.cancel_help') }, function(src)
    if not calls.cancelByCaller(src) then notify(src, 'calls.none_open', 'error') end
end)

-- For phones, radial menus and other scripts: exports.sw_tow:CreateCall(src, message)
exports('CreateCall', function(src, message)
    return calls.create(src, message)
end)

shift.onEnd(function(src)
    for _, call in pairs(active) do
        if call.worker == src then
            call.status, call.worker, call.acceptedAt = 'open', nil, nil
            notify(call.caller, 'calls.reopened', 'inform')
        end
    end
    broadcast()
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastCall[src] = nil
    for id, call in pairs(active) do
        if call.caller == src then remove(id) end
    end
end)

-- Timeouts. One cheap pass every 30 seconds.
CreateThread(function()
    while true do
        Wait(30000)
        local now = os.time()
        for id, call in pairs(active) do
            if not DoesEntityExist(call.vehicle) then
                remove(id, 'calls.vehicle_gone')
            elseif call.status == 'open' and now - call.createdAt > config.calls.acceptTimeout * 60 then
                remove(id, 'calls.expired')
            elseif call.status == 'accepted' and now - call.acceptedAt > config.calls.deliverTimeout * 60 then
                remove(id, 'calls.expired')
            end
        end
    end
end)

return calls
