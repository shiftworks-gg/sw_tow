local test = require 'test'
local flow = require 'flow'
local World = require 'world'
local vector = require 'vector'

test.suite('server › abandoned vehicles')

local SPOT = World.FAR

---A player drives a vehicle to SPOT, gets out and walks away.
local function leftBehind(w, model, owned)
    local driver = w:addPlayer({ coords = SPOT })
    local vehicle
    if owned then
        vehicle = w:ownedVehicle(driver, { coords = SPOT, model = model })
    else
        vehicle = w:createVehicle({ model = model or 'asea', coords = SPOT })
    end
    w:enterVehicle(driver, vehicle)
    w:advance(31) -- one scan sees a player at the wheel
    w:leaveVehicle(driver)
    w:teleport(driver, SPOT + vector.vec3(500, 0, 0))
    return vehicle, driver
end

local function abandonedCalls(w, src)
    local list = {}
    for _, call in ipairs(flow.calls(w, src)) do
        if call.type == 'abandoned' then list[#list + 1] = call end
    end
    return list
end

test.case('a vehicle left alone for 30 minutes becomes a call', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local vehicle = leftBehind(w)
    w:advance(28 * 60)
    test.eq(#abandonedCalls(w, worker), 0, 'not yet after 28 minutes')
    w:advance(3 * 60)
    local list = abandonedCalls(w, worker)
    test.eq(#list, 1, 'a call after 31 minutes')
    test.eq(list[1].plate, w:entity(vehicle).plate)
    w:assertNoErrors()
end)

test.case('a player nearby keeps the timer from running', function()
    local w = newWorld()
    local worker = flow.worker(w)
    leftBehind(w)
    local guard = w:addPlayer({ coords = SPOT + vector.vec3(20, 0, 0) })
    w:advance(40 * 60)
    test.eq(#abandonedCalls(w, worker), 0)
    w:teleport(guard, SPOT + vector.vec3(900, 0, 0))
    w:advance(31 * 60)
    test.eq(#abandonedCalls(w, worker), 1)
end)

test.case('owned vehicles, emergency vehicles and parked traffic are left alone', function()
    local w = newWorld()
    local worker = flow.worker(w)
    leftBehind(w, 'sultan', true)
    w:advance(1)
    leftBehind(w, 'police')
    w:createVehicle({ model = 'asea', coords = SPOT + vector.vec3(0, 40, 0) }) -- never driven by a player
    w:advance(40 * 60)
    test.eq(#abandonedCalls(w, worker), 0)
end)

test.case('calls wait for someone on shift; the time already counts', function()
    local w = newWorld()
    leftBehind(w)
    w:advance(40 * 60)
    test.eq(w:module('server.calls').count(), 0, 'nobody on shift')
    local worker = flow.worker(w)
    w:advance(31)
    test.eq(#abandonedCalls(w, worker), 1)
end)

test.case('an abandoned vehicle pays 60% of a normal delivery', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local vehicle = leftBehind(w)
    w:advance(31 * 60)
    local call = abandonedCalls(w, worker)[1]
    test.accepted(w:call('sw_tow:server:acceptCall', worker, call.id))
    local truck = flow.truck(w, worker, 1)
    flow.drive(w, worker, truck, SPOT + vector.vec3(0, 12, 0))
    test.accepted(flow.load(w, worker, truck, vehicle))
    w:advance(60)
    flow.drive(w, worker, truck, World.YARD)
    local bank = w:money(worker, 'bank')
    test.accepted(flow.deliver(w, worker, truck))
    test.eq(w:money(worker, 'bank') - bank, math.floor(201 * 0.6))
end)

test.case('no more than 4 open abandoned-vehicle calls', function()
    local w = newWorld()
    local worker = flow.worker(w)
    for i = 1, 6 do
        local v = leftBehind(w)
        w:move(v, SPOT + vector.vec3(i * 10, 0, 0))
    end
    w:advance(40 * 60)
    test.eq(#abandonedCalls(w, worker), 4)
end)

test.case('an abandoned-vehicle call closes when a player drives the vehicle away', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local vehicle, driver = leftBehind(w)
    w:advance(31 * 60)
    test.eq(#abandonedCalls(w, worker), 1)
    w:enterVehicle(driver, vehicle)
    w:advance(31)
    test.eq(#abandonedCalls(w, worker), 0)
end)
