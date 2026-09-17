# gitvim.nvim developer tasks
.PHONY: all test test-file lint fmt fmt-check docs clean

# NB: not `NVIM` -- Neovim sets $NVIM to its server socket inside :terminal,
# which would silently override this and try to exec the socket.
NVIM_BIN ?= nvim
TESTS_DIR := tests
MINIMAL := $(TESTS_DIR)/minimal_init.lua

all: fmt-check lint test

# Run the plenary busted suite headlessly.
test:
	@$(NVIM_BIN) --headless --noplugin -u $(MINIMAL) \
		-c "PlenaryBustedDirectory $(TESTS_DIR) { minimal_init = '$(MINIMAL)', sequential = true }" \
		|| (echo "test run failed"; exit 1)

# Run a single spec:  make test-file FILE=tests/gitvim/status_spec.lua
# :PlenaryBustedFile forwards -u to its child nvim only when given a minimal_init
# opt, which its command form cannot take -- so drive busted directly instead.
test-file:
	@$(NVIM_BIN) --headless --noplugin -u $(MINIMAL) \
		-c "lua require('plenary.busted').run('$(FILE)')"

# luacheck and stylua are optional locally (CI always runs them), so skip loudly
# rather than failing a contributor's `make all` over a missing dev tool.
lint:
	@command -v luacheck >/dev/null 2>&1 \
		|| { echo "SKIPPED lint: luacheck not found (luarocks install luacheck)"; exit 0; }; \
	luacheck lua tests

fmt:
	@command -v stylua >/dev/null 2>&1 \
		|| { echo "SKIPPED fmt: stylua not found (cargo install stylua)"; exit 0; }; \
	stylua lua tests

fmt-check:
	@command -v stylua >/dev/null 2>&1 \
		|| { echo "SKIPPED fmt-check: stylua not found (cargo install stylua)"; exit 0; }; \
	stylua --check lua tests

# Regenerate helptags from doc/gitvim.txt
docs:
	@$(NVIM_BIN) --headless -c "helptags doc" -c "qa!"
	@echo "doc/tags regenerated"

clean:
	@rm -rf .tests doc/tags
	@echo "cleaned"
