local test = require 'test'
local flow = require 'flow'
local World = require 'world'
local vector = require 'vector'

test.suite('server › police orders and holds')

local FAR = World.FAR

local function officer(w, coords)
    return w:addPlayer({ job = 'police', jobType = 'leo', onDuty = true, coords = coords or FAR })
end

local function order(w, src, vehicle, form)
    w:advance(4) -- past the rate limit
    return w:call('sw_tow:server:policeOrder', src, w:entity(vehicle).net, form or { reason = 'Parking', fine = 0, hold = false, holdHours = 0 })
end

test.case('an officer on duty orders a tow; workers see a police call', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local cop = officer(w)
    local car = w:createVehicle({ model = 'asea', coords = FAR + vector.vec3(3, 0, 0) })
    test.accepted(order(w, cop, car, { reason = 'Blocking', fine = 300, hold = true, holdHours = 0 }))
    test.truthy(w:noticed(worker, 'calls.new_police'))
    local call = flow.calls(w, worker)[1]
    test.eq(call.type, 'police')
    test.eq(call.message, 'Blocking')
    w:assertNoErrors()
end)

test.case('refused: not police, off duty, too far, occupied, already ordered', function()
    local w = newWorld()
    local car = w:createVehicle({ model = 'asea', coords = FAR + vector.vec3(3, 0, 0) })
    local worker = flow.worker(w)
    w:teleport(worker, FAR)
    test.refused(order(w, worker, car))

    local offDuty = w:addPlayer({ job = 'police', jobType = 'leo', onDuty = false, coords = FAR })
    test.refused(order(w, offDuty, car))

    local cop = officer(w, FAR + vector.vec3(30, 0, 0))
    test.refused(order(w, cop, car))
    w:teleport(cop, FAR)

    local driver = w:addPlayer({ coords = FAR })
    w:enterVehicle(driver, car)
    test.refusedWith('tow.occupied', order(w, cop, car))
    w:leaveVehicle(driver)
    w:teleport(driver, FAR + vector.vec3(100, 0, 0))

    test.accepted(order(w, cop, car))
    test.refusedWith('police.already_ordered', order(w, cop, car))
end)

test.case('fine and hold hours must be whole numbers within the limits', function()
    local w = newWorld()
    local cop = officer(w)
    local car = w:createVehicle({ model = 'asea', coords = FAR + vector.vec3(3, 0, 0) })
    for _, form in ipairs({
        { reason = 'x', fine = 5001, holdHours = 0 },
        { reason = 'x', fine = -1, holdHours = 0 },
        { reason = 'x', fine = 2.5, holdHours = 0 },
        { reason = 'x', fine = 'lots', holdHours = 0 },
        { reason = 'x', fine = 0, holdHours = 169 },
        { reason = 'x', fine = 0, holdHours = -3 },
    }) do
        test.refused(order(w, cop, car, form))
    end
    test.refused(w:call('sw_tow:server:policeOrder', cop, w:entity(car).net, 'not a table'))
    test.accepted(order(w, cop, car, { reason = 'x', fine = 5000, holdHours = 168 }))
    w:assertNoErrors()
end)

test.case('at most 6 orders per officer per hour', function()
    local w = newWorld()
    local cop = officer(w)
    for i = 1, 6 do
        local car = w:createVehicle({ model = 'asea', coords = FAR + vector.vec3(0, i, 0) })
        test.accepted(order(w, cop, car))
    end
    local seventh = w:createVehicle({ model = 'asea', coords = FAR + vector.vec3(3, 3, 0) })
    test.refusedWith('police.limit', order(w, cop, seventh))
    w:advance(3600)
    test.accepted(order(w, cop, seventh))
end)

---Officer orders a tow (with a fine and a hold) on a player's car; a worker brings it in.
local function heldCar(w, holdHours)
    local owner = w:addPlayer({ bank = 5000 })
    local car, vehicleId = w:ownedVehicle(owner, { coords = FAR })
    local cop = officer(w, FAR + vector.vec3(3, 0, 0))
    test.accepted(order(w, cop, car, { reason = 'Red zone', fine = 500, hold = true, holdHours = holdHours or 0 }))
    local worker = flow.worker(w)
    test.accepted(w:call('sw_tow:server:acceptCall', worker, flow.callId(w, worker, 'police')))
    local truck = flow.truck(w, worker, 1)
    flow.drive(w, worker, truck, FAR + vector.vec3(0, 12, 0))
    test.accepted(flow.load(w, worker, truck, car))
    w:advance(60)
    flow.drive(w, worker, truck, World.YARD)
    test.accepted(flow.deliver(w, worker, truck))
    return { owner = owner, cop = cop, worker = worker, vehicleId = vehicleId }
end

test.case('a police hold blocks release until an officer lifts it; the fine goes to the police', function()
    local w = newWorld()
    local t = heldCar(w)
    test.truthy(w:noticed(t.owner, 'impound.owner_notice'), 'owner told where the car is')
    local row = flow.onlyRecord(w)
    test.eq(row.fine, 500)
    test.eq(row.police_hold, 1)

    w:teleport(t.owner, World.OFFICE)
    local item = w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1]
    test.truthy(item.held, 'shown as held')
    test.refusedWith('impound.police_hold', w:call('sw_tow:server:release', t.owner, item.id))

    w:teleport(t.cop, World.FAR)
    test.eq(#w:call('sw_tow:server:holdList', t.cop, flow.YARD_KEY), 0, 'officer away from the counter')
    test.eq(#w:call('sw_tow:server:holdList', t.worker, flow.YARD_KEY), 0, 'not an officer')
    w:teleport(t.cop, World.OFFICE)
    local holds = w:call('sw_tow:server:holdList', t.cop, flow.YARD_KEY)
    test.eq(#holds, 1)
    test.eq(holds[1].note, 'Red zone')
    test.refused(w:call('sw_tow:server:liftHold', t.worker, holds[1].id))
    w:advance(4)
    test.accepted(w:call('sw_tow:server:liftHold', t.cop, holds[1].id))

    item = w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1]
    test.falsy(item.held)
    local bank = w:money(t.owner, 'bank')
    w:advance(1)
    test.accepted(w:call('sw_tow:server:release', t.owner, item.id))
    local paid = bank - w:money(t.owner, 'bank')
    test.eq(paid, item.fee)
    test.eq(w.deposits[1].account, 'police')
    test.eq(w.deposits[1].amount, 500)
    test.eq(w.deposits[2].account, 'tow')
    test.eq(w.deposits[2].amount, math.floor((paid - 500) * 0.6))
    w:assertNoErrors()
end)

test.case('a timed hold ends by itself', function()
    local w = newWorld()
    local t = heldCar(w, 2)
    w:teleport(t.owner, World.OFFICE)
    test.truthy(w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1].held)
    w:advance(2 * 3600 + 5)
    local item = w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1]
    test.falsy(item.held)
    test.accepted(w:call('sw_tow:server:release', t.owner, item.id))
end)
