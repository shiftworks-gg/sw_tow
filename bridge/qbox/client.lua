---Qbox client bridge. The only client file that talks to qbx_core directly.
local bridge = {}

---@return SwJob?
function bridge.getJob()
    local data = exports.qbx_core:GetPlayerData()
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
    RegisterNetEvent('qbx_core:client:playerLoggedOut', cb)
end

---@param cb fun()
function bridge.onJobUpdate(cb)
    RegisterNetEvent('QBCore:Client:OnJobUpdate', function() cb() end)
end

return bridge
