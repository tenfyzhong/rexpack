local root = assert(os.getenv('REXPACK_EVENTS_ROOT'))
local events = dofile(root .. '/events.lua')
local generation = assert(os.getenv('REXPACK_EVENTS_GENERATION'))
local owner = events.token()
local pid = tonumber(os.getenv('REXPACK_EVENTS_PID'))
local function control(op, extra)
    local args = extra or {}
    args.op, args.generation, args.owner, args.pid = op, generation, owner, pid
    local result, err = rex.invoke('rexpack_events_control', args)
    return result, err
end
local claim, err = control('claim')
if not claim or not claim.ok then rex.stop(0) end
local function alive()
    local result = control('alive')
    if not result or not result.ok then rex.stop(0) end
end
local ok, failure = pcall(function()
    local snapshot = assert(claim.snapshot)
    package.path = snapshot.base .. '/?.lua;' .. snapshot.base .. '/?/init.lua;' .. package.path
    local specs = {}
    for _, source in ipairs(snapshot.sources) do
        specs[#specs + 1] = assert(loadstring(source.code, '@' .. source.path))()
    end
    local manager = dofile(root .. '/init.lua')
    local instance = manager.inspect({spec = specs, base = snapshot.base,
        root = snapshot.root, lockfile = snapshot.lockfile, dev = snapshot.dev})
    instance:attach_loader()
    -- Preserve native event names, payloads and context; only gate stale generations.
    local native_on = rex.on
    rex.on = function(event, callback)
        return native_on(event, function(ctx, ev)
            alive()
            return callback(ctx, ev)
        end)
    end
    local registered, registration_error = pcall(instance.register_events, instance)
    rex.on = native_on
    if not registered then error(registration_error, 0) end
    alive()
    rex.every(1, alive)
    local ready = control('ready')
    if not ready or not ready.ok then rex.stop(0) end
end)
if not ok then
    control('failed', {error = tostring(failure)})
    error(failure, 0)
end
