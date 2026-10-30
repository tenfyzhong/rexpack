# rexpack

A small Lua plugin manager with optional lazy loading for [Rex](https://www.superlogical.com/rex).
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
require("rexpack").setup({
    spec = "plugins",
    dev = { path = "dev" },
})
```

Pass the configuration table directly to `setup()`; no additional configuration
module is needed. Relative paths resolve against the Rex configuration directory,
so this example uses `~/.config/rex/plugins` and `~/.config/rex/dev` by default.

Create the `plugins` directory beside `init.lua`. Each `.lua` file returns one
plugin specification. Files are discovered recursively and sorted by path.
Keep their top levels declarative: both the CLI and Rex evaluate these files.
CLI operations never invoke their `init` or `config` callbacks.

Existing dev plugins load directly. For remote plugins, install them with the
CLI before reloading Rex; see [Commands and storage](#commands-and-storage)
for the CLI's configuration-file requirement. Run `rex config reload` after
changing plugin configuration.
Add the **bin directory** to PATH for the shorter `rexpack` command (do not
symlink the executable alone). The wrapper uses `REX_BIN`, then PATH, then known
macOS installation locations. It requires a running local Rex service and does
not start it automatically.

XDG_CONFIG_HOME is respected. CLI `--config PATH` selects its options file.
For a Rex configuration outside its default directory, set `base` explicitly in
the `setup()` options to its absolute directory. Relative spec, local plugin and
lockfile paths are resolved against that base. The CLI derives base from its
selected config file. Use absolute paths when sharing options across locations.

## A plugin per file

```lua
-- plugins/example.lua (replace the illustrative repository/module names)
return {
    'someone/rex-example',
    main = 'example',
    lazy = true,
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

`lazy` defaults to false: plugins and their dependencies load at startup after
all `init(plugin)` callbacks register their native declarations. Set `lazy = true`
to defer the implementation and `config(plugin)` until the first `require`.
`config` runs once. Failed initialization is not automatically retried.
`require('rexpack').load(name)` loads explicitly. A root entry script can be
executed with `dofile(plugin.dir .. '/init.lua')` inside `config`, provided the
plugin also has its declared main module.

`dependencies = {'other-plugin'}` references separately declared plugin names.
Unknown dependencies, dependency cycles, duplicate names and overlapping module
names are rejected. `enabled = false` excludes a plugin. `branch`, `tag` and
`commit` are mutually exclusive. Without one, updates follow origin's default
branch. No semver resolver, nested spec merging, service manager or keys DSL is added.

Rex only permits action/mode declarations at configuration load time. Put them
in `init`, not in a deferred module/config callback. Use the `events` callback
below for native event subscriptions. See the [Rex Lua API](https://www.superlogical.com/rex/docs/reference/lua).

## Automatic event subscriptions

Put native `rex.on` registrations in a plugin's `events` callback. Rex does not
allow these registrations in the configuration VM, so `init` remains for actions
and bindings. For example, a local plugin can log newly created sessions:

```lua
-- plugins/session-log.lua
return {
    name = 'session-log',
    dir = '~/dev/session-log',
    main = 'session_log',
    events = function()
        rex.on('session_created', function(ctx, event)
            require('session_log').record(ctx, event)
        end)
    end,
}
```

```lua
-- ~/dev/session-log/lua/session_log.lua
local M = {}
function M.record(ctx, event)
    print(rex.json.encode(event))
end
return M
```

Reload Rex once after adding the spec. `setup()` starts one shared background
`rex do --all` process for all event plugins, without LaunchAgent or systemd.
The module above loads on the first event. The launcher waits for the server to
publish this configuration's random generation token, then replaces itself with
the runner. The runner stays alive to receive **future** events; completing all
registrations or one batch of callbacks does not stop it. There is no permanent
shell process or separate supervisor.

Only directory-based specs support automatic events. Their source is captured
at configuration load and evaluated again in the runner, with a fresh lazy
loader; `init` is not called again. Keep spec top levels declarative and put
shared options in `config`. Config and runner VMs have separate module caches,
globals and plugin state, so `config` runs once per VM when its module loads.
The runner does not eagerly load `lazy = false` plugins: require the modules
needed by event registrations explicitly. Do not depend on variables initialized
by `init`. Native event names, context and payloads pass through unchanged.

Optional event settings in the same `setup()` call:

```lua
require("rexpack").setup({
    spec = 'plugins',
    events = {
        enabled = true,       -- false disables all event plugins
        startup_attempts = 10, -- 1..60; each probe has a 2-second request timeout
        -- rex_bin = '/absolute/path/to/rex',
        -- server = 'unix:///absolute/path/to/rex.sock',
        -- log = '/absolute/path/to/events.log',
    },
})
```

The executable resolves through `events.rex_bin`, `REX_BIN`, PATH, then known
macOS paths. The target resolves through `events.server`, `REX_SERVER`, then
Rex's default server. Set it explicitly for custom endpoints. Probes never
start a missing server and wait one second between attempts. Config checks and
failed config evaluations can launch short-lived probes, but cannot publish a
matching token or register listeners; probes exit after their bounded retries.

```sh
rex do rexpack_events_control op=status
```

Status reports generation, state, owner, runner PID, last heartbeat and any
registration error. Runner stdout/stderr go to `root/events.log` by default,
truncated on each successful launch; custom log parent directories must exist.
Plugin logging can grow the file during a run, so keep it bounded yourself.

On reload, each event callback checks its generation before invoking plugin
code. A one-second heartbeat stops idle stale runners after reload, disabling or
removing event specs, or losing the server connection. A callback already in
progress may finish; handover does not guarantee exactly-once delivery or replay
missed events. Keep callbacks short. These checks add one server action call per
dispatch and one per second per runner. A runner crash or registration failure
is recovered by `rex config reload` or restarting Rex, not by a persistent
supervisor. Plugin exceptions follow native Rex behavior.

## Developing a plugin

A plugin is an ordinary Lua module in a Git repository or local directory. It
needs no rexpack SDK, manifest or registration API. The **plugin implementation**
lives in its repository; the **user's plugin spec** lives in the user's Rex
configuration and selects its source, options and native actions.

### 1. Create a module

For a repository named `rex-greeting`, use this layout:

```text
rex-greeting/
└── lua/
    └── greeting/
        └── init.lua
```

Create `~/dev/rex-greeting/lua/greeting/init.lua`:

```lua
local M = {}
local prefix = 'Hello'

function M.setup(options)
    options = options or {}
    prefix = options.prefix or 'Hello'
end

function M.greet(ctx, args)
    args = args or {}
    return {message = prefix .. ', ' .. (args.name or 'world') .. '!'}
end

function M.list_sessions(ctx, args)
    -- Rex provides this global directly; rexpack does not wrap or inject it.
    local result, err = rex.call('session.list')
    if err ~= nil then error(err, 0) end
    return result
end

return M
```

`setup` is an ordinary function in this example, not a required Rex API or a
function rexpack calls automatically. The user's `config` callback below calls
it explicitly. Returning a module table makes the plugin usable with normal
Lua `require`, even without rexpack.

The equivalent entry paths `lua/greeting.lua`, `greeting.lua`, and
`greeting/init.lua` also work. Choose one layout. A repository-root `init.lua`
alone does **not** satisfy `main = 'greeting'`.

### 2. Connect the local plugin

Create `~/.config/rex/plugins/greeting.lua` (with rexpack configured as above):

```lua
return {
    name = 'rex-greeting',
    dir = '~/dev/rex-greeting',
    main = 'greeting',
    lazy = true,
    init = function()
        rex.action {
            name = 'greeting_hello',
            title = 'Greeting: Say Hello',
            args = {name = 'string?'},
            run = function(ctx, args)
                return require('greeting').greet(ctx, args)
            end,
        }
        rex.bind('ctrl+shift+g', 'greeting_hello', {name = 'Rex'})
        rex.action {
            name = 'greeting_sessions',
            title = 'Greeting: List Rex Sessions',
            run = function(ctx, args)
                return require('greeting').list_sessions(ctx, args)
            end,
        }
    end,
    config = function()
        require('greeting').setup({prefix = 'Hi'})
    end,
}
```

The three names have different roles:

| Value | Meaning |
| --- | --- |
| `rex-greeting` | Plugin identity for management commands and dependency references |
| `greeting` | Lua entry module, loaded by `require('greeting')` |
| `greeting_hello` | Native Rex action, invoked with `rex do greeting_hello` |

`main` maps the plugin to its entry module and module-name prefix. Without it,
the module name defaults to the plugin name: `rex-greeting` in this example.
It also determines what `rexpack.load('rex-greeting')` requires. Keep submodules
under the same namespace, for example `lua/greeting/format.lua` loaded using
`require('greeting.format')`. A first require of that submodule still loads the
main `greeting` module and runs `config` first. Unrelated top-level namespaces
are not automatically associated with this plugin.

### 3. Run and iterate

The local example needs no download or build step. With the Rex server running:

```sh
rex config check
rex config reload
rexpack profile --json
rex do greeting_hello name=Rex
rex do greeting_sessions
rexpack profile --json
```

The action returns `{"message":"Hi, Rex!"}`. Before its first invocation, the
profile should show `rex-greeting` as `unloaded`; afterward it should be `loaded`
with reason `require:greeting`. The command palette and shortcut invoke the same
action, but this example returns data for the CLI; it does not display a popup.

`greeting_sessions` calls Rex's native `session.list` API **inside the plugin**
and returns its response, which the CLI prints as JSON. It is a read-only
example: it does not create or modify sessions. The plugin accesses the global
`rex` directly; no rexpack API or `require('rex')` is needed. The call runs only
when the action invokes `list_sessions`, not when the module is first read.
Keep client/session operations in runtime callbacks and check the API's error
return, as shown here. Declaring actions still belongs in the spec's `init`.

Edit the module and run `rex config reload` before trying it again. Lua caches
loaded modules, and rexpack does not implement live module replacement. Use a
fresh configuration load after an initialization failure as well.

### 4. Publish or use dev mode

After publishing your repository, replace the local spec's `name` and `dir`
fields with `'your-account/rex-greeting'`. Keep `main`, `init` and `config`
unchanged. The account name is a placeholder for your real repository.

```lua
-- Source fields in the same spec; retain the callbacks from step 2.
'your-account/rex-greeting',
main = 'greeting',
    lazy = true,
```

Run `rexpack install rex-greeting`, then `rex config reload`. To develop the
published plugin from `~/dev/rex-greeting`, set `dev.path = '~/dev'` in the
`setup()` options. Rexpack automatically prefers that directory when
it exists and otherwise uses the installed plugin. Omit
`dir` when using dev mode: an explicit `dir` always wins. Local/dev plugins are
not updated or restored by rexpack.

### Lifecycle rules for authors

- Keep module top levels lightweight and return exports. Do not register
  `rex.action`, modes or named key bindings from a lazily loaded implementation.
  Register those in the spec's `init`; call the plugin from their callbacks.
- Put a plugin `require` inside the action's `run`, as above. Requiring it at
  the top level of the spec or inside `init` defeats deferred loading (and a
  top-level require can happen before the manager installs its loader).
- Loading runs dependencies, `require(main)`, then `config`, before returning
  control to the original action. The current implementation always requires
  `main`; a `config` callback alone does not replace the entry module.
- `config` runs once when loaded, and may run either during startup (`lazy =
  false`) or later in a callback. Keep context-sensitive Rex operations inside
  action functions; use `config` for module options. Pass `ctx`/`args` through
  rather than saving a particular action's context globally.
- Declare another managed plugin in `dependencies = {'plugin-name'}` when its
  initialization must finish first. Use globally unique module namespaces.
- Pure Lua plugins need no `build`. If you ship generated code or native helper
  executables, add an explicit hook such as `build = 'make install'`; see
  [Build hooks](#build-hooks) for Lua callbacks, timeouts and retry behavior.
  Ignore generated artifacts in Git so future updates pass dirty-tree checks.

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

The current CLI's management commands read an options file; they do not extract
the table from `init.lua`. If you use these commands, create
`~/.config/rex/rexpack_config.lua` (or pass another file with `--config PATH`):

```lua
return {
    spec = "plugins",
    dev = { path = "dev" },
}
```

Keep its options consistent with the inline `setup()` table. This file is only
needed for CLI management; Rex itself does not need to `require` it. For example,
run `rexpack install`, then `rex config reload`. `rexpack profile` queries the
running Rex configuration and does not require this file.

All commands accept `--json` and `--config PATH`. Text output is a concise
summary; JSON includes detailed paths, locks, build output and timing.
`profile` always queries the running Rex configuration, not the config selected
on disk. It does not load plugins to obtain measurements.

Default storage is `$XDG_DATA_HOME/rex/rexpack` or `~/.local/share/rex/rexpack`,
overridable with `root`. The configuration base directory holds `rexpack-lock.json`
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

Rexpack first checks `<dev.path>/<plugin-name>` (default `~/dev/<plugin-name>`),
then falls back to the installation directory if the dev directory is missing.
No `dev = true` or pattern match is required. An explicit `dir` takes precedence;
`dev = false` explicitly skips the dev lookup. The legacy `dev.patterns` and
`dev.fallback` options no longer affect resolution.
Local/dev paths are never cloned, updated, restored or included in Git locks.

## Profiling and tests

Profiles contain configuration scan/setup durations and per-plugin init,
module/config, inclusive load and self load durations. Times are seconds from
`os.clock`; the tested Rex implementation includes elapsed waits. Standard Lua
implementations may report CPU time instead. Memory is reported as unavailable,
not zero. Profiles contain bounded per-plugin records and do not poll in the
background. Profiles describe the configuration VM, not the separate event
runner. Disk checkout state and live module state are separate.

```sh
make test-deps                   # install LuaUnit 3.5-1 through LuaRocks
make test                        # development-only LuaJIT (or LUA=lua5.1)
make integration REX=/path/to/rex # running Rex, isolated temporary repositories
make acceptance REX=/path/to/rex  # config check and native action fixture
make benchmark REX=/path/to/rex   # synthetic 100-module startup comparison
```

LuaUnit is a test-only dependency installed through LuaRocks into the ignored
`.test-deps` directory; no framework source is vendored. Install LuaRocks and a
Lua 5.1-compatible interpreter before running `make test-deps`. If LuaRocks needs
an explicit interpreter prefix (for example, Homebrew LuaJIT on macOS), use
`make test-deps LUAROCKS_FLAGS="--lua-dir=$(brew --prefix luajit)"`.
The dependency tree uses Lua 5.1 paths for both LuaJIT and Rex's embedded Lua.

The GitHub Actions `Tests` workflow runs `make test-deps` and `make test` on
Lua 5.1 and LuaJIT for pushes, pull requests, and manual dispatch. It does not
run the live Rex integration or acceptance targets; run those locally against
a running Rex service using the commands above.

Integration fixtures isolate Git hooks and create
signed-off commits only in temporary repositories. Acceptance does not modify
or reload your own Rex configuration. Keyboard registration is validated through
`config check`; the action is invoked through Rex's script action runner.

The benchmark compares seven repetitions of empty/lazy/eager configurations
with 100 synthetic modules, each allocating 2,000 numbers. It verifies that lazy
modules have not executed. It measures manager/module work, not whole application
startup, real plugin workloads or per-plugin memory consumption.
