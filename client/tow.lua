---Loading vehicles onto company trucks.
---Flatbed: ramps and winch cable; see client/flatbed.lua.
---Tow truck: the game's own tow arm holds the vehicle.
local config = require 'config'
local util = require 'shared.util'
local notify = require 'client.notify'
local shift = require 'client.shift'
local impound = require 'client.impound'
local flatbed = require 'client.flatbed'
local sounds = require 'client.sounds'

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
---@return boolean ok, string? errorKey, string? value
local function exclusive(fn)
    if busy then return false, 'busy' end
    busy = true
    flatbed.setBusy(true)
    local ok, result, errorKey, value = pcall(fn)
    busy = false
    flatbed.setBusy(false)
    if not ok then
        lib.print.error(result)
        report(false)
        return false, 'common.failed'
    end
    if result == false then
        report(false, errorKey, value)
        return false, errorKey or 'common.failed', value
    end
    return true
end

local function load(truck, target)
    return exclusive(function()
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
        -- The arm only catches a vehicle close behind it; the server must not count a miss as cargo.
        local deadline = GetGameTimer() + 1000
        while not IsVehicleAttachedToTowTruck(truck, target) and GetGameTimer() < deadline do Wait(50) end
        if not IsVehicleAttachedToTowTruck(truck, target) then
            lib.callback.await('sw_tow:server:detach', false, truckNet)
            return false, 'tow.hook_missed'
        end
        return true
    end)
end

---The owner drove onto the lowered ramps; the worker straps the vehicle where it stands.
local function secureInPlace(truck, target)
    return exclusive(function()
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
    if not target or target == 0 then return false, 'impound.no_cargo' end
    return exclusive(function()
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
    if not yardKey then return false, 'impound.not_in_yard' end
    return exclusive(function()
        return lib.callback.await('sw_tow:server:deliver', false, VehToNet(truck), yardKey)
    end)
end

local function toggleRamps(truck)
    return exclusive(function()
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

---@type table<integer, integer[]> truck entity -> rope handles (two segments)
local ropes = {}
---@type table<integer, { a: vector3, b: vector3, frame: integer }> rope -> the line it was last pinned on, and when
local pinnedOn = {}

local function removeRope(truck)
    local list = ropes[truck]
    ropes[truck] = nil
    if not list then return end
    for i = 1, #list do
        pinnedOn[list[i]] = nil
        if DoesRopeExist(list[i]) then DeleteRope(list[i]) end
    end
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

---The cable's path: winch, bend, hook. While the hook is behind the bed the bend is the roller on
---its rear edge, so the cable lies on the bed and goes down over the edge; once the hook is up on
---the bed the bend sits half-way and the cable runs straight.
---@return vector3 winch, vector3 bend, vector3 hook
local function cablePath(truck, target, roller)
    local w, h = winchPoint(truck), hookPoint(target, truck)
    if GetOffsetFromEntityGivenWorldCoords(truck, h.x, h.y, h.z).y < roller.y then
        return w, GetOffsetFromEntityInWorldCoords(truck, roller.x, roller.y, roller.z), h
    end
    return w, (w + h) / 2, h
end

---Holds a segment straight between its ends: every point of the rope is pinned on the line, each
---frame. A winch cable under load is straight, and this way the game's rope physics never moves it:
---no sag through the ground, no swinging, whether it gets shorter (loading) or longer (unloading).
---Pinned instead of attached to the vehicles: an attached rope is a physical constraint and would
---pull on the vehicle.
local function holdSegment(rope, a, b)
    RopeForceLength(rope, math.max(0.1, #(a - b)))
    local last = GetRopeVertexCount(rope) - 1
    if last < 1 then return end
    local step = (b - a) / last
    for i = 0, last do
        local p = a + step * i
        PinRopeVertex(rope, i, p.x, p.y, p.z)
    end
    pinnedOn[rope] = { a = a, b = b, frame = GetFrameCount() }
end

---A cable segment, pinned straight in the frame it is made: a new rope lies in whatever direction
---the game gives it, and drawn so for even one frame it would flick out to the side.
local function newSegment(a, b)
    local length = #(a - b)
    local rope = AddRope(a.x, a.y, a.z, 0.0, 0.0, 0.0, math.max(length + 1.0, 40.0), 4, length, 0.1, 20.0,
        false, false, false, 1.0, false)
    holdSegment(rope, a, b)
    return rope
end

---How far the cable as drawn strays from the line it was pinned on: the farthest of its points, in
---metres. Read before this frame's pinning, the points are where the last frame drew them. Nil
---until the segment has been pinned in an earlier frame and drawn once.
---@return number?
local function sag(rope)
    local line = pinnedOn[rope]
    if not line or line.frame >= GetFrameCount() then return end
    local a, ab = line.a, line.b - line.a
    local lengthSq = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
    local worst = 0.0
    for i = 0, GetRopeVertexCount(rope) - 1 do
        local p = GetRopeVertexCoord(rope, i)
        local ap = p - a
        local t = lengthSq > 0.0 and (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / lengthSq or 0.0
        worst = math.max(worst, #(p - (a + ab * math.max(0.0, math.min(1.0, t)))))
    end
    return worst
end

---@class SwSag
---@field metres number largest sag seen
---@field segment integer 1 winch to bend, 2 bend to hook
---@field frame integer frames since the cable was made

-- Largest sag seen per truck while /swtow_test measures it (nil: not measuring).
---@type table<integer, SwSag>?
local sagSeen

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
    local list
    local roller = flatbed.rollerOffset(truck)
    if cfg.rope and loadRopeTextures() then
        local w, bend, h = cablePath(truck, target, roller)
        list = { newSegment(w, bend), newSegment(bend, h) }
        ropes[truck] = list
    end
    CreateThread(function()
        local motor = sounds.loop('winch', truck)
        local frame = 0
        while watching[truck] == target do
            if not DoesEntityExist(truck) or not DoesEntityExist(target) then break end
            SetEntityNoCollisionEntity(target, cache.ped, true)
            if list then
                frame = frame + 1
                if sagSeen then
                    for segment = 1, 2 do
                        local metres = sag(list[segment])
                        local worst = sagSeen[truck]
                        if metres and (not worst or metres > worst.metres) then
                            sagSeen[truck] = { metres = metres, segment = segment, frame = frame }
                        end
                    end
                end
                local w, bend, h = cablePath(truck, target, roller)
                holdSegment(list[1], w, bend)
                holdSegment(list[2], bend, h)
            end
            motor.keep()
            Wait(0)
        end
        motor.stop()
        if watching[truck] == target then watching[truck] = nil end
        if ropes[truck] == list then removeRope(truck) end
    end)
end

AddStateBagChangeHandler('sw_tow:winch', '', function(bagName, _, value)
    CreateThread(function()
        local truck, arrived = util.entityFromBag(bagName, 1000)
        if not truck then return end
        if type(value) ~= 'table' or (value.phase ~= 'pulling' and value.phase ~= 'lowering') then
            watching[truck] = nil
            removeRope(truck)
            if not arrived and type(value) == 'table' and value.phase == 'secured' then sounds.play('secured', truck) end
            return
        end
        local target = NetworkDoesEntityExistWithNetworkId(value.target) and NetToVeh(value.target) or 0
        if target ~= 0 then watchWinch(truck, target) end
    end)
end)

-- The tow arm catching and letting go of a vehicle, heard by everyone near the tow truck.
AddStateBagChangeHandler('sw_tow:cargo', '', function(bagName, _, value)
    CreateThread(function()
        local truck, arrived = util.entityFromBag(bagName, 1000)
        if not truck or arrived or state(truck, 'sw_tow:method') ~= 'hook' then return end
        sounds.play(value and 'hookOn' or 'hookOff', truck)
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    watching = {}
    for truck in pairs(ropes) do removeRope(truck) end
end)

---The worker's truck actions, as the target options run them (also used by /swtow_test).
---Each returns ok, errorKey.
return {
    load = load,
    unload = unload,
    deliver = deliver,
    secureInPlace = secureInPlace,
    toggleRamps = toggleRamps,
    isBusy = function() return busy end,
    ---/swtow_test: start measuring how far the cable sags; returns the largest sag per truck so far
    ---(SwSag: metres, which segment, on which frame).
    measureSag = function()
        sagSeen = sagSeen or {}
        return sagSeen
    end,
}
