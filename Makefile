LUA ?= luajit
REX ?= rex
LUAROCKS ?= luarocks
LUAROCKS_FLAGS ?=
LUAUNIT_VERSION := 3.5-1

.PHONY: test-deps test integration acceptance benchmark

test-deps:
	$(LUAROCKS) --lua-version=5.1 $(LUAROCKS_FLAGS) --tree .test-deps install luaunit $(LUAUNIT_VERSION)

test:
	$(LUA) tests/runtime.lua
	$(LUA) tests/build.lua
	$(LUA) tests/events.lua

integration:
	REX_BIN="$(REX)" "$(REX)" --autostart=false do tests/integration.lua
	REXPACK_ROOT="$(CURDIR)" REX_BIN="$(REX)" "$(REX)" --autostart=false do tests/events_integration.lua

acceptance:
	REXPACK_ROOT="$(CURDIR)" "$(REX)" config check tests/rex_config.lua --json
	REXPACK_ROOT="$(CURDIR)" "$(REX)" --autostart=false do tests/rex_config.lua --action rexpack_fixture

benchmark:
	REXPACK_ROOT="$(CURDIR)" "$(REX)" --autostart=false do tests/benchmark.lua --json
