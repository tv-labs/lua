#!/usr/bin/env bash
#
# Idempotently patch and build the optional `luaport` benchmark dep against
# Homebrew's lua@5.4 on macOS.
#
# luaport 1.6.3 ships a Makefile that hardcodes LuaJIT, and its C source uses
# `LUA_GLOBALSINDEX` which was removed in Lua 5.2. Neither is overridable via
# env vars without editing files in deps/, so this script applies two small
# in-place patches after `mix deps.get`:
#
#   1. deps/luaport/Makefile     — pkg-config against lua-5.4, drop LuaJIT flags
#   2. deps/luaport/c_src/luaport.c — replace LUA_GLOBALSINDEX with the
#                                     globals table from the registry
#
# Run this after every `mix deps.get` or `mix deps.clean luaport`. Re-running
# on an already-patched tree is a no-op.
#
# Requires: brew install lua@5.4

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$ROOT/deps/luaport/Makefile"
SRC="$ROOT/deps/luaport/c_src/luaport.c"

if [ ! -f "$MAKEFILE" ] || [ ! -f "$SRC" ]; then
  echo "luaport sources not found under deps/luaport. Run 'MIX_ENV=benchmark mix deps.get' first." >&2
  exit 1
fi

LUA_PREFIX="$(brew --prefix lua@5.4 2>/dev/null || true)"
if [ -z "$LUA_PREFIX" ] || [ ! -d "$LUA_PREFIX/lib/pkgconfig" ]; then
  echo "Homebrew lua@5.4 not found. Install it with: brew install lua@5.4" >&2
  exit 1
fi

PKG_CONFIG_PATH="$LUA_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_PATH

# Patch 1: Makefile — switch from luajit to lua-5.4, drop LuaJIT-only defines.
if grep -q "DLUAP_JIT" "$MAKEFILE"; then
  echo "Patching $MAKEFILE for lua-5.4..."
  # Build a fresh Makefile via sed; idempotent because the next run finds no DLUAP_JIT.
  sed -i.bak \
    -e 's|^LUA_CFLAGS ?= -DLUAP_JIT \$(shell pkg-config --cflags luajit)|LUA_CFLAGS ?= $(shell pkg-config --cflags lua-5.4)|' \
    -e 's|^LUA_LDFLAGS ?= \$(shell pkg-config --libs luajit)|LUA_LDFLAGS ?= $(shell pkg-config --libs lua-5.4)|' \
    -e '/^DEFINES += -DLUAP_BIT/d' \
    -e '/^DEFINES += -DLUAP_FFI/d' \
    "$MAKEFILE"
  rm -f "$MAKEFILE.bak"
else
  echo "$MAKEFILE already patched."
fi

# Patch 2: luaport.c — replace LUA_GLOBALSINDEX (removed in Lua 5.2).
# Match the actual use site, not the explanatory comment left by the patch.
if grep -q "lua_rawset(L, LUA_GLOBALSINDEX)" "$SRC"; then
  echo "Patching $SRC for Lua >= 5.2 globals handling..."
  python3 - "$SRC" <<'PY'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()

old = """  for (int i = 0; i < arity; i++)
  {
    if (e2l_any(buf, index, L) || e2l_any(buf, index, L))
    {
      exit(EXIT_BAD_ANY);
    }

    lua_rawset(L, LUA_GLOBALSINDEX);
  }
"""

new = """  /* Patched for tv-labs/lua benchmarks: LUA_GLOBALSINDEX was removed in
   * Lua 5.2. Push the globals table from the registry, then rawset against
   * it for each key/value pair. */
  lua_pushglobaltable(L);

  for (int i = 0; i < arity; i++)
  {
    if (e2l_any(buf, index, L) || e2l_any(buf, index, L))
    {
      exit(EXIT_BAD_ANY);
    }

    lua_rawset(L, -3);
  }

  lua_pop(L, 1);
"""

if old not in src:
    sys.stderr.write("Expected LUA_GLOBALSINDEX block not found; aborting.\n")
    sys.exit(1)

path.write_text(src.replace(old, new, 1))
PY
else
  echo "$SRC already patched."
fi

echo "Compiling luaport against $LUA_PREFIX..."
cd "$ROOT"
MIX_ENV=benchmark mix deps.compile luaport --force

echo
echo "luaport built successfully. Run benchmarks with:"
echo "  MIX_ENV=benchmark mix run benchmarks/fibonacci.exs"
