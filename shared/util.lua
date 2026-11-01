---Small helpers shared by client and server.
local util = {}

---Is a point inside a box zone rotated around Z?
---@param point vector3
---@param zone { coords: vector3, size: vector3, rotation?: number }
---@return boolean
function util.inZone(point, zone)
    local d = point - zone.coords
    local r = math.rad(-(zone.rotation or 0.0))
    local c, s = math.cos(r), math.sin(r)
    local x = d.x * c - d.y * s
    local y = d.x * s + d.y * c
    return math.abs(x) <= zone.size.x / 2 and math.abs(y) <= zone.size.y / 2 and math.abs(d.z) <= zone.size.z / 2
end

---@param plate string?
---@return string
function util.trimPlate(plate)
    local trimmed = (plate or ''):gsub('^%s+', ''):gsub('%s+$', '')
    return trimmed
end

---Formats whole dollars as `$1,240`.
---@param amount number
---@return string
function util.money(amount)
    local digits = tostring(math.floor(math.abs(amount)))
    local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return (amount < 0 and '-$' or '$') .. grouped
end

---Client: the entity a state bag belongs to. A bag can arrive a moment before its entity exists
---on this client (streaming in), so this waits up to `timeout` ms. Call it from a thread.
---@param bagName string
---@param timeout? integer
---@return integer? entity, boolean? arrived true when the entity was not here yet: the bag came with
---it as it streamed in, so the value is old news (no sound, no animation)
function util.entityFromBag(bagName, timeout)
    local netId = tonumber(bagName:match('^entity:(%d+)$'))
    if not netId then return end
    local arrived = not NetworkDoesEntityExistWithNetworkId(netId)
    local deadline = GetGameTimer() + (timeout or 5000)
    while not NetworkDoesEntityExistWithNetworkId(netId) do
        if GetGameTimer() > deadline then return end
        Wait(50)
    end
    local entity = NetToVeh(netId)
    if entity == 0 then return end
    return entity, arrived
end

---Where company trucks are parked out and handed back: garage.spawns, or the single garage.spawn
---of older configs.
---@param garage table config.garage
---@return vector4[]
function util.truckSpots(garage)
    if type(garage.spawns) == 'table' and #garage.spawns > 0 then return garage.spawns end
    return { garage.spawn }
end

---The spot of a list closest to a point.
---@param coords vector3
---@param spots vector4[]
---@return vector4 spot, number distance
function util.nearestSpot(coords, spots)
    local best, bestDistance = spots[1], math.huge
    for _, spot in ipairs(spots) do
        local d = #(coords - spot.xyz)
        if d < bestDistance then best, bestDistance = spot, d end
    end
    return best, bestDistance
end

---@param value any
---@return boolean
function util.isInteger(value)
    return math.type(value) == 'integer'
end

return util
