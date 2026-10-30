---Notifications. By default they go through the server's ox_lib as they are, so they look like every
---other notification there, restyled or replaced ox_lib included. `config.notify.style = 'shiftworks'`
---gives the Shiftworks dark look; `config.notify.custom` sends them to any notification script.
local config = require 'config'

local cfg = config.notify or {}

local style = {
    backgroundColor = '#172027',
    color = '#e9eef1',
    border = '1px solid #2a363f',
    borderRadius = '4px',
}

-- ox_lib draws FontAwesome icons; Tabler icons are used in our own NUI only.
---@type table<string, { type: 'info'|'warning'|'success'|'error', icon: string, iconColor: string, duration: integer }>
local kinds = {
    success = { type = 'success', icon = 'circle-check', iconColor = '#4cc47e', duration = 4000 },
    inform = { type = 'info', icon = 'circle-info', iconColor = '#ff7a2e', duration = 4000 },
    warning = { type = 'warning', icon = 'triangle-exclamation', iconColor = '#f5c400', duration = 5000 },
    error = { type = 'error', icon = 'circle-xmark', iconColor = '#f07070', duration = 6000 },
}

---@param message string
---@param kind? 'success'|'inform'|'warning'|'error'
local function notify(message, kind)
    kind = kinds[kind] and kind or 'inform'
    if cfg.custom then
        local ok, err = pcall(cfg.custom, message, kind)
        if ok then return end
        lib.print.error(('config.notify.custom failed, using ox_lib: %s'):format(err))
    end
    local k = kinds[kind]
    local shiftworks = cfg.style == 'shiftworks'
    lib.notify({
        title = locale('notify.' .. kind),
        description = message,
        type = k.type,
        icon = shiftworks and k.icon or nil,
        iconColor = shiftworks and k.iconColor or nil,
        duration = k.duration,
        position = cfg.position,
        style = shiftworks and style or nil,
    })
end

RegisterNetEvent('sw_tow:client:notify', function(message, kind)
    if type(message) ~= 'string' then return end
    notify(message, kind)
end)

return notify
