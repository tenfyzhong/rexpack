package.path = './.test-deps/share/lua/5.1/?.lua;' .. package.path
local json = require('dkjson')

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function exec(argv, options)
    options = options or {}
    local parts = {'env'}
    for key, value in pairs(options.env or {}) do
        parts[#parts + 1] = quote(key .. '=' .. value)
    end
    for _, value in ipairs(argv) do
        parts[#parts + 1] = quote(value)
    end
    local command = table.concat(parts, ' ')
    if options.cwd then command = 'cd ' .. quote(options.cwd) .. ' && ' .. command end

    local stderr_path = os.tmpname()
    -- Lua 5.1 does not reliably return the child's status from pipe:close().
    local pipe = assert(io.popen('(' .. command .. ') 2>' .. quote(stderr_path) .. '; printf "\\n%d" "$?"'))
    local stdout, status = pipe:read('*a'):match('^(.*)\n(%d+)$')
    pipe:close()
    local file = assert(io.open(stderr_path))
    local stderr = file:read('*a')
    file:close()
    os.remove(stderr_path)
    return {ok = status == '0', code = tonumber(status), stdout = stdout, stderr = stderr}
end

rex = {exec = exec, json = json, stop = os.exit}
return rex
