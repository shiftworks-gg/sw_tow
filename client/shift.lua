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

---The clerk exists only on this client and only while the player is within 60 m. Aiming at the
---clerk offers the same options as the counter.
---@param office table config.office
---@param options table[] ox_target options of the counter
local function createClerk(office, options)
    local cfg = office.ped
    if not cfg then return end
    local c = cfg.coords or office.coords
    local clerk
    local function remove()
        if clerk and DoesEntityExist(clerk) then DeletePed(clerk) end
        clerk = nil
    end
    lib.points.new({
        coords = c.xyz,
        distance = 60.0,
        onEnter = function()
            if clerk then return end
            local model = lib.requestModel(cfg.model)
            if not model then return end
            -- Stand on the floor under the point, whatever height the config coordinate was taken at.
            local found, groundZ = GetGroundZFor_3dCoord(c.x, c.y, c.z + 1.0, false)
            clerk = CreatePed(4, model, c.x, c.y, found and groundZ or c.z - 1.0, c.w, false, true)
            SetModelAsNoLongerNeeded(model)
            SetEntityInvincible(clerk, true)
            FreezeEntityPosition(clerk, true)
            SetBlockingOfNonTemporaryEvents(clerk, true)
            if cfg.scenario then TaskStartScenarioInPlace(clerk, cfg.scenario, 0, true) end
            exports.ox_target:addLocalEntity(clerk, options)
        end,
        onExit = remove,
    })
    AddEventHandler('onResourceStop', function(resource)
        if resource == cache.resource then remove() end
    end)
end

function shift.createOffice()
    local office = config.office
    local options = officeOptions()
    createClerk(office, options)
    exports.ox_target:addBoxZone({
        name = 'sw_tow_office',
        coords = office.coords.xyz,
        size = office.size,
        rotation = office.coords.w,
        debug = config.debug,
        options = options,
    })
    impound.addBlip(office.coords.xyz, office.blip, office.label)
end

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then truckNet = nil end
end)

return shift
