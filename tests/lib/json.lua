---Minimal JSON decoder for the test suite (locale files). Objects become tables, arrays sequences.
local json = {}

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

---@param text string
---@return any
function json.decode(text)
    local pos = 1

    local function fail(what)
        error(('json: %s at character %d'):format(what, pos), 0)
    end

    local function skip()
        pos = text:find('[^ \t\r\n]', pos) or #text + 1
    end

    local value

    local function str()
        pos = pos + 1
        local out = {}
        while true do
            local c = text:sub(pos, pos)
            if c == '' then fail('unterminated string') end
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            end
            if c == '\\' then
                local e = text:sub(pos + 1, pos + 1)
                if e == 'u' then
                    local code = tonumber(text:sub(pos + 2, pos + 5), 16)
                    if not code then fail('bad unicode escape') end
                    out[#out + 1] = utf8.char(code)
                    pos = pos + 6
                elseif escapes[e] then
                    out[#out + 1] = escapes[e]
                    pos = pos + 2
                else
                    fail('bad escape')
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
    end

    function value()
        skip()
        local c = text:sub(pos, pos)
        if c == '{' then
            local obj = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end
            while true do
                skip()
                if text:sub(pos, pos) ~= '"' then fail('expected key') end
                local key = str()
                skip()
                if text:sub(pos, pos) ~= ':' then fail('expected colon') end
                pos = pos + 1
                if obj[key] ~= nil then fail('duplicate key "' .. key .. '"') end
                obj[key] = value()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == '}' then return obj end
                if sep ~= ',' then fail('expected comma') end
            end
        elseif c == '[' then
            local arr = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            while true do
                arr[#arr + 1] = value()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == ']' then return arr end
                if sep ~= ',' then fail('expected comma') end
            end
        elseif c == '"' then
            return str()
        elseif text:find('^true', pos) then
            pos = pos + 4
            return true
        elseif text:find('^false', pos) then
            pos = pos + 5
            return false
        elseif text:find('^null', pos) then
            pos = pos + 4
            return nil
        else
            local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
            if not number or number == '' then fail('unexpected character') end
            pos = pos + #number
            return tonumber(number)
        end
    end

    local result = value()
    skip()
    if pos <= #text then fail('trailing characters') end
    return result
end

---Enough of json.encode for log payloads in tests.
function json.encode(v)
    local kind = type(v)
    if kind == 'table' then
        local parts = {}
        if #v > 0 then
            for i = 1, #v do parts[i] = json.encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        for k, item in pairs(v) do parts[#parts + 1] = ('%q:%s'):format(tostring(k), json.encode(item)) end
        return '{' .. table.concat(parts, ',') .. '}'
    elseif kind == 'string' then
        return ('%q'):format(v)
    elseif v == nil then
        return 'null'
    end
    return tostring(v)
end

return json
