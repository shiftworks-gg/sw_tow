---`swtow_selftest`: checks the installation on this server, no player needed: framework and jobs,
---integrations and their accounts, database tables, a write/read round trip through the real SQL,
---the database clock, locales and contract spots. Server console, or admins in game (F8).
---Results are printed and saved to selftest.log in the resource folder.
local config = require 'config'
local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local storage = require 'server.storage'
local spotlist = require 'server.spotlist'

local selftest = {}

local COLUMNS = {
    sw_tow_impound = { 'id', 'yard', 'plate', 'vehicle_id', 'owner', 'model', 'reason', 'note', 'fine', 'tow_charge',
        'police_hold', 'hold_until', 'towed_by', 'stored_at', 'released_at', 'released_by', 'paid' },
    sw_tow_log = { 'id', 'citizenid', 'call_type', 'payout', 'distance_m', 'created_at' },
}

---@alias SwCheckStatus 'PASS'|'WARN'|'FAIL'
---@class SwCheckResult
---@field status SwCheckStatus
---@field name string
---@field detail string?

---Writes, reads and releases one test record through server/storage.lua, then deletes it.
---@return SwCheckStatus, string?
local function roundTrip()
    local marker = '__selftest'
    local now = os.time()
    local id = storage.insertImpound({
        yard = marker, plate = 'SWSELF', owner = marker, model = 'asea', reason = 'selftest', note = 'self-test',
        fine = 1, tow_charge = 2, police_hold = true, hold_until = now + 3600, towed_by = marker,
    })
    if not id then return 'FAIL', 'insert returned no id' end
    local ok, status, detail = pcall(function()
        local row = storage.getActive(id)
        if not row then return 'FAIL', 'the record could not be read back' end
        if row.fine ~= 1 or row.tow_charge ~= 2 or row.police_hold ~= 1 then
            return 'FAIL', ('read back wrong values: fine %s, tow %s, hold %s'):format(row.fine, row.tow_charge, row.police_hold)
        end
        if math.abs((row.hold_until or 0) - (now + 3600)) > 5 then
            return 'FAIL', ('hold time is off by %d s'):format((row.hold_until or 0) - (now + 3600))
        end
        local held = false
        for _, r in ipairs(storage.heldInYard(marker)) do held = held or r.id == id end
        if not held then return 'FAIL', 'the police hold list does not show it' end
        local owned = false
        for _, r in ipairs(storage.activeForOwner(marker, marker)) do owned = owned or r.id == id end
        if not owned then return 'FAIL', 'the owner\'s list does not show it' end
        if not storage.liftHold(id) then return 'FAIL', 'lifting the hold changed nothing' end
        if not storage.markReleased(id, marker, 3) then return 'FAIL', 'releasing changed nothing' end
        if storage.markReleased(id, marker, 3) then return 'FAIL', 'a record could be released twice' end
        if storage.getActive(id) then return 'FAIL', 'a released record is still active' end
        -- Storage-day fees compare the database clock (stored_at) with the server clock.
        local drift = (row.stored_at or 0) - now
        if math.abs(drift) > 120 then
            return 'WARN', ('works, but the database clock differs from the server clock by %d s: storage-day fees will be off'):format(drift)
        end
        return 'PASS', 'insert, read, hold list, owner list, lift, release'
    end)
    MySQL.update.await('DELETE FROM sw_tow_impound WHERE id = ?', { id })
    if not ok then return 'FAIL', tostring(status) end
    return status, detail
end

---@return SwCheckResult[]
function selftest.run()
    local results = {}

    ---@param name string
    ---@param fn fun(): SwCheckStatus, string?
    local function check(name, fn)
        local ok, status, detail = pcall(fn)
        if not ok then status, detail = 'FAIL', tostring(status) end
        results[#results + 1] = { status = status, name = name, detail = detail }
    end

    check('framework', function() return 'PASS', framework.name end)

    check('job "' .. config.job .. '"', function()
        if framework.getJobs()[config.job] then return 'PASS' end
        return 'FAIL', 'the framework has no such job: add it or change config.job'
    end)

    check('police job type "' .. config.policeJobType .. '"', function()
        if not config.police.enabled then return 'PASS', 'police orders are off' end
        local names = {}
        for name, job in pairs(framework.getJobs()) do
            if job.type == config.policeJobType then names[#names + 1] = name end
        end
        if #names == 0 then return 'WARN', 'no job has this type: officers cannot order tows or lift holds' end
        table.sort(names)
        return 'PASS', table.concat(names, ', ')
    end)

    check('garage script', function()
        if integrations.names.garage == 'none' then
            return 'WARN', 'none: owned vehicles cannot be impounded and /' .. config.calls.command .. ' is off'
        end
        return 'PASS', integrations.names.garage
    end)

    check('vehicle keys script', function()
        if integrations.names.keys == 'none' then return 'WARN', 'none: workers and owners get no keys from sw_tow' end
        return 'PASS', integrations.names.keys
    end)

    check('banking script', function()
        if integrations.names.banking == 'none' then return 'WARN', 'none: company and police shares of release fees are not paid' end
        return 'PASS', integrations.names.banking
    end)

    for _, account in ipairs({ config.fees.companyAccount, config.police.fineAccount }) do
        check('account "' .. account .. '"', function()
            local exists = integrations.banking.exists(account)
            if exists == nil then return 'PASS', 'not checked without a banking script' end
            if exists then return 'PASS' end
            return 'WARN', 'does not exist in ' .. integrations.names.banking .. ': its share of release fees is lost'
        end)
    end

    for name, wanted in pairs(COLUMNS) do
        check('table ' .. name, function()
            local rows = MySQL.query.await(('SHOW COLUMNS FROM `%s`'):format(name))
            if not rows or #rows == 0 then return 'FAIL', 'missing: restart sw_tow to create it' end
            local have = {}
            for _, row in ipairs(rows) do have[row.Field] = true end
            local missing = {}
            for _, column in ipairs(wanted) do
                if not have[column] then missing[#missing + 1] = column end
            end
            if #missing > 0 then return 'FAIL', 'missing columns: ' .. table.concat(missing, ', ') end
            return 'PASS', #wanted .. ' columns'
        end)
    end

    check('database round trip', roundTrip)

    check('locales', function()
        local language = GetConvar('ox:locale', 'en')
        if locale('calls.blip') == 'calls.blip' then return 'FAIL', 'no texts loaded for "' .. language .. '"' end
        return 'PASS', language
    end)

    check('contract spots', function()
        if not config.contracts.enabled then return 'PASS', 'contracts are off' end
        if #spotlist.all == 0 then return 'FAIL', 'no spots: contracts never appear' end
        return 'PASS', ('%d spots, %d generated'):format(#spotlist.all, spotlist.generatedCount)
    end)

    check('qbx_towjob', function()
        local state = GetResourceState('qbx_towjob')
        if state == 'started' or state == 'starting' then return 'WARN', 'running: it uses the same office, stop it' end
        return 'PASS', 'not running'
    end)

    return results
end

---@param results SwCheckResult[]
---@return string[] lines
function selftest.format(results)
    local counts = { PASS = 0, WARN = 0, FAIL = 0 }
    for _, r in ipairs(results) do counts[r.status] = (counts[r.status] or 0) + 1 end
    local lines = {
        ('sw_tow %s self-test, %s · %d PASS · %d WARN · %d FAIL'):format(GetResourceMetadata(cache.resource, 'version', 0) or '?',
            os.date('%Y-%m-%d %H:%M:%S'), counts.PASS, counts.WARN, counts.FAIL),
    }
    for _, r in ipairs(results) do
        lines[#lines + 1] = ('  %-4s  %-28s %s'):format(r.status, r.name, r.detail or '')
    end
    return lines
end

lib.addCommand('swtow_selftest', {
    help = 'Shiftworks Tow: check the installation (database, jobs, integrations)',
    restricted = 'group.admin',
}, function(src)
    local lines = selftest.format(selftest.run())
    local text = table.concat(lines, '\n')
    print('^3[sw_tow]^7 ' .. text)
    SaveResourceFile(cache.resource, 'selftest.log', text .. '\n', -1)
    if src > 0 then TriggerClientEvent('sw_tow:client:selftest', src, lines) end
end)

return selftest
