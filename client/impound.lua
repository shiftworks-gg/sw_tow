---Impound counter for vehicle owners, and the yard blips.
local config = require 'config'
local util = require 'shared.util'
local notify = require 'client.notify'
local police = require 'client.police'
local dialog = require 'client.dialog'

local impound = {}

local vehicleLabel = dialog.vehicleLabel

---The player's vehicles in a yard, with their fees, and the money they can pay with. Only works at
---the yard's counter.
---@param yardKey string
---@return { id: integer, plate: string, model: string, reason: string, note: string?, fee: integer, parts: table, held: boolean, holdLeft: integer?, storedFor: integer }[] list
---@return { cash: integer, bank: integer } money
function impound.list(yardKey)
    local list, money = lib.callback.await('sw_tow:server:counterList', false, yardKey)
    return list or {}, money or { cash = 0, bank = 0 }
end

---Pays the fee and takes the vehicle out.
---@param id integer record id from impound.list
---@param account? 'cash'|'bank' nil = cash first, then bank
---@return boolean ok, string? errorKey
function impound.release(id, account)
    return lib.callback.await('sw_tow:server:release', false, id, account)
end

---The counter window's data for a yard.
---@param yardKey string
---@param select? string plate to show first
---@return table? data nil when none of the player's vehicles are there
local function counterData(yardKey, select)
    local list, money = impound.list(yardKey)
    if #list == 0 then return end
    local items = {}
    for i, item in ipairs(list) do
        items[i] = {
            id = item.id, plate = item.plate, label = vehicleLabel(item.model), reason = item.reason, note = item.note,
            fee = item.fee, parts = item.parts, held = item.held, holdLeft = item.holdLeft, storedFor = item.storedFor,
        }
    end
    return { title = config.yards[yardKey].label, items = items, money = money, select = select }
end

---The yard whose counter window is open.
---@type string?
local counterYard

dialog.on('pay', function(body)
    if not counterYard or not util.isInteger(body.id) then return { close = true } end
    local ok, errorKey = impound.release(body.id, body.account == 'bank' and 'bank' or 'cash')
    if ok then
        notify(locale('impound.released'), 'success')
        return { close = true }
    end
    local data = counterData(counterYard)
    if not data then return { close = true } end
    return { error = locale(errorKey or 'common.failed'), data = data }
end)

---Releases a vehicle at the counter (the fee is charged) and says how it went.
---@param item table an entry of impound.list()
function impound.releaseItem(item)
    local ok, errorKey = impound.release(item.id)
    notify(locale(ok and 'impound.released' or (errorKey or 'common.failed')), ok and 'success' or 'error')
end

---Asks the owner to confirm the fee, then releases.
---@param item table an entry of impound.list()
function impound.confirmRelease(item)
    local confirm = lib.alertDialog({
        header = locale('impound.release_header', item.plate),
        content = locale('impound.release_confirm', util.money(item.fee)),
        centered = true,
        cancel = true,
        labels = { confirm = locale('impound.release_button', util.money(item.fee)) },
    })
    if confirm ~= 'confirm' then return end
    impound.releaseItem(item)
end

---@param yardKey string
---@param opts? { focus?: boolean, select?: string } the window without the mouse (filming), a plate to show first
function impound.openCounter(yardKey, opts)
    local yard = config.yards[yardKey]
    if dialog.enabled() then
        local data = counterData(yardKey, opts and opts.select)
        if not data then return notify(locale('impound.nothing_here'), 'inform') end
        counterYard = yardKey
        return dialog.open('counter', data, opts)
    end
    local list = impound.list(yardKey)
    if #list == 0 then
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
            onSelect = function() impound.confirmRelease(item) end,
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
            onSelect = function() impound.openCounter(yardKey) end,
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

---The clerk exists only on this client and only while the player is within 60 m. Aiming at the
---clerk offers the same options as the counter.
---@param c vector4 where the clerk stands and faces
---@param cfg { model: string, scenario: string? }
---@param options table[] ox_target options of the counter
function impound.createClerk(c, cfg, options)
    local clerk
    local function remove()
        if clerk and DoesEntityExist(clerk) then DeletePed(clerk) end
        clerk = nil
    end
    lib.points.new({
        coords = c.xyz,
        distance = 60.0,
        onEnter = function()
            if clerk then return end
            local model = lib.requestModel(cfg.model)
            if not model then return end
            -- Stand on the floor under the point, whatever height the config coordinate was taken at.
            local found, groundZ = GetGroundZFor_3dCoord(c.x, c.y, c.z + 1.0, false)
            clerk = CreatePed(4, model, c.x, c.y, found and groundZ or c.z - 1.0, c.w, false, true)
            SetModelAsNoLongerNeeded(model)
            SetEntityInvincible(clerk, true)
            FreezeEntityPosition(clerk, true)
            SetBlockingOfNonTemporaryEvents(clerk, true)
            if cfg.scenario then TaskStartScenarioInPlace(clerk, cfg.scenario, 0, true) end
            exports.ox_target:addLocalEntity(clerk, options)
        end,
        onExit = remove,
    })
    AddEventHandler('onResourceStop', function(resource)
        if resource == cache.resource then remove() end
    end)
end

---Separate counters (yards with their own `counter` position) get their own clerk, or a target box
---when the yard has no `ped`.
function impound.createCounters()
    for key, yard in pairs(config.yards) do
        local counter = yard.counter --[[@as vector4?]]
        if counter and yard.ped then
            impound.createClerk(counter, yard.ped, impound.counterOptions(key))
        elseif counter then
            exports.ox_target:addBoxZone({
                name = 'sw_tow_counter_box_' .. key,
                coords = counter.xyz,
                size = vec3(2.0, 2.0, 2.5),
                rotation = counter.w,
                debug = config.debug,
                options = impound.counterOptions(key),
            })
        end
        impound.addBlip(yard.zone.coords, yard.blip, yard.label)
    end
end

return impound
