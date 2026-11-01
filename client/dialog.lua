---The Shiftworks window (html/dialog.js): the impound counter, the officer's holds and the tow
---order. One window at a time; while it is open the page has the mouse and keyboard.
---With config.ui.menus = 'ox' none of this is used and the modules show ox_lib menus instead.
local config = require 'config'

local dialog = {}

---@type string?
local openKind
---@type table<string, fun(body: table): table?>
local handlers = {}

---Strings the window uses, sent with the page's init message.
dialog.STRING_KEYS = {
    'close', 'to_pay', 'cash', 'bank', 'pay', 'pay_short', 'paying', 'not_enough',
    'fee_base', 'fee_class', 'fee_storage', 'fee_storage_one', 'fee_fine', 'fee_tow',
    'reason_player', 'reason_police', 'reason_contract', 'reason_abandoned', 'here_for',
    'hold_left', 'hold_open', 'hold_text', 'held_button', 'd', 'h', 'min',
    'lift', 'lifting', 'fine_of',
    'order_title', 'reason', 'reason_hint', 'reason_needed', 'fine', 'fine_hint', 'hold', 'hold_hint', 'hold_for',
    'until_lifted', 'send', 'sending', 'vehicle',
}

---The game's name for a vehicle model, e.g. "Sultan".
---@param model string|integer
---@return string
function dialog.vehicleLabel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    local name = GetDisplayNameFromVehicleModel(hash)
    local text = GetLabelText(name)
    if text ~= 'NULL' then return text end
    return type(model) == 'string' and model or name
end

---@return boolean
function dialog.enabled()
    return config.ui.menus ~= 'ox'
end

---@return string? kind of the window that is open
function dialog.current()
    return openKind
end

---Opens the window.
---@param kind 'counter'|'holds'|'order'
---@param data table
---@param opts? { focus?: boolean } focus = false shows it without taking the mouse (filming)
function dialog.open(kind, data, opts)
    openKind = kind
    local focus = not opts or opts.focus ~= false
    SetNuiFocus(focus, focus)
    SendNUIMessage({ type = 'dialog', kind = kind, data = data })
end

function dialog.close()
    if not openKind then return end
    openKind = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'dialogClose' })
end

---Lights up a button as if it was clicked (filming).
---@param action 'pay'|'lift'|'send'
function dialog.press(action)
    SendNUIMessage({ type = 'dialogPress', action = action })
end

---What happens when the player uses the window. The handler returns what the page shows next:
---{ close = true } closes it, { error = text } shows the text, { data = table } redraws it.
---@param action string 'pay', 'lift' or 'send'
---@param fn fun(body: table): table?
function dialog.on(action, fn)
    handlers[action] = fn
end

RegisterNUICallback('dialog', function(body, respond)
    if type(body) ~= 'table' then return respond({}) end
    if body.action == 'close' then
        openKind = nil
        SetNuiFocus(false, false)
        return respond({})
    end
    local handler = handlers[body.action]
    if not handler or not openKind then return respond({ close = true }) end
    local ok, result = pcall(handler, body)
    if not ok then
        lib.print.error(result)
        result = { error = locale('common.failed') }
    end
    result = result or {}
    if result.close then dialog.close() end
    respond(result)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == cache.resource and openKind then SetNuiFocus(false, false) end
end)

return dialog
