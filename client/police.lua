---Police side: order a tow on a vehicle, and lift holds at the impound counter.
local config = require 'config'
local framework = require 'bridge.loader'
local notify = require 'client.notify'

local police = {}
local cfg = config.police

---@return boolean
function police.isOfficer()
    local job = framework.getJob()
    return job ~= nil and job.type == config.policeJobType and job.onDuty
end

local function orderTow(vehicle)
    local input = lib.inputDialog(locale('police.form_title'), {
        { type = 'input', label = locale('police.reason'), required = true, max = 120 },
        { type = 'number', label = locale('police.fine'), min = 0, max = cfg.maxFine, default = 0 },
        { type = 'checkbox', label = locale('police.hold') },
        { type = 'number', label = locale('police.hold_hours'), description = locale('police.hold_hours_hint'),
            min = 0, max = cfg.maxHoldHours, default = 0 },
    })
    if not input then return end
    local ok, errorKey = lib.callback.await('sw_tow:server:policeOrder', false, VehToNet(vehicle), {
        reason = input[1],
        fine = input[2] or 0,
        hold = input[3] == true,
        holdHours = input[4] or 0,
    })
    notify(locale(ok and 'police.ordered' or (errorKey or 'common.failed')), ok and 'success' or 'error')
end

---@param yardKey string
local function openHolds(yardKey)
    local list = lib.callback.await('sw_tow:server:holdList', false, yardKey)
    if not list or #list == 0 then
        notify(locale('police.no_holds'), 'inform')
        return
    end
    local options = {}
    for _, item in ipairs(list) do
        local untilText = item.holdUntil or locale('police.until_lifted')
        options[#options + 1] = {
            title = ('%s · %s'):format(item.plate, item.model),
            description = ('%s · %s'):format(untilText, item.note or ''),
            icon = 'lock-open',
            onSelect = function()
                local ok = lib.callback.await('sw_tow:server:liftHold', false, item.id)
                notify(locale(ok and 'police.lifted' or 'common.failed'), ok and 'success' or 'error')
            end,
        }
    end
    lib.registerContext({ id = 'sw_tow_holds', title = locale('police.holds_title'), options = options })
    lib.showContext('sw_tow_holds')
end

---ox_target option for officers at a yard counter.
---@param yardKey string
function police.counterOption(yardKey)
    return {
        name = 'sw_tow_holds_' .. yardKey,
        icon = 'fa-solid fa-lock-open',
        label = locale('police.holds_title'),
        distance = 2.5,
        canInteract = police.isOfficer,
        onSelect = function() openHolds(yardKey) end,
    }
end

if cfg.enabled then
    exports.ox_target:addGlobalVehicle({
        {
            name = 'sw_tow_police_order',
            icon = 'fa-solid fa-file-signature',
            label = locale('police.order'),
            distance = 3.0,
            canInteract = function(entity)
                local state = Entity(entity).state
                return police.isOfficer() and not state['sw_tow:company'] and not state['sw_tow:towedBy']
            end,
            onSelect = function(data) orderTow(data.entity) end,
        },
    })
end

return police
