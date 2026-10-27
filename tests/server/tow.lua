local test = require 'test'
local flow = require 'flow'
local World = require 'world'
local vector = require 'vector'

test.suite('server › loading vehicles')

local function setup(truckIndex)
    local w = newWorld()
    local src = flow.worker(w)
    local truck = flow.truck(w, src, truckIndex or 1)
    flow.drive(w, src, truck, World.FAR)
    return w, src, truck
end

local function attach(w, src, truck, target)
    w:advance(1) -- past the per-action rate limit
    return w:call('sw_tow:server:attach', src, w:entity(truck).net, w:entity(target).net)
end

test.case('flatbed: winch, secure, and the state bags every client draws from', function()
    local w, src, truck = setup(1)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR + vector.vec3(0, -10, 0) })
    w:teleport(src, World.FAR + vector.vec3(2, -8, 0))
    test.accepted(attach(w, src, truck, car))
    local truckState = w.env.Entity(truck).state
    test.eq(truckState['sw_tow:cargo'], w:entity(car).net, 'cargo bag')
    test.eq(truckState['sw_tow:winch'].phase, 'pulling', 'winch pulling')
    test.eq(w.env.Entity(car).state['sw_tow:towedBy'], w:entity(truck).net, 'towedBy bag')

    test.refused(w:call('sw_tow:server:secured', src, w:entity(truck).net)) -- still 10 m behind
    w:move(car, World.FAR + vector.vec3(0, -1, 0.5))
    test.accepted(w:call('sw_tow:server:secured', src, w:entity(truck).net))
    test.eq(truckState['sw_tow:winch'].phase, 'secured')
    test.truthy(w:module('server.tow').get(truck).secured)
    w:assertNoErrors()
end)

test.case('tow truck: the hook holds it at once', function()
    local w, src, truck = setup(2)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR })
    test.accepted(flow.load(w, src, truck, car))
    test.truthy(w:module('server.tow').get(truck).secured)
    test.eq(w.env.Entity(truck).state['sw_tow:winch'], nil, 'no winch on a tow truck')
end)

test.case('only your own company truck, and only when you stand near it', function()
    local w, src, truck = setup(1)
    local other = flow.worker(w)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR + vector.vec3(0, -10, 0) })
    w:teleport(other, World.FAR + vector.vec3(2, -8, 0))
    test.refused(attach(w, other, truck, car))
    w:teleport(src, World.FAR + vector.vec3(200, 0, 0))
    test.refused(attach(w, src, truck, car))
end)

test.case('refused: occupied, boats and aircraft, company trucks, the truck itself, too far', function()
    local w, src, truck = setup(1)
    w:teleport(src, World.FAR + vector.vec3(2, -8, 0))
    local pos = World.FAR + vector.vec3(0, -10, 0)

    local occupied = w:createVehicle({ model = 'asea', coords = pos })
    local passenger = w:addPlayer({ coords = pos })
    w:enterVehicle(passenger, occupied, 0)
    test.refusedWith('tow.occupied', attach(w, src, truck, occupied))
    w:removeEntity(occupied)

    local boat = w:createVehicle({ model = 'dinghy', coords = pos })
    test.refusedWith('tow.not_towable', attach(w, src, truck, boat))
    w:removeEntity(boat)

    local otherWorker = flow.worker(w)
    w:advance(6)
    local otherTruck = flow.truck(w, otherWorker, 2)
    w:move(otherTruck, pos)
    w:teleport(src, World.FAR + vector.vec3(2, -8, 0))
    test.refusedWith('tow.not_towable', attach(w, src, truck, otherTruck))

    test.refused(attach(w, src, truck, truck))

    local far = w:createVehicle({ model = 'asea', coords = World.FAR + vector.vec3(0, -60, 0) })
    test.refused(attach(w, src, truck, far))
    w:assertNoErrors()
end)

test.case('emergency vehicles need an accepted order', function()
    local w, src, truck = setup(1)
    local police = w:createVehicle({ model = 'police', coords = World.FAR + vector.vec3(0, -10, 0) })
    w:teleport(src, World.FAR + vector.vec3(2, -8, 0))
    test.refusedWith('tow.needs_order', attach(w, src, truck, police))

    w:module('server.calls').add({ type = 'police', plate = 'POL', vehicle = police, coords = World.FAR, message = '' })
    local id = flow.callId(w, src, 'police')
    test.accepted(w:call('sw_tow:server:acceptCall', src, id))
    w:advance(1)
    test.accepted(attach(w, src, truck, police))
end)

test.case('one vehicle at a time', function()
    local w, src, truck = setup(1)
    local a = w:createVehicle({ model = 'asea', coords = World.FAR })
    local b = w:createVehicle({ model = 'asea', coords = World.FAR + vector.vec3(0, -12, 0) })
    test.accepted(flow.load(w, src, truck, a))
    w:advance(1)
    w:teleport(src, World.FAR + vector.vec3(2, -10, 0))
    test.refusedWith('tow.already_loaded', attach(w, src, truck, b))
end)

test.case('unloading: lowering un-secures it, detach frees truck and vehicle', function()
    local w, src, truck = setup(1)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR })
    test.accepted(flow.load(w, src, truck, car))
    local net = w:entity(truck).net
    test.accepted(w:call('sw_tow:server:lowering', src, net))
    local record = w:module('server.tow').get(truck)
    test.falsy(record.secured, 'not secured while it comes down')
    test.eq(w.env.Entity(truck).state['sw_tow:winch'].phase, 'lowering')
    test.accepted(w:call('sw_tow:server:detach', src, net))
    test.eq(w.env.Entity(truck).state['sw_tow:cargo'], nil)
    test.eq(w.env.Entity(car).state['sw_tow:towedBy'], nil)
    test.eq(w:module('server.tow').get(truck), nil)
end)

test.case('a failed unload can be strapped again', function()
    local w, src, truck = setup(1)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR })
    test.accepted(flow.load(w, src, truck, car))
    local net = w:entity(truck).net
    test.accepted(w:call('sw_tow:server:lowering', src, net))
    test.accepted(w:call('sw_tow:server:secured', src, net))
    test.truthy(w:module('server.tow').get(truck).secured)
end)

test.case('cargo is forgotten when the vehicle or the truck disappears, or the shift ends', function()
    local w, src, truck = setup(1)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR })
    test.accepted(flow.load(w, src, truck, car))
    w:removeEntity(car)
    test.eq(w.env.Entity(truck).state['sw_tow:cargo'], nil, 'cargo cleared after the vehicle vanished')

    w:advance(1)
    local car2 = w:createVehicle({ model = 'asea', coords = World.FAR })
    test.accepted(flow.load(w, src, truck, car2))
    w:setJob(src, 'unemployed')
    test.eq(w.env.Entity(car2).state['sw_tow:towedBy'], nil, 'cargo released when the shift ended')
    w:assertNoErrors()
end)

test.case('ramps: only on your own flatbed', function()
    local w, src, truck = setup(2)
    test.refused(w:call('sw_tow:server:ramps', src, w:entity(truck).net, true))
    local w2, src2, flatbed = setup(1)
    w2:teleport(src2, World.FAR + vector.vec3(2, -4, 0))
    test.accepted(w2:call('sw_tow:server:ramps', src2, w2:entity(flatbed).net, true))
    test.eq(w2.env.Entity(flatbed).state['sw_tow:ramps'], true)
    w2:advance(2)
    test.accepted(w2:call('sw_tow:server:ramps', src2, w2:entity(flatbed).net, false))
    test.eq(w2.env.Entity(flatbed).state['sw_tow:ramps'], nil)
end)

test.case('garbage from a client is refused without errors', function()
    local w, src, truck = setup(1)
    for _, args in ipairs({ { 'x', 'y' }, { 1.5, 2 }, { nil, nil }, { 99999, 99998 }, { {}, {} } }) do
        w:advance(1)
        test.refused(w:call('sw_tow:server:attach', src, args[1], args[2]))
    end
    test.refused(w:call('sw_tow:server:secured', src, 'x'))
    test.refused(w:call('sw_tow:server:lowering', src, nil))
    test.refused(w:call('sw_tow:server:detach', src, 12345))
    test.refused(w:call('sw_tow:server:deliver', src, w:entity(truck).net, 'nope'))
    test.refused(w:call('sw_tow:server:deliver', src, w:entity(truck).net, {}))
    w:assertNoErrors()
end)

test.case('ramps can always be raised again right after lowering (a failed unload must not leave them down)', function()
    local w, src, truck = setup(1)
    w:teleport(src, World.FAR + vector.vec3(2, -4, 0))
    local net = w:entity(truck).net
    test.accepted(w:call('sw_tow:server:ramps', src, net, true))
    test.accepted(w:call('sw_tow:server:ramps', src, net, false))
    test.eq(w.env.Entity(truck).state['sw_tow:ramps'], nil)
    test.refused(w:call('sw_tow:server:ramps', src, net, true)) -- lowering stays rate limited
end)
