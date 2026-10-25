---Notifications in the Shiftworks dark style through ox_lib. One line of text, state shown by the
---icon colour and the title word, never by colour alone.
local config = require 'config'

local style = {
    backgroundColor = '#172027',
    color = '#e9eef1',
    border = '1px solid #2a363f',
    borderRadius = '4px',
}

-- ox_lib draws FontAwesome icons; Tabler icons are used in our own NUI only.
local kinds = {
    success = { icon = 'circle-check', iconColor = '#4cc47e', duration = 4000 },
    inform = { icon = 'circle-info', iconColor = '#ff7a2e', duration = 4000 },
    warning = { icon = 'triangle-exclamation', iconColor = '#f5c400', duration = 5000 },
    error = { icon = 'circle-xmark', iconColor = '#f07070', duration = 6000 },
}

---@param message string
---@param kind? 'success'|'inform'|'warning'|'error'
local function notify(message, kind)
    local k = kinds[kind or 'inform'] or kinds.inform
    lib.notify({
        title = locale('notify.' .. (kinds[kind] and kind or 'inform')),
        description = message,
        type = kind == 'error' and 'error' or (kind == 'success' and 'success' or 'inform'),
        icon = k.icon,
        iconColor = k.iconColor,
        duration = k.duration,
        position = config.notify and config.notify.position or 'top-right',
        style = style,
    })
end

RegisterNetEvent('sw_tow:client:notify', function(message, kind)
    if type(message) ~= 'string' then return end
    notify(message, kind)
end)

return notify
