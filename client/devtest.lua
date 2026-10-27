---In-game test runner. /swtow_test plays the main flows with your own character on a development
---server and reports what passed. It calls the same functions as the target options and menus, so
---a pass means the real thing works in the real game: ramps, winch, hook, calls, delivery, pay, the
---counter, police holds, contracts and abandoned vehicles.
---
---Needs `setr sw_tow_dev 1` in server.cfg (see server/devtest.lua) and admin rights.
---  /swtow_test            choose from a menu
---  /swtow_test all        every scenario, about 5 minutes
---  /swtow_test <name>     one scenario (names in the menu)
---Start it standing on flat, open ground with about 40 m free in front of you: trucks and test
---vehicles are brought there. Results go to F8 and to tests-ingame.log in the resource folder.
local config = require 'config'
local util = require 'shared.util'
local notify = require 'client.notify'

-- The self-test (server command swtow_selftest) prints its results here when an admin runs it in game.
RegisterNetEvent('sw_tow:client:selftest', function(lines)
    if type(lines) ~= 'table' then return end
    for _, line in ipairs(lines) do print(line) end
    notify(tostring(lines[1]), tostring(lines[1]):find(' 0 FAIL', 1, true) and 'success' or 'warning')
end)

if GetConvar('sw_tow_dev', '0') ~= '1' then return end

local shift = require 'client.shift'
local tow = require 'client.tow'
local flatbed = require 'client.flatbed'
local calls = require 'client.calls'
local impound = require 'client.impound'
local panel = require 'client.panel'

local FLATBED, HOOK
for index, option in ipairs(config.garage.vehicles) do
    if option.method == 'flatbed' and not FLATBED then FLATBED = index end
    if option.method == 'hook' and not HOOK then HOOK = index end
end
local YARD_KEY = next(config.yards) --[[@as string]]
local YARD = config.yards[YARD_KEY] --[[@as table]]

-- Results ----------------------------------------------------------------------------------------

local lines, counts, current = {}, { PASS = 0, WARN = 0, FAIL = 0, SKIP = 0 }, '?'
local ABORT = setmetatable({}, { __tostring = function() return 'scenario aborted' end })

local function record(status, text)
    counts[status] = counts[status] + 1
    local line = ('%-4s  %-10s %s'):format(status, current, text)
    lines[#lines + 1] = line
    print(('[sw_tow test] %s'):format(line))
end

---A check that is logged and lets the scenario go on.
local function check(condition, what, detail)
    if condition then
        record('PASS', what)
    else
        record('FAIL', what .. (detail ~= nil and (' (' .. tostring(detail) .. ')') or ''))
    end
    return condition
end

---A check the rest of the scenario depends on: a failure ends the scenario.
local function expect(condition, what, detail)
    if not check(condition, what, detail) then error(ABORT, 0) end
    return condition
end

---Readable form of a refusal: the locale key and its text.
local function why(errorKey, value)
    if not errorKey then return nil end
    local text = locale(errorKey, value)
    return text ~= errorKey and ('%s: %s'):format(errorKey, text) or errorKey
end

-- Notifications the server sends, to check refusals that only come as a message.
local notices = {}
AddEventHandler('sw_tow:client:notify', function(message)
    notices[#notices + 1] = message
end)

local function noticed(key, since)
    local text = locale(key)
    for i = since + 1, #notices do
        if notices[i] == text then return true end
    end
    return false
end

-- Helpers ----------------------------------------------------------------------------------------

---Polls `fn` every 100 ms until it returns a true value (returned) or the time is up (nil).
---@param fn fun(): any
---@param timeout? integer ms
---@return any
local function waitFor(fn, timeout)
    local deadline = GetGameTimer() + (timeout or 5000)
    repeat
        local value = fn()
        if value then return value end
        Wait(100)
    until GetGameTimer() > deadline
end

local function wrap(a)
    return ((a + 180.0) % 360.0) - 180.0
end

local function control(entity)
    if NetworkHasControlOfEntity(entity) then return true end
    return waitFor(function()
        NetworkRequestControlOfEntity(entity)
        return NetworkHasControlOfEntity(entity)
    end, 3000) == true
end

---Moves the player, waiting for the ground to load.
---@param coords vector3
---@param heading? number
local function teleport(coords, heading)
    local ped = cache.ped
    if IsPedInAnyVehicle(ped, false) then TaskLeaveVehicle(ped, GetVehiclePedIsIn(ped, false), 16) Wait(300) end
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    if heading then SetEntityHeading(ped, heading) end
    waitFor(function() return HasCollisionLoadedAroundEntity(ped) end, 5000)
    Wait(300)
end

---Moves a vehicle (and whatever is attached to it) to a place, on its wheels.
local function moveVehicle(vehicle, coords, heading)
    control(vehicle)
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    SetEntityCoords(vehicle, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(vehicle, heading)
    SetVehicleOnGroundProperly(vehicle)
    SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
    Wait(500)
end

---@param netId integer
---@return integer?
local function fromNet(netId)
    return waitFor(function()
        if not NetworkDoesEntityExistWithNetworkId(netId) then return nil end
        local entity = NetToVeh(netId)
        return entity ~= 0 and entity or nil
    end, 5000)
end

local function vec4Table(v)
    return { x = v.x, y = v.y, z = v.z, w = v.w }
end

---An unowned test vehicle (plate SWTE…), spawned by the server like any parked car.
---@param drop? boolean let it fall from where it is instead of putting it on the ground below
---@return integer?
local function spawnVehicle(model, at, drop)
    local netId = lib.callback.await('sw_tow:dev:spawnVehicle', false, model, vec4Table(at))
    local vehicle = netId and fromNet(netId)
    if vehicle and not drop then moveVehicle(vehicle, at.xyz, at.w) end
    return vehicle
end

---A test vehicle owned by you, as if bought.
---@return integer? vehicle, integer? vehicleId, string? plate
local function spawnOwned(model, at)
    local netId, vehicleId, plate = lib.callback.await('sw_tow:dev:ownedVehicle', false, model, vec4Table(at))
    if not netId then return nil, nil, vehicleId end
    local vehicle = fromNet(netId)
    if vehicle then moveVehicle(vehicle, at.xyz, at.w) end
    return vehicle, vehicleId, plate
end

local function remove(vehicle)
    if vehicle and DoesEntityExist(vehicle) and control(vehicle) then
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteEntity(vehicle)
    end
end

local function money()
    local m = lib.callback.await('sw_tow:dev:money', false)
    return m and (m.cash + m.bank) or 0
end

local function sitIn(vehicle)
    TaskWarpPedIntoVehicle(cache.ped, vehicle, -1)
    waitFor(function() return GetVehiclePedIsIn(cache.ped, false) == vehicle end, 3000)
end

local function getOut()
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle ~= 0 then
        TaskLeaveVehicle(cache.ped, vehicle, 16)
        waitFor(function() return not IsPedInAnyVehicle(cache.ped, false) end, 3000)
    end
end

---Where the test site is: set when a run starts, where the tester stands.
---@type vector4
local site

---The company truck of the given kind, parked on the test site.
---@param index integer config.garage.vehicles index
---@return integer truck
local function truckOnSite(index)
    local wanted = config.garage.vehicles[index]
    local truck = shift.truck()
    if truck and Entity(truck).state['sw_tow:method'] ~= wanted.method then
        moveVehicle(truck, config.garage.spawn.xyz, config.garage.spawn.w)
        teleport(config.garage.spawn.xyz + vec3(3.0, 0.0, 0.0))
        expect(shift.returnTruck(), 'the other truck is returned')
        truck = nil
    end
    if not truck then
        teleport(config.office.coords.xyz, config.office.coords.w)
        local ok, errorKey = shift.takeTruck(index)
        if errorKey == 'common.wait' then -- one truck request per 5 s
            Wait(5100)
            ok, errorKey = shift.takeTruck(index)
        end
        expect(ok, ('a %s is taken out'):format(wanted.label), why(errorKey))
        truck = expect(waitFor(shift.truck, 5000), 'the truck exists')
    end
    local forward = vec3(-math.sin(math.rad(site.w)), math.cos(math.rad(site.w)), 0.0)
    sitIn(truck)
    moveVehicle(truck, site.xyz + forward * 14.0, site.w)
    getOut()
    teleport(site.xyz + vec3(forward.y, -forward.x, 0.0) * 4.0, site.w)
    return truck
end

---A point behind the truck for a vehicle: its leading end `gap` m behind the ramp foot (or the
---rear bumper for the tow truck), `side` m to the right, turned by `angle`°.
---@return vector4
local function behind(truck, model, gap, side, angle)
    local min = GetModelDimensions(GetEntityModel(truck))
    local foot = Entity(truck).state['sw_tow:method'] == 'flatbed' and flatbed.rampFootY(truck) or min.y
    local vMin, vMax = GetModelDimensions(joaat(model))
    local half = (vMax.y - vMin.y) / 2
    local p = GetOffsetFromEntityInWorldCoords(truck, side or 0.0, foot - gap - half, 0.0)
    return vec4(p.x, p.y, p.z, GetEntityHeading(truck) + (angle or 0.0))
end

---How the vehicle stands on the truck: sideways offset and turn against the truck's axis.
local function onBed(truck, vehicle)
    local c = GetEntityCoords(vehicle)
    local offset = GetOffsetFromEntityGivenWorldCoords(truck, c.x, c.y, c.z)
    local turn = math.abs(wrap(GetEntityHeading(vehicle) - GetEntityHeading(truck)))
    return offset, math.min(turn, 180.0 - turn)
end

local function standsOnGround(vehicle)
    return not IsEntityAttached(vehicle) and GetEntityHeightAboveGround(vehicle) < 1.2
        and math.abs(GetEntityRoll(vehicle)) < 12.0 and math.abs(GetEntityPitch(vehicle)) < 12.0
end

---Into the yard's hand-over zone, with the cargo.
local function driveToYard(truck)
    sitIn(truck)
    moveVehicle(truck, YARD.zone.coords, GetEntityHeading(truck))
    getOut()
    Wait(1000) -- the server catches up with the move
end

---A failed hand-over with what the server knows of the cargo.
local function deliverFailure(truck, errorKey)
    return ('%s · server: %s'):format(why(errorKey), tostring(lib.callback.await('sw_tow:dev:cargo', false, VehToNet(truck))))
end

local function findPlate(plate, near, radius)
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if util.trimPlate(GetVehicleNumberPlateText(vehicle)) == plate
            and (not near or #(GetEntityCoords(vehicle) - near) < (radius or 10.0)) then
            return vehicle
        end
    end
end

local function counter()
    return (YARD.counter or config.office.coords) --[[@as vector4]]
end

local function expectedPay(pickup, factor)
    local p = config.payout
    local distance = #(pickup - YARD.zone.coords)
    return math.floor(math.min(p.max, math.floor(p.base + p.perKm * distance / 1000)) * (factor or 1.0))
end

local function feeFor(model, towCharge, fine)
    local class = GetVehicleClassFromName(joaat(model))
    return config.fees.base + (config.fees.byClass[class] or 0) + (towCharge or 0) + (fine or 0)
end

local function findCall(predicate)
    return waitFor(function()
        for _, call in ipairs(calls.list()) do
            if predicate(call) then return call end
        end
    end, 5000)
end

---Owned car behind a flatbed on the site, called in by you, accepted by you, loaded and brought
---into the yard. Used by the impound and police scenarios.
---@param withCall fun(car: integer, plate: string): table? creates the call and returns it
local function ownedCarToYard(withCall)
    local truck = truckOnSite(FLATBED)
    local car, vehicleId, plate = spawnOwned('sultan', behind(truck, 'sultan', 3.5))
    expect(car, 'an owned test car is spawned', plate)
    ---@cast car integer
    local call = expect(withCall(car, plate --[[@as string]]), 'the call shows in the call list')
    Wait(1100) -- calls and accepting share a 1 s limit
    local accepted, acceptError = calls.accept(call)
    expect(accepted, 'the call is accepted', why(acceptError))
    local pickup = GetEntityCoords(car)
    local loaded, loadError, value = tow.load(truck, car)
    expect(loaded, 'the car is winched onto the flatbed', why(loadError, value))
    return { truck = truck, car = car, vehicleId = vehicleId, plate = plate, call = call, pickup = pickup }
end

---Checks the largest sag of the winch cable seen during a pull (tow.measureSag).
local function cableTaut(what, seen)
    if not config.flatbed.rope then return end
    if not seen then return check(false, what, 'no cable was drawn') end
    check(seen < 0.5, what, ('sagged up to %.2f m'):format(seen))
end

---Waits for a truck state bag to read as wanted (the server's change arrives a moment later).
local function bagIs(entity, key, predicate, timeout)
    return waitFor(function() return predicate(Entity(entity).state[key]) end, timeout or 2000) == true
end

---Reads the panel until its title is the wanted text (it refreshes once a second).
local function panelTitle(key)
    local texts = waitFor(function()
        local t = panel.probe()
        return t and t.title == locale(key) and t or nil
    end, 2500)
    return texts ~= nil, texts or panel.probe()
end

local function garageState(vehicleId)
    return lib.callback.await('sw_tow:dev:garageState', false, vehicleId) or {}
end

-- Scenarios --------------------------------------------------------------------------------------

---@type { name: string, title: string, run: fun() }[]
local scenarios = {}
local function scenario(name, title, run)
    scenarios[#scenarios + 1] = { name = name, title = title, run = run }
end

scenario('points', 'Models and configured places', function()
    local models = { config.flatbed.ramp.model }
    for _, option in ipairs(config.garage.vehicles) do models[#models + 1] = option.model end
    for _, model in ipairs(config.contracts.models) do models[#models + 1] = model end
    if config.office.ped then models[#models + 1] = config.office.ped.model end
    local missing = {}
    for _, model in ipairs(models) do
        if not IsModelInCdimage(joaat(model)) then missing[#missing + 1] = model end
    end
    check(#missing == 0, ('all %d models exist'):format(#models), table.concat(missing, ', '))

    local function ground(name, point)
        teleport(point + vec3(0.0, 0.0, 1.0))
        local found, z = GetGroundZFor_3dCoord(point.x, point.y, point.z + 2.0, false)
        check(found and math.abs(z - point.z) < 1.5, name .. ' is on the ground', found and ('%.1f m off'):format(z - point.z) or 'no ground')
        return found
    end
    ground('office counter', config.office.coords.xyz)
    if config.office.ped then
        local clerk = waitFor(function()
            for _, ped in ipairs(GetGamePool('CPed')) do
                if GetEntityModel(ped) == joaat(config.office.ped.model)
                    and #(GetEntityCoords(ped) - (config.office.ped.coords or config.office.coords).xyz) < 3.0 then
                    return ped
                end
            end
        end, 3000)
        check(clerk, 'the clerk stands at the counter')
    end
    ground('truck spawn', config.garage.spawn.xyz)
    for key, yard in pairs(config.yards) do
        ground(('yard %s hand-over zone'):format(key), yard.zone.coords)
        for i, spot in ipairs(yard.releaseSpots) do
            ground(('yard %s release spot %d'):format(key, i), spot.xyz)
            if #(spot.xyz - config.garage.spawn.xyz) < 4.0 then
                record('WARN', ('yard %s release spot %d is the truck spawn: a truck left there blocks releases (add a spot of its own)'):format(key, i))
            end
        end
    end
end)

scenario('shift', 'Clock in, panel, trucks, clock out', function()
    expect(lib.callback.await('sw_tow:dev:prepare', false), 'the tow job and test money are given')
    Wait(1000)
    if shift.onShift() then
        lib.callback.await('sw_tow:dev:stopShift', false)
        waitFor(function() return not shift.onShift() end, 2000)
    end
    teleport(config.office.coords.xyz + vec3(25.0, 0.0, 0.0))
    check(not shift.clockIn(), 'clocking in away from the counter is refused')
    teleport(config.office.coords.xyz, config.office.coords.w)
    Wait(1100)
    local ok, errorKey = shift.clockIn()
    expect(ok, 'clocking in at the counter works', why(errorKey))
    expect(waitFor(shift.onShift, 2000), 'the shift state reaches this client')

    local texts = waitFor(function()
        local t = panel.probe()
        return t and t.visible and t or nil
    end, 3000)
    if config.ui.enabled then
        check(texts, 'the shift panel is visible')
        if texts then check(texts.title == locale('panel.title_idle'), 'the panel title says on shift', texts.title) end
    end

    ok, errorKey = shift.takeTruck(FLATBED)
    expect(ok, 'a flatbed is taken out', why(errorKey))
    local truck = expect(waitFor(shift.truck, 5000), 'the flatbed exists')
    local plate = util.trimPlate(GetVehicleNumberPlateText(truck))
    check(plate:sub(1, #config.garage.platePrefix) == config.garage.platePrefix, 'its plate has the company prefix', plate)
    check(bagIs(truck, 'sw_tow:method', function(v) return v == 'flatbed' end), 'it is marked as a flatbed')
    Wait(5100)
    check(select(2, shift.takeTruck(FLATBED)) == 'garage.already_out', 'a second truck is refused')
    texts = panel.probe()
    if texts then check(texts.truck:find(plate, 1, true), 'the panel shows the truck', texts.truck) end

    moveVehicle(truck, config.garage.spawn.xyz + vec3(60.0, 0.0, 0.0), config.garage.spawn.w)
    check(select(2, shift.returnTruck()) == 'garage.too_far', 'returning it far from the garage is refused')
    moveVehicle(truck, config.garage.spawn.xyz, config.garage.spawn.w)
    check(shift.returnTruck(), 'returning it at the garage works')
    check(waitFor(function() return not DoesEntityExist(truck) end, 3000), 'the returned truck is gone')

    teleport(config.office.coords.xyz, config.office.coords.w)
    check(shift.clockOut(), 'clocking out works')
    check(waitFor(function() return not shift.onShift() end, 2000), 'the shift has ended')
    if config.ui.enabled then
        texts = panel.probe()
        check(texts and not texts.visible, 'the panel is hidden off shift')
    end
    Wait(1100)
    expect(shift.clockIn(), 'clocking in again for the next scenarios')
end)

scenario('flatbed', 'Flatbed: ramps, winch and unloading in different positions', function()
    local truck = truckOnSite(FLATBED)
    local level, levelError = flatbed.level(truck)
    expect(level, 'the test site is flat enough for the ramps (stand on level open ground)', why(levelError))

    local cases = {
        { model = 'asea', side = 0.0, angle = 0.0, label = 'sedan straight behind' },
        { model = 'baller', side = 0.0, angle = 0.0, label = 'SUV straight behind' },
        { model = 'zentorno', side = 0.0, angle = 0.0, label = 'low sports car' },
        { model = 'asea', side = 1.0, angle = 0.0, label = 'sedan 1 m to the side' },
        { model = 'asea', side = -0.8, angle = 10.0, label = 'sedan turned 10°' },
        { model = 'asea', side = 0.3, angle = 180.0, label = 'sedan rear first' },
    }
    local restZ -- how high a winched sedan sits on the bed, for setting one down there below
    for _, case in ipairs(cases) do
        local car = spawnVehicle(case.model, behind(truck, case.model, 3.5, case.side, case.angle))
        if check(car, case.label .. ': test vehicle spawned') then
            ---@cast car integer
            local sags = tow.measureSag()
            sags[truck] = nil
            local started = GetGameTimer()
            local ok, errorKey, value = tow.load(truck, car)
            local seconds = (GetGameTimer() - started) / 1000
            if check(ok, ('%s: loaded in %.1f s'):format(case.label, seconds), why(errorKey, value)) then
                cableTaut(case.label .. ': the cable stays taut while loading', sags[truck])
                local offset, turn = onBed(truck, car)
                if case.model == 'asea' then restZ = restZ or offset.z end
                check(IsEntityAttachedToEntity(car, truck), case.label .. ': strapped to the truck')
                check(math.abs(offset.x) < 0.25 and turn < 4.0, case.label .. ': straight in the middle of the bed',
                    ('x %+.2f m, turned %.1f°'):format(offset.x, turn))
                check(offset.z > 0.3, case.label .. ': up on the bed', ('z %+.2f m'):format(offset.z))
                check(bagIs(truck, 'sw_tow:winch', function(v) return type(v) == 'table' and v.phase == 'secured' end),
                    case.label .. ': the server counts it as secured')
                sags[truck] = nil
                ok, errorKey = tow.unload(truck)
                check(ok, case.label .. ': unloaded', why(errorKey))
                cableTaut(case.label .. ': the cable stays taut while unloading', sags[truck])
                Wait(500)
                check(standsOnGround(car), case.label .. ': stands on its wheels behind the truck',
                    ('height %.2f m, roll %.0f°'):format(GetEntityHeightAboveGround(car), GetEntityRoll(car)))
                check(bagIs(truck, 'sw_tow:cargo', function(v) return v == nil end), case.label .. ': the truck is empty again')
            end
            remove(car)
        end
    end

    local far = spawnVehicle('asea', behind(truck, 'asea', config.flatbed.winchRange + 4.0))
    if far then
        local ok, errorKey = tow.load(truck, far)
        check(not ok and errorKey == 'tow.too_far', 'out of winch range: refused with how far to move', why(errorKey))
        remove(far)
    end

    local car = spawnVehicle('asea', behind(truck, 'asea', 7.0))
    local blocker = spawnVehicle('asea', behind(truck, 'asea', 2.5, 0.0, 90.0))
    if car and blocker then
        local ok, errorKey = tow.load(truck, car)
        check(not ok and errorKey == 'tow.path_blocked', 'something in the way: refused before pulling', why(errorKey))
        check(not IsEntityAttached(car) and bagIs(truck, 'sw_tow:cargo', function(v) return v == nil end),
            'nothing is left half-loaded')
    end
    remove(car)
    remove(blocker)
    if flatbed.rampsDown(truck) then tow.toggleRamps(truck) end

    -- The owner drives up the ramps; the worker straps it where it stands.
    Wait(1600) -- lowering is rate limited
    check(tow.toggleRamps(truck) and flatbed.rampsDown(truck), 'ramps go down by hand')
    local min = GetModelDimensions(GetEntityModel(truck))
    local driven = spawnVehicle('asea', behind(truck, 'asea', 3.0))
    if driven and control(driven) then
        -- As if driven up the ramps: set down on the middle of the bed, a little above the height the
        -- same model sat at when winched on, then settled.
        local y = (min.y + config.flatbed.bedFrontY) / 2
        local onTop = GetOffsetFromEntityInWorldCoords(truck, 0.0, y, (restZ or 1.4) + 0.15)
        SetEntityCoords(driven, onTop.x, onTop.y, onTop.z, false, false, false, false)
        SetEntityHeading(driven, GetEntityHeading(truck))
        SetEntityVelocity(driven, 0.0, 0.0, 0.0)
        -- Where it goes, for the failure message: truck space right after, at 0.25 s, 1 s and at rest.
        local function at()
            local c = GetEntityCoords(driven)
            local p = GetOffsetFromEntityGivenWorldCoords(truck, c.x, c.y, c.z)
            return ('(%+.2f %+.2f %+.2f)'):format(p.x, p.y, p.z)
        end
        local path = { ('set at z %+.2f, owner %s'):format((restZ or 1.4) + 0.15,
            NetworkHasControlOfEntity(driven) and 'me' or 'other'), at() }
        Wait(250)
        path[#path + 1] = at()
        Wait(750)
        path[#path + 1] = at()
        waitFor(function() return GetEntitySpeed(driven) < 0.05 end, 4000)
        path[#path + 1] = at()
        check(flatbed.isOnBed(truck, driven), 'a car standing on the bed is recognised', table.concat(path, ' → '))
        local ok, errorKey = tow.secureInPlace(truck, driven)
        check(ok and IsEntityAttachedToEntity(driven, truck), 'it is strapped where it stands', why(errorKey))
        check(not flatbed.rampsDown(truck), 'the ramps go up after strapping')
        ok, errorKey = tow.unload(truck)
        check(ok, 'and it unloads', why(errorKey))
        remove(driven)
    end
end)

scenario('hook', 'Tow truck: hook and unhook', function()
    local truck = truckOnSite(HOOK)
    local car = expect(spawnVehicle('asea', behind(truck, 'asea', 1.0)), 'a test vehicle behind the tow arm')
    local ok, errorKey = tow.load(truck, car)
    check(ok, 'hooked to the tow arm', why(errorKey))
    check(IsVehicleAttachedToTowTruck(truck, car), 'the game holds it on the arm')
    check(bagIs(truck, 'sw_tow:cargo', function(v) return v ~= nil end), 'the server counts it as cargo')
    ok, errorKey = tow.unload(truck)
    check(ok, 'unhooked', why(errorKey))
    Wait(1000)
    check(not IsVehicleAttachedToTowTruck(truck, car), 'it is off the arm')
    check(bagIs(truck, 'sw_tow:cargo', function(v) return v == nil end), 'the truck is empty again')
    remove(car)

    local police = spawnVehicle('police', behind(truck, 'police', 1.0))
    if police then
        ok, errorKey = tow.load(truck, police)
        check(not ok and errorKey == 'tow.needs_order', 'an empty police car needs a police order', why(errorKey))
        remove(police)
    end
end)

scenario('impound', 'Player call: tow, pay, impound and release at the counter', function()
    -- Abuse first: an NPC car cannot be called in.
    local right = vec3(math.cos(math.rad(site.w)), math.sin(math.rad(site.w)), 0.0)
    local npc = spawnVehicle('asea', vec4(site.x + right.x * 5.0, site.y + right.y * 5.0, site.z, site.w))
    if npc then
        sitIn(npc)
        getOut()
        local since = #notices
        ExecuteCommand(config.calls.command .. ' swtow_test')
        check(waitFor(function() return noticed('calls.not_owner', since) end, 3000), 'a call for a car you do not own is refused')
        remove(npc)
        Wait(1100)
    end

    local t = ownedCarToYard(function(car, plate)
        sitIn(car)
        getOut()
        ExecuteCommand(config.calls.command .. ' swtow_test')
        return findCall(function(call) return call.plate == plate and call.type == 'player' end)
    end)

    if config.ui.enabled then
        local shown, texts = panelTitle('panel.title_player')
        check(shown, 'the panel shows the call', texts and texts.title)
        check(texts and texts.cargo == t.plate, 'the panel shows the cargo', texts and texts.cargo)
        check(texts and texts.timer ~= nil, 'the panel shows the delivery timer')
    end

    local since = #notices
    ExecuteCommand(config.calls.cancelCommand)
    check(waitFor(function() return noticed('calls.cancel_loaded', since) end, 3000), 'the owner cannot cancel once it is loaded')

    driveToYard(t.truck)
    local ok, errorKey = tow.deliver(t.truck)
    check(not ok and errorKey == 'impound.too_fast', 'an instant trip to the yard is refused as too fast', why(errorKey))
    lib.callback.await('sw_tow:dev:ageCargo', false, VehToNet(t.truck), 3600)
    Wait(600) -- hand-overs are rate limited

    local before = money()
    ok, errorKey = tow.deliver(t.truck)
    expect(ok, 'handed over at the yard', not ok and deliverFailure(t.truck, errorKey) or nil)
    local pay = expectedPay(t.pickup)
    local paid = money() - before
    check(math.abs(paid - pay) <= 2, ('paid %s for the tow'):format(util.money(paid)), ('expected about %s'):format(util.money(pay)))
    check(waitFor(function() return not DoesEntityExist(t.car) end, 3000), 'the car is off the street')
    check(waitFor(function() return calls.active() == nil end, 3000), 'the call is closed')
    local state = garageState(t.vehicleId)
    check(state.state == 2, 'the garage script lists it as impounded', state.state)
    check(lib.callback.await('sw_tow:dev:isHeld', false, t.vehicleId) == YARD.label, 'the public impound lot will not hand it out')

    teleport(counter().xyz, counter().w)
    local item
    for _, entry in ipairs(impound.list(YARD_KEY)) do
        if entry.plate == t.plate then item = entry end
    end
    expect(item, 'the car is listed at the counter')
    local fee = feeFor('sultan', paid)
    check(math.abs(item.fee - fee) <= 2, ('the fee is %s: base + class + the tow'):format(util.money(item.fee)), ('expected %s'):format(util.money(fee)))
    check(not item.held, 'it is not on hold')

    lib.callback.await('sw_tow:dev:ageImpound', false, t.plate, 27)
    local later
    for _, entry in ipairs(impound.list(YARD_KEY)) do
        if entry.plate == t.plate then later = entry end
    end
    check(later and later.fee == item.fee + 2 * config.fees.perDay, 'after 27 hours two storage days are added', later and util.money(later.fee))

    before = money()
    local releasedOk, releaseError = impound.release(item.id)
    expect(releasedOk, 'released at the counter', why(releaseError))
    check(before - money() == later.fee, ('%s charged'):format(util.money(before - money())))
    local released = waitFor(function() return findPlate(t.plate, YARD.releaseSpots[1].xyz, 8.0) end, 5000)
    check(released, 'the car stands on the release spot')
    state = garageState(t.vehicleId)
    check(state.state == 0, 'the garage script lists it as out again', state.state)
    check(lib.callback.await('sw_tow:dev:isHeld', false, t.vehicleId) == false, 'no longer held')
    if released then remove(released) end
end)

scenario('police', 'Police hold: blocked release, lifted hold, fine on the bill', function()
    local fine = 500
    local t = ownedCarToYard(function(car, plate)
        expect(lib.callback.await('sw_tow:dev:policeOrder', false, VehToNet(car), fine, true, 0), 'a police order with a hold is placed')
        return findCall(function(call) return call.plate == plate and call.type == 'police' end)
    end)
    driveToYard(t.truck)
    lib.callback.await('sw_tow:dev:ageCargo', false, VehToNet(t.truck), 3600)
    local before = money()
    local ok, errorKey = tow.deliver(t.truck)
    expect(ok, 'handed over at the yard', not ok and deliverFailure(t.truck, errorKey) or nil)
    local paid = money() - before

    teleport(counter().xyz, counter().w)
    local item
    for _, entry in ipairs(impound.list(YARD_KEY)) do
        if entry.plate == t.plate then item = entry end
    end
    expect(item, 'the car is listed at the counter')
    check(item.held, 'it is shown as on police hold')
    local releasedOk, releaseError = impound.release(item.id)
    check(not releasedOk and releaseError == 'impound.police_hold', 'release is refused while on hold', why(releaseError))
    expect(lib.callback.await('sw_tow:dev:liftHold', false, t.plate), 'the hold is lifted')
    for _, entry in ipairs(impound.list(YARD_KEY)) do
        if entry.plate == t.plate then item = entry end
    end
    check(not item.held, 'it is no longer on hold')
    local fee = feeFor('sultan', paid, fine)
    check(math.abs(item.fee - fee) <= 2, ('the fee includes the %s fine'):format(util.money(fine)), ('%s, expected %s'):format(util.money(item.fee), util.money(fee)))
    Wait(600)
    releasedOk, releaseError = impound.release(item.id)
    check(releasedOk, 'released after the hold', why(releaseError))
    local released = waitFor(function() return findPlate(t.plate, YARD.releaseSpots[1].xyz, 8.0) end, 5000)
    if released then remove(released) end
end)

scenario('contract', 'NPC contract: appears near the spot, looks broken, goes away when dropped', function()
    if not config.contracts.enabled then return record('SKIP', 'contracts are off in config.lua') end
    local id, spot = lib.callback.await('sw_tow:dev:contract', false)
    expect(id, 'a contract is created', spot)
    local call = expect(findCall(function(c) return c.id == id end), 'it shows in the call list')
    expect(calls.accept(call), 'it is accepted')
    if config.ui.enabled then
        local shown, texts = panelTitle('panel.title_contract')
        check(shown, 'the panel shows the contract', texts and texts.title)
    end
    local spotVec = vec3(spot.x, spot.y, spot.z)
    teleport(spotVec + vec3(0.0, 0.0, 30.0))
    teleport(spotVec + vec3(8.0, 8.0, 1.0))
    local vehicle = waitFor(function()
        for _, v in ipairs(GetGamePool('CVehicle')) do
            if Entity(v).state['sw_tow:contract'] == id then return v end
        end
    end, 10000)
    expect(vehicle, 'the broken-down vehicle appears when you get close')
    ---@cast vehicle integer
    Wait(2000)
    check(GetVehicleEngineHealth(vehicle) < 400.0, 'its engine is damaged', ('%.0f'):format(GetVehicleEngineHealth(vehicle)))
    check(GetVehicleDoorLockStatus(vehicle) == 2, 'its doors are locked')
    check(GetVehicleDoorAngleRatio(vehicle, 4) > 0.1, 'its bonnet is open')
    check(calls.drop(id), 'the contract is dropped')
    Wait(500)
    check(DoesEntityExist(vehicle) and findCall(function(c) return c.id == id and not c.mine end),
        'a dropped contract stays open for others, with its vehicle')
    expect(lib.callback.await('sw_tow:dev:closeCall', false, id), 'the contract is closed')
    check(waitFor(function() return not DoesEntityExist(vehicle) end, 5000), 'a closed contract takes its vehicle away')
end)

scenario('abandoned', 'Abandoned vehicle: becomes a call, closes when driven away', function()
    if not config.abandoned.enabled then return record('SKIP', 'abandoned vehicles are off in config.lua') end
    local forward = vec3(-math.sin(math.rad(site.w)), math.cos(math.rad(site.w)), 0.0)
    local at = site.xyz + forward * 6.0
    teleport(site.xyz, site.w) -- the server can only create a vehicle near a player
    local car = expect(spawnVehicle('asea', vec4(at.x, at.y, at.z, site.w)), 'a test vehicle is left behind')
    teleport(site.xyz - forward * (config.abandoned.playerRadius + 20.0))
    check(lib.callback.await('sw_tow:dev:abandon', false, VehToNet(car)), 'it becomes a call when nobody is near')
    local plate = util.trimPlate(GetVehicleNumberPlateText(car))
    check(findCall(function(call) return call.type == 'abandoned' and call.plate == plate end), 'the call shows in the list')
    teleport(at + vec3(2.5, 0.0, 0.0))
    sitIn(car)
    check(GetVehiclePedIsIn(cache.ped, false) == car, 'you sit at the wheel')
    local seen
    check(waitFor(function()
        Wait(400)
        seen = select(2, lib.callback.await('sw_tow:dev:sweepCalls', false, VehToNet(car)))
        return not lib.callback.await('sw_tow:dev:hasCall', false, VehToNet(car))
    end, 6000), 'the call closes when a player drives it away', seen)
    getOut()
    remove(car)
end)

-- Runner -----------------------------------------------------------------------------------------

local running = false

---Leaves no cargo, lowered ramps or accepted call behind for the next scenario.
local function tidy()
    getOut()
    local truck = shift.truck()
    if truck and Entity(truck).state['sw_tow:cargo'] then
        lib.callback.await('sw_tow:server:detach', false, VehToNet(truck))
    end
    if truck and flatbed.rampsDown(truck) then
        Wait(200)
        lib.callback.await('sw_tow:server:ramps', false, VehToNet(truck), false)
    end
    local active = calls.active()
    if active then calls.drop(active.id) end
end

---@param list { name: string, title: string, run: fun() }[]
local function run(list)
    if running then return notify('Tests are already running.', 'warning') end
    local allowed, reason = lib.callback.await('sw_tow:dev:money', false)
    if not allowed then return notify('swtow_test: ' .. tostring(reason), 'error') end
    running = true
    lines, counts = {}, { PASS = 0, WARN = 0, FAIL = 0, SKIP = 0 }
    local c, h = GetEntityCoords(cache.ped), GetEntityHeading(cache.ped)
    site = vec4(c.x, c.y, c.z, h)
    local started = GetGameTimer()

    if not shift.onShift() and list[1].name ~= 'shift' and list[1].name ~= 'points' then
        lib.callback.await('sw_tow:dev:prepare', false)
        Wait(1000)
        teleport(config.office.coords.xyz, config.office.coords.w)
        shift.clockIn()
        waitFor(shift.onShift, 2000)
    end

    for i, s in ipairs(list) do
        current = s.name
        lib.showTextUI(('sw_tow test %d/%d · %s'):format(i, #list, s.title), { position = 'top-center' })
        local ok, err = xpcall(s.run, function(e)
            if e == ABORT then return e end
            return debug.traceback(tostring(e), 2)
        end)
        if not ok and err ~= ABORT then record('FAIL', 'error in the scenario: ' .. tostring(err)) end
        tidy()
        if (s.name == 'shift' or s.name == 'points') and not shift.onShift() then
            lib.callback.await('sw_tow:dev:prepare', false)
            teleport(config.office.coords.xyz, config.office.coords.w)
            Wait(1100)
            shift.clockIn()
        end
    end

    current = 'cleanup'
    local cleaned = lib.callback.await('sw_tow:dev:cleanup', false) or {}
    lib.callback.await('sw_tow:dev:stopShift', false)
    teleport(site.xyz, site.w)
    lib.hideTextUI()

    local summary = ('sw_tow in-game tests: %d PASS · %d WARN · %d FAIL · %d SKIP · %.0f s · removed %s test vehicles, %s records'):format(
        counts.PASS, counts.WARN, counts.FAIL, counts.SKIP, (GetGameTimer() - started) / 1000, cleaned.vehicles or 0, cleaned.records or 0)
    table.insert(lines, 1, summary)
    print('[sw_tow test] ' .. summary)
    lib.callback.await('sw_tow:dev:report', false, lines)
    notify(summary, counts.FAIL == 0 and 'success' or 'error')
    running = false
end

local function byName(name)
    for _, s in ipairs(scenarios) do
        if s.name == name then return s end
    end
end

RegisterCommand('swtow_test', function(_, args)
    local name = args[1]
    if name == 'all' then
        CreateThread(function() run(scenarios) end)
        return
    end
    if name then
        local s = byName(name)
        if not s then
            notify('Unknown scenario: ' .. name, 'error')
            return
        end
        CreateThread(function() run({ s }) end)
        return
    end
    local options = { {
        title = 'All scenarios',
        description = 'About 5 minutes. Stand on flat open ground first.',
        icon = 'list-check',
        onSelect = function() CreateThread(function() run(scenarios) end) end,
    } }
    for _, s in ipairs(scenarios) do
        options[#options + 1] = {
            title = s.name,
            description = s.title,
            icon = 'vial',
            onSelect = function() CreateThread(function() run({ s }) end) end,
        }
    end
    lib.registerContext({ id = 'sw_tow_tests', title = 'sw_tow tests', options = options })
    lib.showContext('sw_tow_tests')
end, false)
