---Impound counter for vehicle owners, and the yard blips.
local config = require 'config'
local util = require 'shared.util'
local notify = require 'client.notify'
local police = require 'client.police'

local impound = {}

local function vehicleLabel(model)
    local name = GetDisplayNameFromVehicleModel(joaat(model))
    local text = GetLabelText(name)
    return text ~= 'NULL' and text or model
end

---@param yardKey string
local function openCounter(yardKey)
    local yard = config.yards[yardKey]
    local list = lib.callback.await('sw_tow:server:counterList', false, yardKey)
    if not list or #list == 0 then
        notify(locale('impound.nothing_here'), 'inform')
        return
    end

    local options = {}
    for _, item in ipairs(list) do
        options[#options + 1] = {
            title = ('%s · %s'):format(item.plate, vehicleLabel(item.model)),
            description = item.held and locale('impound.on_hold') or locale('impound.fee_line', util.money(item.fee)),
            icon = item.held and 'lock' or 'car',
            disabled = item.held,
            onSelect = function()
                local confirm = lib.alertDialog({
                    header = locale('impound.release_header', item.plate),
                    content = locale('impound.release_confirm', util.money(item.fee)),
                    centered = true,
                    cancel = true,
                    labels = { confirm = locale('impound.release_button', util.money(item.fee)) },
                })
                if confirm ~= 'confirm' then return end
                local ok, errorKey = lib.callback.await('sw_tow:server:release', false, item.id)
                notify(locale(ok and 'impound.released' or (errorKey or 'common.failed')), ok and 'success' or 'error')
            end,
        }
    end

    lib.registerContext({ id = 'sw_tow_counter', title = yard.label, options = options })
    lib.showContext('sw_tow_counter')
end

---ox_target options for a yard's release counter.
---@param yardKey string
---@return table[]
function impound.counterOptions(yardKey)
    return {
        {
            name = 'sw_tow_counter_' .. yardKey,
            icon = 'fa-solid fa-square-parking',
            label = locale('impound.counter'),
            distance = 2.5,
            onSelect = function() openCounter(yardKey) end,
        },
        police.counterOption(yardKey),
    }
end

---@param coords vector3
---@param blip { enabled: boolean, sprite: integer, color: integer, scale: number }
---@param label string
function impound.addBlip(coords, blip, label)
    if not blip or not blip.enabled then return end
    local handle = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(handle, blip.sprite)
    SetBlipColour(handle, blip.color)
    SetBlipScale(handle, blip.scale)
    SetBlipAsShortRange(handle, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(handle)
end

---Yard key whose hand-over zone contains this point.
---@param coords vector3
---@return string?
function impound.yardAt(coords)
    for key, yard in pairs(config.yards) do
        if util.inZone(coords, yard.zone) then return key end
    end
end

---Separate counters (yards with their own `counter` position) get their own target box.
function impound.createCounters()
    for key, yard in pairs(config.yards) do
        if yard.counter then
            exports.ox_target:addBoxZone({
                name = 'sw_tow_counter_box_' .. key,
                coords = yard.counter.xyz,
                size = vec3(2.0, 2.0, 2.5),
                rotation = yard.counter.w,
                debug = config.debug,
                options = impound.counterOptions(key),
            })
        end
        impound.addBlip(yard.zone.coords, yard.blip, yard.label)
    end
end

return impound
