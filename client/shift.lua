---The office counter: clock in and out, company trucks, and the release counter of yards that
---share the office. The server decides everything; these options only ask.
local config = require 'config'
local framework = require 'bridge.loader'
local notify = require 'client.notify'
local impound = require 'client.impound'

local shift = {}
local truckNet

---@return boolean
function shift.onShift()
    return LocalPlayer.state['sw_tow:shift'] == true
end

---The worker's company truck entity on this client, if it exists here.
---@return integer?
function shift.truck()
    if not truckNet or not NetworkDoesEntityExistWithNetworkId(truckNet) then return end
    local truck = NetToVeh(truckNet)
    if truck == 0 or not DoesEntityExist(truck) then return end
    return truck
end

local function hasJob()
    local job = framework.getJob()
    return job ~= nil and job.name == config.job
end

local function result(ok, errorKey, successKey)
    if ok then
        if successKey then notify(locale(successKey), 'success') end
    else
        notify(locale(errorKey or 'common.failed'), 'error')
    end
end

local function takeTruckMenu()
    local options = {}
    for index, option in ipairs(config.garage.vehicles) do
        options[#options + 1] = {
            title = option.label,
            description = locale(option.method == 'flatbed' and 'garage.flatbed_hint' or 'garage.hook_hint'),
            icon = 'truck',
            onSelect = function()
                local ok, netIdOrError = lib.callback.await('sw_tow:server:takeTruck', false, index)
                if ok then
                    truckNet = netIdOrError
                    notify(locale('garage.taken', option.label), 'success')
                else
                    result(false, netIdOrError)
                end
            end,
        }
    end
    lib.registerContext({ id = 'sw_tow_trucks', title = locale('garage.title'), options = options })
    lib.showContext('sw_tow_trucks')
end

local function officeOptions()
    local options = {
        {
            name = 'sw_tow_clock_in',
            icon = 'fa-solid fa-business-time',
            label = locale('shift.clock_in'),
            distance = 2.5,
            canInteract = function() return hasJob() and not shift.onShift() end,
            onSelect = function()
                local ok, errorKey = lib.callback.await('sw_tow:server:clockIn', false)
                result(ok, errorKey, 'shift.started')
            end,
        },
        {
            name = 'sw_tow_take_truck',
            icon = 'fa-solid fa-truck-pickup',
            label = locale('garage.take'),
            distance = 2.5,
            canInteract = function() return shift.onShift() and not shift.truck() end,
            onSelect = takeTruckMenu,
        },
        {
            name = 'sw_tow_return_truck',
            icon = 'fa-solid fa-warehouse',
            label = locale('garage.return'),
            distance = 2.5,
            canInteract = function() return shift.onShift() and shift.truck() ~= nil end,
            onSelect = function()
                local ok, errorKey = lib.callback.await('sw_tow:server:returnTruck', false)
                if ok then truckNet = nil end
                result(ok, errorKey, 'garage.returned')
            end,
        },
        {
            name = 'sw_tow_clock_out',
            icon = 'fa-solid fa-door-open',
            label = locale('shift.clock_out'),
            distance = 2.5,
            canInteract = function() return shift.onShift() end,
            onSelect = function()
                local ok, errorKey = lib.callback.await('sw_tow:server:clockOut', false)
                if ok then truckNet = nil end
                result(ok, errorKey, 'shift.ended')
            end,
        },
    }
    for key, yard in pairs(config.yards) do
        if not yard.counter then
            for _, option in ipairs(impound.counterOptions(key)) do options[#options + 1] = option end
        end
    end
    return options
end

function shift.createOffice()
    local office = config.office
    exports.ox_target:addBoxZone({
        name = 'sw_tow_office',
        coords = office.coords.xyz,
        size = office.size,
        rotation = office.coords.w,
        debug = config.debug,
        options = officeOptions(),
    })
    impound.addBlip(office.coords.xyz, office.blip, office.label)
end

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then truckNet = nil end
end)

return shift
