---CfxLua vector types for plain Lua 5.4: vec2/vec3/vec4 with arithmetic, length (#), equality,
---swizzles (v.xy, v.xyz) and norm(). `vector.type` reports 'vector2'/'vector3'/'vector4' like CfxLua.
local vector = {}

local FIELDS = { 'x', 'y', 'z', 'w' }
local INDEX = { x = 1, y = 2, z = 3, w = 4 }
local metas = {}
local make

local function components(v) return rawget(v, 'n') end

local function build(n, values)
    local v = { n = n }
    for i = 1, n do v[FIELDS[i]] = values[i] end
    return setmetatable(v, metas[n])
end

local function isVector(v)
    local mt = getmetatable(v)
    return mt ~= nil and mt.__vector == true
end

local function binary(op)
    return function(a, b)
        local n, out = 0, {}
        if isVector(a) and isVector(b) then
            n = math.min(components(a), components(b))
            for i = 1, n do out[i] = op(a[FIELDS[i]], b[FIELDS[i]]) end
        elseif isVector(a) then
            n = components(a)
            for i = 1, n do out[i] = op(a[FIELDS[i]], b) end
        else
            n = components(b)
            for i = 1, n do out[i] = op(a, b[FIELDS[i]]) end
        end
        return build(n, out)
    end
end

for n = 2, 4 do
    local mt = { __vector = true, __name = 'vector' .. n }
    mt.__index = function(v, key)
        if type(key) ~= 'string' then return nil end
        if #key > 1 and key:match('^[xyzw]+$') then
            local out = {}
            for i = 1, #key do
                local value = rawget(v, key:sub(i, i))
                if value == nil then return nil end
                out[i] = value
            end
            if #out == 1 then return out[1] end
            return build(#out, out)
        end
        return nil
    end
    mt.__add = binary(function(a, b) return a + b end)
    mt.__sub = binary(function(a, b) return a - b end)
    mt.__mul = binary(function(a, b) return a * b end)
    mt.__div = binary(function(a, b) return a / b end)
    mt.__unm = function(v)
        local out = {}
        for i = 1, components(v) do out[i] = -v[FIELDS[i]] end
        return build(components(v), out)
    end
    mt.__len = function(v)
        local sum = 0.0
        for i = 1, components(v) do sum = sum + v[FIELDS[i]] ^ 2 end
        return math.sqrt(sum)
    end
    mt.__eq = function(a, b)
        if not isVector(a) or not isVector(b) or components(a) ~= components(b) then return false end
        for i = 1, components(a) do
            if a[FIELDS[i]] ~= b[FIELDS[i]] then return false end
        end
        return true
    end
    mt.__tostring = function(v)
        local parts = {}
        for i = 1, components(v) do parts[i] = string.format('%.3f', v[FIELDS[i]]) end
        return ('vector%d(%s)'):format(components(v), table.concat(parts, ', '))
    end
    metas[n] = mt
end

make = function(n)
    return function(...)
        local args = { ... }
        local values = {}
        for i = 1, n do values[i] = (args[i] or 0) + 0.0 end
        return build(n, values)
    end
end

vector.vec2, vector.vec3, vector.vec4 = make(2), make(3), make(4)

---@param v table
---@return table
function vector.norm(v)
    local length = #v
    if length == 0 then return v end
    return v / length
end

---type() that knows vectors, as in CfxLua.
function vector.type(value)
    if isVector(value) then return 'vector' .. components(value) end
    return type(value)
end

vector.isVector = isVector
vector.INDEX = INDEX

return vector
