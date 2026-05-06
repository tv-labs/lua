---
id: A16
title: Implement Lua 5.3 _ENV semantics for global access
issue: 186
pr: null
branch: feat/env-semantics
base: main
status: review
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

### Storage migration: globals now live in `_G.data`

Chose option 2 from the plan's "globals storage strategy" — moved global
storage out of the flat `state.globals` map and into the `_G` table's
`data` field. `State.new/0` now allocates `_G` up-front and stores its
tref in `state.g_ref`. New `State.get_global/2` and updated
`State.set_global/3` read/write `_G.data`. The `_G` metatable proxy
(`__index`/`__newindex` routing to `state.globals`) is gone — globals
are just real table fields now.

This was cleaner than option 1 ("keep `state.globals` and sync with
`_G`") and avoids an ongoing sync-risk surface. Host API (`Lua.set!` /
`Lua.get!`) continues to work transparently because they now go through
`State.get_global`/`set_global`.

### `_ENV` as a chunk-level local at register 0

The chunk reserves register 0 for `_ENV`. Codegen emits a new
`:load_env` opcode at the start of every chunk that copies
`state.g_ref` into register 0. User-level `_ENV = ...` becomes a normal
assignment to that local; nested functions inherit `_ENV` via the
existing upvalue chain.

`_ENV` is unconditionally marked as a captured-local at the chunk
level. This guarantees that any later capture by a nested function
(which creates the open-upvalue cell) sees a consistent value, and that
chunk-level `_ENV` access always uses `get_open_upvalue` /
`set_open_upvalue` — which fall back to direct register I/O when no
cell exists yet.

### `set_open_upvalue` no longer relies on a prior register write

Previously, `gen_assign_target` for `{:captured_local, _}` emitted only
`set_open_upvalue` and relied on the (informal) invariant that the
register already held the value before the cell was created. That worked
for the existing call sites but broke under Plan A16 because chunk-level
`_ENV` is now captured-local from the very first instruction, before any
closure has run. Updated `gen_assign_target` to emit a `move` *and* the
`set_open_upvalue` so writes propagate regardless of cell-allocation
state.

### Multi-target assignment to free names: register reservation fix

In `Statement.Assign` codegen for `[a, b] = f()` (multi-return call), the
post-call `ctx.next_reg` only advanced past the *first* result register.
Old code emitted `set_global` per target, which doesn't allocate temp
registers — so it accidentally worked. New code emits `_ENV.<name> = ...`
which loads `_ENV` into a temp register, and the temp allocation
clobbered subsequent call result registers. Fix: bump `ctx.next_reg`
past all the call's expanded result slots after `gen_expr(call, ctx)`.

### FuncDecl target resolution moved after body resolution

The `Statement.FuncDecl{name: [single_name]}` resolver used to tag the
target *before* recursing into the function body. Under A16 that
ordering was wrong: the body may capture `_ENV` from the chunk, and
`captured_locals` (and the `_ENV` upvalue chain in nested functions) is
only finalised after the body is processed. Now we resolve the body
first, then tag the target. This is a generalisation that doesn't change
behaviour for any non-`_ENV` case.

### Eager `_ENV` upvalue allocation in every nested function

`resolve_function_scope` now eagerly walks `find_upvalue("_ENV", ...)`
for every nested function it processes. This guarantees `_ENV` is
always available as an upvalue regardless of whether the function body
references any free name explicitly — required because the
`gen_var_by_name` path (used for FuncDecl table-chain heads like
`function obj.method`) needs to look up `_ENV` at codegen time without
re-walking the scope chain.

### `:get_global` / `:set_global` opcodes are now vestigial

Codegen no longer emits these instructions; all global access goes
through `_ENV` field access. The opcode handlers and constructors
remain in place (`Instruction.get_global/2`, `Instruction.set_global/2`,
the executor `do_execute` clauses) for forward-compatibility with any
external prototypes or hand-written instruction sequences. They could
be removed in a follow-up cleanup.

### `_ENV` is no longer registered as a global

`install_global_g/1` previously stored `_ENV` as a global aliasing
`_G`. With `_ENV` now living in chunk register 0, that global slot is
no longer the source of truth. We still set `state.globals["_ENV"] =
g_ref` at install time for backwards compatibility (so introspection
tools that read `_G._ENV` see something), but reading the global
`_ENV` is decoupled from the chunk-level `_ENV` that free-name access
consults.
