---Server entry point: dependency checks, database, integrations, then the feature modules.
assert(lib.checkDependency('ox_lib', '3.30.0', true))
assert(lib.checkDependency('ox_target', '1.17.0', true))
assert(lib.checkDependency('oxmysql', '2.10.0', true))

local framework = require 'bridge.loader'
local integrations = require 'bridge.integrations'
local storage = require 'server.storage'
require 'server.shift'
require 'server.tow'
require 'server.calls'
require 'server.police'
require 'server.contracts'
require 'server.abandoned'
local impound = require 'server.impound'

local version = GetResourceMetadata(cache.resource, 'version', 0)

MySQL.ready(function()
    storage.migrate()
    impound.load()
    integrations.garage.protect(impound.isHeld)
    print(('^3[sw_tow]^7 Shiftworks Tow & Impound %s · framework %s · garage %s · keys %s · banking %s'):format(
        version, framework.name, integrations.names.garage, integrations.names.keys, integrations.names.banking))
    if integrations.names.garage == 'none' then
        lib.print.warn('No supported garage script found: owned vehicles cannot be impounded.')
    end
end)
