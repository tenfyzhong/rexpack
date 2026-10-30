package.path = './tests/vendor/?.lua;' .. package.path
local lu = require('luaunit')
TestBuild = {}
function TestBuild:testForms()
    local manager = dofile('manage.lua')
    local calls = {}
    local api = {exec = function(argv, opts)
        calls[#calls + 1] = {argv = argv, opts = opts}
        return {ok = true, stdout = 'built', stderr = '', code = 0}
    end}
    local p = {name = 'sample', dir = '/path with spaces', spec = {build = 'make install'}}
    manager.build(p, 'install', {}, api)
    lu.assertEquals(calls[1].argv, {'/bin/sh', '-c', 'make install'})
    lu.assertEquals(calls[1].opts.cwd, p.dir)
    p.spec.build = {'make', 'PREFIX=/path with spaces', 'install'}
    manager.build(p, 'update', {}, api)
    lu.assertEquals(calls[2].argv, p.spec.build)
    p.spec.build = function(plugin) lu.assertEquals(plugin.reason, 'build') end
    manager.build(p, 'build', {}, api)
end
function TestBuild:testFailure()
    local manager = dofile('manage.lua')
    local p = {name = 'sample', dir = '/tmp', spec = {build = 'false'}}
    lu.assertErrorMsgContains('build failed', manager.build, p, 'install', {}, {
        exec = function() return {ok = false, code = 1, stderr = 'failure'} end,
    })
    lu.assertEquals(p.build_status, 'build_failed')
end
os.exit(lu.LuaUnit.run())
