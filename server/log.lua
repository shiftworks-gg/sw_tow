---Logging: ox_lib logger for the server's log service, the console for warnings, and an optional
---Discord webhook set with `set sw_tow:webhook "https://..."` in server.cfg (never in config files).
local config = require 'config'

local log = {}
local webhook = GetConvar('sw_tow:webhook', '')

local colors = {
    info = 0x1F2B34,     -- steel
    payout = 0x1F8A4C,   -- success
    warn = 0xC62F2F,     -- danger
}

local function send(level, src, event, message)
    if webhook == '' then return end
    local who = src and src > 0 and ('%s (id %d)'):format(GetPlayerName(src) or '?', src) or 'server'
    PerformHttpRequest(webhook, function() end, 'POST', json.encode({
        username = 'Shiftworks Tow',
        embeds = { {
            title = event,
            description = message,
            color = colors[level] or colors.info,
            footer = { text = who },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        } },
    }), { ['Content-Type'] = 'application/json' })
end

---@param level 'info'|'payout'|'warn'
---@param src integer?
---@param event string
---@param message string
local function write(level, src, event, message)
    lib.logger(src or 0, event, message)
    if level == 'warn' then
        lib.print.warn(('[%s] %s: %s'):format(src or 0, event, message))
    elseif config.debug then
        lib.print.info(('[%s] %s: %s'):format(src or 0, event, message))
    end
    send(level, src, event, message)
end

function log.info(src, event, message) write('info', src, event, message) end
function log.payout(src, event, message) write('payout', src, event, message) end

---A refused action. Logged, never punished: bans stay the server admin's decision.
function log.warn(src, event, message) write('warn', src, event, message) end

return log
