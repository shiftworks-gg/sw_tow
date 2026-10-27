local test = require 'test'
local World = require 'world'

test.suite('static › config check')

---The config as the server loads it, after `change` (a function that edits it).
local function problems(change)
    local w = World.new(ROOT)
    local config = w:module('config')
    if change then change(config) end
    return w:module('server.configcheck').run(config)
end

local function has(list, fragment)
    for _, line in ipairs(list) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

test.case('the shipped config.lua has no problems', function()
    local list = problems()
    test.eq(#list, 0, table.concat(list, '\n'))
end)

test.case('typical mistakes are named', function()
    local list = problems(function(c)
        c.garage.vehicles[1].method = 'flatbad'
        c.fees.companyShare = 6
        c.garage.platePrefix = 'TOOLONG'
        c.office.coords = require('vector').vec3(1, 2, 3)
        c.payout.account = 'wallet'
        c.contracts.minDistance = 5000
        c.ui.accent = 'orange'
        c.blockedClasses[99] = true
        c.yards.strawberry.releaseSpots = {}
        c.police.maxFine = 10.5
        c.sounds.winch = 'Move_U_D'
        c.sounds.secured = false
    end)
    for _, fragment in ipairs({
        'garage.vehicles.1.method', 'fees.companyShare', 'garage.platePrefix', 'office.coords: must be vec4',
        'payout.account', 'contracts.minDistance', 'ui.accent', 'blockedClasses: 99', 'yards.strawberry.releaseSpots',
        'police.maxFine: must be a whole number', 'sounds.winch',
    }) do
        test.truthy(has(list, fragment), 'names ' .. fragment .. '\n' .. table.concat(list, '\n'))
    end
end)

test.case('a missing section is reported, not crashed on', function()
    local list = problems(function(c) c.flatbed = nil; c.yards = nil end)
    test.truthy(has(list, 'flatbed.winch'))
    test.truthy(has(list, 'yards: needs at least one yard'))
end)

test.case('the server refuses to start with a broken config and says why', function()
    local w = World.new(ROOT, { config = function(c) c.payout.account = 'wallet' end })
    local ok, err = pcall(w.start, w)
    test.falsy(ok, 'start fails')
    test.truthy(tostring(err):find('config.lua has 1 problem', 1, true), tostring(err))
    test.truthy(has(w.errors, 'payout.account'), 'the problem is printed')
end)
