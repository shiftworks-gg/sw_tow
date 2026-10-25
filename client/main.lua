---Client entry point. Every module registers its targets and handlers when required.
local shift = require 'client.shift'
local impound = require 'client.impound'
require 'client.notify'
require 'client.tow'
require 'client.calls'
require 'client.police'
require 'client.contracts'
require 'client.panel'
require 'client.devspots'

shift.createOffice()
impound.createCounters()

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    exports.ox_target:removeZone('sw_tow_office')
end)
