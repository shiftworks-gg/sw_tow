---Game sounds for the trucks: ramps, the winch motor, the straps and the tow arm. They play from the
---truck on every client near it, so they come from the right place, fade with distance and follow
---the game's volume settings. The same state bags that move the ramps and the cable start them.
---config.sounds picks them; /swtow_sounds plays the candidates so they can be chosen by ear.
-- PlaySoundFromEntity takes nil as the soundset for sounds that have none.
---@diagnostic disable: param-type-mismatch
local config = require 'config'

local sounds = {}

---@param event string key of config.sounds
---@return string? name, string? set
local function resolve(event)
    local cfg = config.sounds
    local entry = cfg and cfg.enabled and cfg[event]
    if type(entry) ~= 'table' then return end
    return entry[1], entry[2] or nil
end

---A one-shot sound from an entity.
---@param event string key of config.sounds
---@param entity integer
function sounds.play(event, entity)
    local name, set = resolve(event)
    if not name or not DoesEntityExist(entity) then return end
    PlaySoundFromEntity(-1, name, entity, set, false, 0)
end

---A sound that keeps playing from an entity: call keep() every frame, stop() at the end. A sound
---that ends by itself starts again, so short sounds work as a loop too.
---@param event string key of config.sounds
---@param entity integer
---@return { keep: fun(), stop: fun() }
function sounds.loop(event, entity)
    local name, set = resolve(event)
    if not name then return { keep = function() end, stop = function() end } end
    local id = GetSoundId()
    PlaySoundFromEntity(id, name, entity, set, false, 0)
    return {
        keep = function()
            if HasSoundFinished(id) and DoesEntityExist(entity) then
                PlaySoundFromEntity(id, name, entity, set, false, 0)
            end
        end,
        stop = function()
            StopSound(id)
            ReleaseSoundId(id)
        end,
    }
end

-- Candidates for /swtow_sounds, by event. Names from the game's audio (soundset false = none).
local CANDIDATES = {
    rampsDown = {
        { 'Enter_Car_Ramp_Deploy', 'DLC_GR_MOC_Enter_Exit_Sounds' },
        { 'Enter_Car_Ramp_Hits_Ground', 'DLC_GR_MOC_Enter_Exit_Sounds' },
        { 'RAMP_DOWN', 'TRUCK_RAMP_DOWN' },
        { 'Open', 'Truck_Ramp_Sounds' },
        { 'Hydraulics_Down', 'Lowrider_Super_Mod_Garage_Sounds' },
        { 'ramp_fall', 'DLC_BTL_Collector_Sounds' },
    },
    rampsUp = {
        { 'RAMP_UP', 'TRUCK_RAMP_DOWN' },
        { 'Truck_Ramp_Raise', 'BIG_SCORE_3A_SOUNDS' },
        { 'Close', 'Truck_Ramp_Sounds' },
        { 'Hydraulics_Up', 'Lowrider_Super_Mod_Garage_Sounds' },
    },
    winch = {
        { 'Move_U_D', 'CRANE_SOUNDS' },
        { 'Strain', 'CRANE_SOUNDS' },
        { 'Motor_01', 'FREIGHT_ELEVATOR_SOUNDS' },
        { 'Running', 'CABLE_CAR_SOUNDS' },
        { 'Cable_Strain', 'FBI_05_SOUNDS' },
        { 'Move', 'LIFT_NORMAL_SOUNDSET' },
        { 'FREIGHT_ELEVATOR_02_MOTOR', false },
    },
    secured = {
        { 'Clamp', 'CRANE_SOUNDS' },
        { 'Attach_Container', 'CRANE_SOUNDS' },
        { 'Container_Attach', 'CONTAINER_LIFTER_SOUNDS' },
        { 'hook_attach', 'DLC_SM_Precision_Delivery_Sounds' },
    },
    hookOn = {
        { 'Hook_Engage', 'DLC_IE_Steal_Cargobob_Sounds' },
        { 'Hook_Attach', 'DLC_IE_Steal_Cargobob_Sounds' },
        { 'hook_attach', 'DLC_SM_Precision_Delivery_Sounds' },
        { 'Clamp', 'CRANE_SOUNDS' },
    },
    hookOff = {
        { 'Hook_Detach', 'DLC_IE_Steal_Cargobob_Sounds' },
        { 'hook_detach', 'DLC_SM_Precision_Delivery_Sounds' },
        { 'Container_Release', 'CONTAINER_LIFTER_SOUNDS' },
    },
}

-- Picking sounds by ear: /swtow_sounds [event]. Plays every candidate for 4 seconds from your truck
-- (or from you), names them on screen and in F8. Copy the one you like into config.sounds.
RegisterCommand('swtow_sounds', function(_, args)
    local events = args[1] and { args[1] } or { 'rampsDown', 'rampsUp', 'winch', 'secured', 'hookOn', 'hookOff' }
    CreateThread(function()
        local shift = require 'client.shift'
        for _, event in ipairs(events) do
            local list = CANDIDATES[event]
            if not list then
                print(('[sw_tow] no sound event "%s"'):format(event))
            else
                for i, candidate in ipairs(list) do
                    local source = shift.truck() or cache.ped
                    local text = ('%s %d/%d · { \'%s\', %s }'):format(event, i, #list, candidate[1],
                        candidate[2] and ("'" .. candidate[2] .. "'") or 'false')
                    print('[sw_tow] sound ' .. text)
                    lib.showTextUI(text, { position = 'top-center' })
                    local id = GetSoundId()
                    PlaySoundFromEntity(id, candidate[1], source, candidate[2] or nil, false, 0)
                    Wait(4000)
                    StopSound(id)
                    ReleaseSoundId(id)
                    Wait(600)
                end
            end
        end
        lib.hideTextUI()
    end)
end, false)

return sounds
