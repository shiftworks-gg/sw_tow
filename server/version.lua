---Update check: one console line when a newer release is out on GitHub. Uses the `repository`
---entry in fxmanifest.lua (https://github.com/<owner>/<repo>); without it nothing is checked.

---@param version string
---@return integer[]?
local function parse(version)
    local major, minor, patch = version:match('^v?(%d+)%.(%d+)%.(%d+)')
    if not major then return end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

---@param a integer[]
---@param b integer[]
local function newer(a, b)
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    return false
end

local current = GetResourceMetadata(cache.resource, 'version', 0) or ''
local repository = GetResourceMetadata(cache.resource, 'repository', 0) or ''
local slug = repository:match('^https://github%.com/([%w%-_%.]+/[%w%-_%.]+)/?$')

if slug and parse(current) then
    SetTimeout(5000, function()
        PerformHttpRequest(('https://api.github.com/repos/%s/releases/latest'):format(slug), function(status, body)
            if status ~= 200 or not body then return end
            local ok, release = pcall(json.decode, body)
            if not ok or type(release) ~= 'table' or type(release.tag_name) ~= 'string' then return end
            local latest = parse(release.tag_name)
            if latest and newer(latest, parse(current) --[[@as integer[] ]]) then
                print(('^3[sw_tow]^7 Update available: %s → %s · %s'):format(current, release.tag_name, release.html_url or repository))
            end
        end, 'GET', '', { ['User-Agent'] = 'sw_tow', Accept = 'application/vnd.github+json' })
    end)
end
