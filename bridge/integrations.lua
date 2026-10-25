---Server integrations with garage, vehicle key and banking scripts. Each has an 'auto' choice
---(first running script wins) and a 'none' fallback, set in config.adapters.
local config = require 'config'

local function running(resource)
    return GetResourceState(resource) == 'started'
end

local function pick(kind, implementations, order)
    local wanted = config.adapters[kind] or 'auto'
    if wanted ~= 'auto' then
        local impl = implementations[wanted]
        if not impl then
            error(('sw_tow: unknown %s adapter "%s" in config.adapters'):format(kind, wanted), 0)
        end
        return wanted, impl
    end
    for i = 1, #order do
        if running(order[i]) then return order[i], implementations[order[i]] end
    end
    return 'none', implementations.none
end

---@class SwOwnedVehicle
---@field id integer
---@field owner string
---@field model string
---@field props table

---@class SwGarageAdapter
---@field getVehicleId fun(entity: integer, plate: string): integer?
---@field getVehicle fun(vehicleId: integer): SwOwnedVehicle?
---@field store fun(entity: integer, vehicleId: integer, yard: string, fee: integer): boolean
---@field markOut fun(entity: integer, vehicleId: integer): boolean
---@field protect fun(isHeld: fun(vehicleId: integer): string?)

local garages = {}

garages.qbx_garages = {
    getVehicleId = function(entity, plate)
        return Entity(entity).state.vehicleid or exports.qbx_vehicles:GetVehicleIdByPlate(plate)
    end,

    getVehicle = function(vehicleId)
        local vehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
        if not vehicle or type(vehicle.props) ~= 'table' then return end
        return { id = vehicle.id, owner = vehicle.citizenid, model = vehicle.modelName, props = vehicle.props }
    end,

    store = function(entity, vehicleId, yard, fee)
        -- Body, engine and fuel are read on the server; mods stay as the garage last saved them,
        -- so a client can never inject vehicle properties.
        local ok = exports.qbx_vehicles:SaveVehicle(entity, {
            state = 2,  -- VehicleState.IMPOUNDED
            garage = 'sw_tow_' .. yard,
            depotPrice = fee,
        })
        if not ok then return false end
        MySQL.update.await('UPDATE player_vehicles SET body = ?, engine = ?, fuel = ? WHERE id = ?', {
            math.floor(GetVehicleBodyHealth(entity)),
            math.floor(GetVehicleEngineHealth(entity)),
            math.floor(Entity(entity).state.fuel or 100),
            vehicleId,
        })
        return true
    end,

    markOut = function(entity, vehicleId)
        Entity(entity).state:set('vehicleid', vehicleId, false)
        return exports.qbx_vehicles:SaveVehicle(entity, { state = 0, depotPrice = 0 }) == true
    end,

    -- The public Qbox impound lot lists every IMPOUNDED vehicle. This hook stops it from handing
    -- out a vehicle that is held in a Shiftworks yard. qbx_core removes the hook when we stop.
    protect = function(isHeld)
        exports.qbx_garages:registerHook('spawnVehicle', function(payload)
            local yardLabel = isHeld(payload.vehicleId)
            if not yardLabel then return true end
            TriggerClientEvent('sw_tow:client:notify', payload.source, locale('impound.held_elsewhere', yardLabel), 'error')
            return false
        end)
    end,
}

garages.none = {
    getVehicleId = function() return nil end,
    getVehicle = function() return nil end,
    store = function() return false end,
    markOut = function() return false end,
    protect = function() end,
}

---@class SwKeysAdapter
---@field give fun(src: integer, entity: integer)

local keys = {}

keys.qbx_vehiclekeys = {
    give = function(src, entity)
        exports.qbx_vehiclekeys:GiveKeys(src, entity, true)
    end,
}

keys.none = { give = function() end }

---@class SwBankingAdapter
---@field deposit fun(account: string, amount: integer, reason: string): boolean

local banking = {}

banking['Renewed-Banking'] = {
    deposit = function(account, amount)
        return exports['Renewed-Banking']:addAccountMoney(account, amount) == true
    end,
}

banking.none = { deposit = function() return false end }

local garageName, garage = pick('garage', garages, { 'qbx_garages' })
local keysName, keyAdapter = pick('keys', keys, { 'qbx_vehiclekeys' })
local bankingName, bank = pick('banking', banking, { 'Renewed-Banking' })

return {
    names = { garage = garageName, keys = keysName, banking = bankingName },
    garage = garage --[[@as SwGarageAdapter]],
    keys = keyAdapter --[[@as SwKeysAdapter]],
    banking = bank --[[@as SwBankingAdapter]],
}
