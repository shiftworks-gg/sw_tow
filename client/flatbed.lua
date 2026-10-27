---Flatbed loading. The vanilla flatbed has a fixed bed, so loading works like a car hauler: ramps go
---down behind the bed, the winch cable is hooked to the vehicle, and the winch pulls it up.
---
---How the winch moves the vehicle is set by config.flatbed.motion:
---  'animated' (default): the vehicle is attached to the truck the whole way and follows a computed
---    path: a smooth curve on the ground that lines it up behind the ramps, then up the ramps and
---    along the bed. Each frame the body is pitched by where its two axles stand on the ground, the
---    ramps and the bed, so it tips over the bend between ramp and bed like a car does, and the front
---    wheels turn with the curve. It cannot fly, get stuck or end up crooked, and nobody can block it.
---  'physics': the vehicle stands on its own wheels and the winch sets its speed; the game's physics
---    carries it up. Livelier, less predictable.
---Unloading is always animated: on the way down physics only adds risk.
---
---Ramps are local objects that every client creates from the truck's `sw_tow:ramps` state bag. The
---truck is frozen while they are down.
local config = require 'config'
local util = require 'shared.util'
local sounds = require 'client.sounds'

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

---@param v number
---@param lo number
---@param hi number
---@return number
local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

---@param a number degrees
---@return number degrees in -180..180
local function wrap(a)
    return ((a + 180.0) % 360.0) - 180.0
end

---Eases 0..1 in and out.
---@param x number
---@return number
local function smoothstep(x)
    x = clamp(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)
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
---@return vector3 rearTop world point on the bed surface at the rear edge
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
---@type table<integer, SwRampAdjust> truck entity -> corrections measured when its ramps were placed
local fits = {}

---@class SwRampGeometry
---@field transforms { pos: vector3, rot: vector3 }[]
---@field angle number slope in degrees
---@field footY number truck-space y where the ramps touch the ground
---@field foot vector3 world point where the ramps touch the ground
---@field ground vector3 world point on the ground under the ramp foot
---@field edgeY number truck-space y of the rear edge of the bed
---@field bed vector3 world point on the bed surface at its rear edge
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
    local f, right = axes(truck)
    local truckMin = GetModelDimensions(GetEntityModel(truck))
    local min, max = GetModelDimensions(model)
    local dy, dz = max.y - min.y, max.z - min.z
    local diagonal = math.sqrt(dy * dy + dz * dz)
    if diagonal < 0.1 then return end
    local found, groundZ = GetGroundZFor_3dCoord(top.x - f.x * dy, top.y - f.y * dy, top.z + 0.5, false)
    local truckGround = GetEntityCoords(truck).z - GetEntityHeightAboveGround(truck)
    -- Ground that is not streamed in yet reads as 0 or far off; the truck's own wheels are a safe
    -- reference then, since the ramps only go down on level ground.
    if not found or math.abs(groundZ - truckGround) > 1.5 then groundZ = truckGround end
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
        ground = vec3(foot.x, foot.y, groundZ),
        edgeY = truckMin.y,
        bed = top,
        bedZ = top.z,
        groundZ = groundZ,
        info = ('size %.2f x %.2f x %.2f, bed %.2f m above ground, slope %.0f°, tilted %.1f°%s'):format(
            max.x - min.x, dy, dz, rise, math.deg(slope), math.deg(tilt), flip and ', flipped' or ''),
    }
end

---The ramps as they stand behind this truck now (with the corrections measured when they were placed).
---@param truck integer
---@return SwRampGeometry?
local function currentGeometry(truck)
    return rampGeometry(truck, fits[truck])
end

local function removeRamps(truck)
    local list = ramps[truck]
    ramps[truck], fits[truck] = nil, nil
    if not list then return end
    for i = 1, #list do
        if DoesEntityExist(list[i]) then DeleteObject(list[i]) end
    end
end

---@param truck integer
---@param entity integer
---@return boolean
local function isRamp(truck, entity)
    local list = ramps[truck]
    if not list then return false end
    for i = 1, #list do
        if list[i] == entity then return true end
    end
    return false
end

---Height of the ramp's driving surface at a truck-space point, measured with a ray onto the ramps.
---@param truck integer
---@param y number truck-space y
---@return number?
local function rampSurface(truck, y)
    local p = GetOffsetFromEntityInWorldCoords(truck, 0.0, y, 0.0)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(p.x, p.y, p.z + 4.0, p.x, p.y, p.z - 4.0, 16, 0, 7)
    local _, hit, point, _, entity = GetShapeTestResult(probe)
    if (hit == 1 or hit == true) and isRamp(truck, entity) then return point.z end
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
---@return SwRampGeometry?, SwRampAdjust
local function fitRamps(truck, list)
    local adjust = { tilt = 0.0, z = 0.0 }
    local applied = { tilt = 0.0, z = 0.0 }
    local geometry
    for _ = 1, 4 do
        geometry = rampGeometry(truck, adjust)
        if not geometry then return nil, applied end
        applyTransforms(list, geometry)
        applied = { tilt = adjust.tilt, z = adjust.z }
        local highY, lowY = geometry.edgeY - 0.3, geometry.footY + 0.6
        local zHigh, zLow = rampSurface(truck, highY), rampSurface(truck, lowY)
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
    if flatbed.debug and geometry then print(('[sw_tow] ramps fitted: %s, height %+.2f m'):format(geometry.info, applied.z)) end
    return geometry, applied
end

---@param truck integer
---@return SwRampGeometry?
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
    local fitted, adjust = fitRamps(truck, list)
    fits[truck] = adjust
    return fitted
end

AddStateBagChangeHandler('sw_tow:ramps', '', function(bagName, _, value)
    CreateThread(function()
        local truck, arrived = util.entityFromBag(bagName, 2000)
        if not truck then return end
        if value then placeRamps(truck) else removeRamps(truck) end
        if not arrived then sounds.play(value and 'rampsDown' or 'rampsUp', truck) end
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
    -- Wait for our own copy of the ramps, so the winch never starts before they exist.
    local deadline = GetGameTimer() + 3000
    while (ramps[truck] ~= nil) ~= down and GetGameTimer() < deadline do Wait(50) end
    return true
end

-- The vehicle in the truck's space -----------------------------------------------------------------

---Freezes or releases the truck. Done explicitly around every winch run, not only through the
---ramps state bag, so the truck can never be pushed by its cargo.
---@param truck integer
---@param hold boolean
local function holdTruck(truck, hold)
    if requestControl(truck, 1500) then FreezeEntityPosition(truck, hold) end
end

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

---Where the vehicle stands in the truck's space: offset, and rotation as pitch, roll and yaw in
---degrees, the way attachments take it.
---@param truck integer
---@param target integer
---@return vector3 offset, vector3 rotation
local function relativePose(truck, target)
    local o = toTruck(truck, GetEntityCoords(target))
    local f = toTruck(truck, GetOffsetFromEntityInWorldCoords(target, 0.0, 1.0, 0.0)) - o
    local r = toTruck(truck, GetOffsetFromEntityInWorldCoords(target, 1.0, 0.0, 0.0)) - o
    local pitch = math.asin(clamp(f.z, -1.0, 1.0))
    local roll = math.asin(clamp(-r.z / math.max(0.05, math.cos(pitch)), -1.0, 1.0))
    return o, vec3(math.deg(pitch), math.deg(roll), math.deg(math.atan(-f.x, f.y)))
end

---@param truck integer
---@param target integer
---@param offset vector3
---@param rot vector3
local function attach(truck, target, offset, rot)
    AttachEntityToEntity(target, truck, 0, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z,
        false, false, false, false, 2, true)
end

---Attaches the vehicle where it rests now, so securing never moves it.
---@param truck integer
---@param target integer
local function attachInPlace(truck, target)
    local offset, rot = relativePose(truck, target)
    attach(truck, target, offset, rot)
end

---The straps pull a vehicle that stands on the bed onto the centre line, straight and level, over
---a moment. One that stands far off is left where it is rather than dragged across the bed.
---@param truck integer
---@param target integer
local function straighten(truck, target)
    local offset, rot = relativePose(truck, target)
    local yaw = math.abs(wrap(rot.z)) < 90.0 and 0.0 or 180.0
    local turn = wrap(rot.z - yaw)
    if math.abs(offset.x) > 0.6 or math.abs(turn) > 10.0 then return attach(truck, target, offset, rot) end
    local duration = clamp(0.4 + math.abs(offset.x) + math.abs(turn) / 10.0, 0.4, 1.5) * 1000
    local started = GetGameTimer()
    while DoesEntityExist(truck) and DoesEntityExist(target) do
        local k = smoothstep((GetGameTimer() - started) / duration)
        local left = 1.0 - k
        attach(truck, target, vec3(offset.x * left, offset.y, offset.z),
            vec3(rot.x * left, rot.y * left, yaw + turn * left))
        if k >= 1.0 then break end
        Wait(0)
    end
end

---@class SwBody
---@field front number vehicle-space y of the front axle
---@field rear number vehicle-space y of the rear axle
---@field radius number wheel radius
---@field min vector3
---@field max vector3

---Axles and wheel size, from the wheel bones.
---@param vehicle integer
---@return SwBody
local function measureBody(vehicle)
    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    local function wheel(name)
        local index = GetEntityBoneIndexByName(vehicle, name)
        if index == -1 then return end
        local p = GetWorldPositionOfEntityBone(vehicle, index)
        return GetOffsetFromEntityGivenWorldCoords(vehicle, p.x, p.y, p.z)
    end
    local lf, lr = wheel('wheel_lf'), wheel('wheel_lr')
    local front, rear = lf and lf.y or max.y * 0.6, lr and lr.y or min.y * 0.6
    if front - rear < 1.0 then front, rear = max.y * 0.6, min.y * 0.6 end
    return {
        front = front,
        rear = rear,
        radius = clamp(lf and (lf.z - min.z) or 0.33, 0.2, 0.7),
        min = min,
        max = max,
    }
end

-- The animated winch ----------------------------------------------------------------------------
-- The vehicle follows a path in the truck's space: a cubic curve on the ground from where it stands
-- to the centre line behind the ramps, then straight along it. Its height and pitch come from the
-- surface under its two axles: ground, ramp, bed.

---@class SwProfile heights of the surface the wheels run on, in truck space
---@field farY number a point on the ground away from the ramps
---@field farZ number
---@field footY number
---@field footZ number
---@field edgeY number
---@field bedZ number

---@param truck integer
---@param geometry SwRampGeometry
---@return SwProfile
local function profileFor(truck, geometry)
    local ground, bed = toTruck(truck, geometry.ground), toTruck(truck, geometry.bed)
    return { farY = ground.y - 1.0, farZ = ground.z, footY = ground.y, footZ = ground.z, edgeY = geometry.edgeY, bedZ = bed.z }
end

---@param p SwProfile
---@param y number truck-space y
---@return number z
local function surface(p, y)
    if y >= p.edgeY then return p.bedZ end
    if y >= p.footY then return p.footZ + (p.bedZ - p.footZ) * (y - p.footY) / (p.edgeY - p.footY) end
    -- The ground, from the ramp foot out to the far point and level beyond it.
    local span = p.footY - p.farY
    if span < 0.01 then return p.footZ end
    return p.footZ + (p.farZ - p.footZ) * math.min(1.0, (p.footY - y) / span)
end

---Local z of the ground under a truck-space point, if the ground is there.
---@param truck integer
---@param point vector3
---@return number?
local function groundBelow(truck, point)
    local w = GetOffsetFromEntityInWorldCoords(truck, point.x, point.y, point.z)
    local found, z = GetGroundZFor_3dCoord(w.x, w.y, w.z + 1.0, false)
    if not found then return end
    return toTruck(truck, vec3(w.x, w.y, z)).z
end

---@class SwPath
---@field p0 vector2
---@field p1 vector2
---@field p2 vector2
---@field m0 vector2?
---@field m1 vector2?
---@field d1 vector2 unit direction of the straight part
---@field curve number length of the curve
---@field straight number length of the straight part
---@field total number
---@field samples { t: number, s: number }[] curve parameter by distance

---@param path SwPath
---@param t number
---@return vector2 position, vector2 velocity, vector2 acceleration
local function hermite(path, t)
    local p0, p1, m0, m1 = path.p0, path.p1, path.m0 --[[@as vector2]], path.m1 --[[@as vector2]]
    local t2, t3 = t * t, t * t * t
    local p = p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t) + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2)
    local d = p0 * (6 * t2 - 6 * t) + m0 * (3 * t2 - 4 * t + 1) + p1 * (-6 * t2 + 6 * t) + m1 * (3 * t2 - 2 * t)
    local dd = p0 * (12 * t - 6) + m0 * (6 * t - 4) + p1 * (-12 * t + 6) + m1 * (6 * t - 2)
    return p, d, dd
end

---A curve from p0 leaving along d0 to p1 arriving along d1, then straight on to p2.
---@return SwPath
local function buildPath(p0, d0, p1, d1, p2)
    local path = { p0 = p0, p1 = p1, p2 = p2, d1 = d1, curve = 0.0, samples = {} }
    local chord = #(p1 - p0)
    if chord > 0.05 then
        path.m0, path.m1 = d0 * chord, d1 * chord
        local length, last, steps = 0.0, p0, 40
        path.samples[1] = { t = 0.0, s = 0.0 }
        for i = 1, steps do
            local t = i / steps
            local p = hermite(path, t)
            length = length + #(p - last)
            last = p
            path.samples[i + 1] = { t = t, s = length }
        end
        path.curve = length
    end
    path.straight = #(p2 - p1)
    path.total = path.curve + path.straight
    return path
end

---@param path SwPath
---@param s number distance along the path
---@return vector2 position, vector2 direction, number curvature 1/m, positive turning left
local function pathAt(path, s)
    if s < path.curve then
        local samples, i = path.samples, 2
        while i < #samples and samples[i].s < s do i = i + 1 end
        local a, b = samples[i - 1], samples[i]
        local t = a.t + (b.t - a.t) * (s - a.s) / math.max(1e-6, b.s - a.s)
        local p, d, dd = hermite(path, t)
        local speed = math.max(1e-4, #d)
        return p, d / speed, (d.x * dd.y - d.y * dd.x) / (speed * speed * speed)
    end
    return path.p1 + path.d1 * math.min(s - path.curve, path.straight), path.d1, 0.0
end

---@class SwRun
---@field truck integer
---@field target integer
---@field direction 1|-1 1 = up onto the bed, -1 = down to the ground
---@field motion 1|-1 1 = the vehicle moves nose first
---@field body SwBody
---@field profile SwProfile
---@field path SwPath
---@field h number height of the vehicle's origin above its wheels' contact points
---@field startOffset vector3
---@field startRot vector3
---@field leadEnd number distance from the centre to the end that leads in the direction of travel
---@field rest vector4 world pose on the ground to fall back to (start of a load, end of an unload)

---The pose at distance `s` along the path: origin offset and rotation in truck space, and the
---curvature for the steering.
---@param run SwRun
---@param s number
---@return vector3 offset, vector3 rotation, number curvature
local function poseAt(run, s)
    local p, dir, curvature = pathAt(run.path, s)
    local yaw = math.deg(math.atan(-dir.x, dir.y)) + (run.motion > 0 and 0.0 or 180.0)
    local fwd = vec2(-math.sin(math.rad(yaw)), math.cos(math.rad(yaw)))
    local body = run.body
    local front, rear = p + fwd * body.front, p + fwd * body.rear
    local zFront, zRear = surface(run.profile, front.y), surface(run.profile, rear.y)
    local sinPitch = clamp((zFront - zRear) / (body.front - body.rear), -0.7, 0.7)
    local cosPitch = math.sqrt(1.0 - sinPitch * sinPitch)
    -- From the rear contact point along the pitched body to the axle midpoint line, then up.
    local back = -body.rear
    local o = rear + fwd * (back * cosPitch - run.h * sinPitch)
    local z = zRear + back * sinPitch + run.h * cosPitch
    return vec3(o.x, o.y, z), vec3(math.deg(math.asin(sinPitch)), 0.0, wrap(yaw)), curvature
end

---Plans a winch run from where the vehicle stands now.
---@param truck integer
---@param target integer
---@param direction 1|-1
---@param geometry SwRampGeometry
---@return SwRun
local function planRun(truck, target, direction, geometry)
    local body = measureBody(target)
    local offset, rot = relativePose(truck, target)
    local facing = math.abs(wrap(rot.z)) < 90.0
    local motion = (facing and 1 or -1) * direction
    local profile = profileFor(truck, geometry)
    local resting = -body.min.z
    local trailAxle = motion > 0 and -body.rear or body.front
    local leadEnd = motion > 0 and body.max.y or -body.min.y
    local yaw = math.rad(rot.z)
    local d0 = vec2(-math.sin(yaw), math.cos(yaw)) * motion
    local d1 = vec2(0.0, direction)
    local h, p1, p2
    if direction > 0 then
        local ground = groundBelow(truck, offset)
        h = ground and offset.z - ground or resting
        if math.abs(h - resting) > 0.3 then h = resting end
        profile.farY, profile.farZ = offset.y, offset.z - h
        -- Straight and centred by the time the trailing wheels reach the ramp foot: like a driver,
        -- it still steers a little while the leading wheels start up the ramp.
        local endY = cfg.bedFrontY - leadEnd
        local alignY = math.min(endY, math.max(offset.y + 0.5, profile.footY + trailAxle - 0.2))
        p1, p2 = vec2(0.0, alignY), vec2(0.0, endY)
    else
        h = offset.z - surface(profile, offset.y)
        if math.abs(h - resting) > 0.3 then h = resting end
        -- Down until the wheels nearest the truck are clear of the ramp foot; straight within 2.5 m.
        local endY = profile.footY - 0.6 - trailAxle
        local ground = groundBelow(truck, vec3(0.0, endY, profile.footZ + 1.0))
        profile.farY = endY - 1.0
        profile.farZ = (ground and math.abs(ground - profile.footZ) < 1.0) and ground or profile.footZ
        p1, p2 = vec2(0.0, math.max(endY, offset.y - 2.5)), vec2(0.0, endY)
    end
    local run = {
        truck = truck,
        target = target,
        direction = direction,
        motion = motion,
        body = body,
        profile = profile,
        path = buildPath(vec2(offset.x, offset.y), d0, p1, d1, p2),
        h = h,
        startOffset = offset,
        startRot = rot,
        leadEnd = leadEnd,
    }
    if direction > 0 then
        local c = GetEntityCoords(target)
        run.rest = vec4(c.x, c.y, c.z, GetEntityHeading(target))
    else
        local o, r = poseAt(run, run.path.total)
        local c = GetOffsetFromEntityInWorldCoords(truck, o.x, o.y, o.z)
        run.rest = vec4(c.x, c.y, c.z, GetEntityHeading(truck) + r.z)
    end
    return run
end

---The sharpest front-wheel angle the run's curve asks for, in degrees.
---@param run SwRun
---@return number
local function steerNeeded(run)
    local wheelbase, worst, s = run.body.front - run.body.rear, 0.0, 0.0
    while s < run.path.curve do
        local _, _, curvature = pathAt(run.path, s)
        worst = math.max(worst, math.abs(math.deg(math.atan(wheelbase * curvature))))
        s = s + 0.1
    end
    return worst
end

---Is the way clear: from the vehicle to the ramp foot when loading, behind the ramps when
---unloading? Rays at bumper and bonnet height along both sides and the middle. Map, vehicles and
---objects count; people do not, the vehicle passes through them.
---@param run SwRun
---@return boolean
local function wayClear(run)
    local truck, p, body = run.truck, run.profile, run.body
    local from, to, fromZ, toZ, ignore
    if run.direction > 0 then
        local tipY = run.startOffset.y + run.leadEnd + 0.2
        from, to = vec2(run.startOffset.x, tipY), vec2(0.0, p.footY - 0.3)
        fromZ, toZ, ignore = p.farZ, p.footZ, run.target
    else
        local farEnd = run.path.p2.y - run.leadEnd - 0.2
        from, to = vec2(0.0, p.footY - 0.3), vec2(0.0, farEnd)
        fromZ, toZ, ignore = p.footZ, p.farZ, truck
    end
    if math.abs(to.y - from.y) < 0.2 then return true end
    local half = (body.max.x - body.min.x) / 2 - 0.1
    for _, side in ipairs({ -half, 0.0, half }) do
        for _, height in ipairs({ 0.5, 1.0 }) do
            local a = GetOffsetFromEntityInWorldCoords(truck, from.x + side, from.y, fromZ + height)
            local b = GetOffsetFromEntityInWorldCoords(truck, to.x + side, to.y, toZ + height)
            local probe = StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 1 | 2 | 16, ignore, 7)
            local _, hit, _, _, entity = GetShapeTestResult(probe)
            if (hit == 1 or hit == true) and entity ~= truck and entity ~= run.target and not isRamp(truck, entity) then
                if flatbed.debug then print(('[sw_tow] way blocked by entity %s (side %+.1f, height %.1f)'):format(entity, side, height)) end
                return false
            end
        end
    end
    return true
end

---@type table<integer, vector4> vehicles this client's winch is moving -> ground pose to fall back to
local moving = {}

local ACCEL = 0.8 -- m/s², winch starting and stopping
local BLEND = 0.8 -- metres over which the vehicle eases from how it stood into the path

---Runs the planned path. The vehicle is attached to the truck the whole time, so the truck carries
---it if anything moves, and nothing it meets can push or stop it.
---@param run SwRun
---@return boolean ok, string? why 'gone'|'control'
local function animate(run)
    local truck, target = run.truck, run.target
    local netId = NetworkGetNetworkIdFromEntity(target)
    SetNetworkIdCanMigrate(netId, false)
    moving[target] = run.rest
    SetVehicleDoorsShut(target, false)

    -- Where it stands now against where the path starts: that difference fades out over BLEND.
    local base, baseRot = poseAt(run, 0.0)
    local dOffset = run.startOffset - base
    local dRot = vec3(run.startRot.x - baseRot.x, run.startRot.y - baseRot.y, wrap(run.startRot.z - baseRot.z))
    local wheelbase = run.body.front - run.body.rear
    local wheels = GetVehicleNumberOfWheels(target)
    local total = run.path.total
    local s, v, steer = 0.0, 0.0, 0.0
    local started, lostAt, lastLog = GetGameTimer(), nil, 0
    local ok, why = true, nil

    while true do
        if not DoesEntityExist(truck) or not DoesEntityExist(target) then
            ok, why = false, 'gone'
            break
        end
        local now = GetGameTimer()
        if NetworkHasControlOfEntity(target) then
            lostAt = nil
        else
            NetworkRequestControlOfEntity(target)
            lostAt = lostAt or now
            if now - lostAt > 2000 then
                ok, why = false, 'control'
                break
            end
        end
        if not lostAt then
            local dt = math.min(0.1, GetFrameTime())
            v = math.min(v + ACCEL * dt, cfg.pullSpeed, math.sqrt(2.0 * ACCEL * math.max(0.0, total - s)) + 0.05)
            s = math.min(total, s + v * dt)
            local offset, rot, curvature = poseAt(run, s)
            local fade = 1.0 - smoothstep(s / BLEND)
            attach(truck, target, offset + dOffset * fade, rot + dRot * fade)

            -- Front wheels follow the curve (bicycle model: tan(steer) = wheelbase · curvature);
            -- reversing, they turn the other way. Like hands on a wheel: at most 90° per second.
            local wanted = clamp(math.deg(math.atan(wheelbase * curvature)) * run.motion, -35.0, 35.0)
            local step = 90.0 * dt
            steer = steer + clamp(wanted - steer, -step, step)
            SetVehicleSteeringAngle(target, steer)
            -- Wheels roll with the ground speed.
            local spin = -v * run.motion / run.body.radius
            for i = 0, wheels - 1 do SetVehicleWheelRotationSpeed(target, i, spin) end

            if flatbed.debug and now - lastLog >= 500 then
                lastLog = now
                print(('[sw_tow] winch t=%.1f s=%.2f/%.2f x=%+.2f y=%.2f z=%.2f pitch=%+.1f yaw=%+.1f steer=%+.1f'):format(
                    (now - started) / 1000, s, total, offset.x, offset.y, offset.z, rot.x, rot.z, steer))
            end
            if s >= total then break end
        end
        Wait(0)
    end

    if DoesEntityExist(target) then
        SetVehicleSteeringAngle(target, 0.0)
        for i = 0, wheels - 1 do SetVehicleWheelRotationSpeed(target, i, 0.0) end
    end
    SetNetworkIdCanMigrate(netId, true)
    moving[target] = nil
    if flatbed.debug then print(('[sw_tow] winch %s in %.1f s'):format(ok and 'done' or why, (GetGameTimer() - started) / 1000)) end
    return ok, why
end

-- The physics winch (motion = 'physics') -----------------------------------------------------------

---@class SwPull
---@field truck integer
---@field target integer
---@field direction 1|-1 1 = towards the cab (loading), -1 = down the ramps (letting it back)
---@field done fun(): boolean
---@field speed number
---@field gateY number? loading: steer on the ground until the leading end reaches this, then climb

---Moves the vehicle with the winch until `done`.
---On the ground it rolls along its own body while it is steered the way a driver would (Stanley
---controller: heading error plus offset of the leading axle), and the body turns as steered wheels
---would dictate. On the ramps and the bed physics does the rest.
---@param pull SwPull
---@return boolean ok, string? why 'stuck'|'blocked'|'unstable'|'gone'|'timeout'|'misaligned'|'truck'
local function drive(pull)
    local truck, target = pull.truck, pull.target
    local truckStart = GetEntityCoords(truck)
    local lastLog = 0
    SetVehicleHandbrake(target, false)
    SetVehicleEngineOn(target, false, true, true)
    local _, _, facing = leadingEnd(truck, target)
    -- +1: the vehicle moves along its nose; -1: it moves backwards.
    local motion = (facing and 1 or -1) * pull.direction
    local body = measureBody(target)
    local base = body.front - body.rear
    local steer = 0.0

    local started = GetGameTimer()
    local best, bestAt, boosted = -math.huge, started, false
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
        -- An empty vehicle has its brakes applied: pushed against them it only squats and stalls.
        -- The winch rolls it, so foot brake and handbrake are released every frame.
        SetVehicleBrake(target, false)
        SetVehicleHandbrake(target, false)

        local centre = toTruck(truck, GetEntityCoords(target))
        -- Travel heading error against the truck's axis (towards the cab when loading).
        local travelHeading = GetEntityHeading(target) + (motion > 0 and 0.0 or 180.0)
        local pathHeading = GetEntityHeading(truck) + (pull.direction > 0 and 0.0 or 180.0)
        local headingError = wrap(pathHeading - travelHeading)
        -- Offset of the axle that leads in the direction of travel.
        local axle = GetOffsetFromEntityInWorldCoords(target, 0.0, motion > 0 and body.front or body.rear, 0.0)
        local offset = toTruck(truck, axle).x * pull.direction

        local onGround = pull.direction > 0 and pull.gateY ~= nil
        if onGround then
            local lead = leadingEnd(truck, target)
            if lead >= pull.gateY then
                -- At the ramp foot: it climbs only if it is straight and centred.
                if math.abs(centre.x) > 0.3 or math.abs(headingError) > 4.0 then return false, 'misaligned' end
                pull.gateY, onGround = nil, false
            end
        end

        -- Progress along the truck. Loading gets one stronger pull over a bump; anything else that
        -- stops moving for 1.5 s is stuck, and the winch stops before tyres burn or things break.
        local progress = centre.y * pull.direction
        if progress > best + 0.1 then
            best, bestAt = progress, now
        elseif now - bestAt > 1500 then
            if boosted or pull.direction < 0 then return false, onGround and 'blocked' or 'stuck' end
            boosted, bestAt = true, now
        end

        local speed = pull.speed * (boosted and 1.6 or 1.0)
        local v = GetEntityVelocity(target)
        local along = norm(GetOffsetFromEntityInWorldCoords(target, 0.0, 1.0, 0.0) - GetEntityCoords(target))
        along = norm(vec3(along.x, along.y, 0.0)) * motion

        -- Steering angle for the direction of travel (positive turns the travel direction left).
        local wanted = 0.0
        if onGround then
            -- Right of the axis (offset > 0) means turn left (positive), and harder at low speed.
            local cross = math.deg(math.atan(1.2 * offset, math.max(0.5, GetEntitySpeed(target))))
            wanted = clamp(headingError + cross, -30.0, 30.0)
        end
        -- Like hands on a wheel: at most 60° per second.
        local step = 60.0 * GetFrameTime()
        steer = steer + clamp(wanted - steer, -step, step)

        local want = along * speed
        SetEntityVelocity(target, v.x + (want.x - v.x) * 0.12, v.y + (want.y - v.y) * 0.12, v.z)
        local yaw = 0.0
        if onGround then
            -- The body turns as steered wheels would: yaw rate = v · tan(steer) / wheelbase.
            yaw = GetEntitySpeed(target) * math.tan(math.rad(steer)) / base
            SetEntityAngularVelocity(target, 0.0, 0.0, yaw)
        end

        if flatbed.debug and now - lastLog >= 250 then
            lastLog = now
            print(('[sw_tow] pull t=%.1f y=%.2f x=%+.2f axle=%+.2f heading err=%+.1f steer=%+.1f yaw=%+.2f speed=%.2f pitch=%.1f roll=%.1f%s%s'):format(
                (now - started) / 1000, centre.y, centre.x, offset, headingError, steer, yaw, GetEntitySpeed(target),
                GetEntityPitch(target), GetEntityRoll(target), onGround and ' GROUND' or '', boosted and ' BOOST' or ''))
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

---@param truck integer
---@param target integer
---@param geometry SwRampGeometry
---@return boolean ok, string? errorKey
local function physicsPull(truck, target, geometry)
    local ok, why = drive({
        truck = truck,
        target = target,
        direction = 1,
        speed = cfg.pullSpeed,
        gateY = geometry.footY - 0.3,
        done = function() return leadingEnd(truck, target) >= cfg.bedFrontY end,
    })
    halt(target)
    if flatbed.debug then print('[sw_tow] pull result: ' .. (ok and 'ok' or tostring(why))) end
    if ok then
        Wait(500) -- Let the suspension settle on the bed before the straps go on.
        attachInPlace(truck, target)
        straighten(truck, target)
        return true
    end
    if why == 'gone' then return false, 'tow.no_control' end
    if why ~= 'misaligned' and why ~= 'truck' and why ~= 'blocked' then
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
    if why == 'blocked' then return false, 'tow.path_blocked' end
    return false, why == 'misaligned' and 'tow.not_straight' or 'tow.cannot_climb'
end

-- Loading and unloading -----------------------------------------------------------------------------

---Up onto the bed and strapped. Ramps are down and the truck is held.
---@param truck integer
---@param target integer
---@param geometry SwRampGeometry
---@return boolean ok, string? errorKey
local function pullUp(truck, target, geometry)
    local run = planRun(truck, target, 1, geometry)
    if not wayClear(run) then return false, 'tow.path_blocked' end
    if cfg.motion == 'physics' then return physicsPull(truck, target, geometry) end
    local ok = animate(run)
    if not ok then return false, 'tow.no_control' end
    return true
end

---Down the ramps and let go on the ground. Ramps are down and the truck is held.
---@param truck integer
---@param target integer
---@param geometry SwRampGeometry
---@return boolean ok, string? errorKey
local function letDown(truck, target, geometry)
    local run = planRun(truck, target, -1, geometry)
    if not wayClear(run) then return false, 'tow.landing_blocked' end
    if not animate(run) then
        -- Control was lost on the way: if it comes back, strap it again where it started.
        if DoesEntityExist(target) and DoesEntityExist(truck) and requestControl(target, 1000) then
            attach(truck, target, run.startOffset, run.startRot)
        end
        return false, 'tow.cannot_unload'
    end
    -- It stands on its wheels on the ground at its resting height: letting go does not move it.
    DetachEntity(target, true, true)
    SetEntityVelocity(target, 0.0, 0.0, 0.0)
    SetVehicleOnGroundProperly(target)
    return true
end

---@class SwLineUp
---@field ok boolean
---@field key string? locale key of the first problem
---@field value string? metres or degrees for that message
---@field geometry SwRampGeometry?

-- The sharpest the front wheels may turn while lining up: about what a car can do, so the vehicle
-- never swings round faster than it could on its own wheels.
local MAX_STEER = 32.0

---Roughly how far sideways a vehicle standing straight can still be lined up from `gap` metres
---behind the ramp foot with MAX_STEER (from the planned paths). Only for the tinted zone; the check
---itself plans the real path.
---@param gap number metres between the vehicle's leading end and the ramp foot
---@return number
local function sideAllowance(gap)
    gap = math.max(0.0, gap)
    return math.min(3.0, 0.45 + 0.2 * gap + 0.04 * gap * gap)
end

---How the vehicle stands for loading. The cable only pulls towards the truck, so the leading end
---must be behind the ramp foot and within winch range, and the curve that lines it up must be one
---a car could drive: the further back it stands, the more offset and angle it can take out.
---@param truck integer
---@param target integer
---@param geometry? SwRampGeometry
---@return SwLineUp
function flatbed.assess(truck, target, geometry)
    geometry = geometry or currentGeometry(truck)
    if not geometry then return { ok = false, key = 'tow.no_ramps' } end
    local lead, _, facing = leadingEnd(truck, target)
    local gap = geometry.footY - lead
    local centre = toTruck(truck, GetEntityCoords(target))
    local heading = GetEntityHeading(truck) + (facing and 0.0 or 180.0)
    local angle = math.abs(wrap(heading - GetEntityHeading(target)))

    local result = { ok = false, geometry = geometry }
    if gap < 0.3 then
        result.key, result.value = 'tow.too_close', ('%.0f'):format(math.max(1, 0.3 - gap))
    elseif gap > cfg.winchRange then
        result.key, result.value = 'tow.too_far', ('%.0f'):format(math.max(1, gap - cfg.winchRange))
    elseif angle > 35.0 or math.abs(centre.x) > 3.0 or steerNeeded(planRun(truck, target, 1, geometry)) > MAX_STEER then
        -- Name what is most off: a turned vehicle is straightened by lining up behind it.
        if angle >= 8.0 then
            result.key, result.value = 'tow.off_angle', ('%.0f'):format(angle)
        else
            result.key, result.value = 'tow.off_side', ('%.1f'):format(math.abs(centre.x))
        end
    else
        result.ok = true
    end
    return result
end

---@type table<integer, vector3> truck model -> roller offset
local rollers = {}

---The roller on the rear edge of the bed, in truck space. While the vehicle is behind the bed the
---cable runs along the bed, over this roller and down to the vehicle, never through the bed.
---Measured once per truck model.
---@param truck integer
---@return vector3
function flatbed.rollerOffset(truck)
    local model = GetEntityModel(truck)
    if not rollers[model] then
        local min = GetModelDimensions(model)
        local surface = toTruck(truck, bedRear(truck))
        rollers[model] = vec3(0.0, (cfg.rearY or min.y) + 0.1, surface.z + 0.06)
    end
    return rollers[model]
end

---Where the ramps meet the ground, as truck-space y (behind the truck is negative). For placing
---vehicles in /swtow_test. Nil when the ramp model cannot be loaded.
---@param truck integer
---@return number?
function flatbed.rampFootY(truck)
    local ok, model = pcall(lib.requestModel, cfg.ramp.model)
    if not ok or not model then return end
    local geometry = currentGeometry(truck)
    SetModelAsNoLongerNeeded(model)
    return geometry and geometry.footY
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
    return false, result.key, result.value
end

---Loads `target` onto `truck`: ramps down, winch it up, strap it, ramps up. The server has already
---accepted the attach request. If it fails, the ramps stay down for another try.
---@param truck integer
---@param target integer
---@return boolean secured, string? errorKey
function flatbed.load(truck, target)
    if not flatbed.rampsDown(truck) then
        local down, rampError = flatbed.setRamps(truck, true)
        if not down then return false, rampError end
    end
    if not requestControl(target) then return false, 'tow.no_control' end
    local geometry = currentGeometry(truck)
    if not geometry then return false, 'tow.no_ramps' end
    holdTruck(truck, true)
    local ok, errorKey = pullUp(truck, target, geometry)
    if ok then
        flatbed.setRamps(truck, false)
        holdTruck(truck, false)
        return true
    end
    -- With the ramps still down the truck stays where it is.
    holdTruck(truck, flatbed.rampsDown(truck))
    return false, errorKey
end

---Secures a vehicle that is already on the bed (the owner drove it up the ramps).
---@param truck integer
---@param target integer
---@return boolean
function flatbed.secureInPlace(truck, target)
    if not requestControl(target) then return false end
    halt(target)
    attachInPlace(truck, target)
    straighten(truck, target)
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

---Unloads the cargo: ramps down, winch it down the ramps onto the ground, let go, ramps up. If it
---cannot come down it stays strapped on the bed.
---@param truck integer
---@param target integer
---@return boolean ok, string? errorKey
function flatbed.unload(truck, target)
    if not flatbed.rampsDown(truck) then
        local down, rampError = flatbed.setRamps(truck, true)
        if not down then return false, rampError end
    end
    local geometry = currentGeometry(truck)
    if not geometry or not requestControl(target) then
        flatbed.setRamps(truck, false)
        return false, geometry and 'tow.no_control' or 'tow.no_ramps'
    end
    holdTruck(truck, true)
    local ok, errorKey = letDown(truck, target, geometry)
    flatbed.setRamps(truck, false)
    holdTruck(truck, false)
    return ok, errorKey
end

---Development bench: loads and unloads test vehicles behind your flatbed in a set of standard
---positions and logs how each run went: how long it took, how straight it stands on the bed, and
---whether unloading worked. Only with debug on (setr sw_tow_debug 1). The test vehicles exist only
---for this run.
---@param truck integer
function flatbed.bench(truck)
    if not flatbed.debug then return print('[sw_tow] bench needs debug: setr sw_tow_debug 1') end
    local scenarios = {
        { name = 'straight', x = 0.0, angle = 0.0 },
        { name = 'side 1.0 m', x = 1.0, angle = 0.0 },
        { name = 'side -1.5 m, 10 deg', x = -1.5, angle = 10.0 },
        { name = 'rear first', x = 0.3, angle = 180.0 },
    }
    local models = { 'asea', 'zentorno', 'baller' }
    local results = {}
    local geometry = placeRamps(truck)
    if not geometry then return print('[sw_tow] bench: ramps could not be placed') end
    holdTruck(truck, true)

    for _, modelName in ipairs(models) do
        for _, scenario in ipairs(scenarios) do
            local model = lib.requestModel(modelName)
            local min, max = GetModelDimensions(model)
            local half = (max.y - min.y) / 2
            local spot = GetOffsetFromEntityInWorldCoords(truck, scenario.x, geometry.footY - 4.5 - half, 0.0)
            local vehicle = CreateVehicle(model, spot.x, spot.y, spot.z + 1.0, GetEntityHeading(truck) + scenario.angle, true, false)
            SetModelAsNoLongerNeeded(model)
            SetVehicleOnGroundProperly(vehicle)
            Wait(800)

            local label = ('%s · %s · %s'):format(modelName, scenario.name, cfg.motion or 'animated')
            print('[sw_tow] bench start: ' .. label)
            local steer = steerNeeded(planRun(truck, vehicle, 1, geometry))
            local started = GetGameTimer()
            local loaded, why = pullUp(truck, vehicle, geometry)
            local seconds = (GetGameTimer() - started) / 1000
            local o, r = relativePose(truck, vehicle)
            local unloaded = '-'
            if loaded then
                Wait(500)
                local down, downWhy = letDown(truck, vehicle, geometry)
                unloaded = down and 'ok' or tostring(downWhy)
            end
            local line = ('%s: steer %.0f°, load %s in %.1f s, on the bed x=%+.2f y=%.2f yaw=%+.1f pitch=%+.1f roll=%+.1f, unload %s'):format(
                label, steer, loaded and 'ok' or tostring(why), seconds, o.x, o.y, wrap(r.z), r.x, r.y, unloaded)
            results[#results + 1] = line
            print('[sw_tow] bench result: ' .. line)
            DeleteEntity(vehicle)
            Wait(500)
        end
    end

    removeRamps(truck)
    holdTruck(truck, false)
    print('[sw_tow] bench summary:')
    for i = 1, #results do print('[sw_tow]   ' .. results[i]) end
end

---Development aid: shows ramp candidates behind your truck so the best-looking one can be picked.
---@param truck integer
---@param models string[]
function flatbed.previewRamps(truck, models)
    local saved = cfg.ramp.model
    for _, name in ipairs(models) do
        if IsModelInCdimage(joaat(name)) then
            cfg.ramp.model = name
            local geometry = placeRamps(truck)
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
        local w0, w1 = sideAllowance(g0) + 1.0, sideAllowance(g1) + 1.0
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

local guideRunning = false

local function runGuide()
    if guideRunning then return end
    guideRunning = true
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
                    local geometry = currentGeometry(truck)
                    if geometry then
                        result = flatbed.assess(truck, target, geometry)
                        strips = zoneStrips(truck, geometry)
                    end
                end
            end
            if result then
                showHint(result.ok and locale('tow.guide_ok') or locale(result.key, result.value))
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
    guideRunning = false
end

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if value then CreateThread(runGuide) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    showHint(nil)
    -- A vehicle caught half-way is put down on the ground where it started or was going to land.
    for target, rest in pairs(moving) do
        if DoesEntityExist(target) and NetworkHasControlOfEntity(target) then
            DetachEntity(target, true, true)
            SetEntityCoords(target, rest.x, rest.y, rest.z, false, false, false, false)
            SetEntityHeading(target, rest.w)
            SetVehicleOnGroundProperly(target)
        end
    end
    for truck in pairs(ramps) do
        removeRamps(truck)
        if DoesEntityExist(truck) and NetworkHasControlOfEntity(truck) then FreezeEntityPosition(truck, false) end
    end
end)

return flatbed
