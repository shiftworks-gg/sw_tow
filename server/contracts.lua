---NPC contracts: broken-down vehicles at roadside spots, so the job works on an empty server.
---A contract has no vehicle until a worker accepts it; then the server spawns it, locked, and the
---client that owns it makes it look broken (state bag `sw_tow:contract`).
local config = require 'config'
local framework = require 'bridge.loader'
local log = require 'server.log'
local shift = require 'server.shift'
local calls = require 'server.calls'
local spotlist = require 'server.spotlist'

local spots = spotlist.all

local cfg = config.contracts
local busySpots = {}

local function workersOnShift()
    local list = {}
    for src in pairs(shift.all()) do list[#list + 1] = src end
    return list
end

---A free spot in the distance band from one random worker on shift.
---@param workers integer[]
---@return integer? index
local function pickSpot(workers)
    local worker = workers[math.random(#workers)]
    local ped = GetPlayerPed(worker)
    if ped == 0 then return end
    local origin = GetEntityCoords(ped)
    local candidates = {}
    for index, spot in ipairs(spots) do
        local distance = #(spot - origin)
        if not busySpots[index] and distance >= cfg.minDistance and distance <= cfg.maxDistance then
            candidates[#candidates + 1] = index
        end
    end
    if #candidates == 0 then return end
    return candidates[math.random(#candidates)]
end

---Accepted contracts whose vehicle is not spawned yet. A server-spawned vehicle only gets its plate
---(and an owner) once a client streams it in, so spawning it at a spot far from every player fails
---with "vehicle plate never set". It is spawned when the worker gets close instead.
---@type table<integer, SwCall>
local pending = {}
local spawning = {}

local function spawnVehicleFor(call)
    local spot = spots[call.spot]
    if lib.getClosestVehicle(spot, 4.0, false) then
        log.info(nil, 'contract', ('spot %d is blocked'):format(call.spot))
        return
    end
    local heading = spotlist.headings[call.spot] or math.random(0, 359) + 0.0
    local _, vehicle = framework.spawnVehicle(call.model, vec4(spot.x, spot.y, spot.z, heading), { plate = call.plate })
    SetVehicleDoorsLocked(vehicle, 2)
    Entity(vehicle).state:set('sw_tow:contract', call.id, true)
    call.vehicle = vehicle
end

local function onAccept(call)
    if call.vehicle and DoesEntityExist(call.vehicle) then return true end
    pending[call.id] = call
    return true
end

local function onClose(call, delivered)
    pending[call.id] = nil
    busySpots[call.spot] = nil
    if not delivered and call.vehicle and DoesEntityExist(call.vehicle)
        and not Entity(call.vehicle).state['sw_tow:towedBy'] then
        framework.deleteVehicle(call.vehicle)
    end
end

local function createContract()
    local workers = workersOnShift()
    if #workers == 0 then return end
    local limit = math.min(cfg.maxOpen, #workers + 1)
    if calls.count(function(call) return call.type == 'contract' end) >= limit then return end

    local index = pickSpot(workers)
    if not index then return end
    busySpots[index] = true
    calls.add({
        type = 'contract',
        plate = ('SWC%05d'):format(math.random(0, 99999)),
        coords = spots[index],
        message = locale('contracts.message'),
        model = cfg.models[math.random(#cfg.models)],
        spot = index,
        onAccept = onAccept,
        onClose = onClose,
    })
end

if cfg.enabled and #spots > 0 then
    CreateThread(function()
        while true do
            Wait(1000)
            for id, call in pairs(pending) do
                local ped = call.status == 'accepted' and call.worker and GetPlayerPed(call.worker) or 0
                if call.vehicle or call.status ~= 'accepted' then
                    pending[id] = nil
                elseif ped ~= 0 and not spawning[id]
                    and #(GetEntityCoords(ped) - spots[call.spot]) <= cfg.spawnRadius then
                    spawning[id] = true
                    CreateThread(function()
                        local ok, err = pcall(spawnVehicleFor, call)
                        if not ok then lib.print.error(err) end
                        spawning[id] = nil
                    end)
                end
            end
        end
    end)

    CreateThread(function()
        while true do
            Wait(cfg.interval * 1000)
            local ok, err = pcall(createContract)
            if not ok then lib.print.error(err) end
        end
    end)
end
