-- Synthetic module work, not a measurement of the user's real plugins or app startup.
local root = assert(os.getenv('REXPACK_ROOT'))
local samples = {}
for _, mode in ipairs({'empty', 'lazy', 'eager'}) do
    local times = {}
    for trial = 1, 7 do
        local manager = dofile(root .. '/init.lua')
        local specs = {}
        local count = mode == 'empty' and 0 or 100
        for n = 1, count do
            local name = 'rexpack_benchmark_' .. n
            package.loaded[name] = nil
            package.preload[name] = function()
                local data = {}
                for k = 1, 2000 do data[k] = k * k end
                return data
            end
            specs[#specs + 1] = {name = name, dir = root, lazy = mode ~= 'eager'}
        end
        local previous_path = package.path
        local before = os.clock()
        local instance = manager.setup({spec = specs})
        times[#times + 1] = (os.clock() - before) * 1000
        for n = 1, count do
            local name = 'rexpack_benchmark_' .. n
            assert((package.loaded[name] ~= nil) == (mode == 'eager'))
            package.loaded[name], package.preload[name] = nil, nil
        end
        local loaders = package.loaders or package.searchers
        for n, loader in ipairs(loaders) do
            if loader == instance.loader then table.remove(loaders, n); break end
        end
        package.path = previous_path
    end
    table.sort(times)
    samples[mode] = {median_ms = times[4], min_ms = times[1], max_ms = times[7]}
end
return samples
