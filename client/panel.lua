---Shift panel (NUI). Visible only while on shift; then it is refreshed once per second.
---Off shift nothing runs, so the resource stays at 0.00 ms.
local config = require 'config'
local util = require 'shared.util'
local shift = require 'client.shift'
local calls = require 'client.calls'

local ui = config.ui
local visible = false
local stats = { deliveries = 0, earned = 0 }

local STRING_KEYS = {
    'truck', 'cargo', 'call', 'distance', 'shift', 'deadline', 'calls', 'empty', 'no_call', 'shift_value', 'km',
    'title_idle', 'title_player', 'title_police', 'title_contract', 'title_abandoned',
    'type_player', 'type_police', 'type_contract', 'type_abandoned',
}

local function init()
    local strings = {}
    for _, key in ipairs(STRING_KEYS) do strings[key] = locale('panel.' .. key) end
    SendNUIMessage({
        type = 'init',
        strings = strings,
        ui = {
            accent = ui.accent,
            position = ui.position,
            top = ui.top,
            scale = ui.scale,
            label = ui.label,
            logo = ui.logo,
            key = config.calls.listKey,
        },
    })
end

local function vehicleName(vehicle)
    local label = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)))
    return label ~= 'NULL' and label or GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
end

local function nearestYardDistance(from)
    local best
    for _, yard in pairs(config.yards) do
        local d = #(from - yard.zone.coords)
        if not best or d < best then best = d end
    end
    return best
end

local function snapshot()
    local truck = shift.truck()
    local state = { deliveries = stats.deliveries, earned = stats.earned }
    local origin = GetEntityCoords(cache.ped)

    if truck then
        state.truck = ('%s · %s'):format(vehicleName(truck), util.trimPlate(GetVehicleNumberPlateText(truck)))
        local cargoNet = Entity(truck).state['sw_tow:cargo']
        local cargo = cargoNet and NetworkDoesEntityExistWithNetworkId(cargoNet) and NetToVeh(cargoNet)
        if cargo and cargo ~= 0 then
            state.cargo = util.trimPlate(GetVehicleNumberPlateText(cargo))
            local d = nearestYardDistance(GetEntityCoords(truck))
            state.distance = d and d / 1000 or nil
        end
    end

    local call = calls.active()
    if call then
        local remaining = (call.deadline - GetGameTimer()) / 1000
        state.call = {
            type = call.type,
            plate = call.plate,
            remaining = remaining,
            total = config.calls.deliverTimeout * 60,
        }
        if not state.cargo then state.distance = #(origin - call.coords) / 1000 end
    end
    return state
end

local function show(value)
    if visible == value then return end
    visible = value
    SendNUIMessage({ type = 'visible', value = value })
    if not value then return end
    CreateThread(function()
        while visible do
            SendNUIMessage({ type = 'state', state = snapshot() })
            Wait(1000)
        end
    end)
end

local panel = {}
local probeWaiting

---What the panel shows right now, read from the page itself (for /swtow_test).
---@return table? texts { visible, title, truck, cargo, call, distance, shift, timer }, nil when the page does not answer
function panel.probe()
    if not ui.enabled then return end
    probeWaiting = promise.new()
    SendNUIMessage({ type = 'probe' })
    local waiting = probeWaiting
    SetTimeout(2000, function() if waiting then waiting:resolve(nil) end end)
    local texts = Citizen.Await(waiting)
    probeWaiting = nil
    return texts
end

RegisterNUICallback('probe', function(texts, respond)
    respond(true)
    if probeWaiting then probeWaiting:resolve(texts) end
end)

RegisterNetEvent('sw_tow:client:shiftStats', function(deliveries, earned)
    if type(deliveries) ~= 'number' or type(earned) ~= 'number' then return end
    stats.deliveries, stats.earned = deliveries, earned
end)

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then stats.deliveries, stats.earned = 0, 0 end
    show(ui.enabled and value == true)
end)

-- The page tells us when it has loaded; messages sent before that would be lost.
RegisterNUICallback('ready', function(_, respond)
    respond(true)
    if not ui.enabled then return end
    init()
    visible = false
    show(shift.onShift())
end)

return panel
