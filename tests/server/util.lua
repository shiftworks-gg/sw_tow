local test = require 'test'
local vector = require 'vector'

test.suite('shared › util')

local function util()
    return newWorld():module('shared.util')
end

test.case('money is formatted as $1,240', function()
    local u = util()
    test.eq(u.money(0), '$0')
    test.eq(u.money(999), '$999')
    test.eq(u.money(1240), '$1,240')
    test.eq(u.money(1234567), '$1,234,567')
    test.eq(u.money(-1500), '-$1,500')
    test.eq(u.money(12.9), '$12')
end)

test.case('plates are trimmed', function()
    local u = util()
    test.eq(u.trimPlate('  AB 123  '), 'AB 123')
    test.eq(u.trimPlate(nil), '')
end)

test.case('a point is inside a rotated box zone', function()
    local u = util()
    local zone = { coords = vector.vec3(0, 0, 0), size = vector.vec3(10, 2, 4), rotation = 0.0 }
    test.truthy(u.inZone(vector.vec3(4.9, 0.9, 1.9), zone), 'inside')
    test.falsy(u.inZone(vector.vec3(5.1, 0, 0), zone), 'outside along x')
    test.falsy(u.inZone(vector.vec3(0, 0, 2.1), zone), 'too high')
    zone.rotation = 90.0
    test.truthy(u.inZone(vector.vec3(0, 4.9, 0), zone), 'turned 90°: long side along y')
    test.falsy(u.inZone(vector.vec3(4.9, 0, 0), zone), 'turned 90°: short side along x')
end)

test.case('integers are told apart from floats', function()
    local u = util()
    test.truthy(u.isInteger(3))
    test.falsy(u.isInteger(3.0))
    test.falsy(u.isInteger('3'))
end)
