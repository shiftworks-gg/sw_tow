local test = require 'test'
local flow = require 'flow'
local World = require 'world'
local vector = require 'vector'

test.suite('server › NPC contracts')

local function contracts(w, src)
    local list = {}
    for _, call in ipairs(flow.calls(w, src)) do
        if call.type == 'contract' then list[#list + 1] = call end
    end
    return list
end

local function vehicleWithContract(w, id)
    for entity in pairs(w.entities) do
        if w.env.Entity(entity).state['sw_tow:contract'] == id then return entity end
    end
end

test.case('no contracts while nobody is on shift', function()
    local w = newWorld()
    w:advance(600)
    test.eq(w:module('server.calls').count(), 0)
end)

test.case('contracts appear for workers on shift, at most workers + 1 (and the config cap)', function()
    local w = newWorld()
    local worker = flow.worker(w)
    w:advance(91)
    test.eq(#contracts(w, worker), 1, 'one after the first interval')
    w:advance(10 * 91)
    test.eq(#contracts(w, worker), 2, 'one worker: at most two')
    for _ = 1, 3 do flow.worker(w) end
    w:advance(10 * 91)
    test.eq(#contracts(w, worker), 3, 'config maxOpen = 3')
    for _, call in ipairs(contracts(w, worker)) do
        local d = #(vector.vec3(call.coords.x, call.coords.y, call.coords.z) - World.OFFICE)
        test.truthy(d >= 400 and d <= 3500, ('spot %.0f m away'):format(d))
    end
    w:assertNoErrors()
end)

test.case('the vehicle appears only when the worker comes close, locked and marked broken', function()
    local w = newWorld()
    local worker = flow.worker(w)
    w:advance(91)
    local call = contracts(w, worker)[1]
    test.accepted(w:call('sw_tow:server:acceptCall', worker, call.id))
    w:advance(5)
    test.eq(vehicleWithContract(w, call.id), nil, 'nothing spawned far away')

    local spot = vector.vec3(call.coords.x, call.coords.y, call.coords.z)
    w:teleport(worker, spot + vector.vec3(100, 0, 0))
    w:advance(2)
    local vehicle = vehicleWithContract(w, call.id)
    test.truthy(vehicle, 'spawned when the worker is 100 m away')
    test.eq(w:entity(vehicle).plate, call.plate)
    test.eq(w:entity(vehicle).locked, 2, 'doors locked')
    test.near(#(w:entity(vehicle).coords - spot), 0, 0.01, 'at the spot')
    w:assertNoErrors()
end)

test.case('a delivered contract pays like a call; the spot becomes free', function()
    local w = newWorld()
    local worker = flow.worker(w)
    w:advance(91)
    local call = contracts(w, worker)[1]
    test.accepted(w:call('sw_tow:server:acceptCall', worker, call.id))
    local spot = vector.vec3(call.coords.x, call.coords.y, call.coords.z)
    local truck = flow.truck(w, worker, 1)
    flow.drive(w, worker, truck, spot + vector.vec3(0, 12, 0))
    w:advance(2)
    local vehicle = vehicleWithContract(w, call.id)
    test.accepted(flow.load(w, worker, truck, vehicle))
    w:advance(200)
    flow.drive(w, worker, truck, World.YARD)
    local bank = w:money(worker, 'bank')
    test.accepted(flow.deliver(w, worker, truck))
    test.truthy(w:money(worker, 'bank') > bank, 'paid')
    test.falsy(w:exists(vehicle))
    test.eq(flow.onlyRecord(w), nil, 'NPC vehicles leave no impound record')
    w:assertNoErrors()
end)

test.case('a dropped or expired contract removes its vehicle unless it is on a truck', function()
    local w = newWorld()
    local worker = flow.worker(w)
    w:advance(91)
    local call = contracts(w, worker)[1]
    test.accepted(w:call('sw_tow:server:acceptCall', worker, call.id))
    local spot = vector.vec3(call.coords.x, call.coords.y, call.coords.z)
    w:teleport(worker, spot)
    w:advance(2)
    local vehicle = vehicleWithContract(w, call.id)
    test.truthy(vehicle)
    w:advance(31 * 60)
    test.falsy(w:exists(vehicle), 'removed with the expired call')
    w:assertNoErrors()
end)

test.case('a blocked spot waits until it is clear', function()
    local w = newWorld()
    local worker = flow.worker(w)
    w:advance(91)
    local call = contracts(w, worker)[1]
    local spot = vector.vec3(call.coords.x, call.coords.y, call.coords.z)
    local blocker = w:createVehicle({ model = 'asea', coords = spot + vector.vec3(1, 0, 0) })
    test.accepted(w:call('sw_tow:server:acceptCall', worker, call.id))
    w:teleport(worker, spot + vector.vec3(50, 0, 0))
    w:advance(3)
    test.eq(vehicleWithContract(w, call.id), nil, 'not spawned onto another vehicle')
    w:removeEntity(blocker)
    w:advance(2)
    test.truthy(vehicleWithContract(w, call.id), 'spawned once clear')
end)
