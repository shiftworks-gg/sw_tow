---QBCore client bridge. The only client file that talks to qb-core directly.
local QBCore = exports['qb-core']:GetCoreObject()

local bridge = {}

---@return SwJob?
function bridge.getJob()
    local data = QBCore.Functions.GetPlayerData()
    local job = data and data.job
    if not job then return end
    return {
        name = job.name,
        type = job.type,
        grade = job.grade and job.grade.level or 0,
        onDuty = job.onduty == true,
        isBoss = job.isboss == true,
    }
end

---@return boolean
function bridge.isLoggedIn()
    return LocalPlayer.state.isLoggedIn == true
end

---@param cb fun()
function bridge.onPlayerLoaded(cb)
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', cb)
end

---@param cb fun()
function bridge.onPlayerUnload(cb)
    RegisterNetEvent('QBCore:Client:OnPlayerUnload', cb)
end

---@param cb fun()
function bridge.onJobUpdate(cb)
    RegisterNetEvent('QBCore:Client:OnJobUpdate', function() cb() end)
end

-- Server-created vehicles get their properties from the entity owner (see the server bridge).
RegisterNetEvent('sw_tow:client:applyProps', function(netId, props)
    local deadline = GetGameTimer() + 5000
    while not NetworkDoesEntityExistWithNetworkId(netId) and GetGameTimer() < deadline do Wait(50) end
    if not NetworkDoesEntityExistWithNetworkId(netId) then return end
    lib.setVehicleProperties(NetToVeh(netId), props)
end)

return bridge
