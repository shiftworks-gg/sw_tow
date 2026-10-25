---Tow calls. A call names one vehicle; accepting it gives the worker the right to impound that
---vehicle at the yard. Four sources add calls: players (here), police orders, NPC contracts and the
---abandoned vehicle scanner (their own modules). This module owns accepting, timeouts and closing.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local guard = require 'server.guard'
local log = require 'server.log'
local shift = require 'server.shift'

local calls = {}

---@alias SwCallType 'player'|'police'|'contract'|'abandoned'

---@class SwCall
---@field id integer
---@field type SwCallType
---@field caller integer? src of the player or officer who created it
---@field plate string
---@field vehicle integer? entity; contracts create it when accepted
---@field coords vector3
---@field message string
---@field createdAt integer
---@field status 'open'|'accepted'
---@field worker integer? src
---@field acceptedAt integer?
---@field fine integer? police orders
---@field hold boolean? police orders
---@field holdHours integer? police orders, 0 = until lifted
---@field payFactor number? multiplier on delivery pay
---@field onAccept fun(call: SwCall, src: integer): boolean? prepares the vehicle; false refuses
---@field onClose fun(call: SwCall, delivered: boolean)?

---@type table<integer, SwCall>
local active = {}
local nextId = 0
local lastCall = {}

local function notify(src, key, kind, ...)
    if src then TriggerClientEvent('sw_tow:client:notify', src, locale(key, ...), kind) end
end

---@param filter? fun(call: SwCall): boolean
---@return integer
function calls.count(filter)
    local n = 0
    for _, call in pairs(active) do
        if not filter or filter(call) then n = n + 1 end
    end
    return n
end

local function broadcast()
    for src in pairs(shift.all()) do
        TriggerClientEvent('sw_tow:client:callsChanged', src)
    end
end

---@param id integer
---@param reasonKey string? locale key sent to the caller
---@param delivered boolean?
local function remove(id, reasonKey, delivered)
    local call = active[id]
    if not call then return end
    active[id] = nil
    if reasonKey then notify(call.caller, reasonKey, 'inform') end
    if call.worker then TriggerClientEvent('sw_tow:client:callClosed', call.worker, id) end
    if call.onClose then
        local ok, err = pcall(call.onClose, call, delivered == true)
        if not ok then lib.print.error(err) end
    end
    broadcast()
end

---Adds a call from any source and tells everyone on shift.
---@param call table fields of SwCall without id, status and createdAt
---@return integer id
function calls.add(call)
    nextId = nextId + 1
    call.id, call.status, call.createdAt = nextId, 'open', os.time()
    call.message = type(call.message) == 'string' and call.message:sub(1, 120) or ''
    active[nextId] = call
    log.info(call.caller, 'call_created', ('#%d %s %s'):format(nextId, call.type, call.plate))
    broadcast()
    for worker in pairs(shift.all()) do notify(worker, 'calls.new_' .. call.type, 'inform', call.plate) end
    return nextId
end

---Is there an open or accepted call for this vehicle?
---@param vehicle integer
---@return boolean
function calls.hasVehicle(vehicle)
    for _, call in pairs(active) do
        if call.vehicle == vehicle then return true end
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
    remove(id, 'calls.completed', true)
end

---Player call for the vehicle they are in or drove last.
---@param src integer
---@param message string?
---@return boolean ok, string? errorKey
function calls.createForPlayer(src, message)
    if not guard.rate(src, 'call') then return false end
    local now = os.time()
    if lastCall[src] and now - lastCall[src] < config.calls.cooldown then return false, 'calls.cooldown' end
    for _, call in pairs(active) do
        if call.caller == src and call.type == 'player' then return false, 'calls.already_open' end
    end
    if calls.count() >= config.calls.maxOpen then return false, 'calls.busy' end

    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then vehicle = GetVehiclePedIsIn(ped, true) end
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'calls.no_vehicle' end
    if #(GetEntityCoords(vehicle) - GetEntityCoords(ped)) > config.calls.vehicleRange then return false, 'calls.no_vehicle' end
    if Entity(vehicle).state['sw_tow:company'] or calls.hasVehicle(vehicle) then return false, 'calls.no_vehicle' end

    -- Only the owner may call a tow for an owned vehicle, and unowned (NPC) vehicles cannot be called
    -- in at all: otherwise two players could farm delivery pay with stolen cars.
    local plate = framework.getPlate(vehicle)
    if integrations.names.garage ~= 'none' then
        local vehicleId = integrations.garage.getVehicleId(vehicle, plate)
        local owned = vehicleId and integrations.garage.getVehicle(vehicleId)
        if not owned or owned.owner ~= framework.getCitizenId(src) then return false, 'calls.not_owner' end
    end

    lastCall[src] = now
    calls.add({
        type = 'player',
        caller = src,
        plate = plate,
        vehicle = vehicle,
        coords = GetEntityCoords(vehicle),
        message = message,
    })
    return true
end

---@param src integer
function calls.cancelByCaller(src)
    for id, call in pairs(active) do
        if call.caller == src and call.type == 'player' then
            remove(id)
            notify(src, 'calls.cancelled', 'inform')
            return true
        end
    end
    return false
end

lib.callback.register('sw_tow:server:listCalls', function(src)
    if not shift.get(src) then return {} end
    local list = {}
    for _, call in pairs(active) do
        if call.status == 'open' or call.worker == src then
            list[#list + 1] = {
                id = call.id,
                type = call.type,
                plate = call.plate,
                coords = call.coords,
                message = call.message,
                age = os.time() - call.createdAt,
                mine = call.worker == src,
            }
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
    if call.onAccept then
        local ok, ready = pcall(call.onAccept, call, src)
        if not ok or ready == false then
            if not ok then lib.print.error(ready) end
            remove(id)
            return false, 'common.failed'
        end
    end
    notify(call.caller, 'calls.accepted', 'success', framework.getName(src))
    log.info(src, 'call_accepted', ('#%d %s'):format(id, call.type))
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
    local ok, errorKey = calls.createForPlayer(src, args.message)
    notify(src, ok and 'calls.created' or (errorKey or 'common.failed'), ok and 'success' or 'error')
end)

lib.addCommand(config.calls.cancelCommand, { help = locale('calls.cancel_help') }, function(src)
    if not calls.cancelByCaller(src) then notify(src, 'calls.none_open', 'error') end
end)

-- For phones, radial menus and other scripts: exports.sw_tow:CreateCall(src, message)
exports('CreateCall', function(src, message)
    return calls.createForPlayer(src, message)
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
        if call.caller == src and call.type == 'player' then remove(id) end
    end
end)

-- Timeouts. One cheap pass every 30 seconds.
CreateThread(function()
    while true do
        Wait(30000)
        local now = os.time()
        for id, call in pairs(active) do
            if call.vehicle and not DoesEntityExist(call.vehicle) then
                remove(id, 'calls.vehicle_gone')
            elseif call.status == 'open' and now - call.createdAt > config.calls.acceptTimeout * 60 then
                remove(id, 'calls.expired')
            elseif call.status == 'accepted' and now - call.acceptedAt > config.calls.deliverTimeout * 60 then
                remove(id, 'calls.expired')
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for id in pairs(active) do remove(id) end
end)

return calls
