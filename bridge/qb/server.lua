---QBCore server bridge. The only server file that calls qb-core directly.
local QBCore = exports['qb-core']:GetCoreObject()

local bridge = {}

---@param src integer
local function player(src)
    return QBCore.Functions.GetPlayer(src)
end

---@param src integer
---@return string?
function bridge.getCitizenId(src)
    local p = player(src)
    return p and p.PlayerData.citizenid
end

---Server id of an online character, or nil when they are offline.
---@param citizenid string
---@return integer?
function bridge.getSourceByCitizenId(citizenid)
    local p = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    return p and p.PlayerData.source or nil
end

---@param src integer
---@return string
function bridge.getName(src)
    local p = player(src)
    if not p then return GetPlayerName(src) or ('#' .. src) end
    local info = p.PlayerData.charinfo
    return ('%s %s'):format(info.firstname, info.lastname)
end

---@param src integer
---@return SwJob?
function bridge.getJob(src)
    local p = player(src)
    if not p then return end
    local job = p.PlayerData.job
    return {
        name = job.name,
        type = job.type,
        grade = job.grade and job.grade.level or 0,
        onDuty = job.onduty == true,
        isBoss = job.isboss == true,
    }
end

---@param src integer
---@param onDuty boolean
function bridge.setDuty(src, onDuty)
    local p = player(src)
    if p then p.Functions.SetJobDuty(onDuty) end
end

---@param src integer
---@param account 'cash'|'bank'
---@return integer
function bridge.getMoney(src, account)
    local p = player(src)
    return p and p.PlayerData.money[account] or 0
end

---@param src integer
---@param account 'cash'|'bank'
---@param amount integer
---@param reason string
---@return boolean
function bridge.addMoney(src, account, amount, reason)
    local p = player(src)
    return p ~= nil and p.Functions.AddMoney(account, amount, reason) == true
end

---@param src integer
---@param account 'cash'|'bank'
---@param amount integer
---@param reason string
---@return boolean
function bridge.removeMoney(src, account, amount, reason)
    local p = player(src)
    return p ~= nil and p.Functions.RemoveMoney(account, amount, reason) == true
end

---Creates a networked vehicle on the server. Throws on failure.
---Body mods and colours cannot be set on the server, so the entity owner applies `props`.
---@param model string|integer
---@param coords vector4
---@param props? table ox_lib vehicle properties
---@return integer netId, integer entity
function bridge.spawnVehicle(model, coords, props)
    local hash = type(model) == 'string' and joaat(model) or model
    local entity = CreateVehicleServerSetter(hash, 'automobile', coords.x, coords.y, coords.z, coords.w)
    local deadline = GetGameTimer() + 5000
    while not entity or entity == 0 or not DoesEntityExist(entity) do
        if GetGameTimer() > deadline then
            error(('sw_tow: could not create vehicle %s'):format(tostring(model)), 0)
        end
        Wait(0)
    end

    if props and props.plate then SetVehicleNumberPlateText(entity, props.plate) end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if props then
        local owner
        deadline = GetGameTimer() + 5000
        repeat
            owner = NetworkGetEntityOwner(entity)
            if not owner or owner <= 0 then Wait(50) end
        until (owner and owner > 0) or GetGameTimer() > deadline
        if owner and owner > 0 then
            TriggerClientEvent('sw_tow:client:applyProps', owner, netId, props)
        end
    end
    return netId, entity
end

---@param entity integer
function bridge.deleteVehicle(entity)
    if DoesEntityExist(entity) then DeleteEntity(entity) end
end

---@param entity integer
---@return string
function bridge.getPlate(entity)
    return (GetVehicleNumberPlateText(entity) or ''):match('^%s*(.-)%s*$')
end

---qb-core has no server-side class lookup; callers fall back to the base fee.
---@param model integer
---@return integer?
function bridge.getVehicleClass(model)
    return nil
end

---@param cb fun(src: integer)
function bridge.onPlayerUnload(cb)
    AddEventHandler('QBCore:Server:OnPlayerUnload', cb)
end

---@param cb fun(src: integer, job: SwJob)
function bridge.onJobUpdate(cb)
    AddEventHandler('QBCore:Server:OnJobUpdate', function(src)
        cb(src, bridge.getJob(src))
    end)
end

return bridge
