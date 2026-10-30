local root = assert(os.getenv('REXPACK_ROOT'), 'Set REXPACK_ROOT to the checkout')
local manager = dofile(root .. '/init.lua')
local instance = manager.setup({spec = {{name = 'sample', lazy = true, dir = root .. '/tests/fixtures',
    config = function() _G.rexpack_fixture_configured = true end,
    init = function()
        rex.action {name = 'rexpack_fixture', title = 'Rexpack fixture', run = function()
            assert(_G.rexpack_fixture_loads == nil)
            assert(require('sample').value == 42)
            assert(require('sample').value == 42)
            assert(_G.rexpack_fixture_loads == 1)
            assert(_G.rexpack_fixture_configured)
            return {ok = true}
        end}
        rex.bind('ctrl+shift+f12', 'rexpack_fixture')
    end,
}}})
assert(instance:profile().plugins[1].state == 'unloaded')
