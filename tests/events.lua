package.path = './.test-deps/share/lua/5.1/?.lua;' .. package.path
local lu = require('luaunit')
TestEvents = {}
function TestEvents:testGenerationAndSingleOwner()
    local events = dofile('events.lua')
    local control = events.controller('generation', true, {sources = {}})
    lu.assertFalse(control({generation = 'check', owner = 'one', op = 'claim'}).ok)
    lu.assertTrue(control({generation = 'generation', owner = 'one', op = 'claim'}).ok)
    lu.assertFalse(control({generation = 'generation', owner = 'two', op = 'claim'}).ok)
    lu.assertTrue(control({generation = 'generation', owner = 'one', op = 'alive'}).ok)
    lu.assertFalse(control({generation = 'old', owner = 'one', op = 'alive'}).ok)
end
function TestEvents:testDisabled()
    local control = dofile('events.lua').controller('generation', false, {})
    lu.assertFalse(control({generation = 'generation', owner = 'one', op = 'claim'}).ok)
end
function TestEvents:testEventsDoNotRunInit()
    local manager = dofile('init.lua')
    local called = 0
    local i = manager.inspect({spec = {{name = 'event_plugin', dir = '.',
        init = function() error('init must not run') end,
        events = function() called = called + 1 end,
    }}})
    i:attach_loader()
    i:register_events()
    lu.assertEquals(called, 1)
end
os.exit(lu.LuaUnit.run())
