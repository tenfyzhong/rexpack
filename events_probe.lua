local result = rex.invoke('rexpack_events_control', {
    op = 'probe', generation = os.getenv('REXPACK_EVENTS_GENERATION'),
})
if not result or not result.ok then rex.stop(1) end
