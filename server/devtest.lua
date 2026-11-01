---Server side of the in-game test runner (/swtow_test, see client/devtest.lua). Active only with
---`setr sw_tow_dev 1` in server.cfg, and only for players allowed the ace command.swtow_test (admins).
---It sets up what the scenarios need: the job, money, owned test vehicles, aged cargo and records.
---Every test vehicle has a plate starting with SWTE; `cleanup` removes them and their database rows.
---Never enable this on a live server: it hands out jobs, money and vehicles.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local storage = require 'server.storage'
local shift = require 'server.shift'
local tow = require 'server.tow'
local calls = require 'server.calls'
local contracts = require 'server.contracts'
local abandoned = require 'server.abandoned'
local impound = require 'server.impound'
local police = require 'server.police'

if GetConvar('sw_tow_dev', '0') ~= '1' then return end

local TEST_PLATE = 'SWTE'

lib.print.warn('sw_tow_dev is on: /swtow_test can hand out jobs, money and vehicles. Development servers only.')

---@param name string
---@param fn fun(src: integer, ...): any, any, any
local function register(name, fn)
    lib.callback.register('sw_tow:dev:' .. name, function(src, ...)
        if not IsPlayerAceAllowed(src, 'command.swtow_test') then return false, 'not allowed (ace command.swtow_test)' end
        local ok, a, b, c = pcall(fn, src, ...)
        if not ok then
            lib.print.error(('dev:%s: %s'):format(name, a))
            return false, tostring(a)
        end
        return a, b, c
    end)
end

-- /swtow_coords also lands in coords.log on a dev server, so placed points can be read from disk.
register('coords', function(_, name, text)
    local line = ('%s  %s = %s\n'):format(os.date('%Y-%m-%d %H:%M:%S'), tostring(name or '-'), tostring(text))
    local old = LoadResourceFile(cache.resource, 'coords.log') or ''
    SaveResourceFile(cache.resource, 'coords.log', old .. line, -1)
    return true
end)

local function testPlate()
    for _ = 1, 50 do
        local plate = ('%s%04d'):format(TEST_PLATE, math.random(0, 9999))
        if not MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE plate = ?', { plate }) then return plate end
    end
    error('no free test plate')
end

---@param coords table { x, y, z, w }
local function vec4Of(coords)
    return vec4(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, (coords.w or 0.0) + 0.0)
end

register('prepare', function(src)
    local job = framework.getJob(src)
    if not job or job.name ~= config.job then
        if not framework.setJob(src, config.job, 0) then error('could not give the job ' .. config.job) end
        Wait(500)
    end
    for _, account in ipairs({ 'bank', 'cash' }) do
        local have = framework.getMoney(src, account)
        if have < 20000 then framework.addMoney(src, account, 20000 - have, 'sw-tow-test') end
    end
    return true
end)

-- Pay waiting at the office (payout.collect = 'office') counts as the worker's money too.
register('money', function(src)
    local citizenid = framework.getCitizenId(src)
    return {
        cash = framework.getMoney(src, 'cash'),
        bank = framework.getMoney(src, 'bank') + (citizenid and storage.owed(citizenid) or 0),
    }
end)

register('stats', function(src)
    local current = shift.get(src)
    return current and { deliveries = current.deliveries, earned = current.earned } or false
end)

---A fixed plate (the car a video follows from shot to shot): removes the vehicle that carries it
---and its records first, so every take starts from the same state. Only the tester's own rows.
local function fixedPlate(src, plate)
    if type(plate) ~= 'string' or not plate:match('^[%w ]+$') or #plate > 8 then error('bad plate') end
    calls.closePlate(plate)
    police.resetLimit(src)
    for _, vehicle in ipairs(GetAllVehicles() --[[@as integer[] ]]) do
        if framework.getPlate(vehicle) == plate then framework.deleteVehicle(vehicle) end
    end
    MySQL.update.await('DELETE FROM sw_tow_impound WHERE plate = ?', { plate })
    MySQL.update.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, framework.getCitizenId(src) })
    return plate
end

---A vehicle nobody owns, as if parked by the game.
---@param plate? string a fixed plate instead of a test plate
register('spawnVehicle', function(src, model, coords, plate)
    local netId = framework.spawnVehicle(model, vec4Of(coords), { plate = plate and fixedPlate(src, plate) or testPlate() })
    return netId
end)

---Filming: removes the fixed-plate car and its records.
register('purge', function(src, plate)
    fixedPlate(src, plate)
    return true
end)

---Filming: a police order for a plate at a place, with no vehicle there (the call arrives while the
---worker is across town; the shot only shows the call coming in).
register('filmOrder', function(src, plate, coords, fine, hold, holdHours)
    return calls.add({
        type = 'police', caller = src, plate = plate, coords = vec3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0),
        message = 'Parked on the pavement, blocking a hydrant', fine = fine, hold = hold, holdHours = holdHours,
    })
end)

---A vehicle owned by the tester, registered in the garage script like a bought car.
---@param plate? string a fixed plate instead of a test plate
---@param colors? integer[] { primary, secondary, pearl, wheels } saved with the vehicle, so it comes out
---of the impound in the same paint (the release spawns it from the saved properties)
register('ownedVehicle', function(src, model, coords, plate, colors)
    local citizenid = framework.getCitizenId(src)
    plate = plate and fixedPlate(src, plate) or testPlate()
    local props = { plate = plate }
    if type(colors) == 'table' and colors[1] then
        props.color1 = colors[1]
        props.color2 = colors[2] or colors[1]
        props.pearlescentColor = colors[3] or 0
        props.wheelColor = colors[4] or 0
    end
    local vehicleId
    if integrations.names.garage == 'qbx_garages' then
        local err
        vehicleId, err = exports.qbx_vehicles:CreatePlayerVehicle({ model = model, citizenid = citizenid, props = props })
        if not vehicleId then error('CreatePlayerVehicle: ' .. json.encode(err)) end
    elseif integrations.names.garage == 'qb-garages' then
        vehicleId = MySQL.insert.await(
            'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
            { GetPlayerIdentifierByType(src, 'license'), citizenid, model, joaat(model),
                json.encode(lib.table.merge({ model = joaat(model) }, props)), plate, 'pillboxgarage' })
    else
        error('no garage script: owned vehicles need qbx_garages or qb-garages')
    end
    local netId, entity = framework.spawnVehicle(model, vec4Of(coords), { plate = plate })
    Entity(entity).state:set('vehicleid', vehicleId, false)
    return netId, vehicleId, plate
end)

register('garageState', function(_, vehicleId)
    return MySQL.single.await('SELECT state, garage, depotprice FROM player_vehicles WHERE id = ?', { vehicleId }) or false
end)

register('isHeld', function(_, vehicleId)
    return impound.isHeld(vehicleId) or false
end)

---Pretends the loaded vehicle was picked up `seconds` ago (the too-fast check measures from then).
register('ageCargo', function(_, truckNet, seconds)
    local truck = NetworkGetEntityFromNetworkId(truckNet)
    local record = truck ~= 0 and tow.get(truck)
    if not record then return false end
    record.pickedAt = record.pickedAt - seconds
    return true
end)

---What the server knows of a truck's cargo, for a failure message.
register('cargo', function(_, truckNet)
    local truck = NetworkGetEntityFromNetworkId(truckNet)
    local record = truck ~= 0 and tow.get(truck)
    if not record then return 'no cargo record' end
    return ('secured %s, attached %s, %.1f m from the truck'):format(tostring(record.secured),
        tostring(GetEntityAttachedTo(record.target) == truck), #(GetEntityCoords(record.target) - GetEntityCoords(truck)))
end)

---Pretends an impounded vehicle has stood in the yard `hours` longer.
register('ageImpound', function(_, plate, hours)
    local changed = MySQL.update.await(
        'UPDATE sw_tow_impound SET stored_at = stored_at - INTERVAL ? HOUR WHERE plate = ? AND released_at IS NULL',
        { hours, plate })
    return changed > 0
end)

---A police order without an officer (the officer's form is tested by hand).
register('policeOrder', function(src, netId, fine, hold, holdHours)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 then return false end
    return calls.add({
        type = 'police', caller = src, plate = framework.getPlate(vehicle), vehicle = vehicle,
        coords = GetEntityCoords(vehicle), message = 'swtow_test', fine = fine, hold = hold, holdHours = holdHours,
    })
end)

---Filming (sw_director): an owner's call for a vehicle, made while the tester stands at the truck
---as the worker who receives it. The call command needs the caller at the car.
register('filmCall', function(src, netId, message)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 then return false end
    return calls.add({
        type = 'player', caller = src, plate = framework.getPlate(vehicle), vehicle = vehicle,
        coords = GetEntityCoords(vehicle), message = message or '',
    })
end)

---Filming: the police job on duty for the officer's shots, or the tow job back.
register('filmJob', function(src, name)
    if name == 'police' then
        if not framework.setJob(src, 'police', 0) then error('could not give the police job') end
        framework.setDuty(src, true)
        return true
    end
    return framework.setJob(src, config.job, 0)
end)

register('liftHold', function(_, plate)
    local id = MySQL.scalar.await('SELECT id FROM sw_tow_impound WHERE plate = ? AND released_at IS NULL', { plate })
    return id ~= nil and storage.liftHold(id)
end)

---A contract at the free spot nearest to the tester that is still outside the spawn radius.
register('contract', function(src)
    if not config.contracts.enabled then return false, 'contracts are off in config.lua' end
    local origin = GetEntityCoords(GetPlayerPed(src))
    local best, bestDistance
    for index, spot in ipairs(contracts.spots) do
        local d = #(spot - origin)
        if not contracts.busy[index] and d > config.contracts.spawnRadius + 40.0 and (not bestDistance or d < bestDistance) then
            best, bestDistance = index, d
        end
    end
    if not best then return false, 'no free spot' end
    local id = contracts.create(best)
    return id, contracts.spots[best]
end)

---Marks a vehicle as left behind long ago and scans at once.
register('abandon', function(_, netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 then return false end
    abandoned.track(vehicle, os.time() - config.abandoned.minutes * 60 - 5)
    abandoned.scan()
    return calls.hasVehicle(vehicle)
end)

register('scanAbandoned', function()
    abandoned.scan()
    return true
end)

register('hasCall', function(_, netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    return vehicle ~= 0 and calls.hasVehicle(vehicle)
end)

---Runs the call timeout pass now; says who the server sees at the wheel of a vehicle.
register('sweepCalls', function(_, netId)
    calls.sweep()
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local driver = vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) or 0
    return true, driver == 0 and 'the server sees nobody at the wheel'
        or IsPedAPlayer(driver) and 'the server sees a player at the wheel' or 'the server sees an NPC at the wheel'
end)

register('closeCall', function(_, id)
    return calls.close(id)
end)

register('stopShift', function(src)
    shift.stop(src, 'swtow_test')
    return true
end)

---Removes every test vehicle and its database rows.
register('cleanup', function()
    local removed = 0
    for _, vehicle in ipairs(GetAllVehicles() --[[@as integer[] ]]) do
        if framework.getPlate(vehicle):sub(1, #TEST_PLATE) == TEST_PLATE then
            framework.deleteVehicle(vehicle)
            removed = removed + 1
        end
    end
    local records = MySQL.update.await('DELETE FROM sw_tow_impound WHERE plate LIKE ?', { TEST_PLATE .. '%' })
    local owned = MySQL.update.await('DELETE FROM player_vehicles WHERE plate LIKE ?', { TEST_PLATE .. '%' })
    return { vehicles = removed, records = records, owned = owned }
end)

register('report', function(src, lines)
    if type(lines) ~= 'table' then return false end
    local text = table.concat(lines, '\n')
    SaveResourceFile(cache.resource, 'tests-ingame.log', text .. '\n', -1)
    print(('^3[sw_tow]^7 in-game tests by %s:\n%s'):format(GetPlayerName(src) or src, text))
    return true
end)
