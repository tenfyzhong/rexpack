# rexpack

A small, lazy-loading Lua plugin manager for [Rex](https://www.superlogical.com/rex).
Requires Rex with `rex.exec`, Lua 5.1 package loaders and custom actions, Git, and
POSIX utilities (`sh`, `find`, `test`, `mkdir`, `rmdir`, `pwd`, `rm`). No separate
Lua interpreter is needed in production. macOS is integration-tested; the same
POSIX interfaces are intended for Linux. Windows is not supported yet.

## Install

```sh
git clone https://github.com/tenfyzhong/rexpack.git ~/.config/rex/rexpack
```

Add to Rex's `init.lua`:

```lua
require('rexpack').setup(require('rexpack_config'))
```

Create `~/.config/rex/rexpack_config.lua`:

```lua
return {
    spec = 'plugins',
    dev = {path = '~/dev', patterns = {}, fallback = false},
}
```

Create the `plugins` directory beside this file. Each `.lua` file returns one
plugin specification. Files are discovered recursively and sorted by path.
Keep their top levels declarative: both the CLI and Rex evaluate these files.
CLI operations never invoke their `init` or `config` callbacks.

Run `~/.config/rex/rexpack/bin/rexpack install`, then `rex config reload`.
Add the **bin directory** to PATH for the shorter `rexpack` command (do not
symlink the executable alone). The wrapper uses `REX_BIN`, then PATH, then known
macOS installation locations. It requires a running local Rex service and does
not start it automatically.

XDG_CONFIG_HOME is respected. CLI `--config PATH` selects another shared config.
For a Rex configuration outside its default directory, set `base` explicitly in
the shared options to its absolute directory. Relative spec, local plugin and
lockfile paths are resolved against that base. The CLI derives base from its
selected config file. Use absolute paths when sharing options across locations.

## A plugin per file

```lua
-- plugins/example.lua (replace the illustrative repository/module names)
return {
    'someone/rex-example',
    main = 'example',
    build = 'make install',
    init = function()
        rex.action {
            name = 'example_open',
            title = 'Example: Open',
            run = function(ctx, args)
                return require('example').open(ctx, args)
            end,
        }
        rex.bind('cmd+shift+e', 'example_open')
    end,
    config = function()
        require('example').setup({})
    end,
}
```

Use `url = 'git@host:team/repository.git', name = 'repository'` for arbitrary Git
sources, or `dir = '~/src/repository', name = 'repository'` for local plugins.
`dir` takes precedence. Set `main` when the module differs from the plugin name.
Modules use standard `?.lua` and `?/init.lua` paths in the repository root or
its `lua/` directory. Plugin names contain letters, digits, underscores or hyphens.

`lazy` defaults to true. `init(plugin)` registers lightweight native declarations
at startup; the first `require` loads dependencies, the implementation and
`config(plugin)`. `config` runs once. Failed initialization is not automatically
retried. Use `lazy = false` for declarations that must execute at startup.
`require('rexpack').load(name)` loads explicitly. A root entry script can be
executed with `dofile(plugin.dir .. '/init.lua')` inside `config`, provided the
plugin also has its declared main module.

`dependencies = {'other-plugin'}` references separately declared plugin names.
Unknown dependencies, dependency cycles, duplicate names and overlapping module
names are rejected. `enabled = false` excludes a plugin. `branch`, `tag` and
`commit` are mutually exclusive. Without one, updates follow origin's default
branch. No semver resolver, nested spec merging, event daemon or keys DSL is added.

Rex only permits action/mode declarations at configuration load time. Put them
in `init`, not in a deferred module/config callback. Event scripts remain native
`rex do` scripts. See the [Rex Lua API](https://www.superlogical.com/rex/docs/reference/lua).

## Build hooks

Hooks run after a new installation or a changed checkout, in the final plugin
location, and can be retried explicitly. Choose one form:

```lua
build = 'make build && make install' -- /bin/sh -c; shell syntax is intentional
build = {'make', 'install', 'PREFIX=/path with spaces'} -- argv, no shell
build = 'sh ./scripts/install.sh'
build = function(plugin)
    local install = dofile(plugin.dir .. '/scripts/install.lua')
    install(plugin)
end
```

The Lua argument exposes `name`, absolute `dir`, `reason`, `old_commit` and
`commit`. Reasons are `install`, `update`, `restore` and `build`. Lua functions
can call `rex.exec`; check `result.ok` and raise `error` on failure. Lua callbacks
must explicitly pass `cwd = plugin.dir` to their subprocesses. Shell/argv hooks
already run in that directory. No sudo, tool installation or undeclared scripts
are run automatically.

External hooks have a default 300-second timeout, configurable with global
`build_timeout`. Arbitrary Lua callbacks cannot be forcibly timed out. Command
output, exit status and build duration are retained in operation state.

A failed hook leaves its checkout intact, records `build_failed`, returns a
nonzero CLI exit, and does not advance its lock entry. Use `rexpack build NAME`
to retry. External installation side effects cannot be rolled back. Build
outputs should be gitignored; dirty repositories are protected even during
explicit rebuild. Local/dev plugins build only on an explicit `build` command.
Startup, configuration checks and lazy loading never run hooks or Git.

## Commands and storage

```sh
rexpack install [name]   # missing plugins, using locked commits when available
rexpack update [name]    # fetch and update allowed refs
rexpack restore [name]   # restore locked commits; rebuild changed checkouts
rexpack build [name]     # explicit build/retry
rexpack list
rexpack show NAME
rexpack profile
```

All commands accept `--json` and `--config PATH`. Text output is a concise
summary; JSON includes detailed paths, locks, build output and timing.
`profile` always queries the running Rex configuration, not the config selected
on disk. It does not load plugins to obtain measurements.

Default storage is `$XDG_DATA_HOME/rex/rexpack` or `~/.local/share/rex/rexpack`,
overridable with `root`. The shared config directory holds `rexpack-lock.json`
and `rexpack-lock.json.state`; `lockfile` overrides the former. Commit the lock
file, not the operation-state file. Locks record URL and commit and are replaced
atomically after successful builds. A report can include successes and failures;
any failed operation produces a nonzero exit. Independent plugins continue.

Operations are serial and mutually exclusive per root. Git commands time out
after 120 seconds. Clone uses a temporary directory and a management marker.
Existing unmanaged repositories, source mismatches and dirty checkouts are
rejected. After a process is killed, inspect for running operations before
manually removing the empty `.rexpack-operation` directory; unfinished clone
folders are reported rather than silently reused. Never share different roots
with the same lock file. Reload Rex explicitly after updates; loaded Lua modules
are not hot-swapped.

For development, set `dev.path` and use `dev = true` on a plugin. `dev.patterns`
contains Lua patterns matching the source shorthand or name. `dev = false`
disables matching. Missing dev directories fail unless `fallback = true`.
Local/dev paths are never cloned, updated, restored or included in Git locks.

## Profiling and tests

Profiles contain configuration scan/setup durations and per-plugin init,
module/config, inclusive load and self load durations. Times are seconds from
`os.clock`; the tested Rex implementation includes elapsed waits. Standard Lua
implementations may report CPU time instead. Memory is reported as unavailable,
not zero. Profiles contain bounded per-plugin records and do not poll in the
background. Disk checkout state and live module state are separate.

```sh
make test                        # development-only LuaJIT/Lua and vendored LuaUnit
make integration REX=/path/to/rex # running Rex, isolated temporary repositories
make acceptance REX=/path/to/rex  # config check and native action fixture
make benchmark REX=/path/to/rex   # synthetic 100-module startup comparison
```

The vendored test-only LuaUnit 3.4 is MIT-licensed; its license is included in
`tests/vendor/luaunit.lua`. Integration fixtures isolate Git hooks and create
signed-off commits only in temporary repositories. Acceptance does not modify
or reload your own Rex configuration. Keyboard registration is validated through
`config check`; the action is invoked through Rex's script action runner.

The benchmark compares seven repetitions of empty/lazy/eager configurations
with 100 synthetic modules, each allocating 2,000 numbers. It verifies that lazy
modules have not executed. It measures manager/module work, not whole application
startup, real plugin workloads or per-plugin memory consumption.
