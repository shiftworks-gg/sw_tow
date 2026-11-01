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

---Shots filmed without interface hide the hand-over bay (the zone itself still works).
local filmHidden = false

---@param visible boolean
function calls.setZoneVisible(visible)
    filmHidden = not visible
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

local ZONE_COLOR = { 255, 122, 46 }
local ZONE_READY = { 64, 200, 110 }

---A point of the zone on the ground: `lx` m to the zone's right, `ly` m along it (its rotation is
---the way the truck drives in).
local function zonePoint(zone, lx, ly)
    local rad = math.rad(zone.rotation or 0.0)
    local c, s = math.cos(rad), math.sin(rad)
    local x, y = zone.coords.x + lx * c - ly * s, zone.coords.y + lx * s + ly * c
    local found, z = GetGroundZFor_3dCoord(x, y, zone.coords.z + 2.0, false)
    return vec3(x, y, (found and z or zone.coords.z - 0.9) + 0.04)
end

---The zone painted on the ground in strips, so it follows kerbs and slopes instead of floating
---as a box through walls. Measured once per zone: the ground does not move.
local painted = {} ---@type table<table, { strips: vector3[][], arrows: vector3[][] }>

local function paint(zone)
    if painted[zone] then return painted[zone] end
    local hx, hy = zone.size.x / 2, zone.size.y / 2
    local steps = math.max(2, math.ceil(zone.size.y / 2.5))
    local strips = {}
    for i = 0, steps - 1 do
        local y0, y1 = -hy + zone.size.y * i / steps, -hy + zone.size.y * (i + 1) / steps
        strips[#strips + 1] = { zonePoint(zone, -hx, y0), zonePoint(zone, hx, y0), zonePoint(zone, hx, y1), zonePoint(zone, -hx, y1) }
    end
    -- Chevrons down the middle, pointing the way in.
    local arrows, w = {}, math.min(hx * 0.5, 1.2)
    for _, y in ipairs({ -hy * 0.45, 0.0, hy * 0.45 }) do
        arrows[#arrows + 1] = { zonePoint(zone, -w, y - w * 0.8), zonePoint(zone, 0.0, y), zonePoint(zone, w, y - w * 0.8) }
    end
    painted[zone] = { strips = strips, arrows = arrows }
    return painted[zone]
end

local function line(a, b, r, g, bl)
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, 255)
end

---The hand-over bay on the ground, so the worker sees where to stop the truck; green once the truck
---stands in it.
---@param zone { coords: vector3, size: vector3, rotation?: number }
---@param ready? boolean
local function drawZone(zone, ready)
    local color = ready and ZONE_READY or ZONE_COLOR
    local r, g, b = color[1], color[2], color[3]
    local p = paint(zone)
    for i, q in ipairs(p.strips) do
        -- Both windings, so the tint shows from any camera angle.
        DrawPoly(q[1].x, q[1].y, q[1].z, q[2].x, q[2].y, q[2].z, q[3].x, q[3].y, q[3].z, r, g, b, 55)
        DrawPoly(q[3].x, q[3].y, q[3].z, q[2].x, q[2].y, q[2].z, q[1].x, q[1].y, q[1].z, r, g, b, 55)
        DrawPoly(q[1].x, q[1].y, q[1].z, q[3].x, q[3].y, q[3].z, q[4].x, q[4].y, q[4].z, r, g, b, 55)
        DrawPoly(q[4].x, q[4].y, q[4].z, q[3].x, q[3].y, q[3].z, q[1].x, q[1].y, q[1].z, r, g, b, 55)
        line(q[1], q[4], r, g, b)
        line(q[2], q[3], r, g, b)
        if i == 1 then line(q[1], q[2], r, g, b) end
        if i == #p.strips then line(q[4], q[3], r, g, b) end
    end
    for _, a in ipairs(p.arrows) do
        line(a[1], a[2], r, g, b)
        line(a[2], a[3], r, g, b)
    end
end

---Once the vehicle is on the truck the route leads to the nearest yard; if it comes off again
---before delivery, back to the call.
local function updateRoute()
    local truck = shift.truck()
    local loaded = truck ~= nil and Entity(truck).state['sw_tow:cargo'] ~= nil
    if truck and loaded and routeTarget ~= 'yard' then
        local yard = nearestYard(GetEntityCoords(truck))
        if yard then
            drawRoute(yard.zone.coords, yard.blip and yard.blip.sprite or 524, yard.label)
            routeTarget = 'yard'
            drawnZone = yard.zone
            notify(locale('calls.route_yard'), 'success')
        end
    elseif not loaded and routeTarget == 'yard' then
        -- Unloaded inside the yard is a hand-over: the call is closing, callClosed clears the route.
        local inYard = false
        if truck and drawnZone then inYard = util.inZone(GetEntityCoords(truck), drawnZone) end
        if activeCall and not inYard then
            drawRoute(activeCall.coords, 68, locale('calls.blip'))
            routeTarget = 'call'
        else
            removeBlip()
        end
    end
end

local routing = false

---Runs only while on shift: keeps the route up to date and draws the hand-over zone when the
---worker is within 200 m of it with a loaded truck.
local function runRoute()
    if routing then return end
    routing = true
    local hinted, nextCheck = false, 0
    while shift.onShift() do
        local now = GetGameTimer()
        if now >= nextCheck then
            nextCheck = now + 1000
            updateRoute()
        end
        local zone = routeTarget == 'yard' and drawnZone or nil
        local near = zone ~= nil and #(GetEntityCoords(cache.ped) - zone.coords) < 200.0
        local inside = false
        if zone and near then
            local truck = shift.truck()
            inside = truck ~= nil and util.inZone(GetEntityCoords(truck), zone)
            if not filmHidden then drawZone(zone, inside) end
        end
        if inside ~= hinted then
            if inside then lib.showTextUI(locale('tow.yard_hint')) else lib.hideTextUI() end
            hinted = inside
        end
        Wait(near and 0 or 500)
    end
    if hinted then lib.hideTextUI() end
    routing = false
end

local function streetAt(coords)
    local street = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    return GetStreetNameFromHashKey(street)
end

local function minutes(seconds)
    return math.max(1, math.floor(seconds / 60))
end

---The calls this worker can see: open ones and their own.
---@return table[]
function calls.list()
    if not shift.onShift() then return {} end
    return lib.callback.await('sw_tow:server:listCalls', false) or {}
end

---Accepts a call and sets the route to it.
---@param call { id: integer, type: string, plate: string } an entry of calls.list()
---@return boolean ok, string? errorKey
function calls.accept(call)
    local ok, result = lib.callback.await('sw_tow:server:acceptCall', false, call.id)
    if not ok then return false, result end
    setRoute(call.id, result)
    activeCall = {
        id = call.id,
        type = call.type,
        plate = call.plate,
        coords = vec3(result.x, result.y, result.z),
        deadline = GetGameTimer() + config.calls.deliverTimeout * 60000,
    }
    return true
end

---Gives an accepted call back to the list.
---@param id integer
---@return boolean ok, string? errorKey
function calls.drop(id)
    local ok, errorKey = lib.callback.await('sw_tow:server:dropCall', false, id)
    if ok then clearRoute() end
    return ok, errorKey
end

local function openList()
    if not shift.onShift() then return end
    local list = calls.list()
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
                local ok, errorKey
                if call.mine then
                    ok, errorKey = calls.drop(call.id)
                    if ok then notify(locale('calls.dropped'), 'inform') end
                else
                    ok, errorKey = calls.accept(call)
                    if ok then notify(locale('calls.route_set'), 'success') end
                end
                if not ok then notify(locale(errorKey or 'common.failed'), 'error') end
            end,
        }
    end
    lib.registerContext({ id = 'sw_tow_calls', title = locale('calls.title'), options = options })
    lib.showContext('sw_tow_calls')
end

calls.openList = openList

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

---How many calls are waiting for a worker; nil until the server first says.
---@type integer?
local openCount

---@return integer?
function calls.openCount()
    return openCount
end

RegisterNetEvent('sw_tow:client:callsChanged', function(open)
    -- The list itself is fetched when opened; the panel shows how many are waiting.
    if type(open) == 'number' then openCount = open end
end)

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then
        openCount = nil
        return clearRoute()
    end
    CreateThread(runRoute)
    -- Calls opened before this shift: counted once, then kept up by callsChanged.
    CreateThread(function()
        local n = 0
        for _, call in ipairs(calls.list()) do
            if not call.mine then n = n + 1 end
        end
        openCount = openCount or n
    end)
end)

return calls
