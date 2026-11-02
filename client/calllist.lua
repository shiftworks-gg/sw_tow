---The call list in the Shiftworks style (html/calls.js). It takes the panel's place and works from
---the keyboard without taking the mouse, so a driver picks a call without stopping: the arrow keys
---or the mouse wheel choose, Enter takes, Esc or the list key closes. Calls come nearest first, each
---with an arrow pointing where it is from the camera.
---With config.ui.menus = 'ox' the ox_lib menu of client/calls.lua is shown instead.
local config = require 'config'
local notify = require 'client.notify'
local shift = require 'client.shift'
local calls = require 'client.calls'
local dialog = require 'client.dialog'

local calllist = {}

local isOpen = false
local busy = false
---@class SwListCall
---@field id integer
---@field type string
---@field plate string
---@field coords { x: number, y: number, z: number }
---@field message string
---@field age integer seconds since the call came in
---@field mine boolean
---@field pay integer

---@class SwListEntry
---@field kind 'call'|'end'
---@field call? SwListCall
---@field coords? vector3
---@field distance? number

---What the rows stand for, in the order shown: the worker's own call, open calls nearest first,
---then the end-shift row.
---@type SwListEntry[]
local entries = {}
local selected = 1

-- Keys the list reads. The game's own uses of them (phone, pause menu, weapon and radio wheels) are
-- off while it is open; driving keeps working.
local KEYS = {
    up = { 172, 15, 241 },      -- arrow up, mouse wheel up (on foot / in a vehicle)
    down = { 173, 14, 242 },    -- arrow down, mouse wheel down
    accept = { 191, 201 },      -- Enter
    cancel = { 200, 202 },      -- Esc, Backspace
}
local BLOCKED = { 27, 172, 173, 174, 175, 176, 177, 191, 200, 201, 202, 14, 15, 16, 17, 81, 82, 99, 100, 241, 242, 261, 262 }

local function send(kind, data)
    data = data or {}
    data.type = kind
    SendNUIMessage(data)
end

local function pressed(keys)
    for _, control in ipairs(keys) do
        if IsDisabledControlJustPressed(0, control) then return true end
    end
    return false
end

local function sound(name)
    PlaySoundFrontend(-1, name, 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end

---Where a point is seen from the camera, in degrees clockwise: 0 straight ahead, 90 to the right.
---@param coords vector3
---@return integer
local function bearing(coords)
    local from = GetEntityCoords(cache.ped)
    local target = GetHeadingFromVector_2d(coords.x - from.x, coords.y - from.y)
    -- Headings turn anticlockwise, the page rotates clockwise.
    return math.floor((GetGameplayCamRot(2).z - target) % 360 + 0.5)
end

---The last row: end the shift, or keep working while on the way back.
local function endRow()
    if calls.returning() then
        return { kind = 'end', title = locale('shift.keep_working'), hint = locale('shift.keep_working_hint') }
    end
    local hint = locale(shift.hasTruck() and 'shift.end_truck' or 'shift.end_office')
    if calls.active() then hint = hint .. ' ' .. locale('shift.end_drops_call') end
    return { kind = 'end', title = locale('shift.end'), hint = hint }
end

---@param list table[] calls.list()
local function build(list)
    local origin = GetEntityCoords(cache.ped)
    entries = {}
    for _, call in ipairs(list) do
        local coords = vec3(call.coords.x, call.coords.y, call.coords.z)
        entries[#entries + 1] = { kind = 'call', call = call, coords = coords, distance = #(origin - coords) }
    end
    table.sort(entries, function(a, b)
        if a.call.mine ~= b.call.mine then return a.call.mine == true end
        return a.distance < b.distance
    end)
    entries[#entries + 1] = { kind = 'end' }
end

local function rows()
    local out = {}
    for i, entry in ipairs(entries) do
        if entry.kind == 'end' then
            out[i] = endRow()
        else
            local call = entry.call --[[@as SwListCall]]
            local coords = entry.coords --[[@as vector3]]
            out[i] = {
                kind = 'call', id = call.id, type = call.type, plate = call.plate, message = call.message,
                age = call.age, mine = call.mine == true, pay = call.pay,
                street = calls.streetAt(coords), metres = entry.distance, bearing = bearing(coords),
            }
        end
    end
    return out
end

---Fetches the calls again and redraws, keeping the chosen row where it can.
---@param selectId? integer the call to choose
local function refresh(selectId)
    local current = entries[selected]
    local keepEnd = not selectId and current and current.kind == 'end'
    selectId = selectId or (current and current.call and current.call.id)
    local list = calls.list()
    if not isOpen then return end
    build(list)
    selected = 1
    for i, entry in ipairs(entries) do
        if (keepEnd and entry.kind == 'end') or (selectId and entry.call and entry.call.id == selectId) then selected = i end
    end
    send('calls', { rows = rows(), selected = selected - 1, left = config.ui.position == 'left' })
end

local function move(step)
    local target = math.max(1, math.min(#entries, selected + step))
    if target == selected then return end
    selected = target
    sound('NAV_UP_DOWN')
    send('callsSelect', { selected = selected - 1 })
end

local function choose()
    local entry = entries[selected]
    if not entry then return end
    sound('SELECT')
    if entry.kind == 'end' then
        calllist.close()
        if calls.returning() then calls.cancelEnd() else calls.endShift() end
        return
    end
    busy = true
    send('callsBusy', { value = true })
    CreateThread(function()
        local call = entry.call --[[@as SwListCall]]
        local ok, errorKey
        if call.mine then
            ok, errorKey = calls.drop(call.id)
            if ok then notify(locale('calls.dropped'), 'inform') end
        else
            ok, errorKey = calls.accept(call)
            if ok then notify(locale('calls.route_set'), 'success') end
        end
        busy = false
        if not ok then notify(locale(errorKey or 'common.failed'), 'error') end
        if not isOpen then return end
        if ok then return calllist.close() end
        send('callsBusy', { value = false })
        refresh()
    end)
end

local function controls()
    while isOpen do
        for _, control in ipairs(BLOCKED) do DisableControlAction(0, control, true) end
        if dialog.current() then
            -- The counter or police window took the screen.
            calllist.close()
        elseif pressed(KEYS.cancel) then
            sound('BACK')
            calllist.close()
        elseif not busy and #entries > 0 then
            if pressed(KEYS.up) then move(-1)
            elseif pressed(KEYS.down) then move(1)
            elseif pressed(KEYS.accept) then choose() end
        end
        Wait(0)
    end
    -- Esc that closed the list must not open the pause menu as it is released.
    local until_ = GetGameTimer() + 250
    while not isOpen and (GetGameTimer() < until_ or IsDisabledControlPressed(0, 200)) do
        DisableControlAction(0, 200, true)
        DisableControlAction(0, 202, true)
        Wait(0)
    end
end

---Distances and arrows follow the player and the camera while the list is open.
local function follow()
    while isOpen do
        Wait(200)
        if not isOpen then return end
        local origin = GetEntityCoords(cache.ped)
        local live = {}
        for i, entry in ipairs(entries) do
            if entry.coords then
                live[#live + 1] = { index = i - 1, metres = #(origin - entry.coords), bearing = bearing(entry.coords) }
            end
        end
        send('callsLive', { rows = live })
    end
end

---Opens the list, or closes it when it is open (the list key toggles).
---@param opts? { select?: integer } select: the call to choose (filming)
function calllist.open(opts)
    if isOpen then return calllist.close() end
    if not shift.onShift() or dialog.current() then return end
    isOpen, busy, selected, entries = true, false, 1, {}
    CreateThread(controls)
    CreateThread(follow)
    refresh(opts and opts.select)
end

function calllist.close()
    if not isOpen then return end
    isOpen = false
    send('callsClose')
end

---Keys of the calls section the page uses.
calllist.STRING_KEYS = {
    'title', 'nearest', 'take', 'drop', 'your_call', 'just_now', 'min_ago', 'keys_choose', 'keys_close', 'empty',
    'type_player', 'type_police', 'type_contract', 'type_abandoned',
}

---Texts the page needs, sent with its init message.
---@return table<string, string>
function calllist.strings()
    local strings = { label = config.ui.label or 'Shiftworks · Tow' }
    for _, key in ipairs(calllist.STRING_KEYS) do strings[key] = locale('calls.' .. key) end
    strings.km, strings.m = locale('panel.km'), locale('panel.m')
    return strings
end

-- The list changes while it is open: someone else took a call, a new one came in.
local function changed()
    if isOpen and not busy then CreateThread(function() refresh() end) end
end
AddEventHandler('sw_tow:client:callsChanged', changed)
AddEventHandler('sw_tow:client:callClosed', changed)

AddStateBagChangeHandler('sw_tow:shift', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not value then calllist.close() end
end)

if dialog.enabled() then
    calls.openList = calllist.open
    calls.closeList = calllist.close
end

return calllist
