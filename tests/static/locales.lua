local test = require 'test'
local json = require 'json'

test.suite('static › locales')

local LANGUAGES = { 'en', 'de', 'ru' }

local function read(path)
    local file = assert(io.open(ROOT .. '/' .. path, 'rb'))
    local text = file:read('a')
    file:close()
    return text
end

---Flattens { a = { b = 'x' } } to { ['a.b'] = 'x' }.
local function flatten(tbl, prefix, out)
    out = out or {}
    for key, value in pairs(tbl) do
        local full = prefix and (prefix .. '.' .. key) or key
        if type(value) == 'table' then flatten(value, full, out) else out[full] = value end
    end
    return out
end

local locales = {}
for _, lang in ipairs(LANGUAGES) do
    locales[lang] = flatten(json.decode(read('locales/' .. lang .. '.json')))
end

---Placeholders in order, e.g. { '%s', '%d' }.
local function placeholders(text)
    local list = {}
    for spec in text:gmatch('%%[%-%d%.]*[sdif]') do list[#list + 1] = spec end
    return table.concat(list, ' ')
end

test.case('every language has exactly the English keys', function()
    local problems = {}
    for _, lang in ipairs(LANGUAGES) do
        for key in pairs(locales.en) do
            if locales[lang][key] == nil then problems[#problems + 1] = lang .. ': missing ' .. key end
        end
        for key in pairs(locales[lang]) do
            if locales.en[key] == nil then problems[#problems + 1] = lang .. ': extra ' .. key end
        end
    end
    table.sort(problems)
    test.eq(#problems, 0, table.concat(problems, '\n'))
end)

test.case('placeholders (%s, %d) match the English text in every language', function()
    local problems = {}
    for key, english in pairs(locales.en) do
        for _, lang in ipairs(LANGUAGES) do
            local text = locales[lang][key]
            if type(text) == 'string' and placeholders(text) ~= placeholders(english) then
                problems[#problems + 1] = ('%s %s: "%s" vs en "%s"'):format(lang, key, placeholders(text), placeholders(english))
            end
        end
    end
    table.sort(problems)
    test.eq(#problems, 0, table.concat(problems, '\n'))
end)

test.case('no stray percent signs (a lone % breaks string.format)', function()
    local problems = {}
    for _, lang in ipairs(LANGUAGES) do
        for key, text in pairs(locales[lang]) do
            local stripped = text:gsub('%%%%', ''):gsub('%%[%-%d%.]*[sdif]', '')
            if stripped:find('%%') then problems[#problems + 1] = lang .. ' ' .. key end
        end
    end
    test.eq(#problems, 0, table.concat(problems, '\n'))
end)

---Every locale key the code can ask for.
local function usedKeys()
    local sections = {}
    for key in pairs(locales.en) do sections[key:match('^([^.]+)')] = true end

    local pipe = assert(io.popen(('git -C "%s" ls-files --cached --others --exclude-standard -- "*.lua"'):format(ROOT)))
    local used = {}
    for file in pipe:lines() do
        -- configcheck.lua names config paths ('abandoned.enabled'), not locale keys.
        if not file:match('^tests/') and not file:match('^%.check/') and file ~= 'server/configcheck.lua' then
            local text = read(file)
            for literal in text:gmatch("'([%w_]+%.[%w_]*[%w])'") do
                if sections[literal:match('^([^.]+)')] then used[literal] = file end
            end
        end
    end
    pipe:close()

    -- Keys built at runtime.
    for _, callType in ipairs({ 'player', 'police', 'contract', 'abandoned' }) do
        used['calls.new_' .. callType] = 'server/calls.lua'
        used['calls.type_' .. callType] = 'client/calls.lua'
    end
    for _, kind in ipairs({ 'success', 'inform', 'warning', 'error' }) do used['notify.' .. kind] = 'client/notify.lua' end
    local panel = read('client/panel.lua'):match('STRING_KEYS = (%b{})')
    for key in panel:gmatch("'([%w_]+)'") do used['panel.' .. key] = 'client/panel.lua' end
    return used
end

test.case('every key the code uses exists', function()
    local missing = {}
    for key, file in pairs(usedKeys()) do
        if locales.en[key] == nil then missing[#missing + 1] = key .. ' (' .. file .. ')' end
    end
    table.sort(missing)
    test.eq(#missing, 0, table.concat(missing, '\n'))
end)

test.case('no unused keys', function()
    local used = usedKeys()
    local unused = {}
    for key in pairs(locales.en) do
        if not used[key] then unused[#unused + 1] = key end
    end
    table.sort(unused)
    test.eq(#unused, 0, table.concat(unused, '\n'))
end)
