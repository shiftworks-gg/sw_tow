---Developer tool: finds roadside spots for NPC contracts from the game's road nodes.
---Started by the server command `swtow_spots` (admins only); this side only samples and draws.

-- Road node flags (GET_VEHICLE_NODE_PROPERTIES). A spot must be on an ordinary, active road.
local REJECT = 1      -- off road (dirt tracks)
    | 8               -- switched off (closed roads, car parks)
    | 16              -- tunnel or interior
    | 64              -- highway: no shoulder to stop on, and NPC traffic runs into the truck
    | 128             -- junction
    | 256             -- traffic light
    | 1024            -- water

-- 0x07FB139B592FA687, once REQUEST_PATH_NODES_IN_AREA_THIS_FRAME. Called by hash if renamed again.
local requestPathNodes = RequestPathsPreferAccurateBoundingstruct or function(x1, y1, x2, y2)
    return Citizen.InvokeNative(0x07FB139B592FA687, x1, y1, x2, y2)
end

-- Los Santos and Blaine County, without Cayo Perico.
local MAP = { minX = -3400.0, maxX = 4000.0, minY = -3600.0, maxY = 7600.0 }

---@param x number
---@param y number
---@param size number
local function loadNodes(x, y, size)
    local deadline = GetGameTimer() + 1500
    repeat
        requestPathNodes(x, y, x + size, y + size)
        if AreNodesLoadedForArea(x, y, x + size, y + size) then return true end
        Wait(0)
    until GetGameTimer() > deadline
    return false
end

---A point on the right side of the road, facing along it, or nil.
---@param x number
---@param y number
---@param size number
---@return vector4?
local function roadsideIn(x, y, size)
    local cx, cy = x + size / 2, y + size / 2
    local found, node, heading = GetClosestVehicleNodeWithHeading(cx, cy, 0.0, 0, 3.0, 0)
    if not found then return end
    -- The closest node must lie in this cell, or neighbouring cells would pick the same road.
    if node.x < x or node.x >= x + size or node.y < y or node.y >= y + size then return end

    local _, _, flags = GetVehicleNodeProperties(node.x, node.y, node.z)
    if (flags & REJECT) ~= 0 then return end

    local hasEdge, edge = GetRoadBoundaryUsingHeading(node.x, node.y, node.z, heading)
    if not hasEdge then return end
    local toEdge = vec3(edge.x - node.x, edge.y - node.y, 0.0)
    local width = #toEdge
    -- Narrow roads leave no room to pass a broken-down car; very wide ones are not a lane edge.
    if width < 3.5 or width > 12.0 then return end

    local spot = vec3(node.x, node.y, node.z) + toEdge * ((width - 1.8) / width)
    return vec4(spot.x, spot.y, node.z, heading)
end

lib.callback.register('sw_tow:dev:sampleSpots', function(cellSize)
    if type(cellSize) ~= 'number' or cellSize < 100 then return {} end
    local spots = {}
    local columns = math.ceil((MAP.maxX - MAP.minX) / cellSize)
    local rows = math.ceil((MAP.maxY - MAP.minY) / cellSize)
    local done, total = 0, columns * rows

    for column = 0, columns - 1 do
        for row = 0, rows - 1 do
            local x, y = MAP.minX + column * cellSize, MAP.minY + row * cellSize
            if loadNodes(x, y, cellSize) then
                local spot = roadsideIn(x, y, cellSize)
                if spot then spots[#spots + 1] = spot end
            end
            done = done + 1
        end
        lib.showTextUI(('sw_tow: road scan %d%% · %d spots'):format(math.floor(done / total * 100), #spots))
    end

    lib.hideTextUI()
    return spots
end)

local blips = {}

local function clearBlips()
    for i = 1, #blips do RemoveBlip(blips[i]) end
    blips = {}
end

RegisterNetEvent('sw_tow:dev:showSpots', function(spots)
    clearBlips()
    if type(spots) ~= 'table' then return end
    for i = 1, #spots do
        local spot = spots[i]
        local blip = AddBlipForCoord(spot.x, spot.y, spot.z)
        SetBlipSprite(blip, 68)  -- tow truck
        SetBlipScale(blip, 0.6)
        SetBlipColour(blip, spot.generated and 47 or 3)  -- orange: generated, blue: bundled
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(('sw_tow spot %d'):format(i))
        EndTextCommandSetBlipName(blip)
        blips[#blips + 1] = blip
    end
end)

RegisterNetEvent('sw_tow:dev:hideSpots', clearBlips)

AddEventHandler('onResourceStop', function(resource)
    if resource == cache.resource then clearBlips() end
end)
