local test = require 'test'
local flow = require 'flow'
local World = require 'world'
local vector = require 'vector'

test.suite('server › players at the same moment')

-- Three truck spots 6 m apart along the first one.
local function threeSpots(config)
    local first = config.garage.spawns[1]
    config.garage.spawns = {
        first,
        vector.vec4(first.x + 6.0, first.y, first.z, first.w),
        vector.vec4(first.x + 12.0, first.y, first.z, first.w),
    }
end

local function trucksOn(w, results)
    local spots = {}
    for i, r in ipairs(results) do
        if r[1] then
            local truck = w.env.NetworkGetEntityFromNetworkId(r[2])
            local c = w:entity(truck).coords
            spots[i] = ('%.0f,%.0f'):format(c.x, c.y)
        end
    end
    return spots
end

test.case('three workers take a truck at the same moment: three trucks on three different spots', function()
    local w = newWorld({ config = threeSpots })
    w.spawnDelay = 500
    local a, b, c = flow.worker(w), flow.worker(w), flow.worker(w)
    local results = w:callTogether({
        { 'sw_tow:server:takeTruck', a, 1 }, { 'sw_tow:server:takeTruck', b, 1 }, { 'sw_tow:server:takeTruck', c, 2 },
    })
    for i = 1, 3 do test.accepted(results[i][1], results[i][2]) end
    local spots = trucksOn(w, results)
    test.truthy(spots[1] ~= spots[2] and spots[2] ~= spots[3] and spots[1] ~= spots[3],
        ('different spots: %s | %s | %s'):format(spots[1], spots[2], spots[3]))
    w:assertNoErrors()
end)

test.case('more workers than spots: the last one is told the spots are taken and pays nothing', function()
    local w = newWorld({ config = function(config) config.garage.deposit = 500 end })
    w.spawnDelay = 500
    local a = flow.worker(w, { bank = 1000 })
    local b = flow.worker(w, { bank = 1000 })
    local results = w:callTogether({ { 'sw_tow:server:takeTruck', a, 1 }, { 'sw_tow:server:takeTruck', b, 1 } })
    test.accepted(results[1][1], results[1][2])
    test.eq(results[2][1], false)
    test.eq(results[2][2], 'garage.spot_busy')
    test.eq(w:money(b, 'bank'), 1000, 'no deposit taken')
    w:assertNoErrors()
end)

test.case('a spot with someone standing on it is skipped', function()
    local w = newWorld({ config = threeSpots })
    local bystander = w:addPlayer({ coords = World.TRUCK_SPAWN })
    local src = flow.worker(w)
    local truck = flow.truck(w, src, 1)
    test.truthy(#(w:entity(truck).coords - World.TRUCK_SPAWN) > 5.0, 'not on the person')
    test.truthy(w:ped(bystander), 'bystander still there')
    w:assertNoErrors()
end)

test.case('a double tap at the counter gives one truck and takes one deposit', function()
    local w = newWorld({ config = function(config) threeSpots(config); config.garage.deposit = 500 end })
    w.spawnDelay = 500
    local src = flow.worker(w, { bank = 2000 })
    local results = w:callTogether({ { 'sw_tow:server:takeTruck', src, 1 }, { 'sw_tow:server:takeTruck', src, 1 } })
    local ok = (results[1][1] and 1 or 0) + (results[2][1] and 1 or 0)
    test.eq(ok, 1, 'one truck')
    test.eq(#w.env.GetAllVehicles(), 1, 'one vehicle in the world')
    test.eq(w:money(src, 'bank'), 1500, 'one deposit')
    w:assertNoErrors()
end)

test.case('two owners release at the same moment: two cars on two different spots', function()
    local w = newWorld()
    w.spawnDelay = 500
    local first = flow.towedToYard(w)
    test.accepted(flow.deliver(w, first.worker, first.truck))
    w:advance(2)
    local second = flow.towedToYard(w)
    test.accepted(flow.deliver(w, second.worker, second.truck))

    w:teleport(first.owner, World.COUNTER)
    w:teleport(second.owner, World.COUNTER + vector.vec3(1, 0, 0))
    local id1 = w:call('sw_tow:server:counterList', first.owner, flow.YARD_KEY)[1].id
    local id2 = w:call('sw_tow:server:counterList', second.owner, flow.YARD_KEY)[1].id
    w:advance(2)
    local results = w:callTogether({ { 'sw_tow:server:release', first.owner, id1 }, { 'sw_tow:server:release', second.owner, id2 } })
    test.accepted(results[1][1], results[1][2])
    test.accepted(results[2][1], results[2][2])
    local a = w:entity(w.keysGiven[#w.keysGiven - 1].entity).coords
    local b = w:entity(w.keysGiven[#w.keysGiven].entity).coords
    test.truthy(#(a - b) > 2.0, 'not on top of each other')
    w:assertNoErrors()
end)

test.case('two workers accept the same call at the same moment: one gets it', function()
    local w = newWorld()
    local owner = w:addPlayer({ bank = 5000 })
    local car = w:ownedVehicle(owner, { coords = World.FAR })
    w:teleport(owner, World.FAR + vector.vec3(3, 0, 0))
    local a, b = flow.worker(w), flow.worker(w)
    flow.callTow(w, owner, car)
    local id = flow.callId(w, a, 'player')
    local results = w:callTogether({ { 'sw_tow:server:acceptCall', a, id }, { 'sw_tow:server:acceptCall', b, id } })
    test.truthy(results[1][1], 'first gets it')
    test.eq(results[2][2], 'calls.taken')
    w:assertNoErrors()
end)

test.case('ending the shift twice at once pays once', function()
    local w = newWorld({ config = function(config) config.payout.collect = 'office' end })
    local worker = flow.worker(w, { bank = 0 })
    local t = flow.towedToYard(w, { worker = worker })
    test.accepted(flow.deliver(w, worker, t.truck))
    flow.drive(w, worker, t.truck, World.TRUCK_SPAWN)
    w:teleport(worker, World.TRUCK_SPAWN + vector.vec3(3, 0, 0))
    w:advance(2)
    local results = w:callTogether({ { 'sw_tow:server:endShift', worker }, { 'sw_tow:server:endShift', worker } })
    test.truthy(results[1][1] or results[2][1], 'ended')
    test.eq(w:money(worker, 'bank'), 201, 'paid once')
    w:assertNoErrors()
end)
