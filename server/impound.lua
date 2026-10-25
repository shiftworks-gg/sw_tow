---The impound yard: taking cargo off a truck, storing owned vehicles, fees and release at the counter.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local util = require 'shared.util'
local guard = require 'server.guard'
local log = require 'server.log'
local storage = require 'server.storage'
local shift = require 'server.shift'
local tow = require 'server.tow'
local calls = require 'server.calls'

local impound = {}

---Vehicles currently held in a yard: player_vehicles.id -> yard key.
---@type table<integer, string>
local held = {}
---Records being released right now, so a double click cannot release twice.
local releasing = {}

function impound.load()
    for _, record in ipairs(storage.allActive()) do
        if record.vehicle_id then held[record.vehicle_id] = record.yard end
    end
end

---@param vehicleId integer
---@return string? yardLabel
local function isHeld(vehicleId)
    local yard = held[vehicleId]
    return yard and config.yards[yard] and config.yards[yard].label or nil
end

---@param record SwImpoundRecord
---@param class integer?
---@return integer
function impound.fee(record, class)
    local fees = config.fees
    local hours = (os.time() - record.stored_at) / 3600
    local days = math.ceil(math.max(0, hours - fees.freeHours) / 24)
    local classFee = class and fees.byClass[class] or 0
    return math.floor(fees.base + classFee + days * fees.perDay + (record.fine or 0))
end

---@param record SwImpoundRecord
local function holdActive(record)
    if record.police_hold ~= 1 then return false end
    return record.hold_until == nil or record.hold_until > os.time()
end

---@param src integer
---@param amount integer
---@param reason string
---@return string? account
local function charge(src, amount, reason)
    if amount <= 0 then return 'cash' end
    for _, account in ipairs({ 'cash', 'bank' }) do
        if framework.getMoney(src, account) >= amount and framework.removeMoney(src, account, amount, reason) then
            return account
        end
    end
end

---@param yard table
---@return vector4?
local function freeReleaseSpot(yard)
    for _, spot in ipairs(yard.releaseSpots) do
        if not lib.getClosestVehicle(spot.xyz, 3.0, false) then return spot end
    end
end

local function counterCoords(yard)
    return (yard.counter or config.office.coords).xyz
end

---Pays the worker, and a partner sitting in the truck, for one delivery.
local function payWorkers(src, truck, distance, callType)
    local p = config.payout
    local amount = math.min(p.max, math.floor(p.base + p.perKm * distance / 1000))
    framework.addMoney(src, p.account, amount, 'sw-tow-delivery')
    storage.logDelivery(shift.get(src).citizenid, callType, amount, distance)
    TriggerClientEvent('sw_tow:client:notify', src, locale('impound.paid', util.money(amount)), 'success')
    log.payout(src, 'delivery', ('%s, %d m, %s'):format(callType, math.floor(distance), util.money(amount)))

    local partnerAmount = math.floor(amount * p.partnerShare)
    if partnerAmount <= 0 then return end
    for _, partner in ipairs(guard.occupants(truck)) do
        local partnerShift = partner ~= src and shift.get(partner)
        if partnerShift then
            framework.addMoney(partner, p.account, partnerAmount, 'sw-tow-delivery-partner')
            storage.logDelivery(partnerShift.citizenid, callType, partnerAmount, distance)
            TriggerClientEvent('sw_tow:client:notify', partner, locale('impound.paid', util.money(partnerAmount)), 'success')
        end
    end
end

lib.callback.register('sw_tow:server:deliver', function(src, truckNet, yardKey)
    if not guard.rate(src, 'deliver') then return false end
    local current = shift.get(src)
    local truck = guard.vehicle(truckNet)
    local yard = type(yardKey) == 'string' and config.yards[yardKey]
    if not current or not truck or current.truck ~= truck or not yard then return false end
    if not guard.near(src, GetEntityCoords(truck), 15.0) or not util.inZone(GetEntityCoords(truck), yard.zone) then
        return false, 'impound.not_in_yard'
    end

    local record = tow.get(truck)
    if not record or not record.secured then return false, 'impound.no_cargo' end
    local target = record.target
    if #(GetEntityCoords(target) - GetEntityCoords(truck)) > 10.0 then return false, 'impound.no_cargo' end

    -- A truck cannot be faster than config.payout.maxSpeed on average: stops teleport deliveries.
    local distance = #(record.pickup - yard.zone.coords)
    if os.time() - record.pickedAt < distance / config.payout.maxSpeed then
        log.warn(src, 'deliver', ('too fast: %d m in %d s'):format(math.floor(distance), os.time() - record.pickedAt))
        return false, 'impound.too_fast'
    end

    local plate = framework.getPlate(target)
    local call = calls.acceptedFor(src, target)
    local vehicleId = integrations.garage.getVehicleId(target, plate)

    if vehicleId then
        local owned = integrations.garage.getVehicle(vehicleId)
        if not owned then return false, 'impound.no_order' end
        if not call then
            log.warn(src, 'deliver', ('owned vehicle %s without an order'):format(plate))
            return false, 'impound.no_order'
        end
        local fee = impound.fee({ stored_at = os.time(), fine = 0 }, framework.getVehicleClass(GetEntityModel(target)))
        if not integrations.garage.store(target, vehicleId, yardKey, fee) then return false, 'common.failed' end
        storage.insertImpound({
            yard = yardKey,
            plate = plate,
            vehicle_id = vehicleId,
            owner = owned.owner,
            model = owned.model,
            reason = call.type,
            note = call.message,
            towed_by = current.citizenid,
        })
        held[vehicleId] = yardKey
    end

    tow.clear(truck)
    framework.deleteVehicle(target)

    if call then
        calls.complete(call.id)
        payWorkers(src, truck, distance, call.type)
    else
        -- Unowned vehicle without an order: cleared off the street, no pay (stops farming parked cars).
        TriggerClientEvent('sw_tow:client:notify', src, locale('impound.cleared'), 'inform')
        log.info(src, 'deliver', ('cleared %s without an order'):format(plate))
    end
    return true
end)

lib.callback.register('sw_tow:server:counterList', function(src, yardKey)
    local yard = type(yardKey) == 'string' and config.yards[yardKey]
    local citizenid = framework.getCitizenId(src)
    if not yard or not citizenid or not guard.near(src, counterCoords(yard), 4.0) then return {} end

    local list = {}
    for _, record in ipairs(storage.activeForOwner(citizenid, yardKey)) do
        list[#list + 1] = {
            id = record.id,
            plate = record.plate,
            model = record.model,
            reason = record.reason,
            fee = impound.fee(record, framework.getVehicleClass(joaat(record.model))),
            held = holdActive(record),
            storedAt = record.stored_at,
        }
    end
    return list
end)

lib.callback.register('sw_tow:server:release', function(src, recordId)
    if not util.isInteger(recordId) or releasing[recordId] or not guard.rate(src, 'release') then return false end
    releasing[recordId] = true
    local ok, result, errorKey = pcall(function()
        local record = storage.getActive(recordId)
        local citizenid = framework.getCitizenId(src)
        if not record or not citizenid or record.owner ~= citizenid or not record.vehicle_id then return false end
        local yard = config.yards[record.yard]
        if not yard or not guard.near(src, counterCoords(yard), 4.0) then return false end
        if holdActive(record) then return false, 'impound.police_hold' end

        local vehicle = integrations.garage.getVehicle(record.vehicle_id)
        if not vehicle then return false, 'common.failed' end
        local spot = freeReleaseSpot(yard)
        if not spot then return false, 'impound.no_spot' end

        local fee = impound.fee(record, framework.getVehicleClass(joaat(record.model)))
        local paidFrom = charge(src, fee, 'sw-tow-release')
        if not paidFrom then return false, 'impound.not_enough' end

        local refund = function() if fee > 0 then framework.addMoney(src, paidFrom, fee, 'sw-tow-release-refund') end end
        vehicle.props.lockState = 1
        local spawned, _, entity = pcall(framework.spawnVehicle, vehicle.props.model, spot, vehicle.props)
        if not spawned or not entity or entity == 0 then
            refund()
            return false, 'common.failed'
        end
        if not integrations.garage.markOut(entity, record.vehicle_id) or not storage.markReleased(record.id, citizenid, fee) then
            framework.deleteVehicle(entity)
            refund()
            return false, 'common.failed'
        end

        held[record.vehicle_id] = nil
        integrations.keys.give(src, entity)
        local companyAmount = math.floor(fee * config.fees.companyShare)
        if companyAmount > 0 then
            integrations.banking.deposit(config.fees.companyAccount, companyAmount, 'sw-tow-release')
        end
        log.payout(src, 'release', ('%s, %s'):format(record.plate, util.money(fee)))
        return true
    end)
    releasing[recordId] = nil
    if not ok then
        lib.print.error(result)
        return false, 'common.failed'
    end
    return result, errorKey
end)

impound.isHeld = isHeld

return impound
