LUA ?= luajit
REX ?= rex

.PHONY: test integration acceptance benchmark

test:
	$(LUA) tests/runtime.lua
	$(LUA) tests/build.lua

integration:
	REX_BIN="$(REX)" "$(REX)" --autostart=false do tests/integration.lua

acceptance:
	REXPACK_ROOT="$(CURDIR)" "$(REX)" config check tests/rex_config.lua --json
	REXPACK_ROOT="$(CURDIR)" "$(REX)" --autostart=false do tests/rex_config.lua --action rexpack_fixture

benchmark:
	REXPACK_ROOT="$(CURDIR)" "$(REX)" --autostart=false do tests/benchmark.lua --json
