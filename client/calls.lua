---The workers' call list (ox_lib context menu until the panel ships) and the route to an accepted call.
local config = require 'config'
local notify = require 'client.notify'
local shift = require 'client.shift'

local calls = {}
local routeBlip
local activeCallId
---@type { id: integer, type: string, plate: string, coords: vector3, deadline: integer }?
local activeCall

---The call this worker accepted, for the panel.
function calls.active()
    return activeCall
end

local typeIcons = {
    player = 'phone',
    police = 'shield-halved',
    contract = 'screwdriver-wrench',
    abandoned = 'hourglass-half',
}

local function clearRoute()
    if routeBlip and DoesBlipExist(routeBlip) then RemoveBlip(routeBlip) end
    routeBlip, activeCallId, activeCall = nil, nil, nil
end

local function setRoute(id, coords)
    clearRoute()
    activeCallId = id
    routeBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(routeBlip, 68)
    SetBlipColour(routeBlip, 47)
    SetBlipRoute(routeBlip, true)
    SetBlipRouteColour(routeBlip, 47)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(locale('calls.blip'))
    EndTextCommandSetBlipName(routeBlip)
end

local function streetAt(coords)
    local street = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    return GetStreetNameFromHashKey(street)
end

local function minutes(seconds)
    return math.max(1, math.floor(seconds / 60))
end

local function openList()
    if not shift.onShift() then return end
    local list = lib.callback.await('sw_tow:server:listCalls', false)
    if #list == 0 then
        notify(locale('calls.empty'), 'inform')
        return
    end

    local options = {}
    for _, call in ipairs(list) do
        local coords = vec3(call.coords.x, call.coords.y, call.coords.z)
        local distance = #(GetEntityCoords(cache.ped) - coords) / 1000
        local description = locale('calls.line', streetAt(coords), ('%.1f'):format(distance), minutes(call.age))
        if call.message ~= '' then description = description .. '\n' .. call.message end
        options[#options + 1] = {
            title = ('#%d · %s · %s%s'):format(call.id, locale('calls.type_' .. call.type), call.plate,
                call.mine and (' · ' .. locale('calls.yours')) or ''),
            description = description,
            icon = call.mine and 'location-dot' or (typeIcons[call.type] or 'phone'),
            onSelect = function()
                if call.mine then
                    local ok = lib.callback.await('sw_tow:server:dropCall', false, call.id)
                    if ok then
                        clearRoute()
                        notify(locale('calls.dropped'), 'inform')
                    end
                    return
                end
                local ok, result = lib.callback.await('sw_tow:server:acceptCall', false, call.id)
                if ok then
                    setRoute(call.id, result)
                    activeCall = {
                        id = call.id,
                        type = call.type,
                        plate = call.plate,
                        coords = vec3(result.x, result.y, result.z),
                        deadline = GetGameTimer() + config.calls.deliverTimeout * 60000,
                    }
                    notify(locale('calls.route_set'), 'success')
                else
                    notify(locale(result or 'common.failed'), 'error')
                end
            end,
        }
    end
    lib.registerContext({ id = 'sw_tow_calls', title = locale('calls.title'), options = options })
    lib.showContext('sw_tow_calls')
end

RegisterCommand(config.calls.listCommand, openList, false)

lib.addKeybind({
    name = 'sw_tow_calls',
    description = locale('calls.keybind'),
    defaultKey = config.calls.listKey,
    onPressed = openList,
})

RegisterNetEvent('sw_tow:client:callClosed', function(id)
    if id == activeCallId then clearRoute() end
end)

RegisterNetEvent('sw_tow:client:callsChanged', function()
    -- The list is fetched when opened; nothing to keep in sync here yet.
end)

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then clearRoute() end
end)

return calls
