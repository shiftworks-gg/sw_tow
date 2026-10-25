---Qbox server bridge. The only server file that calls qbx_core directly.
lib.load('@qbx_core.modules.lib')  -- Defines the `qbx` helper table (spawnVehicle, getVehiclePlate).

local bridge = {}

---@param src integer
local function player(src)
    return exports.qbx_core:GetPlayer(src)
end

---@param src integer
---@return string?
function bridge.getCitizenId(src)
    local p = player(src)
    return p and p.PlayerData.citizenid
end

---@param src integer
---@return string
function bridge.getName(src)
    local p = player(src)
    if not p then return GetPlayerName(src) or ('#' .. src) end
    local info = p.PlayerData.charinfo
    return ('%s %s'):format(info.firstname, info.lastname)
end

---@class SwJob
---@field name string
---@field type string?
---@field grade integer
---@field onDuty boolean
---@field isBoss boolean

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
    exports.qbx_core:SetJobDuty(src, onDuty)
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
    return exports.qbx_core:AddMoney(src, account, amount, reason) == true
end

---@param src integer
---@param account 'cash'|'bank'
---@param amount integer
---@param reason string
---@return boolean
function bridge.removeMoney(src, account, amount, reason)
    return exports.qbx_core:RemoveMoney(src, account, amount, reason) == true
end

---Creates a networked vehicle on the server. Throws on failure.
---@param model string|integer
---@param coords vector4
---@param props? table ox_lib vehicle properties
---@return integer netId, integer entity
function bridge.spawnVehicle(model, coords, props)
    return qbx.spawnVehicle({ model = model, spawnSource = coords, props = props })
end

---@param entity integer
function bridge.deleteVehicle(entity)
    exports.qbx_core:DeleteVehicle(entity)
end

---@param entity integer
---@return string
function bridge.getPlate(entity)
    return qbx.getVehiclePlate(entity) or ''
end

---Vehicle class from the model, or nil when no client could report classes yet.
---@param model integer
---@return integer?
function bridge.getVehicleClass(model)
    local ok, class = pcall(exports.qbx_core.GetVehicleClass, exports.qbx_core, model)
    return ok and class or nil
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
