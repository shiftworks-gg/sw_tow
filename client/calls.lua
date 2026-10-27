---The workers' call list (ox_lib context menu until the panel ships) and the route to an accepted call.
local config = require 'config'
local notify = require 'client.notify'
local util = require 'shared.util'
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

---What the route blip points at: 'call' (the vehicle to pick up) or 'yard' (where to hand it over).
---@type 'call'|'yard'?
local routeTarget

local function removeBlip()
    if routeBlip and DoesBlipExist(routeBlip) then RemoveBlip(routeBlip) end
    routeBlip, routeTarget = nil, nil
end

local function clearRoute()
    removeBlip()
    activeCallId, activeCall = nil, nil
end

---@param coords vector3
---@param sprite integer
---@param label string
local function drawRoute(coords, sprite, label)
    removeBlip()
    routeBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(routeBlip, sprite)
    SetBlipColour(routeBlip, 47)
    SetBlipAsShortRange(routeBlip, false)
    SetBlipRoute(routeBlip, true)
    SetBlipRouteColour(routeBlip, 47)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(routeBlip)
end

local function setRoute(id, coords)
    clearRoute()
    activeCallId = id
    drawRoute(coords, 68, locale('calls.blip'))
    routeTarget = 'call'
end

---@param from vector3
---@return table? yard
local function nearestYard(from)
    local best, bestDistance
    for _, yard in pairs(config.yards) do
        local distance = #(from - yard.zone.coords)
        if not bestDistance or distance < bestDistance then best, bestDistance = yard, distance end
    end
    return best
end

---Hand-over zone of the yard the route leads to, drawn on the ground while a vehicle is loaded.
---@type table?
local drawnZone

CreateThread(function()
    local hinted = false
    while true do
        local wait = 500
        local zone = routeTarget == 'yard' and drawnZone or nil
        if zone then
            local origin = GetEntityCoords(cache.ped)
            if #(origin - zone.coords) < 200.0 then
                wait = 0
                local rad = math.rad(zone.rotation or 0.0)
                local c, s = math.cos(rad), math.sin(rad)
                local hx, hy = zone.size.x / 2, zone.size.y / 2
                local z = zone.coords.z - 0.8
                local points = {}
                for i, sign in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
                    local lx, ly = sign[1] * hx, sign[2] * hy
                    points[i] = vec3(zone.coords.x + lx * c - ly * s, zone.coords.y + lx * s + ly * c, z)
                end
                for i = 1, 4 do
                    local a, b = points[i], points[i % 4 + 1]
                    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 255, 122, 46, 255)
                    DrawLine(a.x, a.y, a.z + 1.5, b.x, b.y, b.z + 1.5, 255, 122, 46, 255)
                    DrawLine(a.x, a.y, a.z, a.x, a.y, a.z + 1.5, 255, 122, 46, 255)
                    DrawPoly(a.x, a.y, a.z + 1.5, b.x, b.y, b.z + 1.5, a.x, a.y, a.z, 255, 122, 46, 60)
                    DrawPoly(b.x, b.y, b.z, a.x, a.y, a.z, b.x, b.y, b.z + 1.5, 255, 122, 46, 60)
                end
                DrawMarker(1, zone.coords.x, zone.coords.y, z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    zone.size.x, zone.size.y, 0.4, 255, 122, 46, 40, false, false, 2, false, nil, nil, false)

                local truck = shift.truck()
                local inside = truck ~= nil and util.inZone(GetEntityCoords(truck), zone)
                if inside and not hinted then
                    lib.showTextUI(locale('tow.yard_hint'))
                    hinted = true
                elseif not inside and hinted then
                    lib.hideTextUI()
                    hinted = false
                end
            end
        end
        if hinted and (wait > 0 or not zone) then
            lib.hideTextUI()
            hinted = false
        end
        Wait(wait)
    end
end)

-- Once the vehicle is on the truck the route leads to the nearest yard; if it comes off again
-- before delivery, back to the call.
CreateThread(function()
    while true do
        Wait(1000)
        if shift.onShift() then
            local truck = shift.truck()
            local loaded = truck ~= nil and Entity(truck).state['sw_tow:cargo'] ~= nil
            if loaded and routeTarget ~= 'yard' then
                local yard = nearestYard(GetEntityCoords(truck))
                if yard then
                    drawRoute(yard.zone.coords, yard.blip and yard.blip.sprite or 524, yard.label)
                    routeTarget = 'yard'
                    drawnZone = yard.zone
                    notify(locale('calls.route_yard'), 'success')
                end
            elseif not loaded and routeTarget == 'yard' then
                if activeCall then
                    drawRoute(activeCall.coords, 68, locale('calls.blip'))
                    routeTarget = 'call'
                else
                    removeBlip()
                end
            end
        end
    end
end)

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
