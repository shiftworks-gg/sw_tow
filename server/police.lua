---Police tow orders and holds. An officer on duty marks a vehicle; the order becomes a call that
---carries the fine and the hold into the impound record.
local config = require 'config'
local framework = require 'bridge.loader'
local guard = require 'server.guard'
local log = require 'server.log'
local storage = require 'server.storage'
local calls = require 'server.calls'

local police = {}
local cfg = config.police
local ordersByOfficer = {}

---@param src integer
---@return boolean
function police.isOfficer(src)
    local job = framework.getJob(src)
    return job ~= nil and job.type == config.policeJobType and job.onDuty
end

local function underHourlyLimit(src)
    local now = os.time()
    local recent = {}
    for _, at in ipairs(ordersByOfficer[src] or {}) do
        if now - at < 3600 then recent[#recent + 1] = at end
    end
    ordersByOfficer[src] = recent
    return #recent < cfg.ordersPerHour
end

local function wholeNumber(value, min, max)
    value = math.tointeger(tonumber(value))
    if not value or value < min or value > max then return end
    return value
end

lib.callback.register('sw_tow:server:policeOrder', function(src, netId, form)
    if not cfg.enabled or not guard.rate(src, 'policeOrder') or not police.isOfficer(src) then return false end
    local vehicle = guard.vehicle(netId)
    if not vehicle or type(form) ~= 'table' then return false end
    if not guard.near(src, GetEntityCoords(vehicle), 8.0) then
        log.warn(src, 'police_order', 'too far from the vehicle')
        return false
    end
    if Entity(vehicle).state['sw_tow:company'] or calls.hasVehicle(vehicle) then return false, 'police.already_ordered' end
    if not guard.isEmpty(vehicle) then return false, 'tow.occupied' end

    local fine = wholeNumber(form.fine or 0, 0, cfg.maxFine)
    local holdHours = wholeNumber(form.holdHours or 0, 0, cfg.maxHoldHours)
    if not fine or not holdHours then return false end
    if not underHourlyLimit(src) then return false, 'police.limit' end
    table.insert(ordersByOfficer[src], os.time())

    local reason = type(form.reason) == 'string' and form.reason or ''
    calls.add({
        type = 'police',
        caller = src,
        plate = framework.getPlate(vehicle),
        vehicle = vehicle,
        coords = GetEntityCoords(vehicle),
        message = reason,
        fine = fine,
        hold = form.hold == true,
        holdHours = holdHours,
    })
    log.info(src, 'police_order', ('%s fine %d hold %s'):format(framework.getPlate(vehicle), fine, tostring(form.hold == true)))
    return true
end)

lib.callback.register('sw_tow:server:holdList', function(src, yardKey)
    local yard = type(yardKey) == 'string' and config.yards[yardKey]
    if not yard or not police.isOfficer(src) then return {} end
    if not guard.near(src, (yard.counter or config.office.coords).xyz, 4.0) then return {} end
    local list = {}
    for _, record in ipairs(storage.heldInYard(yardKey)) do
        list[#list + 1] = {
            id = record.id,
            plate = record.plate,
            model = record.model,
            note = record.note,
            holdUntil = record.hold_until and os.date('%d.%m %H:%M', record.hold_until) or nil,
        }
    end
    return list
end)

lib.callback.register('sw_tow:server:liftHold', function(src, recordId)
    if not police.isOfficer(src) or not guard.rate(src, 'policeOrder') or math.type(recordId) ~= 'integer' then return false end
    local record = storage.getActive(recordId)
    if not record then return false end
    local yard = config.yards[record.yard]
    if not yard or not guard.near(src, (yard.counter or config.office.coords).xyz, 4.0) then return false end
    if not storage.liftHold(recordId) then return false end
    log.info(src, 'lift_hold', record.plate)
    return true
end)

AddEventHandler('playerDropped', function()
    ordersByOfficer[source] = nil
end)

return police
