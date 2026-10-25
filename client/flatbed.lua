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
-- Telemetry: config.debug, `setr sw_tow_debug 1` on the server (survives restarts), or /swtow_debug.
local flatbed = { debug = config.debug == true or GetConvar('sw_tow_debug', '0') == '1' }

-- /swtow_debug: winch telemetry and ramp fitting in F8 (and the client log), for tuning.
RegisterCommand('swtow_debug', function()
    flatbed.debug = not flatbed.debug
    print(('[sw_tow] debug %s'):format(flatbed.debug and 'on' or 'off'))
end, false)

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
---@field foot vector3 world point where the ramps touch the ground
---@field edgeY number truck-space y of the rear edge of the bed
---@field bedZ number world z of the bed surface at its rear edge
---@field groundZ number world z of the ground under the ramp foot
---@field info string numbers for the preview and debug output

---@class SwRampAdjust
---@field tilt number extra tilt in radians, from measuring the placed ramp
---@field z number extra height in metres, from measuring the placed ramp

---Where the ramps go. The first guess takes the model's diagonal, lower rear corner to upper front
---corner, as the driving surface; that fits flat plates and ready-made wedges. `adjust` carries the
---corrections found by measuring the placed ramp, because hooks and legs make a bounding box lie
---about where the wheels actually run.
---@param truck integer
---@param adjust? SwRampAdjust
---@return SwRampGeometry?
local function rampGeometry(truck, adjust)
    adjust = adjust or { tilt = 0.0, z = 0.0 }
    local model = joaat(cfg.ramp.model)
    local top = bedRear(truck)
    if not top then return end
    local f, right = axes(truck)
    local truckMin = GetModelDimensions(GetEntityModel(truck))
    local min, max = GetModelDimensions(model)
    local dy, dz = max.y - min.y, max.z - min.z
    local diagonal = math.sqrt(dy * dy + dz * dz)
    local found, groundZ = GetGroundZFor_3dCoord(top.x - f.x * dy, top.y - f.y * dy, top.z + 0.5, false)
    if not found then groundZ = GetEntityCoords(truck).z - GetEntityHeightAboveGround(truck) end
    local rise = math.max(0.05, top.z - groundZ)
    local slope = math.asin(math.min(1.0, rise / diagonal))
    -- Work in a frame whose y points at the truck. Ramps modelled with the high end at -y (flip)
    -- are turned around: their model x and y run the other way.
    local flip = cfg.ramp.flip == true
    local yHigh, yLow = flip and -min.y or max.y, flip and -max.y or min.y
    local xCentre = (min.x + max.x) / 2 * (flip and -1 or 1)
    local tilt = slope - math.atan(dz, dy) + adjust.tilt

    -- A point of that frame after tilting nose-up towards the truck.
    local c, sn = math.cos(tilt), math.sin(tilt)
    local function turned(y, z) return y * c - z * sn, y * sn + z * c end
    local up = vec3(0.0, 0.0, 1.0)
    local highY, highZ = turned(yHigh, max.z)
    local origin = top - f * highY - up * highZ + up * adjust.z - right * xCentre
    local lowY, lowZ = turned(yLow, min.z)
    local foot = origin + right * xCentre + f * lowY + up * lowZ

    local heading = GetEntityHeading(truck) + (flip and 180.0 or 0.0)
    local rot = vec3(math.deg(flip and -tilt or tilt), 0.0, heading)
    local offsets = cfg.ramp.pair and { -cfg.ramp.spacing / 2, cfg.ramp.spacing / 2 } or { 0.0 }
    local list = {}
    for i = 1, #offsets do
        list[i] = { pos = origin + right * offsets[i], rot = rot }
    end
    return {
        transforms = list,
        angle = math.deg(slope),
        footY = toTruck(truck, foot).y,
        foot = foot,
        edgeY = truckMin.y,
        bedZ = top.z,
        groundZ = groundZ,
        info = ('size %.2f x %.2f x %.2f, bed %.2f m above ground, slope %.0f°, tilted %.1f°%s'):format(
            max.x - min.x, dy, dz, rise, math.deg(slope), math.deg(tilt), flip and ', flipped' or ''),
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

---Height of the ramp's driving surface at a truck-space point, measured with a ray onto the ramps.
---@param truck integer
---@param list integer[]
---@param y number truck-space y
---@return number?
local function rampSurface(truck, list, y)
    local p = GetOffsetFromEntityInWorldCoords(truck, 0.0, y, 0.0)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(p.x, p.y, p.z + 4.0, p.x, p.y, p.z - 4.0, 16, 0, 7)
    local _, hit, point, _, entity = GetShapeTestResult(probe)
    if not (hit == 1 or hit == true) then return end
    for i = 1, #list do
        if list[i] == entity then return point.z end
    end
end

local function applyTransforms(list, geometry)
    for i = 1, #list do
        local t = geometry.transforms[i]
        SetEntityCoordsNoOffset(list[i], t.pos.x, t.pos.y, t.pos.z, false, false, false)
        SetEntityRotation(list[i], t.rot.x, t.rot.y, t.rot.z, 2, false)
    end
end

---Places the ramps, then measures where their surface really is and corrects tilt and height until
---it runs from the ground to the bed edge with no step. Two or three rounds are enough.
---@param truck integer
---@param list integer[]
---@return SwRampGeometry?
local function fitRamps(truck, list)
    local adjust = { tilt = 0.0, z = 0.0 }
    local geometry
    for _ = 1, 4 do
        geometry = rampGeometry(truck, adjust)
        if not geometry then return end
        applyTransforms(list, geometry)
        local highY, lowY = geometry.edgeY - 0.3, geometry.footY + 0.6
        local zHigh, zLow = rampSurface(truck, list, highY), rampSurface(truck, list, lowY)
        if not zHigh or not zLow then break end
        -- The straight line the wheels should run on: ground at the foot, bed height at the edge.
        local run = geometry.edgeY - geometry.footY
        local function wanted(y) return geometry.groundZ + (geometry.bedZ - geometry.groundZ) * (y - geometry.footY) / run end
        local slopeWanted = math.atan(wanted(highY) - wanted(lowY), highY - lowY)
        local slopeNow = math.atan(zHigh - zLow, highY - lowY)
        local highError = wanted(highY) - zHigh
        if math.abs(highError) < 0.02 and math.abs(slopeWanted - slopeNow) < math.rad(0.3) then break end
        adjust.tilt = adjust.tilt + (slopeWanted - slopeNow)
        adjust.z = adjust.z + highError
    end
    if flatbed.debug then print(('[sw_tow] ramps fitted: %s, height %+.2f m'):format(geometry.info, adjust.z)) end
    return geometry
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
    fitRamps(truck, list)
    ramps[truck] = list
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

---Can the ramps stand here? The truck must not lean, and the ground under the ramp foot must be
---where the ramps expect it on both sides: a kerb or a pothole would leave them crooked.
---@param truck integer
---@return boolean ok, string? errorKey
function flatbed.level(truck)
    if math.abs(GetEntityRoll(truck)) > 4.0 or math.abs(GetEntityPitch(truck)) > 6.0 then return false, 'tow.uneven' end
    local ok, model = pcall(lib.requestModel, cfg.ramp.model)
    if not ok or not model then return false, 'tow.no_ramps' end
    local geometry = rampGeometry(truck)
    SetModelAsNoLongerNeeded(model)
    if not geometry then return false, 'tow.no_ramps' end
    local _, right = axes(truck)
    local foot = geometry.foot
    for _, side in ipairs({ -0.9, 0.9 }) do
        local p = foot + right * side
        local found, z = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
        if not found or math.abs(z - foot.z) > 0.25 then return false, 'tow.uneven' end
    end
    return true
end

---@param truck integer
---@param down boolean
---@return boolean ok, string? errorKey
function flatbed.setRamps(truck, down)
    if down then
        if GetEntitySpeed(truck) > 0.5 then return false, 'tow.truck_moving' end
        local level, levelError = flatbed.level(truck)
        if not level then return false, levelError end
    end
    local ok, errorKey = lib.callback.await('sw_tow:server:ramps', false, VehToNet(truck), down)
    if not ok then return false, errorKey end
    -- Wait for our own copy of the ramps, so physics never starts before they exist.
    local deadline = GetGameTimer() + 3000
    while (ramps[truck] ~= nil) ~= down and GetGameTimer() < deadline do Wait(50) end
    return true
end

-- Driving the vehicle with the winch --------------------------------------------------------------

---Freezes or releases the truck. Done explicitly around every winch run, not only through the
---ramps state bag, so the truck can never be pushed by its cargo.
---@param truck integer
---@param hold boolean
local function holdTruck(truck, hold)
    if requestControl(truck, 1500) then FreezeEntityPosition(truck, hold) end
end

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
---@return boolean ok, string? why 'stuck'|'unstable'|'gone'|'timeout'|'misaligned'|'truck'
local function drive(pull)
    local truck, target = pull.truck, pull.target
    local truckStart = GetEntityCoords(truck)
    local lastLog = 0
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
        if math.abs(GetEntityPitch(target)) > 40.0 or math.abs(GetEntityRoll(target)) > 25.0 then
            return false, 'unstable'
        end
        -- The truck must not move at all; if it does, the cargo is pushing it: stop at once.
        if #(GetEntityCoords(truck) - truckStart) > 0.25 or math.abs(GetEntityRoll(truck)) > 6.0 then
            return false, 'truck'
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
                    if now - heldSince > 6000 then return false, 'misaligned' end
                end
            end
        end

        -- Progress along the truck. Loading gets one stronger pull over a bump; anything else that
        -- stops moving for 1.5 s is stuck, and the winch stops before tyres burn or things break.
        local progress = local_.y * pull.direction
        if hold then bestAt = now end
        if progress > best + 0.1 then
            best, bestAt = progress, now
        elseif now - bestAt > 1500 then
            if boosted or pull.direction < 0 then return false, 'stuck' end
            boosted, bestAt = true, now
        end

        -- An empty vehicle can keep its brakes on; the winch rolls it, so they stay off every frame.
        SetVehicleHandbrake(target, false)

        local f, right = axes(truck)
        local speed = pull.speed * (boosted and 1.6 or 1.0)
        -- Only on the ground, before the climb, is the body steered (turned and moved onto the
        -- centre line). On the ramps the winch only sets the speed along the truck and physics does
        -- the rest: overriding rotation there makes the vehicle shake.
        local onGround = pull.direction > 0 and pull.gateY ~= nil
        local want
        if hold then
            -- Slide sideways onto the centre line, no forward motion.
            want = right * math.max(-0.5, math.min(0.5, -local_.x * 1.5))
        elseif onGround then
            -- Steer back onto the truck's centre line: aim 3 m ahead on it.
            want = norm(f + right * (-local_.x / 3.0)) * speed
        else
            -- On the ramps or the bed: straight along the truck, the slightest centring only.
            want = norm(f * pull.direction + right * math.max(-0.05, math.min(0.05, -local_.x * 0.1))) * speed
        end
        local v = GetEntityVelocity(target)
        SetEntityVelocity(target, v.x + (want.x - v.x) * 0.12, v.y + (want.y - v.y) * 0.12, v.z)

        local yaw = 0.0
        if onGround then
            -- On flat ground there is no pitch or roll to keep, so only the turn is set.
            yaw = math.max(-0.4, math.min(0.4, math.rad(err) * 1.2))
            SetEntityAngularVelocity(target, 0.0, 0.0, yaw)
        end
        local av = GetEntityRotationVelocity(target)

        if flatbed.debug and now - lastLog >= 250 then
            lastLog = now
            print(('[sw_tow] pull t=%.1f y=%.2f x=%+.2f heading err=%+.1f yaw=%+.2f av.z=%+.2f speed=%.2f pitch=%.1f roll=%.1f%s%s'):format(
                (now - started) / 1000, local_.y, local_.x, err, yaw, av.z, GetEntitySpeed(target),
                GetEntityPitch(target), GetEntityRoll(target), hold and ' HOLD' or (onGround and ' GROUND' or ''),
                boosted and ' BOOST' or ''))
        end
        Wait(0)
    end

    SetEntityVelocity(target, 0.0, 0.0, 0.0)
    SetVehicleHandbrake(target, true)
    return true
end

---Stops the vehicle where it is, with no motion left in it.
local function halt(target)
    if not DoesEntityExist(target) then return end
    SetEntityVelocity(target, 0.0, 0.0, 0.0)
    SetEntityAngularVelocity(target, 0.0, 0.0, 0.0)
    SetVehicleHandbrake(target, true)
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

---@class SwLineUp
---@field ok boolean
---@field key string? locale key of the first problem
---@field value number? metres or degrees for that message
---@field geometry SwRampGeometry?

---How the vehicle stands for loading. The cable only pulls towards the truck, so the leading end
---must be behind the ramp foot and within winch range. Sideways offset and angle get a generous
---allowance: the winch straightens the vehicle on the ground before it climbs, and the further
---back it stands, the more offset it can take out.
---@param truck integer
---@param target integer
---@param geometry? SwRampGeometry
---@return SwLineUp
function flatbed.assess(truck, target, geometry)
    geometry = geometry or rampGeometry(truck)
    if not geometry then return { ok = false, key = 'tow.no_ramps' } end
    local lead, _, facing = leadingEnd(truck, target)
    local gap = geometry.footY - lead
    local centre = toTruck(truck, GetEntityCoords(target))
    local heading = GetEntityHeading(truck) + (facing and 0.0 or 180.0)
    local angle = math.abs(((heading - GetEntityHeading(target) + 180.0) % 360.0) - 180.0)
    local sideLimit = math.min(3.0, 0.5 + math.max(0.0, gap) * 0.35)

    local result = { ok = false, geometry = geometry }
    if angle > 45.0 then
        result.key, result.value = 'tow.off_angle', angle
    elseif gap < 0.3 then
        result.key, result.value = 'tow.too_close', 0.3 - gap
    elseif gap > cfg.winchRange then
        result.key, result.value = 'tow.too_far', gap - cfg.winchRange
    elseif math.abs(centre.x) > sideLimit then
        result.key, result.value = 'tow.off_side', math.abs(centre.x) - sideLimit
    else
        result.ok = true
    end
    return result
end

---@param truck integer
---@param target integer
---@return boolean ok, string? errorKey, string? value
function flatbed.lineUp(truck, target)
    local ok, model = pcall(lib.requestModel, cfg.ramp.model)
    if not ok or not model then return false, 'tow.no_ramps' end
    local result = flatbed.assess(truck, target)
    SetModelAsNoLongerNeeded(model)
    if result.ok then return true end
    return false, result.key, result.value and ('%.0f'):format(result.value) or nil
end

---Loads `target` onto `truck`: ramps down, winch it to the ramp foot and straighten it there, pull
---it up, secure it, ramps up. The server has already accepted the attach request. If the vehicle
---cannot make it (too low for the bend, a wheel off the ramp), it is let back down to the ground.
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
    holdTruck(truck, true)

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
    halt(target)
    if flatbed.debug then print('[sw_tow] load result: ' .. (ok and 'ok' or tostring(why))) end

    if ok then
        Wait(500)  -- Let the suspension settle on the bed before the pose is frozen.
        attachInPlace(truck, target)
        flatbed.setRamps(truck, false)
        holdTruck(truck, false)
        return true
    end

    if why == 'gone' then
        holdTruck(truck, false)
        return false, 'tow.no_control'
    end
    if why ~= 'misaligned' and why ~= 'truck' then
        -- Part-way up: let it roll back down to the ground the way it came.
        drive({
            truck = truck,
            target = target,
            direction = -1,
            speed = cfg.pullSpeed,
            done = function() return leadingEnd(truck, target) <= geometry.footY - 0.5 end,
        })
        halt(target)
    end
    holdTruck(truck, false)
    return false, why == 'misaligned' and 'tow.not_straight' or 'tow.cannot_climb'
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

---Unloads the cargo: ramps down, detach, roll it down the ramps, ramps up. The vehicle rests where
---physics left it when it was secured, so letting go of it never pushes it into the bed.
---@param truck integer
---@param target integer
---@return boolean
function flatbed.unload(truck, target)
    if not flatbed.rampsDown(truck) and not flatbed.setRamps(truck, true) then return false end
    if not requestControl(target) then return false end
    local geometry = rampGeometry(truck)
    if not geometry then return false end
    local min, max = GetModelDimensions(GetEntityModel(target))
    -- Clear of the ramp foot by half a vehicle and a metre.
    local stopY = geometry.footY - (max.y - min.y) / 2 - 1.0
    holdTruck(truck, true)

    DetachEntity(target, true, true)
    halt(target)
    Wait(100)
    local ok, why = drive({
        truck = truck,
        target = target,
        direction = -1,
        speed = cfg.pullSpeed,
        done = function() return toTruck(truck, GetEntityCoords(target)).y <= stopY end,
    })
    halt(target)
    if flatbed.debug then print('[sw_tow] unload result: ' .. (ok and 'ok' or tostring(why))) end
    if not ok then
        -- It did not come down: strap it again where it stands, still cargo of this truck.
        Wait(300)
        attachInPlace(truck, target)
        flatbed.setRamps(truck, false)
        holdTruck(truck, false)
        return false
    end
    SetVehicleOnGroundProperly(target)
    flatbed.setRamps(truck, false)
    holdTruck(truck, false)
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
            local geometry = ramps[truck] and fitRamps(truck, ramps[truck])
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

-- Parking guide ----------------------------------------------------------------------------------
-- While the worker has an empty company flatbed and a vehicle stands behind it, a hint says what to
-- change ("forward 2 m") and the ground behind the ramps is tinted: orange, green once it is fine.
-- Runs only on shift and near the truck; nothing runs otherwise.

local guideBusy = false

---@param busy boolean
function flatbed.setBusy(busy)
    guideBusy = busy
end

---The vehicle most likely meant for loading: the closest one standing behind the truck.
---@param truck integer
---@return integer?
local function candidateBehind(truck)
    local min = GetModelDimensions(GetEntityModel(truck))
    local best, bestDistance
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if vehicle ~= truck and not Entity(vehicle).state['sw_tow:company'] and not Entity(vehicle).state['sw_tow:towedBy'] then
            local p = toTruck(truck, GetEntityCoords(vehicle))
            if p.y < min.y and p.y > min.y - 26.0 and math.abs(p.x) < 8.0 then
                local distance = min.y - p.y + math.abs(p.x)
                if not bestDistance or distance < bestDistance then best, bestDistance = vehicle, distance end
            end
        end
    end
    return best
end

---Corner points of the loading zone on the ground, in strips so it follows slopes.
---@param truck integer
---@param geometry SwRampGeometry
---@return vector3[][]
local function zoneStrips(truck, geometry)
    local function at(x, y)
        local p = GetOffsetFromEntityInWorldCoords(truck, x, y, 0.0)
        local found, z = GetGroundZFor_3dCoord(p.x, p.y, p.z + 2.0, false)
        return vec3(p.x, p.y, (found and z or p.z) + 0.04)
    end
    local strips, steps = {}, 5
    for i = 0, steps - 1 do
        local g0, g1 = 0.3 + (cfg.winchRange - 0.3) * i / steps, 0.3 + (cfg.winchRange - 0.3) * (i + 1) / steps
        local w0, w1 = math.min(3.0, 0.5 + g0 * 0.35) + 1.0, math.min(3.0, 0.5 + g1 * 0.35) + 1.0
        local y0, y1 = geometry.footY - g0, geometry.footY - g1
        strips[#strips + 1] = { at(-w0, y0), at(w0, y0), at(w1, y1), at(-w1, y1) }
    end
    return strips
end

local function drawZone(strips, r, g, b)
    for i = 1, #strips do
        local q = strips[i]
        -- Both windings, so the tint shows from above at any camera angle.
        DrawPoly(q[1].x, q[1].y, q[1].z, q[2].x, q[2].y, q[2].z, q[3].x, q[3].y, q[3].z, r, g, b, 70)
        DrawPoly(q[3].x, q[3].y, q[3].z, q[2].x, q[2].y, q[2].z, q[1].x, q[1].y, q[1].z, r, g, b, 70)
        DrawPoly(q[1].x, q[1].y, q[1].z, q[3].x, q[3].y, q[3].z, q[4].x, q[4].y, q[4].z, r, g, b, 70)
        DrawPoly(q[4].x, q[4].y, q[4].z, q[3].x, q[3].y, q[3].z, q[1].x, q[1].y, q[1].z, r, g, b, 70)
    end
    local a, b2 = strips[1][1], strips[1][2]
    DrawLine(a.x, a.y, a.z, b2.x, b2.y, b2.z, r, g, b, 255)
end

local shownText

local function showHint(text)
    if text == shownText then return end
    shownText = text
    if text then lib.showTextUI(text, { position = 'right-center' }) else lib.hideTextUI() end
end

local function runGuide()
    local shift = require 'client.shift'
    local modelLoaded = false
    local truck, target, strips, result
    local nextCheck = 0
    while LocalPlayer.state['sw_tow:shift'] do
        local now = GetGameTimer()
        if now >= nextCheck then
            nextCheck = now + 300
            truck, target, strips, result = shift.truck(), nil, nil, nil
            if truck and not guideBusy and Entity(truck).state['sw_tow:method'] == 'flatbed'
                and not Entity(truck).state['sw_tow:cargo'] and #(GetEntityCoords(cache.ped) - GetEntityCoords(truck)) < 20.0 then
                if not modelLoaded then modelLoaded = pcall(lib.requestModel, cfg.ramp.model) end
                target = modelLoaded and candidateBehind(truck) or nil
                if target then
                    local geometry = rampGeometry(truck)
                    if geometry then
                        result = flatbed.assess(truck, target, geometry)
                        strips = zoneStrips(truck, geometry)
                    end
                end
            end
            if result then
                showHint(result.ok and locale('tow.guide_ok')
                    or locale(result.key, result.value and ('%.0f'):format(math.max(1, result.value)) or nil))
            else
                showHint(nil)
            end
        end
        if strips and result then
            if result.ok then drawZone(strips, 76, 196, 126) else drawZone(strips, 255, 122, 46) end
            Wait(0)
        else
            Wait(300)
        end
    end
    showHint(nil)
    if modelLoaded then SetModelAsNoLongerNeeded(joaat(cfg.ramp.model)) end
end

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if value then CreateThread(runGuide) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    showHint(nil)
    for truck in pairs(ramps) do
        removeRamps(truck)
        if DoesEntityExist(truck) and NetworkHasControlOfEntity(truck) then FreezeEntityPosition(truck, false) end
    end
end)

return flatbed
