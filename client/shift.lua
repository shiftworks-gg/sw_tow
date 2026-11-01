---The office counter: clock in and out, company trucks, and the release counter of yards that
---share the office. The server decides everything; these options only ask.
local config = require 'config'
local framework = require 'bridge.loader'
local util = require 'shared.util'
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

---True while the worker has a company truck out, wherever it is (also when it is not near enough
---to exist on this client).
---@return boolean
function shift.hasTruck()
    return truckNet ~= nil
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

---@return boolean ok, string? errorKey
function shift.clockIn()
    return lib.callback.await('sw_tow:server:clockIn', false)
end

---@return boolean ok, string? errorKey
function shift.clockOut()
    local ok, errorKey = lib.callback.await('sw_tow:server:clockOut', false)
    if ok then truckNet = nil end
    return ok, errorKey
end

---@param index integer config.garage.vehicles index
---@param replace? boolean the current truck is not coming back: it is removed and its deposit kept
---@return boolean ok, string? errorKey
function shift.takeTruck(index, replace)
    local ok, netIdOrError = lib.callback.await('sw_tow:server:takeTruck', false, index, replace == true)
    if not ok then return false, netIdOrError end
    truckNet = netIdOrError
    return true
end

---@return boolean ok, string? errorKey
function shift.returnTruck()
    local ok, errorKey = lib.callback.await('sw_tow:server:returnTruck', false)
    if ok then truckNet = nil end
    return ok, errorKey
end

---@param replace? boolean
local function takeTruckMenu(replace)
    local options = {}
    local deposit = config.garage.deposit or 0
    for index, option in ipairs(config.garage.vehicles) do
        local description = locale(option.method == 'flatbed' and 'garage.flatbed_hint' or 'garage.hook_hint')
        if deposit > 0 then description = description .. ' · ' .. locale('garage.deposit_hint', util.money(deposit)) end
        options[#options + 1] = {
            title = option.label,
            description = description,
            icon = 'truck',
            onSelect = function()
                local ok, errorKey = shift.takeTruck(index, replace)
                if ok then
                    notify(locale('garage.taken', option.label), 'success')
                else
                    result(false, errorKey)
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
                local ok, errorKey = shift.clockIn()
                result(ok, errorKey, 'shift.started')
            end,
        },
        {
            name = 'sw_tow_take_truck',
            icon = 'fa-solid fa-truck-pickup',
            label = locale('garage.take'),
            distance = 2.5,
            canInteract = function() return shift.onShift() and not shift.hasTruck() end,
            onSelect = function() takeTruckMenu(false) end,
        },
        {
            -- The truck is wrecked, stuck or far away: a new one, the old one's deposit is kept.
            name = 'sw_tow_replace_truck',
            icon = 'fa-solid fa-rotate',
            label = locale('garage.replace'),
            distance = 2.5,
            canInteract = function()
                local truck = shift.truck()
                local nearSpot = truck and #(GetEntityCoords(truck) - config.garage.spawn.xyz) <= config.garage.returnDistance
                return shift.onShift() and shift.hasTruck() and not nearSpot
            end,
            onSelect = function()
                local ok = lib.alertDialog({
                    header = locale('garage.replace'),
                    content = locale('garage.replace_hint'),
                    centered = true,
                    cancel = true,
                })
                if ok == 'confirm' then takeTruckMenu(true) end
            end,
        },
        {
            name = 'sw_tow_return_truck',
            icon = 'fa-solid fa-warehouse',
            label = locale('garage.return'),
            distance = 2.5,
            canInteract = function() return shift.onShift() and shift.truck() ~= nil end,
            onSelect = function()
                local ok, errorKey = shift.returnTruck()
                -- With a deposit the server's message says what came back.
                result(ok, errorKey, (config.garage.deposit or 0) == 0 and 'garage.returned' or nil)
            end,
        },
        {
            name = 'sw_tow_clock_out',
            icon = 'fa-solid fa-door-open',
            label = locale('shift.clock_out'),
            distance = 2.5,
            canInteract = function() return shift.onShift() end,
            onSelect = function()
                local ok, errorKey = shift.clockOut()
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
    local options = officeOptions()
    -- With a clerk the options live on the clerk only: a box around the same spot would list
    -- every option twice in ox_target.
    if office.ped then
        impound.createClerk(office.ped.coords or office.coords, office.ped, options)
    else
        exports.ox_target:addBoxZone({
            name = 'sw_tow_office',
            coords = office.coords.xyz,
            size = office.size,
            rotation = office.coords.w,
            debug = config.debug,
            options = options,
        })
    end
    impound.addBlip(office.coords.xyz, office.blip, office.label)
end

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then truckNet = nil end
end)

-- The game or another resource removed the company truck on the server. This client may still
-- show it; forgetting it brings back "Take a truck" at the counter.
RegisterNetEvent('sw_tow:client:truckLost', function()
    if not truckNet then return end
    truckNet = nil
    notify(locale('garage.lost'), 'error')
end)

return shift
