package.path = './.test-deps/share/lua/5.1/?.lua;' .. package.path
local date = os.date
os.date = function(format, time) return date(format or '%c', time or os.time()) end
local lu = require('luaunit')
local function exec(argv, cwd)
    local r, err = rex.exec(argv, {cwd = cwd, timeout = 10})
    assert(r and r.ok, err or (r and r.stderr))
    return r.stdout:gsub('\n$', '')
end
local function write(path, value)
    local f = assert(io.open(path, 'w')); f:write(value); f:close()
end
TestGit = {}
function TestGit:setUp()
    self.tmp = exec({'mktemp', '-d'})
    self.repo = self.tmp .. '/source'
    exec({'git', 'init', '-b', 'main', self.repo})
    exec({'git', 'config', 'core.hooksPath', '/dev/null'}, self.repo)
    exec({'git', 'config', 'user.email', 'test@example.com'}, self.repo)
    exec({'git', 'config', 'user.name', 'Fixture'}, self.repo)
    write(self.repo .. '/sample.lua', 'return {value = 1}')
    exec({'git', 'add', '.'}, self.repo)
    exec({'git', 'commit', '-s', '-m', 'Initial'}, self.repo)
    self.first = exec({'git', 'rev-parse', 'HEAD'}, self.repo)
    self.manager = dofile('manage.lua')
    self.runtime = dofile('init.lua').inspect({base = self.tmp, root = self.tmp .. '/installed',
        spec = {{name = 'sample', url = self.repo, build = 'printf built > artifact'}}})
end
function TestGit:tearDown() exec({'rm', '-rf', self.tmp}) end
function TestGit:testLifecycle()
    local result = self.manager.run(self.runtime, 'install')
    lu.assertTrue(result.ok)
    local p = self.runtime.plugins.sample
    lu.assertEquals(exec({'git', 'rev-parse', 'HEAD'}, p.dir), self.first)
    local lock = assert(io.open(self.runtime.options.lockfile)):read('*a')
    write(self.repo .. '/sample.lua', 'return {value = 2}')
    exec({'git', 'commit', '-s', '-am', 'Update'}, self.repo)
    -- Build outputs are deliberately ignored by the fixture, as real plugins should do.
    write(p.dir .. '/.git/info/exclude', 'artifact\n')
    lu.assertTrue(self.manager.run(self.runtime, 'update').ok)
    lu.assertNotEquals(exec({'git', 'rev-parse', 'HEAD'}, p.dir), self.first)
    write(self.runtime.options.lockfile, lock)
    lu.assertTrue(self.manager.run(self.runtime, 'restore').ok)
    lu.assertEquals(exec({'git', 'rev-parse', 'HEAD'}, p.dir), self.first)
    write(p.dir .. '/sample.lua', 'dirty')
    lu.assertFalse(self.manager.run(self.runtime, 'update').ok)
end
function TestGit:testBuildFailure()
    self.runtime.plugins.sample.spec.build = 'exit 7'
    lu.assertFalse(self.manager.run(self.runtime, 'install').ok)
    local f = io.open(self.runtime.options.lockfile)
    if f then local data = rex.json.decode(f:read('*a')); f:close(); lu.assertNil(data.sample) end
    self.runtime.plugins.sample.spec.build = 'true'
    lu.assertTrue(self.manager.run(self.runtime, 'build', 'sample').ok)
end
function TestGit:testCLI()
    local cwd = exec({'pwd'})
    write(self.tmp .. '/rexpack_config.lua', 'return {spec = {{name="local", dir="."}}}')
    local r = rex.exec({cwd .. '/bin/rexpack', 'list', '--json', '--config', self.tmp .. '/rexpack_config.lua'},
        {env = {REX_BIN = os.getenv('REX_BIN') or '/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex'}})
    lu.assertTrue(r and r.ok)
    local result = rex.json.decode(r.stdout)
    lu.assertEquals(result[1].name, 'local')
end
function TestGit:testMutex()
    exec({'mkdir', '-p', self.runtime.options.root .. '/.rexpack-operation'})
    lu.assertError(self.manager.run, self.runtime, 'install')
end
function TestGit:testUnchangedDoesNotBuild()
    self.runtime.plugins.sample.spec.build = 'true'
    lu.assertTrue(self.manager.run(self.runtime, 'install').ok)
    self.runtime.plugins.sample.spec.build = function() error('unexpected build') end
    lu.assertTrue(self.manager.run(self.runtime, 'update').ok)
end
function TestGit:testTimeout()
    self.runtime.options.build_timeout = 0.05
    self.runtime.plugins.sample.spec.build = {'sleep', '5'}
    local result = self.manager.run(self.runtime, 'install')
    lu.assertFalse(result.ok)
    lu.assertEquals(result.plugins[1].status, 'build_failed')
end
function TestGit:testUnmanagedRepository()
    exec({'mkdir', '-p', self.runtime.options.root})
    exec({'git', 'clone', self.repo, self.runtime.plugins.sample.dir})
    lu.assertFalse(self.manager.run(self.runtime, 'update').ok)
end
function TestGit:testDependencyFailure()
    self.runtime.plugins.sample.spec.build = 'false'
    local dependent = {name = 'dependent', source = 'local', dir = self.tmp,
        spec = {dependencies = {'sample'}, build = function() error('must not build') end}}
    self.runtime.plugins.dependent = dependent
    self.runtime.order[#self.runtime.order + 1] = dependent
    local result = self.manager.run(self.runtime, 'install', 'dependent')
    lu.assertFalse(result.plugins[2].ok)
end
function TestGit:testBulkBuildOrdersDependencies()
    local built, calls = false, {}
    local i = dofile('init.lua').inspect({base = self.tmp, root = self.tmp .. '/builds', spec = {
        {name = 'dependent', dir = self.tmp, dependencies = {'dependency'}, build = function()
            assert(built, 'dependency artifact missing'); calls[#calls + 1] = 'dependent'
        end},
        {name = 'dependency', dir = self.tmp, build = function()
            built = true; calls[#calls + 1] = 'dependency'
        end},
    }})
    lu.assertTrue(self.manager.run(i, 'build').ok)
    lu.assertEquals(calls, {'dependency', 'dependent'})
    calls = {}
    lu.assertTrue(self.manager.run(i, 'build', 'dependent').ok)
    lu.assertEquals(calls, {'dependent'})
end
function TestGit:testBulkBuildSkipsFailedDependents()
    local calls = {}
    local i = dofile('init.lua').inspect({base = self.tmp, root = self.tmp .. '/builds', spec = {
        {name = 'dependent', dir = self.tmp, dependencies = {'dependency'}, build = function()
            calls[#calls + 1] = 'dependent'
        end},
        {name = 'dependency', dir = self.tmp, build = function() error('dependency failed') end},
        {name = 'independent', dir = self.tmp, build = function() calls[#calls + 1] = 'independent' end},
    }})
    lu.assertFalse(self.manager.run(i, 'build').ok)
    lu.assertEquals(calls, {'independent'})
end
function TestGit:testUpdateFollowsChangedRemoteDefaultBranch()
    self.runtime.plugins.sample.spec.build = false
    lu.assertTrue(self.manager.run(self.runtime, 'install').ok)
    exec({'git', 'checkout', '-b', 'next'}, self.repo)
    write(self.repo .. '/sample.lua', 'return {value = 2}')
    exec({'git', 'commit', '-s', '-am', 'New default branch'}, self.repo)
    local latest = exec({'git', 'rev-parse', 'HEAD'}, self.repo)
    lu.assertTrue(self.manager.run(self.runtime, 'update').ok)
    lu.assertEquals(exec({'git', 'rev-parse', 'HEAD'}, self.runtime.plugins.sample.dir), latest)
end
function TestGit:testPendingBuildSurvivesUnrelatedFailureAcrossInstances()
    local options = self.runtime.options
    options.spec[1].build = false
    lu.assertTrue(self.manager.run(self.runtime, 'install').ok)
    write(self.repo .. '/sample.lua', 'return {value = 2}')
    exec({'git', 'commit', '-s', '-am', 'Needs rebuild'}, self.repo)
    local latest = exec({'git', 'rev-parse', 'HEAD'}, self.repo)
    local function fresh() return dofile('init.lua').inspect(options) end
    options.spec[1].build = 'false'
    lu.assertFalse(self.manager.run(fresh(), 'update').ok)
    local directory = self.runtime.plugins.sample.dir
    write(directory .. '/sample.lua', 'dirty')
    lu.assertFalse(self.manager.run(fresh(), 'update').ok)
    exec({'git', 'checkout', '--', 'sample.lua'}, directory)
    local calls = 0
    options.spec[1].build = function() calls = calls + 1 end
    lu.assertEquals(self.manager.list(fresh())[1].lock.commit, self.first)
    lu.assertTrue(self.manager.run(fresh(), 'update').ok)
    lu.assertEquals(calls, 1)
    lu.assertEquals(self.manager.list(fresh())[1].lock.commit, latest)
    lu.assertTrue(self.manager.run(fresh(), 'update').ok)
    lu.assertEquals(calls, 1)
end
local failures = lu.LuaUnit.run()
if failures > 0 then rex.stop(1) end
