---Picks the framework bridge for this side (client or server) from the resources that are running.
---Everything else in sw_tow talks to the bridge only, never to a framework directly.

local frameworks = {
    { name = 'qbox', resource = 'qbx_core' },  -- First: qbx_core also provides 'qb-core'.
    { name = 'qb', resource = 'qb-core' },
    { name = 'esx', resource = 'es_extended' },
}

local function detect()
    for i = 1, #frameworks do
        local state = GetResourceState(frameworks[i].resource)
        if state == 'started' or state == 'starting' then
            return frameworks[i].name
        end
    end
end

local name = detect()
if not name then
    error('sw_tow: no supported framework is running. Start Qbox or QBCore before sw_tow.', 0)
end

local side = IsDuplicityVersion() and 'server' or 'client'
local ok, bridge = pcall(require, ('bridge.%s.%s'):format(name, side))
if not ok then
    error(('sw_tow: the %s bridge is not available in this version (%s)'):format(name, bridge), 0)
end

bridge.name = name
return bridge
