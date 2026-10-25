---Loading vehicles onto company trucks.
---Flatbed: the worker hooks the winch cable, the vehicle is pulled behind the truck and up onto the
---bed. The worker's client moves the vehicle through attachment offsets (synced by the game); every
---client nearby draws the cable locally from the truck's `sw_tow:winch` state bag.
---Tow truck: the game's own tow arm holds the vehicle.
local config = require 'config'
local util = require 'shared.util'
local notify = require 'client.notify'
local shift = require 'client.shift'
local impound = require 'client.impound'

local busy = false
local cfg = config.flatbed

local function state(entity, key)
    return Entity(entity).state[key]
end

local function report(ok, errorKey)
    if not ok then notify(locale(errorKey or 'common.failed'), 'error') end
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

local function dimensions(entity)
    local min, max = GetModelDimensions(GetEntityModel(entity))
    return min, max
end

local function boneOf(truck)
    local index = GetEntityBoneIndexByName(truck, cfg.bone)
    return index ~= -1 and index or 0
end

---Position of the bone in the truck's own space; attachment offsets are relative to it.
local function boneOffset(truck, bone)
    if bone == 0 then return vec3(0.0, 0.0, 0.0) end
    return GetOffsetFromEntityGivenWorldCoords(truck, GetWorldPositionOfEntityBone(truck, bone))
end

local function rearOf(truck)
    local min = dimensions(truck)
    return GetOffsetFromEntityInWorldCoords(truck, 0.0, min.y, 0.0)
end

local function winchPoint(truck)
    return GetOffsetFromEntityInWorldCoords(truck, cfg.winch.x, cfg.winch.y, cfg.winch.z)
end

local function hookPoint(target)
    local min, max = dimensions(target)
    return GetOffsetFromEntityInWorldCoords(target, 0.0, max.y - 0.15, min.z + 0.35)
end

local function normalizeAngle(angle)
    return (angle + 180.0) % 360.0 - 180.0
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

---Moves an attached vehicle through keyframes at winch speed. Returns false if either entity is gone.
---@param keyframes { pos: vector3, rot: vector3 }[] offsets relative to the bone
local function animate(truck, target, bone, keyframes)
    for i = 1, #keyframes - 1 do
        local from, to = keyframes[i], keyframes[i + 1]
        local duration = math.max(300.0, #(to.pos - from.pos) / cfg.pullSpeed * 1000.0)
        local start = GetGameTimer()
        local t = 0.0
        while t < 1.0 do
            if not DoesEntityExist(truck) or not DoesEntityExist(target) then return false end
            t = math.min(1.0, (GetGameTimer() - start) / duration)
            local p, r = lerp(from.pos, to.pos, t), lerp(from.rot, to.rot, t)
            AttachEntityToEntity(target, truck, bone, p.x, p.y, p.z, r.x, r.y, r.z, false, false, false, false, 2, true)
            Wait(0)
        end
    end
    return true
end

---Offsets (relative to the bone) for a vehicle standing on the ground behind the bed and on the bed.
local function pathPoints(truck, target, bone)
    local offset = boneOffset(truck, bone)
    local min = dimensions(target)
    local groundZ = -GetEntityHeightAboveGround(truck) - min.z
    local behind = vec3(0.0, cfg.rampStart.y, groundZ) - offset
    local onBed = vec3(cfg.bed.x, cfg.bed.y, cfg.bed.z - min.z) - offset
    return behind, onBed, offset
end

local function winchOn(truck, target)
    local bone = boneOf(truck)
    local behind, onBed, offset = pathPoints(truck, target, bone)
    local start = GetOffsetFromEntityGivenWorldCoords(truck, GetEntityCoords(target)) - offset
    local heading = normalizeAngle(GetEntityHeading(target) - GetEntityHeading(truck))
    return animate(truck, target, bone, {
        { pos = start, rot = vec3(0.0, 0.0, heading) },
        { pos = vec3(behind.x, behind.y, start.z), rot = vec3(0.0, 0.0, 0.0) },
        { pos = onBed, rot = vec3(0.0, 0.0, 0.0) },
    })
end

local function winchOff(truck, target)
    local bone = boneOf(truck)
    local behind, onBed = pathPoints(truck, target, bone)
    local ok = animate(truck, target, bone, {
        { pos = onBed, rot = vec3(0.0, 0.0, 0.0) },
        { pos = behind, rot = vec3(0.0, 0.0, 0.0) },
    })
    if DoesEntityExist(target) then
        DetachEntity(target, true, true)
        SetVehicleOnGroundProperly(target)
    end
    return ok
end

---@param truck integer
---@param target integer
local function load(truck, target)
    if busy then return end
    busy = true
    local truckNet, targetNet = VehToNet(truck), VehToNet(target)
    local method = state(truck, 'sw_tow:method')
    local ok, errorKey = lib.callback.await('sw_tow:server:attach', false, truckNet, targetNet)
    if not report(ok, errorKey) then busy = false return end

    if not requestControl(target) or (method == 'hook' and not requestControl(truck)) then
        lib.callback.await('sw_tow:server:detach', false, truckNet)
        report(false, 'tow.no_control')
        busy = false
        return
    end

    if method == 'flatbed' then
        SetVehicleDoorsShut(target, false)
        if winchOn(truck, target) then
            report(lib.callback.await('sw_tow:server:secured', false, truckNet))
        else
            lib.callback.await('sw_tow:server:detach', false, truckNet)
        end
    else
        SetVehicleTowTruckArmPosition(truck, 1.0)
        AttachVehicleToTowTruck(truck, target, false, 0.0, 0.0, 0.0)
        SetVehicleTowTruckArmPosition(truck, 0.0)
    end
    busy = false
end

local function unload(truck)
    if busy then return end
    local targetNet = state(truck, 'sw_tow:cargo')
    local target = targetNet and NetworkDoesEntityExistWithNetworkId(targetNet) and NetToVeh(targetNet)
    if not target or target == 0 then return end
    busy = true
    local truckNet = VehToNet(truck)
    if requestControl(target) and lib.callback.await('sw_tow:server:lowering', false, truckNet) then
        if state(truck, 'sw_tow:method') == 'flatbed' then
            winchOff(truck, target)
        else
            DetachVehicleFromTowTruck(truck, target)
        end
        lib.callback.await('sw_tow:server:detach', false, truckNet)
    else
        report(false, 'tow.no_control')
    end
    busy = false
end

local function deliver(truck)
    if busy then return end
    local yardKey = impound.yardAt(GetEntityCoords(truck))
    if not yardKey then return end
    busy = true
    report(lib.callback.await('sw_tow:server:deliver', false, VehToNet(truck), yardKey))
    busy = false
end

---Can the worker hook this vehicle with their own truck?
local function canLoad(entity, method)
    if busy or not shift.onShift() then return false end
    local truck = shift.truck()
    if not truck or entity == truck or state(truck, 'sw_tow:method') ~= method or state(truck, 'sw_tow:cargo') then return false end
    if state(entity, 'sw_tow:company') or state(entity, 'sw_tow:towedBy') then return false end
    local range = method == 'flatbed' and cfg.winchRange or config.hook.range
    return #(GetEntityCoords(entity) - rearOf(truck)) <= range
end

local function isMyLoadedTruck(entity)
    return not busy and shift.onShift() and entity == shift.truck() and state(entity, 'sw_tow:cargo') ~= nil
end

exports.ox_target:addGlobalVehicle({
    {
        name = 'sw_tow_winch',
        icon = 'fa-solid fa-link',
        label = locale('tow.winch'),
        distance = 3.0,
        canInteract = function(entity) return canLoad(entity, 'flatbed') end,
        onSelect = function(data) load(shift.truck(), data.entity) end,
    },
    {
        name = 'sw_tow_hook',
        icon = 'fa-solid fa-anchor',
        label = locale('tow.hook'),
        distance = 3.0,
        canInteract = function(entity) return canLoad(entity, 'hook') end,
        onSelect = function(data) load(shift.truck(), data.entity) end,
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

local function startRope(truck, target)
    removeRope(truck)
    if not loadRopeTextures() then return end
    local a, b = winchPoint(truck), hookPoint(target)
    local length = #(a - b)
    local rope = AddRope(a.x, a.y, a.z, 0.0, 0.0, 0.0, length, 4, length + 2.0, 0.5, 0.5, false, false, false, 1.0, false)
    AttachEntitiesToRope(rope, truck, target, a.x, a.y, a.z, b.x, b.y, b.z, length, false, false, nil, nil)
    ropes[truck] = rope
    CreateThread(function()
        -- Runs only while the cable is out: keeps its length equal to the real distance.
        while ropes[truck] == rope do
            if not DoesEntityExist(truck) or not DoesEntityExist(target) then
                removeRope(truck)
                return
            end
            RopeForceLength(rope, #(winchPoint(truck) - hookPoint(target)))
            Wait(0)
        end
    end)
end

AddStateBagChangeHandler('sw_tow:winch', '', function(bagName, _, value)
    if not cfg.rope then return end
    CreateThread(function()
        local truck = util.entityFromBag(bagName, 1000)
        if not truck then return end
        if type(value) ~= 'table' or (value.phase ~= 'pulling' and value.phase ~= 'lowering') then
            removeRope(truck)
            return
        end
        local target = NetworkDoesEntityExistWithNetworkId(value.target) and NetToVeh(value.target) or 0
        if target ~= 0 then startRope(truck, target) end
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for truck in pairs(ropes) do removeRope(truck) end
end)
