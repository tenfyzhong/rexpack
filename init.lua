local M = {}
local source_path = debug.getinfo(1, 'S').source:gsub('^@', '')
local module_dir = source_path:match('^(.*)/') or '.'
local Instance = {}
Instance.__index = Instance

local function path(value, base)
    value = value:gsub('^~/', (os.getenv('HOME') or '') .. '/')
    if value:sub(1, 1) ~= '/' then value = base .. '/' .. value end
    return value
end

function M.inspect(options)
    local started = os.clock()
    options = options or {}
    local base = options.base or ((os.getenv('XDG_CONFIG_HOME') or
        (os.getenv('HOME') .. '/.config')) .. '/rex')
    options.base = base
    options.root = path(options.root or ((os.getenv('XDG_DATA_HOME') or
        os.getenv('HOME') .. '/.local/share') .. '/rex/rexpack'), base)
    options.lockfile = path(options.lockfile or 'rexpack-lock.json', base)
    local self = setmetatable({plugins = {}, order = {}, options = options, sources = {}}, Instance)
    local specs = options.spec or 'plugins'
    if type(specs) == 'string' then
        local result, err = rex.exec({'find', path(specs, base), '-type', 'f', '-name', '*.lua'})
        assert(result and result.ok, err or (result and result.stderr))
        local files = {}
        for file in result.stdout:gmatch('[^\n]+') do files[#files + 1] = file end
        table.sort(files)
        specs = {}
        for _, file in ipairs(files) do
            local f = assert(io.open(file))
            local code = f:read('*a'); f:close()
            self.sources[#self.sources + 1] = {path = file, code = code}
            specs[#specs + 1] = assert(loadstring(code, '@' .. file))()
        end
    end
    for _, spec in ipairs(specs) do
        if spec.enabled ~= false then
            local name = spec.name or (spec[1] and spec[1]:match('([^/]+)$'))
            assert(name and name:match('^[%w_-]+$'), 'invalid plugin name')
            assert(not self.plugins[name], 'duplicate plugin: ' .. name)
            local versions = (spec.branch and 1 or 0) + (spec.tag and 1 or 0) + (spec.commit and 1 or 0)
            assert(versions <= 1, 'conflicting version selectors: ' .. name)
            local plugin = {name = name, main = spec.main or name, spec = spec,
                state = 'unloaded', source = spec.dir and 'local' or 'git',
                url = spec.url or (spec[1] and ('https://github.com/' .. spec[1] .. '.git')),
                dir = path(spec.dir or (options.root .. '/' .. name), base)}
            assert(plugin.main:match('^[%w_.-]+$'), 'invalid module name')
            for _, other in ipairs(self.order) do
                assert(plugin.main ~= other.main and
                    plugin.main:sub(1, #other.main + 1) ~= other.main .. '.' and
                    other.main:sub(1, #plugin.main + 1) ~= plugin.main .. '.', 'module conflict')
            end
            local dev = options.dev or {}
            local use_dev = spec.dev == true
            if spec.dev == nil then
                for _, pattern in ipairs(dev.patterns or {}) do
                    if (spec[1] or name):match(pattern) then use_dev = true end
                end
            end
            if not spec.dir and use_dev then
                local directory = path((dev.path or '~/dev') .. '/' .. name, base)
                local r = rex.exec({'test', '-d', directory})
                if r and r.ok then
                    plugin.dir, plugin.source = directory, 'dev'
                else
                    assert(dev.fallback, 'missing dev directory: ' .. directory)
                end
            end
            self.plugins[name] = plugin
            self.order[#self.order + 1] = plugin
        end
    end
    local visited, visiting = {}, {}
    local function visit(p)
        assert(not visiting[p.name], 'dependency cycle: ' .. p.name)
        if visited[p.name] then return end
        visiting[p.name] = true
        for _, name in ipairs(p.spec.dependencies or {}) do
            visit(assert(self.plugins[name], 'unknown dependency: ' .. name))
        end
        visiting[p.name], visited[p.name] = nil, true
    end
    for _, p in ipairs(self.order) do visit(p) end
    self.scan_elapsed = os.clock() - started
    return self
end

function Instance:attach_loader()
    if self.loader then return end
    local loaders = package.loaders or package.searchers
    local function loader(module)
        for _, p in ipairs(self.order) do
            if module == p.main or module:sub(1, #p.main + 1) == p.main .. '.' then
                if p.state == 'loaded' or p.state == 'loading' then return '\n\trexpack: loading ' .. p.name end
                return function()
                    package.loaded[module] = nil
                    self:load(p.name, 'require:' .. module)
                    if module == p.main then return p.module end
                    return require(module)
                end
            end
        end
        return '\n\tno rexpack plugin for ' .. module
    end
    self.loader = loader
    table.insert(loaders, 1, loader)
end

function Instance:register_events()
    for _, p in ipairs(self.order) do
        if p.spec.events then
            assert(type(p.spec.events) == 'function', 'events must be a function: ' .. p.name)
            p.spec.events(p)
        end
    end
end

function M.setup(options)
    local started = os.clock()
    assert(not M.instance, 'rexpack is already configured')
    local self = M.inspect(options)
    self:attach_loader()
    for _, p in ipairs(self.order) do
        local before = os.clock()
        if p.spec.init then p.spec.init(p) end
        p.init_elapsed = os.clock() - before
    end
    for _, p in ipairs(self.order) do
        if p.spec.lazy == false then self:load(p.name, 'startup') end
    end
    M.instance = self
    self.setup_elapsed = os.clock() - started
    if rex and rex.action then
        rex.action {name = 'rexpack_profile', title = 'Rexpack: Profile',
            run = function() return self:profile() end}
        dofile(module_dir .. '/events.lua').start(self, module_dir)
    end
    return self
end

function Instance:load(name, reason)
    local p = assert(self.plugins[name], 'unknown plugin: ' .. name)
    if p.state == 'loaded' then return p.module end
    if p.state == 'failed' then error(p.error, 0) end
    assert(p.state ~= 'loading', 'recursive load: ' .. name)
    p.state = 'loading'
    p.reason = reason or 'manual'
    local started = os.clock()
    local dependency_elapsed = 0
    local ok, result = pcall(function()
        local before = os.clock()
        for _, dependency in ipairs(p.spec.dependencies or {}) do self:load(dependency, 'dependency:' .. name) end
        dependency_elapsed = os.clock() - before
        package.path = p.dir .. '/?.lua;' .. p.dir .. '/?/init.lua;' ..
            p.dir .. '/lua/?.lua;' .. p.dir .. '/lua/?/init.lua;' .. package.path
        before = os.clock()
        local module = require(p.main)
        p.module_elapsed = os.clock() - before
        before = os.clock()
        if p.spec.config then p.spec.config(p) end
        p.config_elapsed = os.clock() - before
        return module
    end)
    p.elapsed = os.clock() - started
    p.self_elapsed = p.elapsed - dependency_elapsed
    if not ok then p.state, p.error = 'failed', tostring(result); error(result, 0) end
    p.state, p.module = 'loaded', result
    return result
end

function Instance:profile()
    local rows = {}
    for _, p in ipairs(self.order) do
        rows[#rows + 1] = {name = p.name, state = p.state, error = p.error,
            elapsed = p.elapsed, self_elapsed = p.self_elapsed,
            init_elapsed = p.init_elapsed, module_elapsed = p.module_elapsed,
            config_elapsed = p.config_elapsed, reason = p.reason}
    end
    return {clock = 'os.clock', memory = 'unavailable', plugins = rows,
        scan_elapsed = self.scan_elapsed, setup_elapsed = self.setup_elapsed}
end

function M.load(name)
    return assert(M.instance, 'rexpack is not configured'):load(name)
end

return M
