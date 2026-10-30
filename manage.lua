local M = {}
function M.build(plugin, reason, options, api)
    api = api or rex
    options = options or {}
    plugin.reason = reason
    local started = os.clock()
    local ok, err = pcall(function()
        local hook = plugin.spec.build
        if type(hook) == 'function' then
            hook(plugin)
        elseif hook ~= nil and hook ~= false then
            local argv = type(hook) == 'string' and {'/bin/sh', '-c', hook} or hook
            assert(type(argv) == 'table' and #argv > 0, 'invalid build hook')
            local result, failure = api.exec(argv, {cwd = plugin.dir, timeout = options.build_timeout or 300})
            plugin.build_result = result
            assert(result and result.ok, failure or (result and result.stderr) or 'command failed')
        end
    end)
    plugin.build_elapsed = os.clock() - started
    plugin.build_status = ok and 'built' or 'build_failed'
    if not ok then error('build failed for ' .. plugin.name .. ': ' .. tostring(err), 0) end
end
local function command(argv, cwd, timeout)
    local result, err = rex.exec(argv, {cwd = cwd, timeout = timeout or 120,
        env = {GIT_TERMINAL_PROMPT = '0'}})
    assert(result and result.ok, err or (result and result.stderr) or 'command failed')
    return result.stdout:gsub('\n$', '')
end
local function exists(directory)
    local result = rex.exec({'test', '-d', directory})
    return result and result.ok
end
local function read_json(file)
    local f = io.open(file)
    if not f then return {} end
    local text = f:read('*a'); f:close()
    return assert(rex.json.decode(text))
end
local function write_json(file, value)
    local text = assert(rex.json.encode(value, {indent = true}))
    local f = assert(io.open(file .. '.tmp', 'w'))
    assert(f:write(text .. '\n')); assert(f:close())
    assert(os.rename(file .. '.tmp', file))
end
local function git(p, ...)
    local argv = {'git'}
    for _, value in ipairs({...}) do argv[#argv + 1] = value end
    return command(argv, p.dir)
end
local function verify(p)
    local marker = assert(io.open(p.dir .. '/.git/rexpack-managed'), 'unmanaged plugin directory')
    marker:close()
    assert(git(p, 'rev-parse', '--show-toplevel') == command({'pwd', '-P'}, p.dir), 'not a plugin repository')
    assert(git(p, 'remote', 'get-url', 'origin') == p.url, 'repository source mismatch')
    assert(git(p, 'status', '--porcelain') == '', 'dirty plugin: ' .. p.name)
end
function M.list(instance)
    local locks = read_json(instance.options.lockfile)
    local state = read_json(instance.options.lockfile .. '.state')
    local rows = {}
    for _, p in ipairs(instance.order) do
        local row = {name = p.name, dir = p.dir, source = p.source, url = p.url,
            installed = exists(p.dir), lock = locks[p.name], operation = state[p.name],
            dependencies = p.spec.dependencies or {}}
        if row.installed and p.source == 'git' then
            local ok, commit = pcall(git, p, 'rev-parse', 'HEAD')
            if ok then row.commit = commit else row.error = tostring(commit) end
        end
        rows[#rows + 1] = row
    end
    return rows
end
function M.run(instance, operation, name)
    assert(operation == 'install' or operation == 'update' or operation == 'restore' or operation == 'build',
        'unknown operation')
    local options = instance.options
    command({'mkdir', '-p', options.root})
    local mutex = options.root .. '/.rexpack-operation'
    command({'mkdir', mutex})
    local ok, result = pcall(function()
        local locks = read_json(options.lockfile)
        local states = read_json(options.lockfile .. '.state')
        local selected, seen = {}, {}
        local function select(p)
            if seen[p.name] then return end
            seen[p.name] = true
            if operation ~= 'build' then
                for _, dep in ipairs(p.spec.dependencies or {}) do select(instance.plugins[dep]) end
            end
            selected[#selected + 1] = p
        end
        if name then select(assert(instance.plugins[name], 'unknown plugin: ' .. name))
        else for _, p in ipairs(instance.order) do select(p) end end
        local report = {ok = true, plugins = {}}
        local failed = {}
        for _, p in ipairs(selected) do
            local started = os.clock()
            local success, failure = pcall(function()
                for _, dependency in ipairs(p.spec.dependencies or {}) do
                    assert(not failed[dependency], 'dependency failed: ' .. dependency)
                end
                if p.source ~= 'git' then
                    if operation == 'build' then M.build(p, operation, options) end
                    return
                end
                assert(p.url, 'missing Git URL')
                local installed = exists(p.dir)
                local lock = locks[p.name]
                if lock then assert(lock.url == p.url, 'lock source mismatch') end
                if operation == 'restore' then assert(lock, 'no locked version') end
                if not installed then
                    assert(operation ~= 'build', 'plugin not installed')
                    local temporary = p.dir .. '.rexpack-clone'
                    assert(not exists(temporary), 'unfinished clone directory: ' .. temporary)
                    local cloned, err = pcall(command, {'git', 'clone', '--', p.url, temporary})
                    if not cloned then
                        command({'rm', '-rf', temporary}); error(err, 0)
                    end
                    local marker = assert(io.open(temporary .. '/.git/rexpack-managed', 'w'))
                    marker:write('rexpack\n'); marker:close()
                    assert(os.rename(temporary, p.dir))
                end
                verify(p)
                p.old_commit = installed and git(p, 'rev-parse', 'HEAD') or nil
                if operation ~= 'build' and (operation ~= 'install' or not installed) then
                    local target
                    if operation == 'restore' or (operation == 'install' and lock) then
                        target = lock.commit
                    elseif p.spec.commit then target = p.spec.commit
                    elseif p.spec.tag then target = 'refs/tags/' .. p.spec.tag
                    else
                        local branch = p.spec.branch
                        if not branch then
                            branch = git(p, 'symbolic-ref', 'refs/remotes/origin/HEAD'):gsub('^refs/remotes/origin/', '')
                        end
                        target = 'refs/remotes/origin/' .. branch
                    end
                    if installed then git(p, 'fetch', '--tags', 'origin') end
                    local resolved = git(p, 'rev-parse', '--verify', '--end-of-options', target .. '^{commit}')
                    git(p, 'checkout', '--detach', resolved)
                end
                p.commit = git(p, 'rev-parse', 'HEAD')
                local pending = states[p.name] and states[p.name].status == 'build_failed'
                if operation == 'build' or not installed or p.old_commit ~= p.commit or pending then
                    M.build(p, operation, options)
                end
                locks[p.name] = {url = p.url, commit = p.commit}
                write_json(options.lockfile, locks)
            end)
            local entry = {name = p.name, ok = success, elapsed = os.clock() - started,
                status = success and 'ok' or (p.build_status == 'build_failed' and 'build_failed' or 'failed'),
                error = not success and tostring(failure) or nil,
                build = p.build_result, build_elapsed = p.build_elapsed}
            states[p.name] = entry
            write_json(options.lockfile .. '.state', states)
            report.plugins[#report.plugins + 1] = entry
            if not success then report.ok = false; failed[p.name] = true end
        end
        return report
    end)
    local released, release_error = pcall(command, {'rmdir', mutex})
    if not ok then error(result, 0) end
    assert(released, release_error)
    return result
end
return M
