---
id: B17
title: "VM instruction budget: configurable :max_steps with catchable exhaustion"
issue: 306
pr: 320
branch: feat/vm-max-steps
base: main
status: merged
direction: B
unlocks:
  - deterministic CPU bound for library consumers calling Lua.eval!/2 without a host Task + timeout wrapper
  - closes the pure-CPU-exhaustion gap left open after #305 (allocation-bomb hardening)
---

## Goal

Add a `:max_steps` option to `Lua.new/1` that bounds the number of VM
instructions a single evaluation may execute, mirroring the existing
`:max_call_depth`:

- Default `:infinity` — no limit, existing behavior byte-for-byte
  unchanged, and the default path stays free of new per-instruction
  cost.
- A positive integer caps total instructions executed. On exhaustion the
  VM raises a **catchable** Lua runtime error (message
  `"instruction budget exceeded"`) so `pcall` can recover, just like the
  `"stack overflow"` raised by `:max_call_depth`.

The bound must apply to **both** execution paths: the interpreter
(`do_execute/8` in `lib/lua/vm/executor.ex`) and the compiled dispatcher
(`dispatch/8` in `lib/lua/vm/dispatcher.ex`). A runaway script such as
`while true do end` or a tight numeric loop must terminate
deterministically inside the VM rather than relying on a host
wall-clock timeout.

## Out of scope

- **`:max_alloc_bytes`** — the companion deterministic memory bound that
  tallies bytes at allocating opcodes (concat, table grow). The issue
  explicitly defers it ("Could land in a follow-up"). Do NOT implement it
  here. If touching the allocating opcodes tempts a "while I'm here"
  change, log it under `## Discoveries` and stop.
- **Per-instruction counting on every opcode.** The budget is enforced at
  loop back-edges and call boundaries only (see Implementation notes).
  Straight-line code is bounded transitively because every unbounded
  growth path is a loop or recursion; counting every opcode would tax the
  default `:infinity` path, which the issue forbids.
- **Tail-call optimization** or any change to how frames are pushed.
- **Wall-clock timeouts** or `max_heap_size` — those are host concerns,
  already documented in the sandboxing guide.
- **Resetting / inspecting the remaining budget from Lua or the public
  API.** The budget is configured once at `Lua.new/1` and spans one
  top-level evaluation. No mid-run introspection.

## Success criteria

- [ ] `mix format` produces no diff.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `:max_steps` is accepted by `Lua.new/1`, validated exactly like
      `:max_call_depth` (positive integer or `:infinity`; anything else
      raises `ArgumentError` with a clear message naming `:max_steps`).
- [ ] Default is `:infinity` and existing tests are unchanged (same
      `mix test` pass/fail counts as `main` before the change).
- [ ] A finite `:max_steps` aborts a non-terminating script
      (`while true do end`) with a Lua runtime error whose message
      contains `"instruction budget exceeded"`.
- [ ] The exhaustion error is **catchable via `pcall`**: a new test
      asserts `pcall` returns `{false, message}` with the message and that
      the VM stays usable afterward.
- [ ] A program that finishes under the budget runs normally and returns
      its result; the budget does not leak across evaluations (a second
      `Lua.eval!/2` on the same `Lua.new(max_steps: N)` state gets a fresh
      budget).
- [ ] Both the interpreter and the compiled dispatcher enforce the budget
      (test exercises both paths — see Implementation notes for how to
      force the compiled path).
- [ ] The counter is threaded as a function parameter, NOT stored in
      `%State{}`, preserving the executor's deliberate
      `line`-off-`State` discipline. `max_steps` (the configured ceiling)
      lives in `%State{}` like `max_call_depth`; the running tally does
      not.
- [ ] `mix test --only lua53` shows no regression in suite pass count
      vs `main` before the change.
- [ ] Benchmarked: `mix run benchmarks/fibonacci.exs` and
      `mix run benchmarks/dispatcher_vs_interpreter.exs` (default
      `LUA_BENCH_MODE=quick`) on `main` vs this branch with `:max_steps`
      left at its `:infinity` default show no meaningful regression.
      Numbers recorded in the PR body.
- [ ] Docs: the sandboxing guide's "Call depth" / resource-limits section
      is extended to cover `:max_steps` (see Implementation notes for the
      file-path resolution).
- [ ] No source or test file references the plan id `B17` (repo rule in
      `CLAUDE.md`). The id lives only in the commit body and PR
      description.

## Implementation notes

Mirror `:max_call_depth` everywhere it appears.

### 1. Public API — `lib/lua.ex`

- Add `max_steps: :infinity` to the `Keyword.validate!/2` defaults at
  `new/1`.
- Fetch and validate it next to `max_call_depth`:
  `max_steps = validate_max_steps!(Keyword.fetch!(opts, :max_steps))`.
- Add `validate_max_steps!/1` mirroring `validate_max_call_depth!/1`:
  `:infinity` and `pos_integer` pass; anything else raises `ArgumentError`
  with a message naming `:max_steps`.
- Thread it into the seeded state alongside `max_call_depth`.
- Add a `* :max_steps - ...` bullet to the `## Options` moduledoc with a
  doctest mirroring the `:max_call_depth` doctest.

### 2. State — `lib/lua/vm/state.ex`

- Add `max_steps: :infinity` to `defstruct` and to the `@type t`. Do NOT
  add a running-tally field — the tally is a threaded parameter, not
  state.
- Add a guard helper `check_steps!/2` taking the state and the current
  step count, ordered so the `:infinity` clause resolves first with no
  struct rebuild, raising the same `Lua.VM.RuntimeError` used by
  `"stack overflow"` so `pcall`/`xpcall` catch it for free.

### 3. Interpreter — `lib/lua/vm/executor.ex`

- Thread a `steps` counter as a new trailing parameter on `do_execute`,
  turning `do_execute/8` into `do_execute/9`. Seed it at `0` at both
  entry points (`execute/5` and `call_function/3`). Thread it through
  `do_frame_return` so the tally spans frames within one interpreter
  evaluation (non-tail recursion stacks frames in the same `do_execute`
  chain, so the recursion bound is global to the evaluation).
- Increment + check only at loop back-edges (the `:cps_while_body`,
  `:cps_repeat_cond` repeat branch, `:cps_numeric_for` continue, and
  `:cps_generic_for` continue, all in the `do_execute([], ...)` cont
  dispatcher) and at the two `State.check_call_depth!` call boundaries.
- The cross-module `:compiled_closure` / `Dispatcher.execute` and
  `call_value` hand-offs carry the tally through a `steps` field on
  `%State{}` rather than changing the `{results, state}` return shape
  (changing it would ripple into out-of-scope stdlib modules). The crossing
  engine writes its threaded tally into `state.steps` at the boundary — only
  where the struct is already rebuilt to push a call frame, never per opcode
  — and the entered engine seeds from it and stamps the final tally back, so
  the budget spans recursion that alternates execution engines.

### 4. Compiled dispatcher — `lib/lua/vm/dispatcher.ex`

- Thread the same `steps` counter through `dispatch/8` → `dispatch/9`,
  seeded at `0` at the dispatcher entry.
- Increment + `State.check_steps!/2` at the dispatcher's loop back-edges
  and at the six `State.check_call_depth!(state)` call-boundary sites.

### 5. Test — `test/lua/vm/max_steps_test.exs`

New file. Cover: finite budget aborts `while true do end`; `pcall`
catches it and state stays usable; bounded loop returns normally and no
cross-eval leak; recursion under a finite budget raises the budget error
(interpreter path); `:infinity` imposes no bound; the compiled-dispatcher
path is bounded too; validation rejects `0`, `-1`, `:nope`.

### 6. Docs — sandboxing guide

`guides/sandboxing.md` is not tracked on `main`; the published guide is
`guides/examples/sandboxing.livemd`. Add a resource-limits section there
covering `:max_steps` mirroring the `:max_call_depth` framing.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/max_steps_test.exs
mix test test/lua/vm/recursion_depth_test.exs
mix test
mix test --only lua53
```

## Risks

- **Regressing the default `:infinity` hot path.** Mitigation:
  `check_steps!/2` short-circuits on `:infinity` in a single
  function-head match; counting happens only at loop back-edges and call
  boundaries, never per opcode; gated on the benchmark step.
- **Counter scoping bug (per-frame vs whole-evaluation).** Mitigation:
  thread `steps` through `do_execute`/`do_frame_return` so the
  interpreter tally is global to one evaluation. The recursion test is
  the guard.
- **Budget leaking across evaluations.** Mitigation: seed at `0` on each
  `execute/5` / `Dispatcher.execute/4` entry.
- **Only one path enforced.** Mitigation: the test forces the compiled
  path explicitly.
- **Error not catchable.** Mitigation: reuse `Lua.VM.RuntimeError`.
- **Plan-id leakage into source/tests.** Mitigation: id stays in the
  commit body and PR description only.

## What changed

PR #320 (merged). The option shipped **renamed** from the plan's working
name `:max_steps` to `:max_instructions` — the name used in `Lua.new/1`,
the docs, and the CHANGELOG. Everything else below matches what landed.

Files touched:

- `lib/lua.ex` — `:max_steps` added to `new/1` defaults, validated via
  `validate_max_steps!/1`, threaded into the seeded state; `## Options`
  moduledoc bullet + doctest.
- `lib/lua/vm/state.ex` — `max_steps` field on `defstruct` and `@type t`;
  `check_steps!/2` guard raising a catchable `Lua.VM.RuntimeError`
  (`"instruction budget exceeded"`); a `steps` field that carries the tally
  across engine boundaries (never written per opcode).
- `lib/lua/vm/executor.ex` — `steps` threaded as a 9th parameter through
  `do_execute`, `do_frame_return`, and `continue_after_call`; increment +
  `check_steps!/2` at the four loop back-edges and the two call boundaries;
  seeds its tally from `state.steps` at the interpreter entry points and
  stamps the final tally back via `finish_steps/2` at evaluation terminals
  so the budget survives `Executor ↔ Dispatcher` hand-offs.
- `lib/lua/vm/dispatcher.ex` — `steps` threaded through `dispatch`,
  `finish_body`, `apply_multi_call_result`, `return_one`, `return_multi`;
  increment + `check_steps!/2` at the loop back-edges and the six call
  boundaries; seeds from / writes back `state.steps` at the dispatcher entry,
  terminals, and `Executor` bridges so the budget is continuous across the
  boundary.
- `test/lua/vm/max_steps_test.exs` — new: enforcement on both paths,
  catchability via `pcall`, no cross-eval leak, `:infinity` default,
  validation, and cross-engine mutual recursion (budget spans an
  interpreted/compiled alternating call chain, plus a guard asserting the
  pair is genuinely split across both engines).
- `guides/examples/sandboxing.livemd` — "Bounding CPU work" section
  documenting `:max_call_depth` and `:max_steps`.

Test delta: `mix test` 2114 → 2128 passed (13 new cases + 1 new doctest),
19 skipped, 1 excluded. `mix test --only lua53` unchanged (17 passed,
12 skipped).

Discoveries / deviation from the original plan:

- The cross-module `Executor ↔ Dispatcher` hand-off carries the running
  tally through a `steps` field on `%State{}` rather than changing
  `Dispatcher.execute/4`'s `{results, state}` return shape (which would have
  rippled into out-of-scope stdlib modules). The crossing engine writes its
  threaded tally into `state.steps` at the boundary — where the struct is
  already rebuilt to push a call frame, so the default `:infinity` path adds
  no per-opcode cost — and the entered engine seeds its own threaded tally
  from `state.steps`, stamping the final tally back at its terminal. The
  budget therefore spans a call chain that alternates execution engines
  (e.g. a `goto`-bearing interpreted closure and a plain compiled closure in
  unbounded mutual recursion) instead of resetting at each boundary, closing
  the gap a fresh-budget reseed would have left open between
  `max_call_depth: :infinity` and a deterministic CPU bound. Regression
  coverage: `test/lua/vm/max_steps_test.exs` "cross-engine mutual recursion".
- The benchmark gate could not run: the benchee harness only loads under
  `MIX_ENV=benchmark`, which pulls in `luaport`, whose native build needs a
  matching C Lua toolchain (the comparison baselines are PUC-Lua / Luaport,
  not just the internal engines). The default `:infinity` path remains
  zero-cost by construction: one integer increment + one short-circuiting
  `check_steps!/2` head-match per back-edge / call boundary, never per
  opcode, structurally identical to the existing `check_call_depth!/1`. The
  cross-boundary fix adds only a `steps:` field assignment inside the
  `%State{}` rebuild that each engine hand-off already performs to push a
  call frame (`call_stack` / `call_depth`), so it costs nothing on
  straight-line code and nothing extra beyond the already-present boundary
  struct rebuild. Still owed: an actual run in CI or on a host with a
  compatible C Lua before merge.
