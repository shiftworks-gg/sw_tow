---Shifts and company trucks. A shift is server state; the player's `sw_tow:shift` state bag mirrors
---it so clients can show the right options without asking the server.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local guard = require 'server.guard'
local log = require 'server.log'
local storage = require 'server.storage'
local util = require 'shared.util'

local shift = {}

---@class SwShift
---@field citizenid string
---@field startedAt integer
---@field deliveries integer
---@field earned integer
---@field truck integer? entity
---@field method 'flatbed'|'hook'?
---@field deposit integer? paid for the truck that is out
---@field condition number? truck condition 0..1, sampled while it is out

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
    current.truck, current.method, current.deposit, current.condition = nil, nil, nil, nil
    if DoesEntityExist(truck) then framework.deleteVehicle(truck) end
end

local function notify(src, key, kind, ...)
    TriggerClientEvent('sw_tow:client:notify', src, locale(key, ...), kind)
end

---Cash first, then bank. Returns the account it came from.
---@return 'cash'|'bank'?
local function charge(src, amount, reason)
    if amount <= 0 then return 'cash' end
    for _, account in ipairs({ 'cash', 'bank' }) do
        if framework.getMoney(src, account) >= amount and framework.removeMoney(src, account, amount, reason) then
            return account
        end
    end
end

---How whole a truck is, 0 (wreck) to 1 (as taken out): the worse of engine and body.
---@param truck integer
---@return number
local function condition(truck)
    local engine = GetVehicleEngineHealth(truck) or 1000.0
    local body = GetVehicleBodyHealth(truck) or 1000.0
    return math.max(0.0, math.min(1.0, math.min(engine, body) / 1000.0))
end

---The truck comes back: the deposit is paid back, less the damage when garage.damageFromDeposit.
---@param src integer
local function handInTruck(src)
    local current = shifts[src]
    if not current or not current.truck then return end
    local deposit = current.deposit or 0
    if deposit > 0 then
        local back = deposit
        if config.garage.damageFromDeposit and DoesEntityExist(current.truck) then
            back = math.floor(deposit * condition(current.truck))
        end
        if back > 0 then framework.addMoney(src, config.payout.account, back, 'sw-tow-deposit') end
        if back < deposit then
            notify(src, 'garage.deposit_damage', 'warning', util.money(back), util.money(deposit - back))
        else
            notify(src, 'garage.deposit_back', 'success', util.money(back))
        end
        log.payout(src, 'deposit_back', ('%s of %s'):format(util.money(back), util.money(deposit)))
    end
    deleteTruck(src)
end

---The truck is not coming back (left somewhere, wrecked, replaced): the deposit is kept.
---@param src integer
local function forfeitTruck(src)
    local current = shifts[src]
    if not current or not current.truck then return end
    local deposit = current.deposit or 0
    if deposit > 0 then
        notify(src, 'garage.deposit_lost', 'error', util.money(deposit))
        log.warn(src, 'deposit_lost', util.money(deposit))
    end
    deleteTruck(src)
end

---Pays out what the company owes this worker: pay collected at the office, deposits owed back.
---@param src integer
---@param key string notification text, with the amount
local function payOwed(src, key)
    local citizenid = framework.getCitizenId(src)
    if not citizenid then return end
    local amount = storage.takeOwed(citizenid)
    if amount <= 0 then return end
    framework.addMoney(src, config.payout.account, amount, 'sw-tow-pay')
    notify(src, key, 'success', util.money(amount))
    log.payout(src, 'pay', util.money(amount))
end

---Is the worker's truck parked back at the truck spot, with the worker next to it?
local function truckAtDepot(src, truck)
    local at = GetEntityCoords(truck)
    return #(at - config.garage.spawn.xyz) <= config.garage.returnDistance and guard.near(src, at, 15.0)
end

---@param src integer
---@param reason string
function shift.stop(src, reason)
    local current = shifts[src]
    if not current then return end
    for i = 1, #listeners do listeners[i](src) end
    -- Not the worker's choice (left the server, job changed, restart): a deposit is owed back and
    -- paid with the next pay at the office.
    if current.truck and (current.deposit or 0) > 0 then storage.addOwed(current.citizenid, current.deposit) end
    deleteTruck(src)
    shifts[src] = nil
    Player(src).state:set('sw_tow:shift', false, true)
    log.info(src, 'shift_end', reason)
end

---The worker ends the shift at the office or the truck spot: truck settled, pay handed over.
---@param src integer
---@param reason string
local function finish(src, reason)
    local current = shifts[src]
    if not current then return end
    if current.truck then
        if DoesEntityExist(current.truck) and truckAtDepot(src, current.truck) then handInTruck(src) else forfeitTruck(src) end
    end
    shift.stop(src, reason)
    framework.setDuty(src, false)
    payOwed(src, 'shift.paid')
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
    -- Anything left from an earlier shift (a disconnect before collecting) is paid now.
    payOwed(src, 'shift.paid_earlier')
    return true
end)

---Clock out at the counter. A truck still out (not back at the truck spot) keeps its deposit.
lib.callback.register('sw_tow:server:clockOut', function(src)
    if not shifts[src] or not nearOffice(src) then return false end
    finish(src, 'clocked out')
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

---Takes a company truck. `replace`: the worker's current truck is not coming back (wrecked, stuck,
---left somewhere); it is removed and its deposit kept.
lib.callback.register('sw_tow:server:takeTruck', function(src, index, replace)
    local current = shifts[src]
    if not current then return false end
    if not guard.rate(src, 'takeTruck') then return false, 'common.wait' end
    local option = type(index) == 'number' and config.garage.vehicles[index]
    if not option then return false end
    if current.truck and DoesEntityExist(current.truck) and replace ~= true then return false, 'garage.already_out' end
    if not nearOffice(src) then
        log.warn(src, 'take_truck', 'not at the office')
        return false
    end
    if current.truck and Entity(current.truck).state['sw_tow:cargo'] then return false, 'garage.has_cargo' end
    if lib.getClosestVehicle(config.garage.spawn.xyz, 3.0, true) then return false, 'garage.spot_busy' end

    local deposit = config.garage.deposit or 0
    local paidFrom = charge(src, deposit, 'sw-tow-deposit')
    if not paidFrom then return false, 'garage.no_deposit' end
    local function refund()
        if deposit > 0 then framework.addMoney(src, paidFrom, deposit, 'sw-tow-deposit-refund') end
    end

    local plate = freePlate()
    if not plate then
        refund()
        return false
    end
    local ok, netId, truck = pcall(framework.spawnVehicle, option.model, config.garage.spawn, { plate = plate })
    if not ok or not truck or truck == 0 then
        refund()
        log.warn(src, 'take_truck', ('spawn failed: %s'):format(tostring(netId)))
        return false
    end
    -- The worker may have left while the truck was spawning.
    if shifts[src] ~= current then
        refund()
        framework.deleteVehicle(truck)
        return false
    end

    if current.truck then forfeitTruck(src) end
    current.truck, current.method, current.deposit, current.condition = truck, option.method, deposit, 1.0
    truckOwner[truck] = src
    local state = Entity(truck).state
    state:set('sw_tow:company', current.citizenid, true)
    state:set('sw_tow:method', option.method, true)
    integrations.keys.give(src, truck)
    if deposit > 0 then notify(src, 'garage.deposit_taken', 'inform', util.money(deposit)) end
    log.info(src, 'take_truck', ('%s %s, deposit %s'):format(option.model, plate, util.money(deposit)))
    return true, netId
end)

lib.callback.register('sw_tow:server:returnTruck', function(src)
    local current = shifts[src]
    if not current or not current.truck or not DoesEntityExist(current.truck) then return false end
    if #(GetEntityCoords(current.truck) - config.garage.spawn.xyz) > config.garage.returnDistance then
        return false, 'garage.too_far'
    end
    if Entity(current.truck).state['sw_tow:cargo'] then return false, 'garage.has_cargo' end
    handInTruck(src)
    return true
end)

---"End shift": with a truck, once it is back at the truck spot with nothing on it (the truck is
---handed in); without one, at the office counter.
lib.callback.register('sw_tow:server:endShift', function(src)
    local current = shifts[src]
    if not current then return false end
    if not guard.rate(src, 'clock') then return false, 'common.wait' end
    local truck = current.truck
    if truck and DoesEntityExist(truck) then
        if Entity(truck).state['sw_tow:cargo'] then return false, 'garage.has_cargo' end
        if not truckAtDepot(src, truck) then return false, 'garage.too_far' end
    elseif not nearOffice(src) then
        return false, 'shift.not_at_office'
    end
    finish(src, truck and 'ended, truck returned' or 'ended')
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
    -- Removed while still in working order: not the worker's doing, the deposit comes back. A wreck
    -- that the game cleared away keeps it.
    local deposit = current.deposit or 0
    if deposit > 0 and (current.condition or 1.0) > 0.1 then
        framework.addMoney(src, config.payout.account, deposit, 'sw-tow-deposit')
        notify(src, 'garage.deposit_back', 'success', util.money(deposit))
    elseif deposit > 0 then
        notify(src, 'garage.deposit_lost', 'error', util.money(deposit))
    end
    current.truck, current.method, current.deposit, current.condition = nil, nil, nil, nil
    local owner = NetworkGetEntityOwner(entity)
    log.warn(src, 'truck_lost', ('company truck removed by the game or another resource (network owner %s)')
        :format(owner and owner > 0 and ('player ' .. owner) or 'server'))
    TriggerClientEvent('sw_tow:client:truckLost', src)
end)

-- Truck condition every 10 s while trucks are out, so a wreck the game clears away is told apart
-- from a truck removed in working order.
CreateThread(function()
    while true do
        Wait(10000)
        for _, current in pairs(shifts) do
            if current.truck and DoesEntityExist(current.truck) then current.condition = condition(current.truck) end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for src in pairs(shifts) do
        deleteTruck(src)
        Player(src).state:set('sw_tow:shift', false, true)
    end
end)

return shift
