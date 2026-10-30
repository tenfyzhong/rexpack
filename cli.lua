local root = assert(os.getenv('REXPACK_ROOT'), 'Run bin/rexpack')
local operation = os.getenv('REXPACK_COMMAND')
local name = os.getenv('REXPACK_NAME')
if name == '' then name = nil end
local function run()
    if operation == 'profile' then
        local result, err = rex.invoke('rexpack_profile')
        assert(result, err or 'Rexpack is not loaded in the running Rex configuration')
        return result
    end
    local config = os.getenv('REXPACK_CONFIG')
    config = config:gsub('^~/', os.getenv('HOME') .. '/')
    if config:sub(1, 1) ~= '/' then
        local r = rex.exec({'pwd'})
        assert(r and r.ok, 'cannot resolve working directory')
        config = r.stdout:gsub('\n$', '') .. '/' .. config
    end
    local base = assert(config:match('^(.*)/[^/]+$'))
    package.path = base .. '/?.lua;' .. base .. '/?/init.lua;' .. package.path
    local options = assert(loadfile(config))()
    options.base = base
    local instance = dofile(root .. '/init.lua').inspect(options)
    local manager = dofile(root .. '/manage.lua')
    if operation == 'list' or operation == 'show' then
        local rows = manager.list(instance)
        if operation == 'show' then
            assert(name, 'show requires a plugin name')
            for _, row in ipairs(rows) do if row.name == name then return row end end
            error('unknown plugin: ' .. name)
        end
        return rows
    end
    return manager.run(instance, operation, name)
end
local ok, result = pcall(run)
if not ok then print('rexpack: ' .. tostring(result)); rex.stop(1) end
if os.getenv('REXPACK_JSON') == '1' then
    print(assert(rex.json.encode(result, {indent = true})))
else
    local rows = result.plugins or (result.name and {result}) or result
    if #rows == 0 then print('No plugins') end
    for _, row in ipairs(rows) do
        print(row.name .. '  ' .. (row.state or row.status or row.source or '') ..
            '  ' .. (row.error or row.commit or row.dir or '') ..
            (row.elapsed and string.format('  %.3f ms', row.elapsed * 1000) or ''))
    end
    if result.ok then print('Done. Run rex config reload to use installed versions.') end
end
if result.ok == false then rex.stop(1) end
