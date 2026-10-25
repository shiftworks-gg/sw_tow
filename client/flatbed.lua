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
    if (hit == 1 or hit == true) and entity == truck then return point end
    -- No hit (unusual model): fall back to the configured bed height.
    return GetOffsetFromEntityInWorldCoords(truck, 0.0, y, cfg.bedHeight or 0.55)
end

-- Ramps ------------------------------------------------------------------------------------------

---@type table<integer, integer[]> truck entity -> ramp objects on this client
local ramps = {}

---@class SwRampGeometry
---@field transforms { pos: vector3, rot: vector3 }[]
---@field angle number slope in degrees
---@field footY number truck-space y where the ramps touch the ground
---@field info string numbers for the preview and debug output

---Where the ramps go. The driving surface is taken as the model's diagonal from its lower rear
---corner to its upper front corner, which fits a flat plate and a ready-made wedge alike. The ramp
---is turned so that this line runs from the ground to the rear edge of the bed.
---@param truck integer
---@return SwRampGeometry?
local function rampGeometry(truck)
    local model = joaat(cfg.ramp.model)
    local top = bedRear(truck)
    if not top then return end
    local f, right = axes(truck)
    local min, max = GetModelDimensions(model)
    local dy, dz = max.y - min.y, max.z - min.z
    local diagonal = math.sqrt(dy * dy + dz * dz)
    local found, groundZ = GetGroundZFor_3dCoord(top.x - f.x * dy, top.y - f.y * dy, top.z + 0.5, false)
    if not found then groundZ = GetEntityCoords(truck).z - GetEntityHeightAboveGround(truck) end
    local rise = math.max(0.05, top.z - groundZ)
    local slope = math.asin(math.min(1.0, rise / diagonal))
    local pitch = slope - math.atan(dz, dy)

    -- Model-space point rotated about the ramp's own x axis.
    local c, sn = math.cos(pitch), math.sin(pitch)
    local function turned(y, z) return y * c - z * sn, y * sn + z * c end
    local up = vec3(0.0, 0.0, 1.0)
    local frontY, frontZ = turned(max.y, max.z)
    local origin = top - f * frontY - up * frontZ
    local rearY, rearZ = turned(min.y, min.z)
    local foot = origin + f * rearY + up * rearZ

    local rot = vec3(math.deg(pitch), 0.0, GetEntityHeading(truck))
    local offsets = cfg.ramp.pair and { -cfg.ramp.spacing / 2, cfg.ramp.spacing / 2 } or { 0.0 }
    local list = {}
    for i = 1, #offsets do
        list[i] = { pos = origin + right * offsets[i], rot = rot }
    end
    return {
        transforms = list,
        angle = math.deg(slope),
        footY = toTruck(truck, foot).y,
        info = ('size %.2f x %.2f x %.2f, bed %.2f m above ground, slope %.0f°, turned %.0f°'):format(
            max.x - min.x, dy, dz, rise, math.deg(slope), math.deg(pitch)),
    }
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
    local geometry = rampGeometry(truck)
    if not geometry then return end
    local list = {}
    for i = 1, #geometry.transforms do
        local t = geometry.transforms[i]
        local object = CreateObjectNoOffset(model, t.pos.x, t.pos.y, t.pos.z, false, false, false)
        SetEntityRotation(object, t.rot.x, t.rot.y, t.rot.z, 2, false)
        FreezeEntityPosition(object, true)
        list[i] = object
    end
    SetModelAsNoLongerNeeded(model)
    ramps[truck] = list
    flatbed.drawGuide(truck, list, geometry)
    if config.debug then print('[sw_tow] ramps: ' .. geometry.info) end
end

---Ground marking behind the ramps for the worker who owns the truck: the centre line the vehicle
---must stand on and the stop line its bumper must stay behind. Drawn only while the ramps are down.
---@param truck integer
---@param list integer[]
---@param geometry SwRampGeometry
function flatbed.drawGuide(truck, list, geometry)
    local shift = require 'client.shift'
    if shift.truck() ~= truck then return end
    local stopY = geometry.footY - 0.3
    local function at(x, y)
        local p = GetOffsetFromEntityInWorldCoords(truck, x, y, 0.0)
        local found, z = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
        return vec3(p.x, p.y, (found and z or p.z) + 0.03)
    end
    local stopL, stopR = at(-1.3, stopY), at(1.3, stopY)
    local lineA, lineB = at(0.0, stopY), at(0.0, stopY - 9.0)
    local edges = { { at(-0.8, stopY), at(-3.8, stopY - 9.0) }, { at(0.8, stopY), at(3.8, stopY - 9.0) } }
    CreateThread(function()
        while ramps[truck] == list do
            DrawLine(stopL.x, stopL.y, stopL.z, stopR.x, stopR.y, stopR.z, 255, 122, 46, 255)
            DrawLine(lineA.x, lineA.y, lineA.z, lineB.x, lineB.y, lineB.z, 255, 122, 46, 255)
            for i = 1, 2 do
                local a, b = edges[i][1], edges[i][2]
                DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 255, 122, 46, 120)
            end
            Wait(0)
        end
    end)
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
---@field gateY number? loading: the leading end waits here until the vehicle is straight and centred

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
    local heldSince
    while true do
        if not DoesEntityExist(truck) or not DoesEntityExist(target) then return false, 'gone' end
        if not NetworkHasControlOfEntity(target) then requestControl(target, 500) end
        if pull.done() then break end

        local now = GetGameTimer()
        if now - started > (cfg.pullTimeout or 40) * 1000 then return false, 'timeout' end
        if math.abs(GetEntityPitch(target)) > 40.0 or math.abs(GetEntityRoll(target)) > 35.0 then
            return false, 'unstable'
        end

        local local_ = toTruck(truck, GetEntityCoords(target))
        local err = ((targetHeading - GetEntityHeading(target) + 180.0) % 360.0) - 180.0

        -- At the foot of the ramps the vehicle must be straight and centred before it climbs, or
        -- one side would go up first. Until then it only turns and slides onto the line.
        local hold = false
        if pull.gateY then
            local lead = leadingEnd(truck, target)
            if lead >= pull.gateY then
                if math.abs(local_.x) <= 0.3 and math.abs(err) <= 5.0 then
                    pull.gateY, heldSince = nil, nil
                else
                    hold = true
                    heldSince = heldSince or now
                    if now - heldSince > 4000 then return false, 'misaligned' end
                end
            end
        end

        -- Progress along the truck; no progress for 2.5 s means the vehicle hangs on something.
        local progress = local_.y * pull.direction
        if hold then bestAt = now end
        if progress > best + 0.1 then
            best, bestAt = progress, now
        elseif now - bestAt > 2500 then
            if boosted then return false, 'stuck' end
            boosted, bestAt = true, now
        end

        local f, right = axes(truck)
        local speed = pull.speed * (boosted and 1.6 or 1.0)
        local want
        if hold then
            -- Slide sideways onto the centre line, no forward motion.
            want = right * math.max(-0.5, math.min(0.5, -local_.x * 1.5))
        else
            -- Steer back onto the truck's centre line: aim 3 m ahead on it.
            want = norm(f * pull.direction + right * (-local_.x / 3.0)) * speed
        end
        local v = GetEntityVelocity(target)
        SetEntityVelocity(target, v.x + (want.x - v.x) * 0.2, v.y + (want.y - v.y) * 0.2, v.z)

        -- Keep the vehicle straight; nobody is steering it.
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

---Can the winch pull this vehicle straight up the ramps from where it stands? The cable only pulls
---towards the truck, so the vehicle must be behind the ramp foot, roughly in line and not turned
---more than 30°. The further back it stands, the more sideways offset the pull can straighten out.
---@param truck integer
---@param target integer
---@return boolean ok, string? errorKey
function flatbed.lineUp(truck, target)
    local ok, model = pcall(lib.requestModel, cfg.ramp.model)
    if not ok or not model then return false, 'tow.no_ramps' end
    local geometry = rampGeometry(truck)
    SetModelAsNoLongerNeeded(model)
    if not geometry then return false, 'tow.no_ramps' end

    local lead, _, facing = leadingEnd(truck, target)
    local gap = geometry.footY - lead
    if gap < 0.3 then return false, 'tow.too_close' end
    local centre = toTruck(truck, GetEntityCoords(target))
    local heading = GetEntityHeading(truck) + (facing and 0.0 or 180.0)
    local err = ((heading - GetEntityHeading(target) + 180.0) % 360.0) - 180.0
    if math.abs(err) > 30.0 or math.abs(centre.x) > 0.5 + gap / 3.0 then return false, 'tow.not_in_line' end
    return true
end

---Loads `target` onto `truck`: ramps down, winch it to the ramp foot and straighten it there, pull
---it up, secure it, ramps up. The server has already accepted the attach request.
---@param truck integer
---@param target integer
---@return boolean secured, string? errorKey
function flatbed.load(truck, target)
    if not flatbed.rampsDown(truck) then
        local down, rampError = flatbed.setRamps(truck, true)
        if not down then return false, rampError end
    end
    if not requestControl(target) then return false, 'tow.no_control' end
    local geometry = rampGeometry(truck)
    if not geometry then return false, 'tow.no_ramps' end
    SetVehicleDoorsShut(target, false)

    local ok, why = drive({
        truck = truck,
        target = target,
        direction = 1,
        speed = cfg.pullSpeed,
        gateY = geometry.footY - 0.3,
        done = function()
            local lead = leadingEnd(truck, target)
            return lead >= cfg.bedFrontY
        end,
    })
    if not ok and why == 'gone' then return false, 'tow.no_control' end
    if not ok and why == 'misaligned' then
        -- Still on the ground: leave it there rather than drag it up crooked.
        return false, 'tow.not_in_line'
    end
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
            local geometry = rampGeometry(truck)
            print(('[sw_tow] ramp preview: %s · %s'):format(name, geometry and geometry.info or 'no geometry'))
            lib.showTextUI(('%s · %.0f°'):format(name, geometry and geometry.angle or 0))
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
