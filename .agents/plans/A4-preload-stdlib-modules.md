---
id: A4
title: Pre-load Lua stdlib tables into package.loaded
issue: 165
pr: null
branch: fix/preload-stdlib-modules
base: main
status: ready
direction: A
unlocks:
  - attrib.lua
---

## Goal

Make `require "io"`, `require "string"`, `require "math"`, `require "table"`,
etc. resolve to the existing global stdlib tables instead of trying to find
them on the filesystem.

Currently `attrib.lua` fails with:

```
runtime error: module 'io' not found:
  no file 'test/lua53_tests/?.lua'
```

Lua 5.3's runtime pre-populates `package.loaded` with all built-in libraries,
so `require` returns the cached table without filesystem lookup.

## Out of scope

- Implementing missing stdlib modules (e.g. `io` is currently sandboxed/
  partial; that's a separate concern).
- Changes to `package.path` or the search algorithm.
- Adding new entries to `_G` — the goal is to make `require` find what's
  already there, not to add new globals.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit test in `test/lua/vm/stdlib/package_test.exs` (or
      `test/lua_test.exs`):
  - `require "string" == string` (returns the same table)
  - `require "math" == math`
  - `require "table" == table`
  - `require "debug" == debug`
  - `require "string"` works twice without re-evaluating (cache check)
- [ ] `attrib.lua` progresses past line 1 of its initial `require` block.

## Implementation notes

In `lib/lua/vm/stdlib.ex`'s `install/1` function:

1. After creating the `package.loaded` table, populate it with refs to
   each stdlib table that's already in globals.
2. Modules to pre-load (whatever's actually in globals as a table):
   `string`, `math`, `table`, `os`, `debug`, `coroutine` (if exists),
   `io` (if exists), `package` itself.

Code shape (rough):

```elixir
defp preload_stdlib_modules(state, package_loaded_tref) do
  modules = ["string", "math", "table", "os", "debug", "coroutine", "io"]

  Enum.reduce(modules, state, fn name, state ->
    case Map.get(state.globals, name) do
      {:tref, _} = tref ->
        State.update_table(state, package_loaded_tref, fn t ->
          %{t | data: Map.put(t.data, name, tref)}
        end)
      _ ->
        state
    end
  end)
end
```

Call this from `install/1` after `install_package_table/1`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- Whether `io` is currently a table or a sandboxed-function. If it's the
  sandboxed function, `require "io"` will return that, which may break
  scripts that expect the table interface. Inspect first.
- Order matters: stdlib tables must be created before pre-loading. Verify
  install order.

## Discoveries

(populated during implementation)
