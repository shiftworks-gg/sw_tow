local test = require 'test'

test.suite('static › every Lua file compiles')

---Lua files of the resource (tracked and new), without the test suite itself.
local function luaFiles()
    local pipe = assert(io.popen(('git -C "%s" ls-files --cached --others --exclude-standard -- "*.lua"'):format(ROOT)))
    local files = {}
    for line in pipe:lines() do
        if not line:match('^tests/') and not line:match('^%.check/') then files[#files + 1] = line end
    end
    pipe:close()
    return files
end

test.case('all resource files parse as Lua 5.4', function()
    local files = luaFiles()
    test.truthy(#files > 20, 'found the resource files')
    local broken = {}
    for _, file in ipairs(files) do
        local _, err = loadfile(ROOT .. '/' .. file, 't')
        if err then broken[#broken + 1] = err end
    end
    test.eq(#broken, 0, table.concat(broken, '\n'))
end)

test.case('fxmanifest lists every client and shared file the client loads', function()
    local manifest = assert(io.open(ROOT .. '/fxmanifest.lua')):read('a')
    for _, pattern in ipairs({ "'config.lua'", "'shared/%*.lua'", "'client/%*.lua'", "'bridge/loader.lua'", "'locales/%*.json'" }) do
        test.truthy(manifest:find(pattern), 'fxmanifest files{} has ' .. pattern)
    end
end)
