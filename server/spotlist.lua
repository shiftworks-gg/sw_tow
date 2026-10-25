---Roadside spots for NPC contracts: the bundled list plus data/spots.generated.lua when it exists.
local FILE = 'data/spots.generated.lua'

local bundled = require 'data.spots'

---Reads the generated file. It may only build vectors, nothing else is in reach.
---Hand-added vec3 lines are fine; they get a random heading like the bundled spots.
---@return (vector3|vector4)[]
local function readGenerated()
    local text = LoadResourceFile(cache.resource, FILE)
    if not text then return {} end
    local chunk, err = load(text, '@' .. FILE, 't', { vec3 = vec3, vec4 = vec4 })
    if not chunk then
        lib.print.error(('%s is broken and was ignored: %s'):format(FILE, err))
        return {}
    end
    local ok, list = pcall(chunk)
    if not ok or type(list) ~= 'table' then
        lib.print.error(('%s is broken and was ignored: %s'):format(FILE, ok and 'no list returned' or list))
        return {}
    end
    local spots = {}
    for i = 1, #list do
        local kind = type(list[i])
        if kind == 'vector3' or kind == 'vector4' then spots[#spots + 1] = list[i] end
    end
    return spots
end

local all, headings = {}, {}
for i = 1, #bundled do all[#all + 1] = bundled[i] end
local generated = readGenerated()
for i = 1, #generated do
    local spot = generated[i]
    all[#all + 1] = spot.xyz
    if type(spot) == 'vector4' then headings[#all] = spot.w end
end

return {
    bundled = bundled,   ---@type vector3[]
    all = all,           ---@type vector3[] Every spot in use since the resource started.
    headings = headings, ---@type table<integer, number> Road heading by index; bundled spots have none.
    generatedCount = #generated,
    readGenerated = readGenerated,
}
