---A small test framework: suites of named cases, assertions with clear messages, and a summary.
local test = {}

local cases = {}
local currentSuite = '?'

---@param name string
function test.suite(name)
    currentSuite = name
end

---@param name string
---@param fn fun()
function test.case(name, fn)
    cases[#cases + 1] = { suite = currentSuite, name = name, fn = fn }
end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

local function fail(message, level)
    error(message, (level or 1) + 2)
end

---@param actual any
---@param expected any
---@param what? string
function test.eq(actual, expected, what)
    if actual ~= expected then
        fail(('%sexpected %s, got %s'):format(what and (what .. ': ') or '', show(expected), show(actual)))
    end
end

---@param actual number
---@param expected number
---@param tolerance number
---@param what? string
function test.near(actual, expected, tolerance, what)
    if type(actual) ~= 'number' or math.abs(actual - expected) > tolerance then
        fail(('%sexpected %s ± %s, got %s'):format(what and (what .. ': ') or '', show(expected), show(tolerance), show(actual)))
    end
end

---@param value any
---@param what? string
function test.truthy(value, what)
    if not value then fail(('%sexpected a true value, got %s'):format(what and (what .. ': ') or '', show(value))) end
end

---@param value any
---@param what? string
function test.falsy(value, what)
    if value then fail(('%sexpected a false value, got %s'):format(what and (what .. ': ') or '', show(value))) end
end

---Checks that a callback's (ok, errorKey) result is a refusal. Pass the call as the last argument:
---Lua keeps all its results only there.
---@param ok any
function test.refused(ok)
    if ok then fail('expected a refusal, got success') end
end

---Checks that a callback refused with this locale key: test.refusedWith('garage.too_far', w:call(...)).
---@param expectedKey string
---@param ok any
---@param errorKey any
function test.refusedWith(expectedKey, ok, errorKey)
    if ok then fail(('expected refusal %s, got success'):format(show(expectedKey))) end
    if errorKey ~= expectedKey then
        fail(('expected refusal %s, got %s'):format(show(expectedKey), show(errorKey)))
    end
end

---@param ok any
---@param errorKey any
function test.accepted(ok, errorKey)
    if not ok then fail(('expected success, got refusal %s'):format(show(errorKey))) end
end

---@param filter string?
---@return boolean allPassed
function test.run(filter)
    local passed, failed, failures = 0, 0, {}
    local lastSuite
    for _, c in ipairs(cases) do
        local full = c.suite .. ' › ' .. c.name
        if not filter or full:lower():find(filter:lower(), 1, true) then
            if c.suite ~= lastSuite then
                print('\n' .. c.suite)
                lastSuite = c.suite
            end
            local ok, err = xpcall(c.fn, debug.traceback)
            if ok then
                passed = passed + 1
                print('  ok    ' .. c.name)
            else
                failed = failed + 1
                print('  FAIL  ' .. c.name)
                failures[#failures + 1] = { name = full, err = err }
            end
        end
    end
    for _, f in ipairs(failures) do
        print(('\n--- %s\n%s'):format(f.name, f.err))
    end
    print(('\n%d passed, %d failed'):format(passed, failed))
    return failed == 0
end

return test
