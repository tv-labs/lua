---
id: A43
title: "Implement the os standard library"
issue: 280
pr: 289
branch: fix/runtime-type-errors
base: main
status: merged
direction: A
unlocks:
  - all.lua
---

## Goal

Implement a sandbox-safe Lua 5.3 `os` standard library so code that
calls `os.clock`, `os.time`, `os.date`, etc. no longer raises a runtime
type error on a nil `os` global.

## Context

Sub-plan of the A21 triage cluster (parent
`.agents/plans/A21-triage-runtime-type-errors.md`, issue #259). Triage
of the four cluster files found:

- `utf8.lua` — already passes; no work needed.
- `math.lua` — first runtime failure under suite config is `load()`
  being sandboxed at line 277 (`checkcompt` → `assert(load(code))`);
  this is a `load`/sandbox concern, out of scope here.
- `coroutine.lua` — `coroutine` global is nil; the whole coroutine
  subsystem is unimplemented, far too large for this PR.
- `all.lua` — first runtime failure is `attempt to call a nil value
  (field 'clock' on global 'os')` at line 57. The `os` library is not
  implemented at all.

The single most tractable concrete fix is the missing `os` library.

## Out of scope

- `coroutine.lua` and the coroutine subsystem.
- `math.lua` `load()` sandbox behaviour.
- Filesystem / subprocess os functions (`os.remove`, `os.rename`,
  `os.execute`) beyond sandbox-safe stubs.
- Making `all.lua` fully pass — it is the suite harness and will
  progress to the next failure (it loads other suite files). The skip
  range is narrowed to reflect the new failure point.

## Success criteria

- [ ] New `Lua.VM.Stdlib.Os` module installed into the global env.
- [ ] `os.time`, `os.clock`, `os.difftime`, `os.date`, `os.getenv`,
      `os.setlocale`, `os.tmpname`, `os.exit` implemented per Lua 5.3.
- [ ] Regression unit tests under `test/lua/vm/stdlib/`.
- [ ] `all.lua` skip range narrowed to its new (post-os) failure with a
      precise reason.
- [ ] `mix test` and `mix test test/lua53_suite_test.exs --only lua53`
      both green.

## Implementation notes

- Model the module on `lib/lua/vm/stdlib/math.ex` (behaviour
  `Lua.VM.Stdlib.Library`, `lib_name/0`, `install/1`, native funcs of
  arity 2 returning `{results, state}`).
- Register it in `lib/lua/vm/stdlib.ex` alongside the other libraries.
- `os.time` with a table arg builds a unix timestamp from the fields;
  bare `os.time()` returns the current epoch seconds.
- `os.date` supports `*t` / `!*t` (table) and strftime-like format
  strings; `!` selects UTC.
- `os.setlocale` is a no-op that returns "C" (sandbox has no locale).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua53_suite_test.exs --only lua53
```

## Risks

- `os.date` format coverage is partial; only the directives the suite
  and common code use are guaranteed.
- `all.lua` will not pass outright; the narrowed skip must land on a
  syntactically valid boundary.

## Discoveries

- The high-level `Lua` API already lists `os.getenv`, `os.exit`,
  `os.tmpname`, `os.execute`, `os.remove`, `os.rename` in its
  `@default_sandbox`, anticipating an os library. Those remain blocked
  by default; the unit test pins that contract.
- `all.lua`'s harness `do ... end` block (63..209) wraps the dofile
  redefinition, so the skip must keep the `do`/`end` balanced — hence
  two ranges (137..208, 211..263) rather than one.
- After os lands, `all.lua` progresses to `attempt to call a number
  value (upvalue 'report')` inside the dofile-redefinition closure — a
  VM upvalue concern surfacing only through the unsupported
  loadfile/string.dump path; left for a future coroutine/load pass.
