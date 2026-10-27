---Offline test suite for sw_tow. Runs the real server code on a simulated FiveM server.
---  lua tests/run.lua            all tests
---  lua tests/run.lua impound    only tests whose suite or name contains "impound"
local here = (arg and arg[0] or 'tests/run.lua'):gsub('\\', '/'):match('^(.*)/[^/]*$') or '.'
local root = here:match('^(.*)/[^/]*$') or '.'
if here == 'tests' then root = '.' end
package.path = here .. '/lib/?.lua;' .. package.path

local test = require 'test'
local World = require 'world'

---A fresh server for one test.
---@param options? table see World.new
function _G.newWorld(options)
    return World.new(root, options):start()
end
_G.ROOT = root

local specs = {
    'static/syntax', 'static/locales', 'static/config',
    'server/util', 'server/shift', 'server/tow', 'server/calls', 'server/impound', 'server/police',
    'server/contracts', 'server/abandoned',
}
for _, name in ipairs(specs) do
    local chunk, err = loadfile(here .. '/' .. name .. '.lua')
    if not chunk then error(err, 0) end
    chunk()
end

os.exit(test.run(arg and arg[1]) and 0 or 1)
