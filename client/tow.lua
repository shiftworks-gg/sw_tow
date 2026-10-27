---Loading vehicles onto company trucks.
---Flatbed: ramps and winch cable; see client/flatbed.lua.
---Tow truck: the game's own tow arm holds the vehicle.
local config = require 'config'
local util = require 'shared.util'
local notify = require 'client.notify'
local shift = require 'client.shift'
local impound = require 'client.impound'
local flatbed = require 'client.flatbed'

local busy = false
local cfg = config.flatbed

local function state(entity, key)
    return Entity(entity).state[key]
end

local function report(ok, errorKey, ...)
    if not ok then notify(locale(errorKey or 'common.failed', ...), 'error') end
    return ok
end

---@param entity integer
---@param timeout? integer ms
---@return boolean
local function requestControl(entity, timeout)
    if NetworkHasControlOfEntity(entity) then return true end
    local deadline = GetGameTimer() + (timeout or 3000)
    NetworkRequestControlOfEntity(entity)
    while not NetworkHasControlOfEntity(entity) do
        if GetGameTimer() > deadline or not DoesEntityExist(entity) then return false end
        NetworkRequestControlOfEntity(entity)
        Wait(50)
    end
    return true
end

local function rearOf(truck)
    local min = GetModelDimensions(GetEntityModel(truck))
    return GetOffsetFromEntityInWorldCoords(truck, 0.0, min.y, 0.0)
end

local function winchPoint(truck)
    return GetOffsetFromEntityInWorldCoords(truck, cfg.winch.x, cfg.winch.y, cfg.winch.z)
end

---The cable hook on the end of the vehicle that faces the truck, low on the bumper.
local function hookPoint(target, truck)
    local min, max = GetModelDimensions(GetEntityModel(target))
    local front = GetOffsetFromEntityInWorldCoords(target, 0.0, max.y - 0.15, min.z + 0.35)
    local back = GetOffsetFromEntityInWorldCoords(target, 0.0, min.y + 0.15, min.z + 0.35)
    local winch = winchPoint(truck)
    return #(front - winch) <= #(back - winch) and front or back
end

---Runs one truck action at a time and reports a refusal to the player.
---@param fn fun(): boolean?, string?, string?
local function exclusive(fn)
    if busy then return end
    busy = true
    flatbed.setBusy(true)
    local ok, result, errorKey, value = pcall(fn)
    busy = false
    flatbed.setBusy(false)
    if not ok then
        lib.print.error(result)
        report(false)
    elseif result == false then
        report(false, errorKey, value)
    end
end

local function load(truck, target)
    exclusive(function()
        local truckNet, targetNet = VehToNet(truck), VehToNet(target)
        local method = state(truck, 'sw_tow:method')
        if method == 'flatbed' then
            local inLine, lineError, value = flatbed.lineUp(truck, target)
            if not inLine then return false, lineError, value end
        end
        local ok, errorKey = lib.callback.await('sw_tow:server:attach', false, truckNet, targetNet)
        if not ok then return false, errorKey end

        if not requestControl(target) or (method == 'hook' and not requestControl(truck)) then
            lib.callback.await('sw_tow:server:detach', false, truckNet)
            return false, 'tow.no_control'
        end

        if method == 'flatbed' then
            local loaded, loadError = flatbed.load(truck, target)
            if not loaded then
                lib.callback.await('sw_tow:server:detach', false, truckNet)
                return false, loadError or 'tow.no_control'
            end
            return lib.callback.await('sw_tow:server:secured', false, truckNet)
        end

        SetVehicleTowTruckArmPosition(truck, 1.0)
        AttachVehicleToTowTruck(truck, target, false, 0.0, 0.0, 0.0)
        SetVehicleTowTruckArmPosition(truck, 0.0)
        return true
    end)
end

---The owner drove onto the lowered ramps; the worker straps the vehicle where it stands.
local function secureInPlace(truck, target)
    exclusive(function()
        local truckNet = VehToNet(truck)
        local ok, errorKey = lib.callback.await('sw_tow:server:attach', false, truckNet, VehToNet(target))
        if not ok then return false, errorKey end
        if not flatbed.secureInPlace(truck, target) then
            lib.callback.await('sw_tow:server:detach', false, truckNet)
            return false, 'tow.no_control'
        end
        return lib.callback.await('sw_tow:server:secured', false, truckNet)
    end)
end

local function unload(truck)
    local targetNet = state(truck, 'sw_tow:cargo')
    local target = targetNet and NetworkDoesEntityExistWithNetworkId(targetNet) and NetToVeh(targetNet)
    if not target or target == 0 then return end
    exclusive(function()
        local truckNet = VehToNet(truck)
        if not requestControl(target) or not lib.callback.await('sw_tow:server:lowering', false, truckNet) then
            return false, 'tow.no_control'
        end
        if state(truck, 'sw_tow:method') == 'flatbed' then
            local unloaded, unloadError = flatbed.unload(truck, target)
            if not unloaded then
                -- Still on the bed and strapped: it stays this truck's cargo.
                lib.callback.await('sw_tow:server:secured', false, truckNet)
                return false, unloadError or 'tow.cannot_unload'
            end
        else
            DetachVehicleFromTowTruck(truck, target)
        end
        -- Unloading inside a yard is the hand-over.
        local yardKey = impound.yardAt(GetEntityCoords(truck))
        if yardKey then
            local ok, errorKey = lib.callback.await('sw_tow:server:deliver', false, truckNet, yardKey, true)
            if ok then return true end
            lib.callback.await('sw_tow:server:detach', false, truckNet)
            return false, errorKey or 'common.failed'
        end
        lib.callback.await('sw_tow:server:detach', false, truckNet)
        return true
    end)
end

local function deliver(truck)
    local yardKey = impound.yardAt(GetEntityCoords(truck))
    if not yardKey then return end
    exclusive(function()
        return lib.callback.await('sw_tow:server:deliver', false, VehToNet(truck), yardKey)
    end)
end

local function toggleRamps(truck)
    exclusive(function()
        return flatbed.setRamps(truck, not flatbed.rampsDown(truck))
    end)
end

---Can the worker hook this vehicle with their own truck?
local function canLoad(entity, method)
    if busy or not shift.onShift() then return false end
    local truck = shift.truck()
    if not truck or entity == truck or state(truck, 'sw_tow:method') ~= method or state(truck, 'sw_tow:cargo') then return false end
    if state(entity, 'sw_tow:company') or state(entity, 'sw_tow:towedBy') then return false end
    if method == 'flatbed' then
        -- Shown for anything behind the truck; the line-up check then says exactly what to change.
        return not flatbed.isOnBed(truck, entity) and #(GetEntityCoords(entity) - rearOf(truck)) <= cfg.winchRange + 12.0
    end
    return #(GetEntityCoords(entity) - rearOf(truck)) <= config.hook.range
end

local function isMyFlatbed(entity)
    return not busy and shift.onShift() and entity == shift.truck() and state(entity, 'sw_tow:method') == 'flatbed'
        and state(entity, 'sw_tow:cargo') == nil
end

local function isMyLoadedTruck(entity)
    return not busy and shift.onShift() and entity == shift.truck() and state(entity, 'sw_tow:cargo') ~= nil
end

exports.ox_target:addGlobalVehicle({
    {
        name = 'sw_tow_ramps',
        icon = 'fa-solid fa-arrows-up-down',
        label = locale('tow.ramps'),
        distance = 4.0,
        canInteract = isMyFlatbed,
        onSelect = function(data) toggleRamps(data.entity) end,
    },
    {
        name = 'sw_tow_winch',
        icon = 'fa-solid fa-link',
        label = locale('tow.winch'),
        distance = 3.0,
        canInteract = function(entity) return canLoad(entity, 'flatbed') end,
        onSelect = function(data) load(shift.truck() --[[@as integer]], data.entity) end,
    },
    {
        name = 'sw_tow_secure',
        icon = 'fa-solid fa-lock',
        label = locale('tow.secure'),
        distance = 3.0,
        canInteract = function(entity)
            local truck = shift.truck()
            return truck ~= nil and entity ~= truck and isMyFlatbed(truck) and flatbed.rampsDown(truck)
                and flatbed.isOnBed(truck, entity)
        end,
        onSelect = function(data) secureInPlace(shift.truck() --[[@as integer]], data.entity) end,
    },
    {
        name = 'sw_tow_hook',
        icon = 'fa-solid fa-anchor',
        label = locale('tow.hook'),
        distance = 3.0,
        canInteract = function(entity) return canLoad(entity, 'hook') end,
        onSelect = function(data) load(shift.truck() --[[@as integer]], data.entity) end,
    },
    {
        name = 'sw_tow_deliver',
        icon = 'fa-solid fa-square-parking',
        label = locale('tow.deliver'),
        distance = 4.0,
        canInteract = function(entity) return isMyLoadedTruck(entity) and impound.yardAt(GetEntityCoords(entity)) ~= nil end,
        onSelect = function(data) deliver(data.entity) end,
    },
    {
        name = 'sw_tow_unload',
        icon = 'fa-solid fa-arrow-down-long',
        label = locale('tow.unload'),
        distance = 4.0,
        canInteract = isMyLoadedTruck,
        onSelect = function(data) unload(data.entity) end,
    },
})

-- Ramp candidates for config.flatbed.ramp.model: stand behind your flatbed and run /swtow_ramps
-- (all candidates) or /swtow_ramps <model> [<model> ...].
RegisterCommand('swtow_ramps', function(_, args)
    local truck = shift.truck()
    if not truck then return notify(locale('tow.need_truck'), 'error') end
    flatbed.previewRamps(truck, #args > 0 and args or cfg.ramp.candidates)
end, false)

-- Winch bench for tuning (debug only): stand behind your flatbed on level ground and run /swtow_bench.
RegisterCommand('swtow_bench', function()
    local truck = shift.truck()
    if not truck then return notify(locale('tow.need_truck'), 'error') end
    CreateThread(function() flatbed.bench(truck) end)
end, false)

-- Winch cable, drawn by every client that has the truck streamed in.

---@type table<integer, integer> truck entity -> rope handle
local ropes = {}

local function removeRope(truck)
    local rope = ropes[truck]
    ropes[truck] = nil
    if rope and DoesRopeExist(rope) then DeleteRope(rope) end
end

local function loadRopeTextures()
    if RopeAreTexturesLoaded() then return true end
    RopeLoadTextures()
    local deadline = GetGameTimer() + 3000
    while not RopeAreTexturesLoaded() do
        if GetGameTimer() > deadline then return false end
        Wait(0)
    end
    return true
end

---@type table<integer, integer> truck entity -> winch target this client is watching
local watching = {}

---Runs on every client near a truck while its winch moves a vehicle (state bag phase pulling or
---lowering): draws the cable, and lets this client's player pass through the moving vehicle (in
---physics mode too), so nobody can block a loading by standing in the way or be pushed over by it.
---@param truck integer
---@param target integer
local function watchWinch(truck, target)
    if watching[truck] == target then return end
    watching[truck] = target
    removeRope(truck)
    local rope
    if cfg.rope and loadRopeTextures() then
        local a, b = winchPoint(truck), hookPoint(target, truck)
        local length = #(a - b)
        -- Taut from the start (no slack to sag through the road), free to shorten as fast as the
        -- vehicle comes in, and long enough to pay out when it is let down.
        rope = AddRope(a.x, a.y, a.z, 0.0, 0.0, 0.0, math.max(length + 1.0, 40.0), 4, length, 0.1, 20.0,
            false, false, false, 1.0, false)
        ropes[truck] = rope
    end
    CreateThread(function()
        while watching[truck] == target do
            if not DoesEntityExist(truck) or not DoesEntityExist(target) then break end
            SetEntityNoCollisionEntity(target, cache.ped, true)
            if rope then
                -- The ends are pinned each frame instead of attaching the rope to the vehicles: an
                -- attached rope is a physical constraint and would pull on the vehicle.
                local w, h = winchPoint(truck), hookPoint(target, truck)
                local last = GetRopeVertexCount(rope) - 1
                if last > 0 then
                    PinRopeVertex(rope, 0, w.x, w.y, w.z)
                    PinRopeVertex(rope, last, h.x, h.y, h.z)
                end
                RopeForceLength(rope, #(w - h))
            end
            Wait(0)
        end
        if watching[truck] == target then watching[truck] = nil end
        if ropes[truck] == rope then removeRope(truck) end
    end)
end

AddStateBagChangeHandler('sw_tow:winch', '', function(bagName, _, value)
    CreateThread(function()
        local truck = util.entityFromBag(bagName, 1000)
        if not truck then return end
        if type(value) ~= 'table' or (value.phase ~= 'pulling' and value.phase ~= 'lowering') then
            watching[truck] = nil
            removeRope(truck)
            return
        end
        local target = NetworkDoesEntityExistWithNetworkId(value.target) and NetToVeh(value.target) or 0
        if target ~= 0 then watchWinch(truck, target) end
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    watching = {}
    for truck in pairs(ropes) do removeRope(truck) end
end)
