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

---Sends a tow order and says how it went.
---@param order { reason: string, fine: number, hold: boolean, holdHours: number }
function police.sendOrder(vehicle, order)
    local ok, errorKey = lib.callback.await('sw_tow:server:policeOrder', false, VehToNet(vehicle), order)
    notify(locale(ok and 'police.ordered' or (errorKey or 'common.failed')), ok and 'success' or 'error')
end

---The officer's form; `preset` fills it in (for filming).
---@param preset? { reason: string, fine: number, hold: boolean, holdHours: number }
function police.orderTow(vehicle, preset)
    local input = lib.inputDialog(locale('police.form_title'), {
        { type = 'input', label = locale('police.reason'), required = true, max = 120, default = preset and preset.reason },
        { type = 'number', label = locale('police.fine'), min = 0, max = cfg.maxFine, default = preset and preset.fine or 0 },
        { type = 'checkbox', label = locale('police.hold'), checked = preset and preset.hold },
        { type = 'number', label = locale('police.hold_hours'), description = locale('police.hold_hours_hint'),
            min = 0, max = cfg.maxHoldHours, default = preset and preset.holdHours or 0 },
    })
    if not input then return end
    police.sendOrder(vehicle, {
        reason = tostring(input[1]),
        fine = tonumber(input[2]) or 0,
        hold = input[3] == true,
        holdHours = tonumber(input[4]) or 0,
    })
end

---Lifts a hold and says how it went.
---@param id integer impound record
function police.liftHold(id)
    local ok, errorKey = lib.callback.await('sw_tow:server:liftHold', false, id)
    notify(locale(ok and 'police.lifted' or (errorKey or 'common.failed')), ok and 'success' or 'error')
end

---@param yardKey string
function police.openHolds(yardKey)
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
            onSelect = function() police.liftHold(item.id) end,
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
        onSelect = function() police.openHolds(yardKey) end,
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
            onSelect = function(data) police.orderTow(data.entity) end,
        },
    })
end

return police
