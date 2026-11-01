---Shift panel (NUI). Visible only while on shift; then it is refreshed once per second.
---Off shift nothing runs, so the resource stays at 0.00 ms.
local config = require 'config'
local util = require 'shared.util'
local shift = require 'client.shift'
local calls = require 'client.calls'
local dialog = require 'client.dialog'

local ui = config.ui
local visible = false
local stats = { deliveries = 0, earned = 0 }
local shiftStarted ---@type integer? game timer when this shift began

local STRING_KEYS = {
    'title_idle', 'title_player', 'title_police', 'title_contract', 'title_abandoned',
    'do_pickup', 'do_load', 'do_deliver', 'step_pickup', 'step_load', 'step_deliver',
    'at_pickup', 'at_yard', 'left', 'distance', 'deliver_within',
    'waiting', 'calls_open', 'open_short', 'take_hint', 'no_calls',
    'truck', 'no_truck', 'cargo', 'empty', 'earned', 'tows', 'km', 'm',
    'status_winching', 'status_lowering', 'status_secured', 'status_hooked',
    'do_return', 'do_office', 'title_return', 'at_depot',
}

---The server's ox_lib colour, when its owner set one (setr ox:primaryColor), so the panel matches
---their menus and notifications.
local function oxTheme()
    local color = GetConvar('ox:primaryColor', '')
    if color == '' then return end
    return { color = color, shade = GetConvarInt('ox:primaryShade', 8) }
end

local function init()
    local strings = {}
    for _, key in ipairs(STRING_KEYS) do strings[key] = locale('panel.' .. key) end
    local dialogStrings = {}
    for _, key in ipairs(dialog.STRING_KEYS) do dialogStrings[key] = locale('ui.' .. key) end
    SendNUIMessage({
        type = 'init',
        strings = strings,
        dialogStrings = dialogStrings,
        ui = {
            theme = ui.theme,
            accent = ui.accent,
            ox = oxTheme(),
            colors = ui.colors,
            font = ui.font,
            opacity = ui.opacity,
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
    local model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
    local label = GetLabelText(model)
    return label ~= 'NULL' and label or model
end

local function nearestYard(from)
    local best, bestDistance
    for _, yard in pairs(config.yards) do
        local d = #(from - yard.zone.coords)
        if not bestDistance or d < bestDistance then best, bestDistance = yard, d end
    end
    return best, bestDistance
end

local function streetAt(coords)
    return GetStreetNameFromHashKey((GetStreetNameAtCoord(coords.x, coords.y, coords.z)))
end

---What the cargo is doing: the winch moving it, strapped, or on the tow arm.
local function cargoStatus(truck)
    local winch = Entity(truck).state['sw_tow:winch']
    if type(winch) == 'table' then
        if winch.phase == 'pulling' then return 'winching' end
        if winch.phase == 'lowering' then return 'lowering' end
        return 'secured'
    end
    return Entity(truck).state['sw_tow:method'] == 'hook' and 'hooked' or 'secured'
end

local function snapshot()
    local truck = shift.truck()
    local state = {
        deliveries = stats.deliveries,
        earned = stats.earned,
        onShift = shiftStarted and (GetGameTimer() - shiftStarted) / 1000 or 0,
        open = calls.openCount(),
    }

    if truck then
        state.truck = { name = vehicleName(truck), plate = util.trimPlate(GetVehicleNumberPlateText(truck)) }
        local cargoNet = Entity(truck).state['sw_tow:cargo']
        local cargo = cargoNet and NetworkDoesEntityExistWithNetworkId(cargoNet) and NetToVeh(cargoNet)
        if cargo and cargo ~= 0 then
            state.cargo = util.trimPlate(GetVehicleNumberPlateText(cargo))
            state.status = cargoStatus(truck)
        end
    end

    local call = calls.active()
    if call then
        state.call = {
            type = call.type,
            plate = call.plate,
            remaining = (call.deadline - GetGameTimer()) / 1000,
            total = config.calls.deliverTimeout * 60,
        }
    end

    -- Where to go next: the depot when ending the shift, the yard with a vehicle on board, else the
    -- accepted call.
    local origin = GetEntityCoords(truck or cache.ped)
    local returning = calls.returning()
    if returning == 'depot' and truck then
        state.returning = 'depot'
        state.route = { to = 'depot', where = config.office.label, metres = select(2, util.nearestSpot(origin, util.truckSpots(config.garage))) }
    elseif returning == 'office' then
        state.returning = 'office'
        state.route = { to = 'office', where = config.office.label, metres = #(origin - config.office.coords.xyz) }
    elseif state.cargo then
        local yard, distance = nearestYard(origin)
        if yard then state.route = { to = 'yard', where = yard.label or streetAt(yard.zone.coords), metres = distance } end
    elseif call then
        state.route = { to = 'pickup', where = streetAt(call.coords), metres = #(origin - call.coords) }
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

-- For servers that draw their own HUD (ui.enabled = false): the data the panel shows, nil off shift.
exports('GetShiftState', function()
    if not shift.onShift() then return end
    return snapshot()
end)

local panel = {}
local probeWaiting

---What the panel shows right now, read from the page itself (for /swtow_test).
---@return table? texts { visible, title, kind, truck, cargo, distance, shift, timer }, nil when the page does not answer
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
    if value then
        shiftStarted = shiftStarted or GetGameTimer()
    else
        stats.deliveries, stats.earned, shiftStarted = 0, 0, nil
    end
    show(ui.enabled and value == true)
end)

-- The page tells us when it has loaded; messages sent before that would be lost.
RegisterNUICallback('ready', function(_, respond)
    respond(true)
    -- The window (counter, holds, order) needs the strings and colours even without the panel.
    init()
    if not ui.enabled then return end
    visible = false
    if shift.onShift() then shiftStarted = shiftStarted or GetGameTimer() end
    show(shift.onShift())
end)

return panel
