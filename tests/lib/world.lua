---A fake FiveM server for the test suite. It runs the real server modules of sw_tow (server/*.lua)
---against simulated players, peds, vehicles, state bags, events, threads and a clock, so whole flows
---(clock in, load, deliver, pay, release) can be checked in milliseconds without the game.
---
---Replaced by fakes: the framework bridge (bridge.loader), the garage/keys/banking integrations
---(bridge.integrations) and the database layer (server.storage). Those are thin and are checked on a
---real server by `swtow_selftest` instead.
local vector = require 'vector'
local json = require 'json'

local World = {}
World.__index = World

local BASE_TIME = 1767225600 -- 2026-01-01 00:00 UTC

---Jenkins one-at-a-time, as GetHashKey/joaat (unsigned).
---@param text string
---@return integer
local function joaat(text)
    local hash = 0
    text = text:lower()
    for i = 1, #text do
        hash = (hash + text:byte(i)) & 0xFFFFFFFF
        hash = (hash + (hash << 10)) & 0xFFFFFFFF
        hash = hash ~ (hash >> 6)
    end
    hash = (hash + (hash << 3)) & 0xFFFFFFFF
    hash = hash ~ (hash >> 11)
    hash = (hash + (hash << 15)) & 0xFFFFFFFF
    return hash
end
World.joaat = joaat

-- Vehicle classes the fake framework reports, by model name.
local CLASSES = {
    asea = 1, premier = 1, sultan = 1, baller = 2, zentorno = 7, adder = 7, blista = 0, panto = 0,
    police = 18, police2 = 18, barracks = 19, dinghy = 14, maverick = 15, flatbed = 20, towtruck = 11,
    bison = 11, burrito3 = 12,
}

World.OFFICE = vector.vec3(472.18, -1310.78, 29.22)
World.TRUCK_SPAWN = vector.vec3(489.65, -1331.82, 29.33)
World.YARD = vector.vec3(408.38, -1638.62, 29.38)       -- centre of the hand-over bay
World.COUNTER = vector.vec3(402.97, -1628.89, 29.29)    -- the yard's release counter
World.RELEASE = { vector.vec3(395.58, -1645.16, 29.29), vector.vec3(397.96, -1647.01, 29.29) }
World.FAR = vector.vec3(1200.0, -1300.0, 35.0)   -- far from the office and the yard

local function newBag()
    local values = {}
    local bag = {}
    bag.set = function(_, key, value) values[key] = value end
    return setmetatable(bag, {
        __index = function(_, key) return values[key] end,
        __newindex = function(_, key, value) values[key] = value end,
    })
end

local function copy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

---@param root string resource folder
---@param options? { adapters?: table, convars?: table, files?: table, config?: fun(config: table) }
function World.new(root, options)
    options = options or {}
    math.randomseed(42)
    local w = setmetatable({
        root = root,
        timer = 0,
        time = BASE_TIME,
        entities = {},
        nextEntity = 100,
        nextNet = 1,
        players = {},
        bags = {},
        playerBags = {},
        handlers = {},
        callbacks = {},
        commands = {},
        exported = {},
        clientEvents = {},
        threads = {},
        errors = {},
        output = {},
        files = options.files or {},
        convars = options.convars or {},
        adapters = options.adapters or {},
        configure = options.config,
        hooks = { unload = {}, job = {} },
        -- Fake database and integrations.
        impoundRows = {},
        nextImpoundId = 0,
        deliveryLog = {},
        owed = {},
        garageVehicles = {},
        nextGarageId = 0,
        keysGiven = {},
        deposits = {},
        failNextSpawn = false,
        failGarageStore = false,
    }, World)
    w.env = w:buildEnv()
    return w
end

-- Clock and threads -------------------------------------------------------------------------------

function World:setTimer(ms)
    self.timer = ms
    self.time = BASE_TIME + ms // 1000
end

function World:recordError(message)
    self.errors[#self.errors + 1] = message
end

function World:resume(thread)
    local ok, kind, ms = coroutine.resume(thread.co)
    if not ok then
        thread.dead = true
        self:recordError('thread error: ' .. tostring(kind) .. '\n' .. debug.traceback(thread.co))
        return
    end
    if coroutine.status(thread.co) == 'dead' then
        thread.dead = true
        return
    end
    assert(kind == 'wait', 'a thread yielded something other than Wait')
    thread.wake = self.timer + math.max(0, ms or 0)
end

function World:spawnThread(fn)
    local thread = { co = coroutine.create(fn), wake = self.timer }
    self.threads[#self.threads + 1] = thread
    self:resume(thread)
end

---Runs every thread that wakes within the next `seconds`, in time order.
---@param seconds number
function World:advance(seconds)
    local target = self.timer + math.floor(seconds * 1000)
    local guard = 0
    while true do
        local nextThread
        for _, thread in ipairs(self.threads) do
            if not thread.dead and thread.wake <= target and (not nextThread or thread.wake < nextThread.wake) then
                nextThread = thread
            end
        end
        if not nextThread then break end
        guard = guard + 1
        assert(guard < 200000, 'threads do not yield time (Wait(0) loop?)')
        if nextThread.wake > self.timer then self:setTimer(nextThread.wake) end
        self:resume(nextThread)
    end
    self:setTimer(target)
    local alive = {}
    for _, thread in ipairs(self.threads) do
        if not thread.dead then alive[#alive + 1] = thread end
    end
    self.threads = alive
end

---Runs `fn` like a callback or event handler: in its own coroutine; any Wait inside only moves the clock.
function World:runNow(fn, ...)
    local co = coroutine.create(fn)
    local results = table.pack(coroutine.resume(co, ...))
    local guard = 0
    while true do
        if not results[1] then
            error(('handler error: %s\n%s'):format(tostring(results[2]), debug.traceback(co)), 0)
        end
        if coroutine.status(co) == 'dead' then
            return table.unpack(results, 2, results.n)
        end
        guard = guard + 1
        assert(guard < 100000, 'handler waits forever')
        self:setTimer(self.timer + math.max(0, results[3] or 0))
        results = table.pack(coroutine.resume(co))
    end
end

-- Entities ----------------------------------------------------------------------------------------

---@param spec { model: string, coords: table, heading?: number, plate?: string, owner?: integer }
---@return integer entity
function World:createVehicle(spec)
    local id = self.nextEntity
    self.nextEntity = id + 1
    local net = self.nextNet
    self.nextNet = net + 1
    local model = type(spec.model) == 'string' and joaat(spec.model) or spec.model
    self.entities[id] = {
        id = id,
        type = 2,
        net = net,
        model = model,
        modelName = type(spec.model) == 'string' and spec.model or nil,
        coords = vector.vec3(spec.coords.x, spec.coords.y, spec.coords.z),
        heading = spec.heading or spec.coords.w or 0.0,
        plate = spec.plate or ('NPC%05d'):format(id),
        seats = {},
        owner = spec.owner or -1,
        body = 1000.0,
        engine = 1000.0,
        locked = 1,
    }
    return id
end

function World:entity(id)
    return self.entities[id]
end

function World:exists(id)
    return self.entities[id] ~= nil
end

function World:removeEntity(id)
    local e = self.entities[id]
    if not e then return end
    for _, src in pairs(e.seats) do
        local player = self.players[self:playerOfPed(src)]
        if player then player.vehicle = nil end
    end
    self.entities[id] = nil
    self:trigger('entityRemoved', nil, id)
end

---@param id integer
---@param coords table vec3
function World:move(id, coords)
    local e = assert(self.entities[id], 'no such entity')
    e.coords = vector.vec3(coords.x, coords.y, coords.z)
end

-- Players -----------------------------------------------------------------------------------------

---@param spec? { job?: string, jobType?: string, onDuty?: boolean, coords?: table, cash?: integer, bank?: integer, name?: string }
---@return integer src
function World:addPlayer(spec)
    spec = spec or {}
    local src = #self.players + 1
    while self.players[src] do src = src + 1 end
    local ped = self.nextEntity
    self.nextEntity = ped + 1
    local coords = spec.coords or World.OFFICE
    self.entities[ped] = { id = ped, type = 1, isPlayer = true, src = src, coords = vector.vec3(coords.x, coords.y, coords.z), seats = {} }
    self.players[src] = {
        src = src,
        ped = ped,
        name = spec.name or ('Player' .. src),
        citizenid = spec.citizenid or ('CID' .. src),
        job = { name = spec.job or 'unemployed', type = spec.jobType, grade = 0, onDuty = spec.onDuty ~= false, isBoss = false },
        money = { cash = spec.cash or 0, bank = spec.bank or 0 },
    }
    return src
end

function World:playerOfPed(ped)
    local e = self.entities[ped]
    return e and e.src
end

function World:ped(src)
    return self.players[src].ped
end

---Moves a player on foot (out of any vehicle) to a point.
function World:teleport(src, coords)
    self:leaveVehicle(src)
    self:move(self:ped(src), coords)
end

---@param src integer
---@param vehicle integer
---@param seat? integer -1 = driver
function World:enterVehicle(src, vehicle, seat)
    local player = self.players[src]
    local e = assert(self.entities[vehicle], 'no such vehicle')
    self:leaveVehicle(src)
    e.seats[seat or -1] = player.ped
    player.vehicle, player.lastVehicle = vehicle, vehicle
    self:move(player.ped, e.coords)
end

function World:leaveVehicle(src)
    local player = self.players[src]
    local vehicle = player.vehicle and self.entities[player.vehicle]
    if vehicle then
        for seat, ped in pairs(vehicle.seats) do
            if ped == player.ped then vehicle.seats[seat] = nil end
        end
        self:move(player.ped, vehicle.coords + vector.vec3(2.0, 0.0, 0.0))
    end
    player.vehicle = nil
end

---@param src integer
---@param name string
---@param jobType? string
---@param onDuty? boolean
function World:setJob(src, name, jobType, onDuty)
    local player = self.players[src]
    player.job = { name = name, type = jobType, grade = 0, onDuty = onDuty ~= false, isBoss = false }
    for _, cb in ipairs(self.hooks.job) do self:runNow(cb, src) end
end

function World:logout(src)
    for _, cb in ipairs(self.hooks.unload) do self:runNow(cb, src) end
end

function World:drop(src)
    self:leaveVehicle(src)
    self:trigger('playerDropped', src, 'left')
    self.entities[self.players[src].ped] = nil
    self.players[src] = nil
end

---@param src integer
function World:money(src, account)
    return self.players[src].money[account]
end

-- Events, callbacks, commands ---------------------------------------------------------------------

function World:trigger(name, src, ...)
    local list = self.handlers[name]
    if not list then return end
    for _, fn in ipairs(list) do
        self.env.source = src
        self:runNow(fn, ...)
    end
    self.env.source = nil
end

---Calls a lib.callback handler the way a client would.
---@param name string e.g. 'sw_tow:server:clockIn'
---@param src integer
function World:call(name, src, ...)
    local fn = assert(self.callbacks[name], 'no callback ' .. name)
    return self:runNow(fn, src, ...)
end

---Runs a chat command as a player.
function World:command(name, src, args)
    local fn = assert(self.commands[name], 'no command ' .. name)
    return self:runNow(fn, src, args or {}, '')
end

---Client events sent to a player, optionally only those with one name.
---@return { name: string, args: table }[]
function World:sent(src, name)
    local list = {}
    for _, event in ipairs(self.clientEvents) do
        if (event.target == src or event.target == -1) and (not name or event.name == name) then list[#list + 1] = event end
    end
    return list
end

---Text of the notifications a player got (locale keys with their arguments, see `locale` below).
---@return string[]
function World:notices(src)
    local list = {}
    for _, event in ipairs(self:sent(src, 'sw_tow:client:notify')) do list[#list + 1] = event.args[1] end
    return list
end

---Did the player get a notification starting with this locale key?
function World:noticed(src, key)
    for _, text in ipairs(self:notices(src)) do
        if text == key or text:sub(1, #key + 1) == key .. '|' then return true end
    end
    return false
end

function World:clearSent()
    self.clientEvents = {}
end

-- Garage (fake player_vehicles) -------------------------------------------------------------------

---Adds an owned vehicle to the fake garage and spawns it.
---@param src integer owner
---@param spec { model?: string, coords: table, plate?: string, heading?: number }
---@return integer entity, integer vehicleId
function World:ownedVehicle(src, spec)
    self.nextGarageId = self.nextGarageId + 1
    local id = self.nextGarageId
    local plate = spec.plate or ('OWN%05d'):format(id)
    local model = spec.model or 'sultan'
    self.garageVehicles[id] = { id = id, owner = self.players[src].citizenid, model = model, plate = plate, state = 0 }
    local entity = self:createVehicle({ model = model, coords = spec.coords, heading = spec.heading, plate = plate })
    return entity, id
end

function World:garageVehicle(id)
    return self.garageVehicles[id]
end

-- Modules -----------------------------------------------------------------------------------------

function World:fakeFramework()
    local w = self
    local framework = { name = 'qbox' }
    local function player(src) return w.players[src] end

    function framework.getCitizenId(src)
        local p = player(src)
        return p and p.citizenid
    end

    function framework.getSourceByCitizenId(citizenid)
        for src, p in pairs(w.players) do
            if p.citizenid == citizenid then return src end
        end
    end

    function framework.getName(src)
        local p = player(src)
        return p and p.name or ('#' .. tostring(src))
    end

    function framework.getJob(src)
        local p = player(src)
        return p and copy(p.job)
    end

    function framework.setDuty(src, onDuty)
        local p = player(src)
        if p then p.job.onDuty = onDuty end
    end

    function framework.getMoney(src, account)
        local p = player(src)
        return p and p.money[account] or 0
    end

    function framework.addMoney(src, account, amount)
        local p = player(src)
        if not p then return false end
        p.money[account] = p.money[account] + amount
        return true
    end

    function framework.removeMoney(src, account, amount)
        local p = player(src)
        if not p or p.money[account] < amount then return false end
        p.money[account] = p.money[account] - amount
        return true
    end

    function framework.spawnVehicle(model, coords, props)
        if w.failNextSpawn then
            w.failNextSpawn = false
            error('spawn failed (test)', 0)
        end
        local entity = w:createVehicle({ model = model, coords = coords, heading = coords.w, plate = props and props.plate })
        return w.entities[entity].net, entity
    end

    function framework.deleteVehicle(entity)
        w:removeEntity(entity)
    end

    function framework.getPlate(entity)
        local e = w.entities[entity]
        return e and (e.plate:match('^%s*(.-)%s*$')) or ''
    end

    function framework.getVehicleClass(model)
        for name, class in pairs(CLASSES) do
            if joaat(name) == model then return class end
        end
    end

    function framework.onPlayerUnload(cb) w.hooks.unload[#w.hooks.unload + 1] = cb end
    function framework.onJobUpdate(cb)
        w.hooks.job[#w.hooks.job + 1] = function(src) cb(src, framework.getJob(src)) end
    end

    return framework
end

function World:fakeIntegrations()
    local w = self
    local names = {
        garage = w.adapters.garage or 'qbx_garages',
        keys = w.adapters.keys or 'qbx_vehiclekeys',
        banking = w.adapters.banking or 'Renewed-Banking',
    }

    local garage
    if names.garage == 'none' then
        garage = {
            getVehicleId = function() return nil end,
            getVehicle = function() return nil end,
            store = function() return false end,
            markOut = function() return false end,
            protect = function() end,
        }
    else
        garage = {
            getVehicleId = function(_, plate)
                for id, v in pairs(w.garageVehicles) do
                    if v.plate == plate then return id end
                end
            end,
            getVehicle = function(id)
                local v = w.garageVehicles[id]
                if not v then return end
                return { id = v.id, owner = v.owner, model = v.model, props = { model = joaat(v.model), plate = v.plate } }
            end,
            store = function(_, id, yard, fee)
                if w.failGarageStore then return false end
                local v = w.garageVehicles[id]
                v.state, v.garage, v.depotPrice = 2, 'sw_tow_' .. yard, fee
                return true
            end,
            markOut = function(_, id)
                local v = w.garageVehicles[id]
                v.state, v.depotPrice = 0, 0
                return true
            end,
            protect = function(isHeld) w.isHeld = isHeld end,
        }
    end

    return {
        names = names,
        garage = garage,
        keys = { give = function(src, entity) w.keysGiven[#w.keysGiven + 1] = { src = src, entity = entity } end },
        banking = {
            deposit = function(account, amount, reason)
                if names.banking == 'none' then return false end
                w.deposits[#w.deposits + 1] = { account = account, amount = amount, reason = reason }
                return true
            end,
        },
    }
end

---In-memory server.storage with the same contract as the SQL version: rows come back as copies.
function World:fakeStorage()
    local w = self
    local storage = {}

    local function active(row) return row.released_at == nil end
    local function list(filter)
        local out = {}
        for _, row in pairs(w.impoundRows) do
            if active(row) and filter(row) then out[#out + 1] = copy(row) end
        end
        table.sort(out, function(a, b) return a.stored_at < b.stored_at or (a.stored_at == b.stored_at and a.id < b.id) end)
        return out
    end

    function storage.migrate() end

    function storage.insertImpound(record)
        w.nextImpoundId = w.nextImpoundId + 1
        local id = w.nextImpoundId
        w.impoundRows[id] = {
            id = id,
            yard = record.yard,
            plate = record.plate,
            vehicle_id = record.vehicle_id,
            owner = record.owner,
            model = record.model,
            reason = record.reason,
            note = record.note,
            fine = record.fine or 0,
            tow_charge = record.tow_charge or 0,
            police_hold = record.police_hold and 1 or 0,
            hold_until = record.hold_until,
            towed_by = record.towed_by,
            stored_at = w.time,
        }
        return id
    end

    function storage.deleteImpound(id)
        local row = w.impoundRows[id]
        if row and active(row) then w.impoundRows[id] = nil end
    end

    function storage.heldInYard(yard)
        return list(function(row) return row.yard == yard and row.police_hold == 1 end)
    end

    function storage.liftHold(id)
        local row = w.impoundRows[id]
        if not row or not active(row) then return false end
        row.police_hold, row.hold_until = 0, nil
        return true
    end

    function storage.allActive()
        return list(function() return true end)
    end

    function storage.getActive(id)
        local row = w.impoundRows[id]
        return row and active(row) and copy(row) or nil
    end

    function storage.activeForOwner(owner, yard)
        return list(function(row) return row.owner == owner and row.yard == yard end)
    end

    function storage.markReleased(id, releasedBy, paid)
        local row = w.impoundRows[id]
        if not row or not active(row) then return false end
        row.released_at, row.released_by, row.paid = w.time, releasedBy, paid
        return true
    end

    function storage.logDelivery(citizenid, callType, payout, distance)
        w.deliveryLog[#w.deliveryLog + 1] = { citizenid = citizenid, call_type = callType, payout = payout, distance_m = math.floor(distance) }
    end

    function storage.addOwed(citizenid, amount)
        if amount <= 0 then return end
        w.owed[citizenid] = (w.owed[citizenid] or 0) + amount
    end

    function storage.owed(citizenid)
        return w.owed[citizenid] or 0
    end

    function storage.takeOwed(citizenid)
        local amount = w.owed[citizenid] or 0
        w.owed[citizenid] = 0
        return amount
    end

    return storage
end

function World:buildEnv()
    local w = self
    local env = {}
    setmetatable(env, { __index = _G })

    local overrides = {
        ['bridge.loader'] = function() return w:fakeFramework() end,
        ['bridge.integrations'] = function() return w:fakeIntegrations() end,
        ['server.storage'] = function() return w:fakeStorage() end,
    }
    local loaded = {}
    local loading = {}

    function env.require(name)
        if loaded[name] ~= nil then return loaded[name] end
        if overrides[name] then
            loaded[name] = overrides[name]()
            return loaded[name]
        end
        assert(not loading[name], 'circular require: ' .. name)
        loading[name] = true
        local path = w.root .. '/' .. name:gsub('%.', '/') .. '.lua'
        local chunk, err = loadfile(path, 't', env)
        if not chunk then error(err, 2) end
        local result = chunk()
        loading[name] = nil
        loaded[name] = result == nil and true or result
        return loaded[name]
    end

    -- Lua with CfxLua's vector type.
    env.type = vector.type
    env.vec2, env.vec3, env.vec4 = vector.vec2, vector.vec3, vector.vec4
    env.vector2, env.vector3, env.vector4 = vector.vec2, vector.vec3, vector.vec4
    env.norm = vector.norm
    env.json = json
    env.joaat = joaat
    env.GetHashKey = joaat
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        w.output[#w.output + 1] = table.concat(parts, ' ')
    end
    env.os = setmetatable({
        time = function(t) if t then return os.time(t) end return w.time end,
        date = function(fmt, t) return os.date(fmt, t or w.time) end,
    }, { __index = os })

    -- Threads.
    env.CreateThread = function(fn) w:spawnThread(fn) end
    env.Wait = function(ms)
        local _, main = coroutine.running()
        if main then error('Wait called outside a thread', 2) end
        coroutine.yield('wait', ms)
    end
    env.SetTimeout = function(ms, fn)
        w:spawnThread(function()
            env.Wait(ms)
            fn()
        end)
    end
    env.GetGameTimer = function() return w.timer end

    -- Resource and convars.
    env.cache = { resource = 'sw_tow' }
    env.IsDuplicityVersion = function() return true end
    env.GetCurrentResourceName = function() return 'sw_tow' end
    env.GetResourceState = function(name) return (w.adapters.running or {})[name] and 'started' or 'missing' end
    env.GetConvar = function(name, default) return w.convars[name] or default end
    env.GetConvarInt = function(name, default) return tonumber(w.convars[name]) or default end
    env.GetResourceMetadata = function(_, key)
        if key == 'version' then return '1.0.0' end
        if key == 'repository' then return '' end
    end
    env.LoadResourceFile = function(_, path) return w.files[path] end
    env.SaveResourceFile = function(_, path, data)
        w.files[path] = data
        return true
    end
    env.PerformHttpRequest = function() end
    env.RegisterCommand = function(name, fn) w.commands[name] = function(src, args) return fn(src, args, '') end end

    -- Events.
    env.AddEventHandler = function(name, fn)
        w.handlers[name] = w.handlers[name] or {}
        table.insert(w.handlers[name], fn)
    end
    env.RegisterNetEvent = function(name, fn) if fn then env.AddEventHandler(name, fn) end end
    env.TriggerEvent = function(name, ...) w:trigger(name, nil, ...) end
    env.TriggerClientEvent = function(name, target, ...)
        w.clientEvents[#w.clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
    end
    env.exports = setmetatable({}, {
        __call = function(_, name, fn) w.exported[name] = fn end,
        __index = function(_, resource) error('unexpected export call to ' .. tostring(resource), 2) end,
    })

    -- State bags.
    env.Entity = function(entity)
        w.bags[entity] = w.bags[entity] or newBag()
        return { state = w.bags[entity] }
    end
    env.Player = function(src)
        src = tonumber(src)
        w.playerBags[src] = w.playerBags[src] or newBag()
        return { state = w.playerBags[src] }
    end

    -- Natives.
    env.GetPlayers = function()
        local list = {}
        for src in pairs(w.players) do list[#list + 1] = tostring(src) end
        table.sort(list)
        return list
    end
    env.GetPlayerName = function(src)
        local p = w.players[tonumber(src)]
        return p and p.name
    end
    env.GetPlayerPed = function(src)
        local p = w.players[tonumber(src)]
        return p and p.ped or 0
    end
    env.DoesEntityExist = function(id) return w.entities[id] ~= nil end
    env.GetEntityType = function(id)
        local e = w.entities[id]
        return e and e.type or 0
    end
    env.GetEntityCoords = function(id)
        local e = w.entities[id]
        if not e then return vector.vec3(0, 0, 0) end
        if e.type == 1 then
            local p = w.players[e.src]
            if p and p.vehicle and w.entities[p.vehicle] then return w.entities[p.vehicle].coords end
        end
        return e.coords
    end
    env.GetEntityAttachedTo = function(id)
        local e = w.entities[id]
        return e and e.attachedTo or 0
    end
    env.GetEntityHeading = function(id)
        local e = w.entities[id]
        return e and e.heading or 0.0
    end
    env.GetEntityModel = function(id)
        local e = w.entities[id]
        return e and e.model or 0
    end
    env.NetworkGetEntityFromNetworkId = function(net)
        for id, e in pairs(w.entities) do
            if e.net == net then return id end
        end
        return 0
    end
    env.NetworkGetNetworkIdFromEntity = function(id)
        local e = w.entities[id]
        return e and e.net or 0
    end
    env.NetworkGetEntityOwner = function(id)
        local e = w.entities[id]
        if not e then return -1 end
        if e.type == 1 then return e.src end
        return e.owner
    end
    env.GetPedInVehicleSeat = function(vehicle, seat)
        local e = w.entities[vehicle]
        return e and e.seats[seat] or 0
    end
    env.IsPedAPlayer = function(ped)
        local e = w.entities[ped]
        return e ~= nil and e.isPlayer == true
    end
    env.GetVehiclePedIsIn = function(ped, last)
        local p = w.players[w:playerOfPed(ped) or -1]
        if not p then return 0 end
        if p.vehicle and w.entities[p.vehicle] then return p.vehicle end
        if last and p.lastVehicle and w.entities[p.lastVehicle] then return p.lastVehicle end
        return 0
    end
    env.GetAllVehicles = function()
        local list = {}
        for id, e in pairs(w.entities) do
            if e.type == 2 then list[#list + 1] = id end
        end
        table.sort(list)
        return list
    end
    env.DeleteEntity = function(id) w:removeEntity(id) end
    env.SetVehicleDoorsLocked = function(id, state)
        local e = w.entities[id]
        if e then e.locked = state end
    end
    env.GetVehicleBodyHealth = function(id) return w.entities[id].body end
    env.GetVehicleEngineHealth = function(id) return w.entities[id].engine end
    env.GetVehicleNumberPlateText = function(id)
        local e = w.entities[id]
        return e and e.plate or ''
    end

    -- MySQL is only touched through server.storage (faked) and MySQL.ready.
    env.MySQL = { ready = function(fn) fn() end }

    -- ox_lib.
    local function logger(level)
        return function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
            local text = table.concat(parts, ' ')
            w.output[#w.output + 1] = ('[%s] %s'):format(level, text)
            if level == 'error' then w:recordError(text) end
        end
    end
    env.lib = {
        print = { info = logger('info'), warn = logger('warn'), error = logger('error'), debug = logger('debug'), verbose = logger('verbose') },
        logger = function() end,
        checkDependency = function() return true end,
        callback = {
            register = function(name, fn) w.callbacks[name] = fn end,
        },
        addCommand = function(names, _, fn)
            if type(names) == 'string' then names = { names } end
            for _, name in ipairs(names) do w.commands[name] = fn end
        end,
        getClosestVehicle = function(coords, maxDistance, includePlayers)
            local best, bestDistance, bestCoords
            for id, e in pairs(w.entities) do
                if e.type == 2 then
                    local occupied = next(e.seats) ~= nil
                    local d = #(e.coords - coords)
                    if d <= (maxDistance or 2.0) and (includePlayers or not occupied) and (not bestDistance or d < bestDistance) then
                        best, bestDistance, bestCoords = id, d, e.coords
                    end
                end
            end
            return best, bestCoords
        end,
    }

    -- ox_lib's locale(): tests see the key and its arguments, e.g. "impound.paid|$192".
    env.locale = function(key, ...)
        local n = select('#', ...)
        if n == 0 then return key end
        local parts = { key }
        for i = 1, n do parts[#parts + 1] = tostring((select(i, ...))) end
        return table.concat(parts, '|')
    end

    return env
end

---Loads the server the way fxmanifest does: server/main.lua requires everything else.
---`options.config(config)` (World.new) may change config values first.
function World:start()
    self:runNow(function()
        local config = self.env.require('config')
        if self.configure then self.configure(config) end
        self.env.require('server.main')
    end)
    return self
end

---A loaded module of the resource (the same instance the server uses).
---@param name string e.g. 'server.calls'
function World:module(name)
    return self.env.require(name)
end

---Every error logged with lib.print.error or thrown in a thread so far.
function World:assertNoErrors()
    if #self.errors > 0 then
        error('errors were logged:\n' .. table.concat(self.errors, '\n'), 2)
    end
end

return World
