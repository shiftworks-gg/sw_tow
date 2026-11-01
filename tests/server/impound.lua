local test = require 'test'
local flow = require 'flow'
local World = require 'world'
local vector = require 'vector'

test.suite('server › delivery, pay and the impound yard')

-- Pickup is ~861 m from the yard: $150 + $60/km × 0.861 = $201 (rounded down).
local PAY = 201
-- Release right after delivery: $250 base + $0 class (sultan is a sedan) + the $192 tow.
local FEE = 250 + PAY

test.case('a player call delivered: worker paid, vehicle stored with its fee, call closed', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    local bankBefore = w:money(t.worker, 'bank')
    test.accepted(flow.deliver(w, t.worker, t.truck))

    test.eq(w:money(t.worker, 'bank') - bankBefore, PAY, 'paid into the bank')
    test.truthy(w:noticed(t.worker, 'impound.paid'), 'worker told')
    test.truthy(w:noticed(t.owner, 'calls.completed'), 'caller told')
    test.falsy(w:exists(t.car), 'vehicle removed from the street')
    test.eq(#flow.calls(w, t.worker), 0, 'call closed')
    test.eq(w.env.Entity(t.truck).state['sw_tow:cargo'], nil, 'truck empty')

    local row = flow.onlyRecord(w)
    test.eq(row.vehicle_id, t.vehicleId)
    test.eq(row.owner, w.players[t.owner].citizenid)
    test.eq(row.reason, 'player')
    test.eq(row.tow_charge, PAY, 'the owner pays the tow back')
    test.eq(w:garageVehicle(t.vehicleId).state, 2, 'garage: impounded')
    test.eq(w:garageVehicle(t.vehicleId).depotPrice, FEE, 'garage shows the fee')

    local stats = w:sent(t.worker, 'sw_tow:client:shiftStats')
    test.eq(stats[#stats].args[1], 1, 'one delivery')
    test.eq(stats[#stats].args[2], PAY, 'earned')
    test.eq(w.deliveryLog[1].payout, PAY, 'delivery logged')
    w:assertNoErrors()
end)

test.case('the public impound lot cannot hand out a held vehicle', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    test.eq(w.isHeld(t.vehicleId), nil, 'not held before delivery')
    test.accepted(flow.deliver(w, t.worker, t.truck))
    test.eq(w.isHeld(t.vehicleId), 'Shiftworks Impound')
end)

test.case('too fast: a teleport to the yard is refused and nothing changes', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR })
    w:module('server.calls').add({ type = 'contract', plate = 'C1', vehicle = car, coords = World.FAR, message = '' })
    test.accepted(w:call('sw_tow:server:acceptCall', worker, flow.callId(w, worker, 'contract')))
    local truck = flow.truck(w, worker, 1)
    flow.drive(w, worker, truck, World.FAR + vector.vec3(0, 12, 0))
    test.accepted(flow.load(w, worker, truck, car))
    w:advance(5)
    flow.drive(w, worker, truck, World.YARD)
    local bank = w:money(worker, 'bank')
    test.refusedWith('impound.too_fast', flow.deliver(w, worker, truck))
    test.eq(w:money(worker, 'bank'), bank, 'not paid')
    test.truthy(w:exists(car), 'still on the truck')
    w:advance(30)
    test.accepted(flow.deliver(w, worker, truck))
end)

test.case('delivery only inside the yard and with the worker next to the truck', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    flow.drive(w, t.worker, t.truck, World.YARD + vector.vec3(40, 0, 0))
    test.refusedWith('impound.not_in_yard', flow.deliver(w, t.worker, t.truck))
    flow.drive(w, t.worker, t.truck, World.YARD)
    w:teleport(t.worker, World.YARD + vector.vec3(0, 60, 0))
    w:advance(1)
    test.refused(flow.deliver(w, t.worker, t.truck))
end)

test.case('an owned vehicle without an accepted call is refused (no stealing cars into the yard)', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local owner = w:addPlayer({})
    local car, vehicleId = w:ownedVehicle(owner, { coords = World.FAR })
    local truck = flow.truck(w, worker, 1)
    flow.drive(w, worker, truck, World.FAR + vector.vec3(0, 12, 0))
    test.accepted(flow.load(w, worker, truck, car))
    w:advance(60)
    flow.drive(w, worker, truck, World.YARD)
    test.refusedWith('impound.no_order', flow.deliver(w, worker, truck))
    test.truthy(w:exists(car))
    test.eq(w:garageVehicle(vehicleId).state, 0, 'garage untouched')
    test.eq(flow.onlyRecord(w), nil, 'no record')
end)

test.case('an unowned vehicle without a call is cleared off the street without pay', function()
    local w = newWorld()
    local worker = flow.worker(w)
    local car = w:createVehicle({ model = 'asea', coords = World.FAR })
    local truck = flow.truck(w, worker, 1)
    flow.drive(w, worker, truck, World.FAR + vector.vec3(0, 12, 0))
    test.accepted(flow.load(w, worker, truck, car))
    w:advance(60)
    flow.drive(w, worker, truck, World.YARD)
    local bank = w:money(worker, 'bank')
    test.accepted(flow.deliver(w, worker, truck))
    test.eq(w:money(worker, 'bank'), bank, 'no pay')
    test.truthy(w:noticed(worker, 'impound.cleared'))
    test.falsy(w:exists(car))
end)

test.case('a partner on shift in the truck gets half on top; the owner pays both back', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    local partner = flow.worker(w)
    w:enterVehicle(partner, t.truck, 0)
    local before = w:money(partner, 'bank')
    test.accepted(flow.deliver(w, t.worker, t.truck))
    test.eq(w:money(partner, 'bank') - before, PAY // 2)
    test.eq(flow.onlyRecord(w).tow_charge, PAY + PAY // 2, 'tow charge covers both')
end)

test.case('a garage that cannot store the vehicle undoes the delivery', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    w.failGarageStore = true
    local bank = w:money(t.worker, 'bank')
    test.refusedWith('common.failed', flow.deliver(w, t.worker, t.truck))
    test.eq(flow.onlyRecord(w), nil, 'record removed again')
    test.eq(w.isHeld(t.vehicleId), nil, 'not held')
    test.truthy(w:exists(t.car), 'vehicle still on the truck')
    test.eq(w:money(t.worker, 'bank'), bank, 'not paid')
    w.failGarageStore = false
    w:advance(2)
    test.accepted(flow.deliver(w, t.worker, t.truck))
end)

test.case('unloading inside the yard hands the vehicle over', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    local net = w:entity(t.truck).net
    test.accepted(w:call('sw_tow:server:lowering', t.worker, net))
    w:move(t.car, World.YARD + vector.vec3(0, -14, 0)) -- rolled down behind the truck
    test.accepted(flow.deliver(w, t.worker, t.truck, true))
    test.eq(w:garageVehicle(t.vehicleId).state, 2)
end)

test.case('the "unloaded" flag means nothing unless the vehicle is really being unloaded', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    w:move(t.car, World.YARD + vector.vec3(0, -14, 0))
    test.refusedWith('impound.no_cargo', flow.deliver(w, t.worker, t.truck, true))
end)

test.case('fees: base + class + started days after the free hours + fine + tow', function()
    local w = newWorld()
    local impound = w:module('server.impound')
    local now = w.time
    local function fee(hours, class, fine, tow)
        return impound.fee({ stored_at = now - math.floor(hours * 3600), fine = fine, tow_charge = tow }, class)
    end
    test.eq(fee(0), 250, 'base')
    test.eq(fee(1.99), 250, 'inside the free hours')
    test.eq(fee(2.01), 350, 'first started day')
    test.eq(fee(26.0), 350, 'still the first day')
    test.eq(fee(26.01), 450, 'second day')
    test.eq(fee(0, 7), 700, 'super class +$450')
    test.eq(fee(0, 1), 250, 'class without a surcharge')
    test.eq(fee(0, nil, 500, 192), 942, 'fine and tow')
end)

test.case('release: the owner pays at the counter and gets the vehicle with keys', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    test.accepted(flow.deliver(w, t.worker, t.truck))
    local owner = t.owner

    w:teleport(owner, World.FAR)
    test.eq(#w:call('sw_tow:server:counterList', owner, flow.YARD_KEY), 0, 'nothing away from the counter')

    w:teleport(owner, World.COUNTER)
    local list = w:call('sw_tow:server:counterList', owner, flow.YARD_KEY)
    test.eq(#list, 1)
    test.eq(list[1].fee, FEE)
    test.falsy(list[1].held)

    local bank = w:money(owner, 'bank')
    test.accepted(w:call('sw_tow:server:release', owner, list[1].id))
    test.eq(bank - w:money(owner, 'bank'), FEE, 'charged')
    test.eq(w:garageVehicle(t.vehicleId).state, 0, 'garage: out')
    test.eq(w.isHeld(t.vehicleId), nil, 'no longer held')
    local key = w.keysGiven[#w.keysGiven]
    test.eq(key.src, owner, 'keys to the owner')
    test.eq(w:entity(key.entity).plate, w:garageVehicle(t.vehicleId).plate, 'the right vehicle')
    test.near(#(w:entity(key.entity).coords - World.RELEASE[1]), 0, 0.01, 'on the release spot')
    test.eq(w.deposits[1].account, 'tow')
    test.eq(w.deposits[1].amount, math.floor(FEE * 0.6), 'company share')
    test.eq(#w:call('sw_tow:server:counterList', owner, flow.YARD_KEY), 0, 'gone from the list')
    w:assertNoErrors()
end)

test.case('release: cash first, then bank; not enough money is refused', function()
    local w = newWorld()
    local t = flow.towedToYard(w, { cash = FEE, bank = 0 })
    test.accepted(flow.deliver(w, t.worker, t.truck))
    w:teleport(t.owner, World.COUNTER)
    local id = w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1].id
    w.players[t.owner].money.cash = FEE - 1
    test.refusedWith('impound.not_enough', w:call('sw_tow:server:release', t.owner, id))
    w.players[t.owner].money.cash = FEE
    w:advance(1)
    test.accepted(w:call('sw_tow:server:release', t.owner, id))
    test.eq(w:money(t.owner, 'cash'), 0)
end)

test.case('release: storage days are charged', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    test.accepted(flow.deliver(w, t.worker, t.truck))
    w:advance(26 * 3600 + 60)
    w:teleport(t.owner, World.COUNTER)
    test.eq(w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1].fee, FEE + 200)
end)

test.case('release: refused without charging when the release spot is taken or the spawn fails', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    test.accepted(flow.deliver(w, t.worker, t.truck))
    w:teleport(t.owner, World.COUNTER)
    local id = w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1].id
    local bank = w:money(t.owner, 'bank')

    local blockers = {}
    for i, spot in ipairs(World.RELEASE) do
        blockers[i] = w:createVehicle({ model = 'asea', coords = spot })
    end
    test.refusedWith('impound.no_spot', w:call('sw_tow:server:release', t.owner, id))
    test.eq(w:money(t.owner, 'bank'), bank)
    local sitter = w:addPlayer({})
    w:enterVehicle(sitter, blockers[1])
    w:advance(1)
    test.refusedWith('impound.no_spot', w:call('sw_tow:server:release', t.owner, id)) -- a player's car counts too
    w:leaveVehicle(sitter)
    for _, blocker in ipairs(blockers) do w:removeEntity(blocker) end

    w.failNextSpawn = true
    w:advance(1)
    test.refusedWith('common.failed', w:call('sw_tow:server:release', t.owner, id))
    test.eq(w:money(t.owner, 'bank'), bank, 'refunded')
    test.eq(w:garageVehicle(t.vehicleId).state, 2, 'still impounded')
    w:assertNoErrors()
end)

test.case('release: only the owner, and only once', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    test.accepted(flow.deliver(w, t.worker, t.truck))
    w:teleport(t.owner, World.COUNTER)
    local id = w:call('sw_tow:server:counterList', t.owner, flow.YARD_KEY)[1].id

    local thief = w:addPlayer({ bank = 10000 })
    w:teleport(thief, World.COUNTER)
    test.eq(#w:call('sw_tow:server:counterList', thief, flow.YARD_KEY), 0, 'not in the thief\'s list')
    test.refused(w:call('sw_tow:server:release', thief, id))

    test.accepted(w:call('sw_tow:server:release', t.owner, id))
    local bank = w:money(t.owner, 'bank')
    w:advance(1)
    test.refused(w:call('sw_tow:server:release', t.owner, id))
    test.eq(w:money(t.owner, 'bank'), bank, 'charged once')
end)

test.case('held vehicles are remembered across a restart', function()
    local w = World.new(ROOT)
    w.impoundRows[7] = { id = 7, yard = 'davis', plate = 'OLD', vehicle_id = 42, owner = 'CIDX', model = 'sultan',
        reason = 'player', fine = 0, tow_charge = 0, police_hold = 0, stored_at = w.time - 3600 }
    w.nextImpoundId = 7
    w:start()
    test.eq(w.isHeld(42), 'Shiftworks Impound')
end)

test.case('garbage from a client at the counter is refused without errors', function()
    local w = newWorld()
    local src = w:addPlayer({})
    w:teleport(src, World.COUNTER)
    for _, value in ipairs({ 'x', 1.5, -1, 0, {}, true }) do
        w:advance(1)
        test.refused(w:call('sw_tow:server:release', src, value))
        test.eq(#w:call('sw_tow:server:counterList', src, value), 0)
    end
    w:assertNoErrors()
end)

test.case('a car strapped to the truck is delivered even if its position on the server trails behind', function()
    local w = newWorld()
    local t = flow.towedToYard(w)
    local truckCoords = w:entity(t.truck).coords
    w:move(t.car, truckCoords + vector.vec3(0.0, -60.0, 0.0))
    test.refusedWith('impound.no_cargo', flow.deliver(w, t.worker, t.truck))
    w:entity(t.car).attachedTo = t.truck
    w:advance(1)
    test.accepted(flow.deliver(w, t.worker, t.truck))
end)
