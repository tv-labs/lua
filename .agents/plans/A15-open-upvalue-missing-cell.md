---
id: A15
title: set_open_upvalue / get_open_upvalue crash when cell is missing
issue: null
pr: null
branch: fix/open-upvalue-missing-cell
base: main
status: in-progress
direction: A
unlocks:
  - sort.lua
  - strings.lua
  - verybig.lua
---

## Goal

Fix the `Map.fetch!` crash inside `set_open_upvalue` and `get_open_upvalue`
in `lib/lua/vm/executor.ex` (lines 301 and 310 at the time of writing).
When these handlers run with a register that has no entry in
`state.open_upvalues`, the VM raises:

```
Lua runtime error: key N not found in: %{}
```

instead of behaving correctly. This was discovered while shipping plan A1:
A1's stated table-read bug already passes, but the same error message also
appears here from a completely unrelated path.

## Reproduction

`test/lua53_tests/sort.lua` fails partway through with:

```
testing (parts of) table library
testing unpack
Lua runtime error: key 3 not found in:

    %{}
```

Stacktrace ends at `lib/lua/vm/executor.ex:310` inside `set_open_upvalue`.
`strings.lua` and `verybig.lua` produce the same error shape with
different keys.

## Out of scope

- The for-loop register regression in A14 (separate bug, separate symptom).
- Any other suite failure that surfaces *after* this fix lands.
- Refactors of the upvalue / closure pipeline beyond what is needed.

## Success criteria

- [ ] `mix test` passes (no regressions vs. baseline).
- [ ] `mix test test/lua/vm/table_index_test.exs` still green (sanity).
- [ ] New unit test in `test/lua/vm/upvalue_test.exs` (or appropriate
      existing file) reproduces the original sort.lua-style failure as a
      minimal Lua snippet and asserts it does not crash.
- [ ] At least one of `sort.lua`, `strings.lua`, `verybig.lua` makes more
      progress than before (passes outright if no further bugs surface;
      otherwise fails later, at a different site, and that site is logged
      in `## Discoveries`).

## Implementation notes

The crash is `Map.fetch!(state.open_upvalues, reg)` against an empty (or
not-yet-populated) `open_upvalues`.

Read the lifecycle:

```bash
grep -nE "open_upvalues|open_upvalue|set_open_upvalue|get_open_upvalue" \
  lib/lua/vm/executor.ex
```

`open_upvalues` is reset to `%{}` at:

- VM entry (line ~30)
- Tailcall / call boundaries (lines ~59, 551, 1252, 1470, 1515, 1564)
- Loop-end cleanups (`Map.reject(...)` at lines ~197, 230, 416, 453)

Cells are only *created* by the `closure` handler around line 470, which
adds `{reg => cell_ref}` when a nested prototype captures a parent local.

Hypothesis: a code path emits `set_open_upvalue` / `get_open_upvalue` for
a register that was never claimed by a `closure`. Either:

1. The compiler emits these instructions when it shouldn't, or
2. A `Map.reject` cleanup is too eager and removes a cell that is still
   live, or
3. `open_upvalues` is reset (`%{}`) without first promoting live cells
   into closed-upvalue cells, leaving dangling instructions.

Reduce sort.lua to the smallest snippet that reproduces, then bisect from
there. A starting reduction:

```bash
elixir -e 'try do Lua.eval!(File.read!("test/lua53_tests/sort.lua")) rescue e -> IO.puts(Exception.format_stacktrace(__STACKTRACE__)) end'
```

Tag the snippet, copy into `test/lua/vm/upvalue_test.exs`, and iterate.

Likely fix shape: either make `set_open_upvalue` / `get_open_upvalue` fall
back to creating the cell on demand (mirroring `closure`'s logic at line
470), or fix the offending compiler emission / cleanup site.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/upvalue_test.exs
mix test --only lua53
```

Capture suite delta in PR body.

## Risks

- Falling back to "create cell on demand" hides real compiler bugs. Prefer
  to find the upstream cause first.
- Eager cleanup via `Map.reject` may be the root cause. Tightening it
  could leak upvalue cells; verify with the metatable / closure regression
  tests in `test/lua/vm/metatable_test.exs` and any closure tests.

## Discoveries

(populated during implementation)
