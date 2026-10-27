---Steps that many tests share: a worker on shift, a company truck, loading, driving, delivering.
---Each step goes through the same server callbacks a real client uses.
local World = require 'world'
local vector = require 'vector'
local test = require 'test'

local flow = {}

flow.YARD_KEY = 'strawberry'

---A player with the tow job, clocked in at the office.
---@param w table World
---@param spec? table addPlayer spec
---@return integer src
function flow.worker(w, spec)
    spec = spec or {}
    spec.job = spec.job or 'tow'
    local src = w:addPlayer(spec)
    test.accepted(flow.clockIn(w, src))
    return src
end

---@return boolean ok, string? errorKey
function flow.clockIn(w, src)
    w:teleport(src, World.OFFICE)
    return w:call('sw_tow:server:clockIn', src)
end

---Takes a company truck at the office. index 1 = flatbed, 2 = tow truck.
---@return integer truck
function flow.truck(w, src, index)
    w:teleport(src, World.OFFICE)
    local ok, netId = w:call('sw_tow:server:takeTruck', src, index or 1)
    test.accepted(ok, netId)
    return w.env.NetworkGetEntityFromNetworkId(netId)
end

---Moves a truck (with its cargo and the worker next to it) to a place.
function flow.drive(w, src, truck, coords)
    local tow = w:module('server.tow')
    local record = tow.get(truck)
    w:move(truck, coords)
    if record then w:move(record.target, coords + vector.vec3(0.0, -1.0, 0.5)) end
    if not w.players[src].vehicle then w:move(w:ped(src), coords + vector.vec3(3.0, 0.0, 0.0)) end
end

---Puts a vehicle behind the truck and the worker next to it, then winches or hooks it on.
---@return boolean ok, string? errorKey
function flow.load(w, src, truck, target)
    local truckCoords = w:entity(truck).coords
    w:move(target, truckCoords + vector.vec3(0.0, -10.0, 0.0))
    w:teleport(src, truckCoords + vector.vec3(2.0, -8.0, 0.0))
    local truckNet, targetNet = w:entity(truck).net, w:entity(target).net
    local ok, errorKey = w:call('sw_tow:server:attach', src, truckNet, targetNet)
    if not ok then return ok, errorKey end
    if w.env.Entity(truck).state['sw_tow:method'] == 'flatbed' then
        -- The winch pulls it onto the bed.
        w:move(target, truckCoords + vector.vec3(0.0, -1.0, 0.5))
        return w:call('sw_tow:server:secured', src, truckNet)
    end
    w:move(target, truckCoords + vector.vec3(0.0, -4.0, 0.0))
    return true
end

---@return boolean ok, string? errorKey
function flow.deliver(w, src, truck, unloaded)
    return w:call('sw_tow:server:deliver', src, w:entity(truck).net, flow.YARD_KEY, unloaded)
end

---The player sits in their vehicle, gets out and calls a tow with /calltow.
function flow.callTow(w, src, vehicle, message)
    w:enterVehicle(src, vehicle)
    w:leaveVehicle(src)
    w:command('calltow', src, { message = message })
end

---Calls the worker can see.
---@return table[]
function flow.calls(w, src)
    return w:call('sw_tow:server:listCalls', src)
end

---The id of the only open call of a type.
function flow.callId(w, src, callType)
    for _, call in ipairs(flow.calls(w, src)) do
        if call.type == callType and not call.mine then return call.id end
    end
    error('no open call of type ' .. tostring(callType))
end

---Owner calls, worker accepts, loads it with a fresh truck and brings it to the yard (not delivered yet).
---@return { owner: integer, worker: integer, car: integer, vehicleId: integer, truck: integer, callId: integer }
function flow.towedToYard(w, opts)
    opts = opts or {}
    local owner = opts.owner or w:addPlayer({ cash = opts.cash or 0, bank = opts.bank or 5000 })
    local worker = opts.worker or flow.worker(w)
    local car, vehicleId = w:ownedVehicle(owner, { coords = World.FAR, model = opts.model })
    w:teleport(owner, World.FAR + vector.vec3(3.0, 0.0, 0.0))
    flow.callTow(w, owner, car)
    local id = flow.callId(w, worker, 'player')
    test.accepted(w:call('sw_tow:server:acceptCall', worker, id))
    local truck = flow.truck(w, worker, opts.truckIndex or 1)
    flow.drive(w, worker, truck, World.FAR + vector.vec3(0.0, 12.0, 0.0))
    test.accepted(flow.load(w, worker, truck, car))
    w:advance(60)
    flow.drive(w, worker, truck, World.YARD)
    return { owner = owner, worker = worker, car = car, vehicleId = vehicleId, truck = truck, callId = id }
end

---The first active impound record (fake database row).
function flow.onlyRecord(w)
    local found
    for _, row in pairs(w.impoundRows) do
        if row.released_at == nil then
            assert(not found, 'more than one active impound record')
            found = row
        end
    end
    return found
end

return flow
