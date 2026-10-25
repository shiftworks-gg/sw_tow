---Flatbed loading with real physics. The vanilla flatbed has a fixed bed, so loading works like a
---car hauler: ramps go down behind the bed, the winch cable is hooked to the vehicle, and the winch
---pulls it up the ramps. While it is pulled the vehicle is not attached to anything: it stands on its
---own wheels, rolls, and the game's physics carries it over the bend between ramp and bed. The winch
---only sets the speed along the truck. The vehicle is attached once it rests on the bed ("secured").
---
---Ramps are local objects that every client creates from the truck's `sw_tow:ramps` state bag, so
---the client that simulates the vehicle always has them. The truck is frozen while they are down.
local config = require 'config'
local util = require 'shared.util'

local cfg = config.flatbed
local flatbed = {}

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

---Truck axes in world space: forward and right, flat on the ground plane.
---@param truck integer
---@return vector3 forward, vector3 right
local function axes(truck)
    local origin = GetEntityCoords(truck)
    local f = GetOffsetFromEntityInWorldCoords(truck, 0.0, 1.0, 0.0) - origin
    f = norm(vec3(f.x, f.y, 0.0))
    return f, vec3(f.y, -f.x, 0.0)
end

---A point in the truck's own space (x right, y forward, z up).
---@param truck integer
---@param point vector3
---@return vector3
local function toTruck(truck, point)
    return GetOffsetFromEntityGivenWorldCoords(truck, point.x, point.y, point.z)
end

-- Geometry of the bed, measured on the truck itself -----------------------------------------------

---Height of the bed surface just inside its rear edge, found with a ray straight down onto the truck.
---@param truck integer
---@return vector3? rearTop world point on the bed surface at the rear edge
local function bedRear(truck)
    local min, max = GetModelDimensions(GetEntityModel(truck))
    local y = cfg.rearY or (min.y + 0.35)
    local from = GetOffsetFromEntityInWorldCoords(truck, 0.0, y, max.z + 1.0)
    local to = GetOffsetFromEntityInWorldCoords(truck, 0.0, y, min.z)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 2, 0, 7)
    local _, hit, point, _, entity = GetShapeTestResult(probe)
    if hit == 1 and entity == truck then return point end
    -- No hit (unusual model): fall back to the configured bed height.
    return GetOffsetFromEntityInWorldCoords(truck, 0.0, y, cfg.bedHeight or 0.55)
end

-- Ramps ------------------------------------------------------------------------------------------

---@type table<integer, integer[]> truck entity -> ramp objects on this client
local ramps = {}

---World transforms for the ramps: their top edge meets the rear edge of the bed, their foot is on
---the ground. The slope follows from the ramp model's length and the measured bed height.
---@param truck integer
---@return { pos: vector3, rot: vector3 }[]? transforms, number? angle degrees
local function rampTransforms(truck)
    local model = joaat(cfg.ramp.model)
    local top = bedRear(truck)
    if not top then return end
    local f, right = axes(truck)
    local min, max = GetModelDimensions(model)
    local length = max.y - min.y
    local found, groundZ = GetGroundZFor_3dCoord(top.x - f.x * length, top.y - f.y * length, top.z + 0.5, false)
    if not found then groundZ = GetEntityCoords(truck).z - GetEntityHeightAboveGround(truck) end
    local rise = math.max(0.05, top.z - groundZ)
    local pitch = math.asin(math.min(1.0, rise / length))

    -- Ramp axes after tilting nose-up towards the truck.
    local along = vec3(f.x * math.cos(pitch), f.y * math.cos(pitch), math.sin(pitch))
    local up = vec3(-f.x * math.sin(pitch), -f.y * math.sin(pitch), math.cos(pitch))
    -- Midpoint of the ramp's top surface, then back to the model origin.
    local mid = top - along * (length / 2)
    local origin = mid - up * max.z - along * ((max.y + min.y) / 2)

    local heading = GetEntityHeading(truck)
    local rot = vec3(math.deg(pitch), 0.0, heading)
    local offsets = cfg.ramp.pair and { -cfg.ramp.spacing / 2, cfg.ramp.spacing / 2 } or { 0.0 }
    local list = {}
    for i = 1, #offsets do
        list[i] = { pos = origin + right * offsets[i], rot = rot }
    end
    return list, math.deg(pitch)
end

local function removeRamps(truck)
    local list = ramps[truck]
    ramps[truck] = nil
    if not list then return end
    for i = 1, #list do
        if DoesEntityExist(list[i]) then DeleteObject(list[i]) end
    end
end

local function placeRamps(truck)
    removeRamps(truck)
    if not IsModelInCdimage(joaat(cfg.ramp.model)) then
        lib.print.warn(('ramp model %s does not exist; pick one with /swtow_ramps'):format(cfg.ramp.model))
        return
    end
    local ok, model = pcall(lib.requestModel, cfg.ramp.model)
    if not ok or not model then return end
    local transforms, angle = rampTransforms(truck)
    if not transforms then return end
    local list = {}
    for i = 1, #transforms do
        local t = transforms[i]
        local object = CreateObjectNoOffset(model, t.pos.x, t.pos.y, t.pos.z, false, false, false)
        SetEntityRotation(object, t.rot.x, t.rot.y, t.rot.z, 2, false)
        FreezeEntityPosition(object, true)
        list[i] = object
    end
    SetModelAsNoLongerNeeded(model)
    ramps[truck] = list
    if config.debug then print(('[sw_tow] ramps at %.1f°'):format(angle)) end
end

AddStateBagChangeHandler('sw_tow:ramps', '', function(bagName, _, value)
    CreateThread(function()
        local truck = util.entityFromBag(bagName, 2000)
        if not truck then return end
        if value then placeRamps(truck) else removeRamps(truck) end
        -- The client that simulates the truck keeps it still while the ramps are down.
        if NetworkHasControlOfEntity(truck) then FreezeEntityPosition(truck, value and true or false) end
    end)
end)

---@param truck integer
---@return boolean
function flatbed.rampsDown(truck)
    return Entity(truck).state['sw_tow:ramps'] == true
end

---@param truck integer
---@param down boolean
---@return boolean ok, string? errorKey
function flatbed.setRamps(truck, down)
    if down and GetEntitySpeed(truck) > 0.5 then return false, 'tow.truck_moving' end
    local ok, errorKey = lib.callback.await('sw_tow:server:ramps', false, VehToNet(truck), down)
    if not ok then return false, errorKey end
    -- Wait for our own copy of the ramps, so physics never starts before they exist.
    local deadline = GetGameTimer() + 3000
    while (ramps[truck] ~= nil) ~= down and GetGameTimer() < deadline do Wait(50) end
    return true
end

-- Driving the vehicle with the winch --------------------------------------------------------------

---@class SwPull
---@field truck integer
---@field target integer
---@field direction 1|-1 1 = towards the cab (loading), -1 = down the ramps (unloading)
---@field done fun(): boolean
---@field speed number

---The end of the vehicle that faces the cab, in the truck's space (y). Loading front or rear first
---depends on how the vehicle stands; the winch hooks the end that points at the truck.
---@param truck integer
---@param target integer
---@return number leadY, number length, boolean facing vehicle front points at the cab
local function leadingEnd(truck, target)
    local min, max = GetModelDimensions(GetEntityModel(target))
    local f = axes(truck)
    local tf = GetOffsetFromEntityInWorldCoords(target, 0.0, 1.0, 0.0) - GetEntityCoords(target)
    local facing = (tf.x * f.x + tf.y * f.y) >= 0
    local tip = GetOffsetFromEntityInWorldCoords(target, 0.0, facing and max.y or min.y, 0.0)
    return toTruck(truck, tip).y, max.y - min.y, facing
end

---Moves the vehicle along the truck at winch speed until `done`. Only horizontal velocity is set:
---gravity, wheel contact, suspension and the bend at the top of the ramp stay with the physics.
---@param pull SwPull
---@return boolean ok, string? why 'stuck'|'unstable'|'gone'|'timeout'
local function drive(pull)
    local truck, target = pull.truck, pull.target
    SetVehicleHandbrake(target, false)
    SetVehicleBrake(target, false)
    SetVehicleEngineOn(target, false, true, true)
    local _, _, facing = leadingEnd(truck, target)
    local targetHeading = GetEntityHeading(truck) + (facing and 0.0 or 180.0)

    local started = GetGameTimer()
    local best, bestAt, boosted = -math.huge, started, false
    while true do
        if not DoesEntityExist(truck) or not DoesEntityExist(target) then return false, 'gone' end
        if not NetworkHasControlOfEntity(target) then requestControl(target, 500) end
        if pull.done() then break end

        local now = GetGameTimer()
        if now - started > (cfg.pullTimeout or 40) * 1000 then return false, 'timeout' end
        if math.abs(GetEntityPitch(target)) > 40.0 or math.abs(GetEntityRoll(target)) > 35.0 then
            return false, 'unstable'
        end

        -- Progress along the truck; no progress for 2.5 s means the vehicle hangs on something.
        local progress = toTruck(truck, GetEntityCoords(target)).y * pull.direction
        if progress > best + 0.1 then
            best, bestAt = progress, now
        elseif now - bestAt > 2500 then
            if boosted then return false, 'stuck' end
            boosted, bestAt = true, now
        end

        local f, right = axes(truck)
        local local_ = toTruck(truck, GetEntityCoords(target))
        -- Steer back onto the truck's centre line: aim 3 m ahead on it.
        local lateral = -local_.x / 3.0
        local dir = norm(f * pull.direction + right * lateral)
        local speed = pull.speed * (boosted and 1.6 or 1.0)
        local v = GetEntityVelocity(target)
        local want = dir * speed
        SetEntityVelocity(target, v.x + (want.x - v.x) * 0.2, v.y + (want.y - v.y) * 0.2, v.z)

        -- Keep the vehicle straight; nobody is steering it.
        local err = ((targetHeading - GetEntityHeading(target) + 180.0) % 360.0) - 180.0
        local av = GetEntityRotationVelocity(target)
        SetEntityAngularVelocity(target, av.x, av.y, math.max(-0.6, math.min(0.6, math.rad(err) * 1.5)))
        Wait(0)
    end

    SetEntityVelocity(target, 0.0, 0.0, 0.0)
    SetVehicleHandbrake(target, true)
    return true
end

---Attaches the vehicle where it rests now, so securing never moves it.
---@param truck integer
---@param target integer
local function attachInPlace(truck, target)
    local offset = toTruck(truck, GetEntityCoords(target))
    local rt, rv = GetEntityRotation(truck, 2), GetEntityRotation(target, 2)
    local rot = vec3(rv.x - rt.x, rv.y - rt.y, ((rv.z - rt.z + 180.0) % 360.0) - 180.0)
    AttachEntityToEntity(target, truck, 0, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z,
        false, false, false, false, 2, true)
end

---Last resort when physics cannot finish: lift the vehicle onto the bed in a short glide.
---@param truck integer
---@param target integer
local function glideOntoBed(truck, target)
    local min, max = GetModelDimensions(GetEntityModel(target))
    local _, _, facing = leadingEnd(truck, target)
    local bed = toTruck(truck, bedRear(truck) --[[@as vector3]])
    local final = vec3(0.0, cfg.bedFrontY - (max.y - min.y) / 2 - 0.2, bed.z - min.z)
    local finalRot = vec3(0.0, 0.0, facing and 0.0 or 180.0)
    local from = toTruck(truck, GetEntityCoords(target))
    local start = GetGameTimer()
    while true do
        local t = math.min(1.0, (GetGameTimer() - start) / 1500)
        local p = from + (final - from) * t
        AttachEntityToEntity(target, truck, 0, p.x, p.y, p.z, finalRot.x, finalRot.y, finalRot.z,
            false, false, false, false, 2, true)
        if t >= 1.0 or not DoesEntityExist(target) then break end
        Wait(0)
    end
end

---Loads `target` onto `truck`: ramps down, winch it up, secure it, ramps up.
---The server has already accepted the attach request (cargo record, cable state).
---@param truck integer
---@param target integer
---@return boolean secured
function flatbed.load(truck, target)
    if not flatbed.rampsDown(truck) and not flatbed.setRamps(truck, true) then return false end
    if not requestControl(target) then return false end
    SetVehicleDoorsShut(target, false)

    local ok, why = drive({
        truck = truck,
        target = target,
        direction = 1,
        speed = cfg.pullSpeed,
        done = function()
            local lead = leadingEnd(truck, target)
            return lead >= cfg.bedFrontY
        end,
    })
    if not ok and why == 'gone' then return false end
    Wait(400)  -- Let the suspension settle before the pose is frozen.
    if ok then
        attachInPlace(truck, target)
    else
        if config.debug then print('[sw_tow] winch fallback: ' .. tostring(why)) end
        glideOntoBed(truck, target)
    end
    flatbed.setRamps(truck, false)
    return true
end

---Secures a vehicle that is already on the bed (the owner drove it up the ramps).
---@param truck integer
---@param target integer
---@return boolean
function flatbed.secureInPlace(truck, target)
    if not requestControl(target) then return false end
    SetEntityVelocity(target, 0.0, 0.0, 0.0)
    attachInPlace(truck, target)
    flatbed.setRamps(truck, false)
    return true
end

---Is this vehicle standing on the bed of the truck (for securing in place)?
---@param truck integer
---@param target integer
---@return boolean
function flatbed.isOnBed(truck, target)
    local p = toTruck(truck, GetEntityCoords(target))
    local min = GetModelDimensions(GetEntityModel(truck))
    return math.abs(p.x) < 1.2 and p.y > min.y and p.y < cfg.bedFrontY and p.z > 0.3
end

---Unloads the cargo: ramps down, detach, roll it down the ramps, ramps up.
---@param truck integer
---@param target integer
---@return boolean
function flatbed.unload(truck, target)
    if not flatbed.rampsDown(truck) and not flatbed.setRamps(truck, true) then return false end
    if not requestControl(target) then return false end
    local min, max = GetModelDimensions(GetEntityModel(target))
    local truckMin = GetModelDimensions(GetEntityModel(truck))
    local rampMin, rampMax = GetModelDimensions(joaat(cfg.ramp.model))
    -- Clear of the ramp foot by half a vehicle and a metre.
    local stopY = truckMin.y - (rampMax.y - rampMin.y) - (max.y - min.y) / 2 - 1.0

    -- Detach from the pose it rests in, with no motion carried over.
    DetachEntity(target, true, true)
    SetEntityVelocity(target, 0.0, 0.0, 0.0)

    drive({
        truck = truck,
        target = target,
        direction = -1,
        speed = cfg.pullSpeed,
        done = function() return toTruck(truck, GetEntityCoords(target)).y <= stopY end,
    })
    SetVehicleOnGroundProperly(target)
    flatbed.setRamps(truck, false)
    return true
end

---Development aid: shows ramp candidates behind your truck so the best-looking one can be picked.
---@param truck integer
---@param models string[]
function flatbed.previewRamps(truck, models)
    local saved = cfg.ramp.model
    for _, name in ipairs(models) do
        if IsModelInCdimage(joaat(name)) then
            cfg.ramp.model = name
            placeRamps(truck)
            local angle = select(2, rampTransforms(truck))
            print(('[sw_tow] ramp preview: %s (%.0f°)'):format(name, angle or 0))
            lib.showTextUI(('%s · %.0f°'):format(name, angle or 0))
            Wait(6000)
            removeRamps(truck)
        else
            print(('[sw_tow] ramp preview: %s does not exist'):format(name))
        end
    end
    lib.hideTextUI()
    cfg.ramp.model = saved
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for truck in pairs(ramps) do
        removeRamps(truck)
        if DoesEntityExist(truck) and NetworkHasControlOfEntity(truck) then FreezeEntityPosition(truck, false) end
    end
end)

return flatbed
