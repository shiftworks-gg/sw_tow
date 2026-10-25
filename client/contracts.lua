---Makes contract vehicles look broken down. Runs on whichever client owns the vehicle when its
---`sw_tow:contract` state bag arrives; engine health and doors sync to everyone from there.
local util = require 'shared.util'

AddStateBagChangeHandler('sw_tow:contract', '', function(bagName, _, value)
    if not value then return end
    -- The bag usually arrives as the vehicle streams in, before it exists on this client.
    CreateThread(function()
        local vehicle = util.entityFromBag(bagName)
        if not vehicle or not NetworkHasControlOfEntity(vehicle) then return end
        SetVehicleEngineHealth(vehicle, math.random(120, 280) + 0.0)
        SetVehicleEngineOn(vehicle, false, true, true)
        SetVehicleDoorOpen(vehicle, 4, false, false)
        SetVehicleIndicatorLights(vehicle, 0, true)
        SetVehicleIndicatorLights(vehicle, 1, true)
    end)
end)
