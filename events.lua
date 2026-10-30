local M = {}

-- No yields inside this controller: claims are serialized by Rex's action VM.
function M.controller(generation, enabled, snapshot)
    local owner, pid, state, failure, last_seen
    state = enabled and 'starting' or 'disabled'
    return function(args)
        args = args or {}
        if args.op == 'status' then
            return {generation = generation, enabled = enabled, owner = owner, pid = pid,
                state = state, error = failure, last_seen = last_seen}
        end
        if not enabled or args.generation ~= generation then return {ok = false} end
        if args.op == 'probe' then return {ok = true} end
        if args.op == 'claim' and not owner then
            assert(type(args.owner) == 'string' and args.owner ~= '', 'missing runner owner')
            owner, pid, state = args.owner, args.pid, 'claimed'
        end
        if args.owner ~= owner or not owner then return {ok = false} end
        last_seen = os.time()
        if args.op == 'claim' then return {ok = true, snapshot = snapshot} end
        if args.op == 'ready' then state = 'running' end
        if args.op == 'failed' then state, failure = 'failed', tostring(args.error):sub(1, 4096) end
        return {ok = true}
    end
end

function M.token()
    local f = assert(io.open('/dev/urandom', 'rb'), 'cannot open random source')
    local bytes = f:read(16); f:close()
    assert(bytes and #bytes == 16, 'cannot read random source')
    return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

function M.start(instance, module_dir)
    local config = instance.options.events or {}
    assert(type(config) == 'table', 'events options must be a table')
    local enabled = false
    for _, p in ipairs(instance.order) do
        if p.spec.events ~= nil then
            assert(type(p.spec.events) == 'function', 'events must be a function: ' .. p.name)
            enabled = true
        end
    end
    enabled = enabled and config.enabled ~= false
    local generation = enabled and M.token() or 'disabled'
    local snapshot = {sources = instance.sources, base = instance.options.base,
        root = instance.options.root, lockfile = instance.options.lockfile, dev = instance.options.dev}
    if enabled then
        assert(type(instance.options.spec) == 'string' or instance.options.spec == nil,
            'event plugins require a spec directory so callbacks can be loaded in the runner')
    end
    local control = M.controller(generation, enabled, snapshot)
    local process
    rex.action {name = 'rexpack_events_control', title = 'Rexpack: Event Runner Status',
        run = function(_, args)
            local result = control(args)
            if args.op == 'status' and process and not process:running() and result.enabled then
                result.state = result.state == 'failed' and 'failed' or 'exited'
            end
            return result
        end}
    if not enabled then return end
    local attempts = config.startup_attempts or 10
    assert(type(attempts) == 'number' and attempts >= 1 and attempts <= 60 and attempts % 1 == 0,
        'events.startup_attempts must be an integer from 1 to 60')
    local r, err = rex.exec({'mkdir', '-p', instance.options.root})
    assert(r and r.ok, err or (r and r.stderr))
    local log = config.log or (instance.options.root .. '/events.log')
    process, err = rex.exec.start({'/bin/sh', module_dir .. '/bin/rexpack-events'}, {
        detach = true, stdout = false, stderr = false,
        env = {REXPACK_EVENTS_ROOT = module_dir, REXPACK_EVENTS_GENERATION = generation,
            REXPACK_EVENTS_SERVER = config.server or os.getenv('REX_SERVER') or '',
            REXPACK_EVENTS_LOG = log, REXPACK_EVENTS_ATTEMPTS = tostring(attempts),
            REX_BIN = config.rex_bin or os.getenv('REX_BIN') or '',
            REX_SESSION = false, REX_BLOCK = false, REX_CLIENT = false},
    })
    assert(process, err)
end
return M
