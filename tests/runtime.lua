package.path = './tests/vendor/?.lua;./?.lua;' .. package.path
local lu = require('luaunit')
TestRuntime = {}
function TestRuntime:testLazy()
    local manager = dofile('init.lua')
    local called = 0
    package.preload.example = function() called = called + 1; return {value = 42} end
    local instance = manager.setup({spec = {{name = 'example', dir = '.', main = 'example'}}})
    lu.assertEquals(called, 0)
    lu.assertEquals(instance:load('example').value, 42)
    instance:load('example')
    lu.assertEquals(called, 1)
end
function TestRuntime:testCycles()
    local manager = dofile('init.lua')
    lu.assertErrorMsgContains('cycle', manager.setup, {spec = {
        {name = 'a', dir = '.', dependencies = {'b'}},
        {name = 'b', dir = '.', dependencies = {'a'}},
    }})
end
function TestRuntime:testNativeRequire()
    local manager = dofile('init.lua')
    local count = 0
    package.loaded.native_example = nil
    package.preload.native_example = function() return {value = 9} end
    local instance = manager.setup({spec = {{name = 'native_example', dir = '.',
        config = function() count = count + 1 end}}})
    lu.assertEquals(require('native_example').value, 9)
    lu.assertEquals(count, 1)
    lu.assertEquals(instance.plugins.native_example.state, 'loaded')
    lu.assertEquals(instance.plugins.native_example.reason, 'require:native_example')
end
function TestRuntime:testInspectDoesNotInitialize()
    local manager = dofile('init.lua')
    local instance = manager.inspect({spec = {{name = 'inspect', dir = '.',
        init = function() error('must not initialize') end}}})
    lu.assertEquals(instance.plugins.inspect.source, 'local')
end
function TestRuntime:testConflictingModules()
    local manager = dofile('init.lua')
    lu.assertErrorMsgContains('module conflict', manager.setup, {spec = {
        {name = 'one', dir = '.', main = 'shared'},
        {name = 'two', dir = '.', main = 'shared.child'},
    }})
end
function TestRuntime:testConflictingVersions()
    local manager = dofile('init.lua')
    lu.assertErrorMsgContains('version', manager.setup, {spec = {
        {name = 'one', dir = '.', branch = 'main', tag = 'v1'},
    }})
end
function TestRuntime:testProfileDoesNotLoad()
    local manager = dofile('init.lua')
    local instance = manager.setup({spec = {{name = 'profile_only', dir = '.'}}})
    lu.assertEquals(instance:profile().plugins[1].state, 'unloaded')
end
function TestRuntime:testDevResolution()
    local old = rex
    rex = {exec = function(argv) return {ok = argv[3] == '/development/project'} end}
    local m = dofile('init.lua')
    local i = m.inspect({dev = {path = '/development'}, spec = {
        {'owner/project', dev = true}, {name = 'local', dir = '/local', dev = true},
    }})
    lu.assertEquals(i.plugins.project.dir, '/development/project')
    lu.assertEquals(i.plugins.project.source, 'dev')
    lu.assertEquals(i.plugins['local'].source, 'local')
    lu.assertErrorMsgContains('missing dev', m.inspect, {dev = {path = '/missing'},
        spec = {{'owner/project', dev = true}}})
    rex = old
end
function TestRuntime:testFailureDoesNotRetry()
    local m = dofile('init.lua')
    local calls = 0
    package.preload.broken = function() calls = calls + 1; error('broken module') end
    local i = m.setup({spec = {{name = 'broken', dir = '.'}}})
    lu.assertErrorMsgContains('broken module', i.load, i, 'broken')
    lu.assertErrorMsgContains('broken module', i.load, i, 'broken')
    lu.assertEquals(calls, 1)
end
os.exit(lu.LuaUnit.run())
