---
id: A16
title: Implement Lua 5.3 _ENV semantics for global access
issue: 186
pr: null
branch: feat/env-semantics
base: main
status: in-progress
direction: A
unlocks:
  - events.lua
  - attrib.lua
  - locals.lua
  - errors.lua
---

## Goal

Make user-level reassignment of `_ENV` actually redirect subsequent
"global" reads and writes through the named environment table, matching
Lua 5.3 semantics. Today `_ENV` is a one-time alias of `_G` set at
stdlib install; reassigning it has no effect because globals live in a
flat `state.globals` Elixir map and `:get_global` / `:set_global`
opcodes bypass any user-controlled environment.

## Background

In Lua 5.3, every "global" name reference is syntactic sugar for
`_ENV.name`, where `_ENV` is an implicit upvalue in every function. A
user can swap their environment with `_ENV = setmetatable({}, ...)` or
`local _ENV = ...` and all subsequent free-name accesses go through
that table (and its metamethods).

This implementation does not do any of that. Free-name resolution in
`scope.ex` produces a `{:global, name}` tag, codegen emits dedicated
`:get_global` / `:set_global` opcodes, and the executor reads/writes a
flat `state.globals` map that no Lua-level table participates in.
`_G` is a metatable-backed proxy whose `data` map is empty and whose
`__index`/`__newindex` route to `state.globals`. `_ENV` is set once to
that same proxy and never consulted again.

This blocks `events.lua` immediately (line 10 swaps `_ENV`) and is
needed by other suite files.

## Out of scope

- Removing `state.globals` entirely. The host API still needs a way to
  set globals from Elixir; we may keep the field but reframe it as the
  raw data of the top-level `_ENV` table.
- Changing the `_G` proxy table's user-visible identity. Code that does
  `_G == _ENV` at the top level must still hold.
- Performance regressions: the existing `:get_global` / `:set_global`
  fast path may be retained when `_ENV` is provably the unmodified
  globals table, or replaced in a follow-up perf plan.

## Success criteria

- [ ] `mix test` passes (no regressions; should remain at or above
      current count).
- [ ] New unit tests in `test/lua/vm/env_semantics_test.exs`:
  - Reassigning `_ENV` to a fresh table redirects subsequent global
    writes (does not touch original `_G`).
  - Reading a free variable after `_ENV` swap consults the new
    environment's `__index` metamethod.
  - `local _ENV = ...` inside a function redirects only that function's
    free-name access.
  - Setting a key to `nil` in `_ENV`-with-`__index` chain falls through
    to the chained table on next read.
  - Top-level `_G == _ENV` still holds before any user reassignment.
- [ ] `events.lua` progresses past line 19 (the `_ENV`-dependent block).
      Suite count: events.lua should flip to passing or surface a new,
      different failure.
- [ ] No regression in `test/language/global_test.exs`.

## Implementation notes

Expected files to touch:

- `lib/lua/compiler/scope.ex` — at lines 308-328 (and 217-227 for
  `FuncDecl`), the `:not_found` branch should resolve as if the source
  had been `_ENV.name`. Either:
  - Rewrite at scope-resolution time to a structured form
    `{:env_field, name}` and let codegen handle it; or
  - Resolve `_ENV` itself by the normal upvalue/local/global rules and
    bake that into the AST node.
- `lib/lua/compiler/codegen.ex` — at the four `{:global, name}` handling
  sites (627-633, 721-725, 929-933, 1290-1296), emit:
  - Lookup `_ENV` (as upvalue or local), then
  - `:get_field` / `:set_field` on it.
  - These ops already invoke `__index` / `__newindex` correctly.
- `lib/lua/vm/state.ex` and `lib/lua/vm/executor.ex` — decide on the
  globals storage strategy. Options:
  1. Keep `state.globals` as the storage and make the top-level
     `_ENV`/`_G` table's `data` map *be* `state.globals` (or keep them
     in sync). Pro: minimal host-API churn. Con: ongoing sync risk.
  2. Move globals into the `_G` table's `data` map proper, reframe
     `state.globals` as a thin pointer to it, update `set_global/3` to
     write into that table.
- `lib/lua/vm/stdlib.ex` — at `install_global_g/1` (lines 67-115):
  - Stop using a metatable proxy to fake the globals table; instead
    make the storage live in the table's `data`.
  - Ensure `_ENV` is installed as an upvalue/local on the main chunk's
    function, not just a global named `"_ENV"`.
- Main-chunk execution path — wherever `Lua.VM.execute` runs the top
  chunk, bind the `_ENV` upvalue to the globals table.

The precise design (scope option 1 vs 2 above) should be chosen during
implementation; whichever path is simpler to keep
`test/language/global_test.exs` passing should win.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/env_semantics_test.exs
mix test test/language/global_test.exs
```

## Risks

- Substantial change touching scope resolution, codegen for every free
  variable, and global storage. Risk of accidentally breaking unrelated
  tests is high — keep a tight verify loop.
- Host API: external callers using `Lua.set_global/3` /
  `Lua.get_global/2` must continue to work. Ensure those go through the
  new globals storage.
- Performance: replacing direct `:get_global`/`:set_global` with field
  access on `_ENV` is one extra indirection per global access. If a
  measurable regression appears, retain the fast-path opcodes for the
  case where `_ENV` is provably the unmodified globals table.
- Closures: nested functions inherit `_ENV` like any other upvalue.
  Closure capture must thread `_ENV` correctly even across multiple
  levels.

## Discoveries

(populated during implementation)
