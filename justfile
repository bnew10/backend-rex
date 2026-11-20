export PATH := env("PATH") + ":" + home_directory() / ".luarocks/bin:" + home_directory() / ".local/share/nvim/mason/bin"
export LUA_PATH := env("LUA_PATH", ";") + ";" + home_directory() / ".luarocks/share/lua/5.1/?.lua;" + home_directory() / ".luarocks/share/lua/5.1/?/init.lua"
export LUA_CPATH := env("LUA_CPATH", ";") + ";" + home_directory() / ".luarocks/lib/lua/5.1/?.so"

# Smart-splits core revision to test against
SMART_SPLITS_REV := "v3.0.0"

# Clone smart-splits core at the pinned revision (no-op if already there)
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="deps/smart-splits.nvim"
    # `^{commit}`: the tag is annotated, so the bare tag names the tag object, never HEAD
    if [ -d "$dir" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$(git -C "$dir" rev-parse '{{ SMART_SPLITS_REV }}^{commit}' 2>/dev/null)" ]; then
      exit 0
    fi
    rm -rf "$dir"
    mkdir -p deps
    git clone --filter=blob:none --no-checkout https://github.com/smart-splits-nvim/smart-splits.nvim "$dir"
    git -C "$dir" checkout --quiet '{{ SMART_SPLITS_REV }}'

# Run the hermetic specs (no Rex server needed)
test: deps
    SMART_SPLITS_DIR="$(pwd)/deps/smart-splits.nvim" busted --run=core </dev/null

# Check formatting
fmt-check:
    stylua --check lua tests

# Format code
fmt:
    stylua lua tests

# Run selene
lint:
    selene ./lua/ ./tests/

# Run LuaLS type checking
typecheck: deps
    #!/usr/bin/env bash
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    VIMRUNTIME="$(nvim --clean -i NONE --headless --cmd 'lua io.write(vim.env.VIMRUNTIME)' --cmd 'quitall')" \
    lua-language-server --check=. --checklevel=Warning --check_format=pretty --configpath=.luarc.json --logpath="$tmpdir/luals"

# Drive a real Neovim in a scratch Rex session (needs a running Rex server)
e2e: deps
    nvim -l tests/e2e/run.lua

# Run all checks
check: fmt-check lint typecheck test
