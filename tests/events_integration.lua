package.path = './tests/vendor/?.lua;' .. package.path
local date = os.date
os.date = function(format, time) return date(format or '%c', time or os.time()) end
local lu = require('luaunit')
local root = assert(os.getenv('REXPACK_ROOT'))
local binary = assert(os.getenv('REX_BIN'))
local function exec(argv, opts)
    local r, err = rex.exec(argv, opts or {timeout = 10})
    assert(r and r.ok, err or (r and (r.stderr .. r.stdout)))
    return r.stdout:gsub('\n$', '')
end
local function write(path, data)
    local f = assert(io.open(path, 'w')); assert(f:write(data)); f:close()
end
local function read(path)
    local f = io.open(path); if not f then return '' end
    local data = f:read('*a'); f:close(); return data
end
local function wait_for(fn, message)
    for _ = 1, 100 do
        local ok, result = pcall(fn)
        if ok and result then return result end
        rex.sleep(0.1)
    end
    error(message)
end
TestEventsLive = {}
function TestEventsLive:command(...)
    local argv = {binary, '--autostart=false', '--server', self.endpoint, '--timeout', '2s'}
    for _, v in ipairs({...}) do argv[#argv + 1] = v end
    return exec(argv)
end
function TestEventsLive:status()
    return rex.json.decode(self:command('do', 'rexpack_events_control', 'op=status'))
end
function TestEventsLive:setUp()
    self.tmp = exec({'mktemp', '-d', '/tmp/rexpack-events.XXXXXX'})
    self.endpoint = 'unix://' .. self.tmp .. '/rex.sock'
    exec({'mkdir', '-p', self.tmp .. '/plugins', self.tmp .. '/modules'})
    self.marker = self.tmp .. '/events.txt'
    write(self.tmp .. '/modules/event_fixture.lua', 'return {handle = function() local f = assert(io.open(' ..
        string.format('%q', self.marker) .. ', "a")); f:write("event\\n"); f:close() end}\n')
    self.spec = 'return {name="event_fixture", dir=' .. string.format('%q', self.tmp .. '/modules') ..
        ', init=function() end, events=function() rex.on("session_created", function() require("event_fixture").handle() end) end}\n'
    write(self.tmp .. '/plugins/test.lua', self.spec)
    self.config = 'dofile(' .. string.format('%q', root .. '/init.lua') .. ').setup({base=' ..
        string.format('%q', self.tmp) .. ', root=' .. string.format('%q', self.tmp .. '/data') .. ', spec="plugins", events={rex_bin=' .. string.format('%q', binary) ..
        ', server=' .. string.format('%q', self.endpoint) .. ', startup_attempts=4}})\n'
    write(self.tmp .. '/init.lua', self.config)
    exec({binary, 'config', 'check', self.tmp .. '/init.lua'})
    self.server = assert(rex.exec.start({binary, 'server', 'run', '--listen', self.endpoint,
        '--state-dir', self.tmp .. '/state', '--config', self.tmp .. '/init.lua'},
        {stdout = false, stderr = false}))
    local ok, err = pcall(wait_for, function() return self:status().state == 'running' end, 'runner did not start')
    if not ok then
        print(self:command('do', 'rexpack_events_control', 'op=status'))
        print(read(self.tmp .. '/data/events.log'))
        error(err)
    end
end
function TestEventsLive:tearDown()
    if self.server then self.server:kill(); self.server:wait(3) end
    rex.sleep(1.2)
    if self.tmp then exec({'rm', '-rf', self.tmp}) end
end
function TestEventsLive:process_exists(pid)
    local result = rex.exec({'kill', '-0', tostring(pid)})
    return result and result.ok
end
function TestEventsLive:testMultiplePluginsShareRunnerAndRegistrationFailure()
    write(self.tmp .. '/plugins/second.lua', 'return {name="second", lazy=true, dir=' ..
        string.format('%q', self.tmp .. '/modules') .. ', events=function() rex.on("session_created", function() ' ..
        'local f=assert(io.open(' .. string.format('%q', self.tmp .. '/second.txt') ..
        ', "a")); f:write("second"); f:close() end) end}')
    local first = self:status()
    self:command('config', 'reload')
    local current = wait_for(function()
        local status = self:status()
        if status.state == 'running' and status.owner ~= first.owner then return status end
    end, 'shared runner not ready')
    self:command('new', 'shared-event')
    wait_for(function() return read(self.marker) == 'event\n' and
        read(self.tmp .. '/second.txt') == 'second' end, 'both plugins did not receive event')
    lu.assertEquals(self:status().pid, current.pid)
    write(self.tmp .. '/plugins/second.lua', 'return {name="second", lazy=true, dir=' ..
        string.format('%q', self.tmp .. '/modules') .. ', events=function() error("registration failed") end}')
    self:command('config', 'reload')
    local failed = wait_for(function()
        local status = self:status()
        if status.state == 'failed' then return status end
    end, 'registration failure not reported')
    lu.assertStrContains(failed.error, 'registration failed')
    wait_for(function() return not self:process_exists(failed.pid) end, 'failed runner survived')
end
function TestEventsLive:testCrashReloadAndServerShutdown()
    local first = self:status()
    lu.assertTrue(self:process_exists(first.pid))
    exec({'kill', '-TERM', tostring(first.pid)})
    wait_for(function() return self:status().state == 'exited' end, 'runner exit not reported')
    self:command('config', 'reload')
    local current = wait_for(function()
        local status = self:status()
        if status.state == 'running' and status.owner ~= first.owner then return status end
    end, 'reload did not recover runner')
    self.server:kill(); self.server:wait(3); self.server = nil
    wait_for(function() return not self:process_exists(current.pid) end, 'runner survived server shutdown')
end
function TestEventsLive:testStartupCheckReloadAndDisable()
    local first = self:status()
    self:command('new', 'event-one')
    wait_for(function() return read(self.marker) == 'event\n' end, 'first event was not dispatched')
    exec({binary, 'config', 'check', self.tmp .. '/init.lua'})
    rex.sleep(1.5)
    lu.assertEquals(self:status().owner, first.owner)
    write(self.tmp .. '/init.lua', self.config .. 'error("invalid config")\n')
    local bad = rex.exec({binary, '--server', self.endpoint, 'config', 'reload'})
    lu.assertFalse(bad.ok)
    lu.assertEquals(self:status().generation, first.generation)
    write(self.tmp .. '/init.lua', self.config)
    self:command('config', 'reload')
    wait_for(function() local s = self:status(); return s.state == 'running' and s.generation ~= first.generation end,
        'new generation did not start')
    wait_for(function() return not self:process_exists(first.pid) end, 'old runner survived reload')
    local second = self:status()
    self:command('new', 'event-two')
    wait_for(function() return read(self.marker) == 'event\nevent\n' end, 'reload duplicated or lost event')
    write(self.tmp .. '/plugins/test.lua', 'return {name="event_fixture", dir=' .. string.format('%q', self.tmp .. '/modules') .. '}')
    self:command('config', 'reload')
    wait_for(function() return self:status().state == 'disabled' end, 'events not disabled')
    wait_for(function() return not self:process_exists(second.pid) end, 'disabled runner survived')
    self:command('new', 'event-three')
    rex.sleep(0.3)
    lu.assertEquals(read(self.marker), 'event\nevent\n')
end
local failures = lu.LuaUnit.run()
if failures > 0 then rex.stop(1) end
