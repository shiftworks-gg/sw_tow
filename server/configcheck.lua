---Checks config.lua when the resource starts and names every problem in plain words, so a typo
---shows up in the console at once instead of as an error in the middle of a shift.

local checker = {}

---@param cfg table the config table
---@return string[] problems empty when the config is fine
function checker.run(cfg)
    local problems = {}

    local function problem(path, message)
        problems[#problems + 1] = ('%s: %s'):format(path, message)
    end

    local function get(path)
        local value = cfg
        for key in path:gmatch('[^.]+') do
            if type(value) ~= 'table' then return nil end
            value = value[tonumber(key) or key]
        end
        return value
    end

    local function number(path, min, max)
        local v = get(path)
        if type(v) ~= 'number' then return problem(path, 'must be a number') end
        if (min and v < min) or (max and v > max) then
            problem(path, ('must be between %s and %s, is %s'):format(min or '-∞', max or '∞', v))
        end
    end

    local function integer(path, min, max)
        local v = get(path)
        if math.type(v) ~= 'integer' then return problem(path, 'must be a whole number') end
        number(path, min, max)
    end

    local function text(path)
        local v = get(path)
        if type(v) ~= 'string' or v == '' then problem(path, 'must be a text in quotes') end
    end

    local function oneOf(path, options)
        local v = get(path)
        for _, option in ipairs(options) do
            if v == option then return end
        end
        problem(path, ('must be one of %s, is %s'):format(table.concat(options, ', '), tostring(v)))
    end

    local function vector(path, kind, optional)
        local v = get(path)
        if v == nil and optional then return end
        if type(v) ~= kind then
            problem(path, ('must be %s(...)'):format(kind == 'vector4' and 'vec4' or 'vec3'))
        end
    end

    local function boolean(path)
        if type(get(path)) ~= 'boolean' then problem(path, 'must be true or false') end
    end

    local function classes(path)
        local v = get(path)
        if type(v) ~= 'table' then return problem(path, 'must be a list like { [14] = true }') end
        for class in pairs(v) do
            if math.type(class) ~= 'integer' or class < 0 or class > 22 then
                problem(path, ('%s is not a vehicle class (0 to 22)'):format(tostring(class)))
            end
        end
    end

    local function zone(path)
        vector(path .. '.coords', 'vector3')
        vector(path .. '.size', 'vector3')
        local rotation = get(path .. '.rotation')
        if rotation ~= nil and type(rotation) ~= 'number' then problem(path .. '.rotation', 'must be a number') end
    end

    text('job')
    text('policeJobType')
    boolean('debug')

    boolean('ui.enabled')
    oneOf('ui.position', { 'right', 'left' })
    number('ui.top', 0, 90)
    number('ui.scale', 0.8, 1.3)
    if type(get('ui.accent')) ~= 'string' or not get('ui.accent'):match('^#%x%x%x%x%x%x$') then
        problem('ui.accent', 'must be a colour like \'#ff7a2e\'')
    end

    oneOf('adapters.garage', { 'auto', 'qbx_garages', 'qb-garages', 'none' })
    oneOf('adapters.keys', { 'auto', 'qbx_vehiclekeys', 'qb-vehiclekeys', 'none' })
    oneOf('adapters.banking', { 'auto', 'Renewed-Banking', 'qb-banking', 'none' })

    text('office.label')
    vector('office.coords', 'vector4')
    vector('office.size', 'vector3')
    if get('office.ped') ~= nil then
        text('office.ped.model')
        vector('office.ped.coords', 'vector4', true)
    end

    vector('garage.spawn', 'vector4')
    number('garage.returnDistance', 1)
    local prefix = get('garage.platePrefix')
    if type(prefix) ~= 'string' or not prefix:match('^[%u%d]+$') or #prefix > 4 then
        problem('garage.platePrefix', 'must be 1 to 4 capital letters or digits (plates have 8 characters)')
    end
    local vehicles = get('garage.vehicles')
    if type(vehicles) ~= 'table' or #vehicles == 0 then
        problem('garage.vehicles', 'needs at least one truck')
    else
        for i = 1, #vehicles do
            text(('garage.vehicles.%d.model'):format(i))
            text(('garage.vehicles.%d.label'):format(i))
            oneOf(('garage.vehicles.%d.method'):format(i), { 'flatbed', 'hook' })
        end
    end

    local yards = get('yards')
    if type(yards) ~= 'table' or next(yards) == nil then
        problem('yards', 'needs at least one yard')
    else
        for key in pairs(yards) do
            local path = 'yards.' .. tostring(key)
            if type(key) ~= 'string' or not key:match('^[%w_]+$') or #key > 24 then
                problem(path, 'the yard name must be letters, digits or _ (24 at most)')
            else
                text(path .. '.label')
                zone(path .. '.zone')
                vector(path .. '.counter', 'vector4', true)
                local spots = get(path .. '.releaseSpots')
                if type(spots) ~= 'table' or #spots == 0 then
                    problem(path .. '.releaseSpots', 'needs at least one vec4 spot')
                else
                    for i = 1, #spots do vector(('%s.releaseSpots.%d'):format(path, i), 'vector4') end
                end
            end
        end
    end

    vector('flatbed.winch', 'vector3')
    number('flatbed.bedFrontY')
    text('flatbed.ramp.model')
    boolean('flatbed.ramp.flip')
    boolean('flatbed.ramp.pair')
    number('flatbed.ramp.spacing', 0.5, 4)
    number('flatbed.winchRange', 3, 20)
    oneOf('flatbed.motion', { 'animated', 'physics' })
    number('flatbed.pullSpeed', 0.2, 5)
    number('flatbed.pullTimeout', 5)
    boolean('flatbed.rope')

    number('hook.range', 2, 15)

    boolean('sounds.enabled')
    for _, event in ipairs({ 'rampsDown', 'rampsUp', 'winch', 'secured', 'hookOn', 'hookOff' }) do
        local entry = get('sounds.' .. event)
        if entry ~= false and (type(entry) ~= 'table' or type(entry[1]) ~= 'string'
            or (entry[2] ~= false and type(entry[2]) ~= 'string')) then
            problem('sounds.' .. event, "must be { 'sound name', 'soundset' } or false")
        end
    end
    classes('blockedClasses')
    classes('orderOnlyClasses')

    text('calls.command')
    text('calls.cancelCommand')
    text('calls.listCommand')
    text('calls.listKey')
    number('calls.vehicleRange', 1)
    number('calls.acceptTimeout', 1)
    number('calls.deliverTimeout', 1)
    number('calls.cooldown', 0)
    integer('calls.maxOpen', 1)

    boolean('police.enabled')
    integer('police.maxFine', 0)
    integer('police.maxHoldHours', 0)
    integer('police.ordersPerHour', 1)
    text('police.fineAccount')

    boolean('contracts.enabled')
    integer('contracts.maxOpen', 0)
    number('contracts.interval', 10)
    number('contracts.minDistance', 0)
    number('contracts.maxDistance', 100)
    if type(get('contracts.minDistance')) == 'number' and type(get('contracts.maxDistance')) == 'number'
        and get('contracts.minDistance') >= get('contracts.maxDistance') then
        problem('contracts.minDistance', 'must be smaller than contracts.maxDistance')
    end
    number('contracts.spawnRadius', 50, 400)
    local models = get('contracts.models')
    if type(models) ~= 'table' or #models == 0 then problem('contracts.models', 'needs at least one model') end

    boolean('abandoned.enabled')
    number('abandoned.minutes', 1)
    number('abandoned.playerRadius', 5)
    boolean('abandoned.owned')
    integer('abandoned.maxOpen', 0)
    number('abandoned.scanInterval', 5)
    number('abandoned.payFactor', 0, 5)
    local ignore = get('abandoned.ignoreZones')
    if type(ignore) ~= 'table' then
        problem('abandoned.ignoreZones', 'must be a list (it can be empty: {})')
    else
        for i = 1, #ignore do zone(('abandoned.ignoreZones.%d'):format(i)) end
    end

    integer('payout.base', 0)
    integer('payout.perKm', 0)
    integer('payout.max', 0)
    oneOf('payout.account', { 'cash', 'bank' })
    number('payout.partnerShare', 0, 1)
    number('payout.maxSpeed', 5)

    integer('fees.base', 0)
    local byClass = get('fees.byClass')
    if type(byClass) ~= 'table' then
        problem('fees.byClass', 'must be a list like { [7] = 450 }')
    else
        for class, amount in pairs(byClass) do
            if math.type(class) ~= 'integer' or class < 0 or class > 22 then
                problem('fees.byClass', ('%s is not a vehicle class (0 to 22)'):format(tostring(class)))
            elseif math.type(amount) ~= 'integer' or amount < 0 then
                problem(('fees.byClass.%d'):format(class), 'must be a whole number of dollars')
            end
        end
    end
    integer('fees.perDay', 0)
    number('fees.freeHours', 0)
    number('fees.companyShare', 0, 1)
    text('fees.companyAccount')

    local limits = get('limits')
    if type(limits) ~= 'table' or type(limits.default) ~= 'number' then
        problem('limits.default', 'must be a number of milliseconds')
    else
        for key, value in pairs(limits) do
            if type(value) ~= 'number' or value < 0 then problem('limits.' .. tostring(key), 'must be milliseconds (0 or more)') end
        end
    end

    table.sort(problems)
    return problems
end

return checker
