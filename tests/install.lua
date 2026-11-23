package.path = './.test-deps/share/lua/5.1/?.lua;' .. package.path
local lu = require('luaunit')
local api = require('tests.fixtures.rex')

local function checked(argv, options)
    local result = api.exec(argv, options)
    assert(result.ok, result.stderr .. result.stdout)
    return result.stdout:gsub('\n$', '')
end

local function write(path, contents)
    local file = assert(io.open(path, 'w'))
    assert(file:write(contents))
    assert(file:close())
end

local function read(path)
    local file = assert(io.open(path))
    local contents = file:read('*a')
    file:close()
    return contents
end

TestInstall = {}
function TestInstall:git(directory, ...)
    return checked({'git', '-C', directory, ...}, {env = self.env})
end

function TestInstall:setUp()
    local cwd = checked({'pwd', '-P'})
    self.tmp = checked({'mktemp', '-d'})
    self.repo = self.tmp .. '/source repo'
    self.config = self.tmp .. '/rexpack_config.lua'
    self.checkout = self.tmp .. '/installed/sample'
    self.lockfile = self.tmp .. '/rexpack-lock.json'
    self.url = 'https://example.invalid/sample.git'
    self.other_url = 'https://example.invalid/other.git'
    self.env = {
        GIT_CONFIG_GLOBAL = self.tmp .. '/gitconfig',
        GIT_CONFIG_NOSYSTEM = '1',
        REX_BIN = os.getenv('REX_BIN') or cwd .. '/tests/fixtures/rex',
    }
    self.cli = cwd .. '/bin/rexpack'
    self:git(self.tmp, 'init', '-b', 'main', self.repo)
    self:git(self.repo, 'config', 'user.name', 'Fixture')
    self:git(self.repo, 'config', 'user.email', 'test@example.com')
    self:git(self.repo, 'config', 'core.hooksPath', '/dev/null')
    write(self.repo .. '/sample.lua', 'return {version = 1}\n')
    write(self.repo .. '/.gitignore', 'artifact\n')
    self:git(self.repo, 'add', '.')
    self:git(self.repo, 'commit', '-s', '-m', 'Initial plugin')
    self.first = self:git(self.repo, 'rev-parse', 'HEAD')
    write(self.repo .. '/sample.lua', 'return {version = 2}\n')
    self:git(self.repo, 'commit', '-s', '-am', 'Update plugin')
    local rewrite = 'url.' .. self.repo .. '.insteadOf'
    self:git(self.repo, 'config', '--global', '--add', rewrite, self.url)
    self:git(self.repo, 'config', '--global', '--add', rewrite, self.other_url)
    checked({'mkdir', self.tmp .. '/plugins'})
    write(self.config, 'return {root = "installed", dev = {path = "dev"}}\n')
    write(self.tmp .. '/plugins/sample.lua', string.format(
        'return {name = "sample", url = %q, commit = %q, build = "cp sample.lua artifact"}\n',
        self.url, self.first))
end

function TestInstall:tearDown()
    checked({'rm', '-rf', self.tmp})
end

function TestInstall:runCLI(operation)
    return api.exec({self.cli, operation, '--json', '--config', self.config}, {env = self.env})
end

function TestInstall:assertInstalled()
    local result = self:runCLI('install')
    lu.assertTrue(result.ok, result.stdout .. result.stderr)
    lu.assertEquals(self:git(self.checkout, 'config', '--get-all', 'remote.origin.url'), self.url)
    lu.assertEquals(self:git(self.checkout, 'remote', 'get-url', 'origin'), self.repo)
    lu.assertEquals(self:git(self.checkout, 'rev-parse', 'HEAD'), self.first)
    lu.assertEquals(read(self.checkout .. '/sample.lua'), 'return {version = 1}\n')
    lu.assertEquals(read(self.checkout .. '/artifact'), 'return {version = 1}\n')
    local lock = assert(api.json.decode(read(self.lockfile)))
    lu.assertEquals(lock.sample, {url = self.url, commit = self.first})
end

function TestInstall:testCleanInstallWithRewrittenURL()
    self:assertInstalled()
    os.remove(self.checkout .. '/artifact')
    lu.assertTrue(self:runCLI('install').ok)
    local artifact = io.open(self.checkout .. '/artifact')
    if artifact then artifact:close() end
    lu.assertNil(artifact)
end

function TestInstall:testRetryFinishesPreviouslyClonedPluginWithoutLock()
    checked({'mkdir', self.tmp .. '/installed'})
    self:git(self.tmp, 'clone', '--', self.url, self.checkout)
    write(self.checkout .. '/.git/rexpack-managed', 'rexpack\n')
    lu.assertNotEquals(self:git(self.checkout, 'rev-parse', 'HEAD'), self.first)
    self:assertInstalled()
end

function TestInstall:testRejectsDifferentConfiguredOriginDespiteIdenticalRewrite()
    self:assertInstalled()
    self:git(self.checkout, 'remote', 'set-url', 'origin', self.other_url)
    lu.assertEquals(self:git(self.checkout, 'remote', 'get-url', 'origin'), self.repo)
    local result = self:runCLI('update')
    lu.assertEquals(result.code, 1)
    lu.assertStrContains(result.stdout, 'repository source mismatch')
end

function TestInstall:testRejectsAdditionalOriginURL()
    self:assertInstalled()
    self:git(self.checkout, 'config', '--add', 'remote.origin.url', self.other_url)
    local result = self:runCLI('update')
    lu.assertEquals(result.code, 1)
    lu.assertStrContains(result.stdout, 'repository source mismatch')
end

os.exit(lu.LuaUnit.run())
