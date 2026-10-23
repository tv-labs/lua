---
id: A51
title: "Suspend/resume: deflua returns {:suspend, values}, Lua.eval!/call_function surface {:suspended, values, lua}, Lua.resume/2 continues"
issue: null
pr: 434
branch: feat/deflua-suspend-resume
base: main
status: review
direction: A
---

## Goal

Give embedders host-driven suspension of a running Lua evaluation. A
`deflua` function may return `{:suspend, values}` (or
`{:suspend, values, %Lua{}}`) to suspend the VM at that call; the
public entry point (`Lua.eval!/2`, `Lua.call_function/3`) then returns
immediately with `{:suspended, values, %Lua{}}` carrying a resumable
continuation. `Lua.resume/2` (new) re-enters the VM; the resume values
become the suspended call's results, exactly as if the `deflua` had
returned them.

```elixir
defmodule Scheduler do
  use Lua.API, scope: "scheduler"

  deflua yield(value), state do
    {:suspend, [value], state}
  end
end

lua = Lua.new() |> Lua.load_api(Scheduler)

{:suspended, [42], lua} =
  Lua.eval!(lua, "local x = scheduler.yield(42); return x + 1")

{:ok, [11], lua} = Lua.resume(lua, [10])   # the suspended call "returns" 10
```

Why this is tractable: both engines are fully tail-recursive CPS loops
(`Lua.VM.Executor.do_execute/9`, `Lua.VM.Dispatcher.dispatch/11`). The
entire machine state — remaining instructions / pc, register file,
CPS continuation stack, saved call frames, line, instruction tally —
is explicit immutable data in scope at every call site. The BEAM stack
carries no Lua control flow, so "unwinding" a suspended call is just
returning that data. No continuation capture of the Erlang stack is
needed or possible; the VM never relies on it.

What is missing today (confirmed by reading `Lua.VM.State`,
`lib/lua/vm/state.ex:20-72`): the `%Lua{}` returned by `eval!` carries
the heap (tables, userdata, metatables, upvalue cells) and diagnostic
control state (`call_stack` as `{source, line, name_hint}` traceback
tuples, `call_depth`, `instruction_count`) but **not** the resumable
control state — no pc/rest, no registers, no continuation stack, no
saved frames with their `base`/`result_count`. Resuming from `%Lua{}`
alone is impossible; the continuation must be captured at the call site
and returned alongside.

## Out of scope

- The Lua `coroutine` library (`create`/`resume`/`wrap`/`yield`/
  `status`). That is phase 2 and builds on this machinery; `coroutine.lua`
  stays a documented suite skip. No suite delta is expected from this
  plan.
- Suspension **across a native re-entry boundary**: `pcall`/`xpcall`,
  metamethod callbacks (`__index`, `__call`, …), generic-for iterators,
  `table.sort` comparators, `gsub` functions, and `deflua` functions
  that themselves call back into Lua (`Lua.call_function!`/`eval!`).
  v1 raises a catchable Lua error there — "attempt to suspend across a
  native call boundary" (Lua 5.2-style yield-across-C semantics). True
  Lua 5.3 yield-across-`pcall` needs continuation composition through
  Elixir frames, which the BEAM cannot capture; that is phase 2.
- Tick-based / time-sliced suspension (a `State.tick!` hook variant of
  `:max_instructions`). Separate plan.
- Persistence/serialization of continuations to disk. Continuations
  are pure in-memory terms; a snapshot holding a local fun in a register
  is not persistable (documented, not supported).
- A non-bang `Lua.eval/2`. `eval!` itself returns the tagged union.
- Changes to `Lua.Chunk`, the parser, or the compiler. None needed:
  suspension is purely a runtime + API feature.

## Success criteria

- [ ] A `deflua` returning `{:suspend, values}` / `{:suspend, values, %Lua{}}`
      suspends; `Lua.eval!/2` returns `{:suspended, values, lua}` (values
      decoded when `decode: true`, default; raw + display-wrapped when
      `decode: false`, matching result handling).
- [ ] `Lua.resume/2` returns
      `{:ok, results, lua} | {:error, exception, lua} | {:suspended, values, lua}`;
      `Lua.resume!/2` returns `{results, lua} | {:suspended, values, lua}`
      and raises on error. Resume values are encoded host→Lua values (same
      convention as `Lua.call_function/3` args).
- [ ] Resume values become the suspended call's results with correct
      multi-return semantics: `local x = yield()`, `local a, b = yield()`,
      `return yield()`, `f(yield())` (vararg expansion), and tail position.
- [ ] Suspension works from both engines: interpreted code (executor) and
      bytecode-compiled closures (dispatcher), including a suspend that
      crosses an Executor↔Dispatcher boundary mid-evaluation.
- [ ] Heap effects made before the suspend are kept (visible in the
      suspended `%Lua{}` and after resume) — same §2.3 discipline as
      `pcall` error recovery.
- [ ] `:max_instructions` budget spans suspend/resume (tally is captured
      in the continuation and re-seeded on resume; resume is not a
      top-level eval and does not reset the budget).
- [ ] Suspend across `pcall`/`xpcall` returns the boundary error as an
      ordinary protected error (`false, "attempt to suspend across a
      native call boundary"`), and does not corrupt state.
- [ ] `Lua.call_function/3` surfaces `{:suspended, values, lua}`; a
      native called directly (outside any Lua execution) suspends into a
      degenerate continuation whose resume returns the resume values as
      the call results.
- [ ] Resuming a `%Lua{}` with `continuation: nil` raises `ArgumentError`.
- [ ] Unencoded suspend values are rejected with the existing
      "deflua functions must return encoded data" error.
- [ ] New test file `test/lua/suspend_resume_test.exs` covers the matrix
      above; doctests on `Lua.resume/2` pass via `doctest Lua`.
- [ ] `mix format`, `mix compile --warnings-as-errors`, `mix test` pass.
- [ ] `mix test test/lua53_suite_test.exs --only lua53` unchanged
      (20/29; `coroutine.lua` remains a documented skip).

## Implementation notes

### Public API shapes

- `%Lua{}` gains a field: `defstruct [:state, :continuation, debug: false]`
  (`lib/lua.ex:28`). `continuation` is `nil | Lua.VM.Continuation.t()`.
  Additive; `Lua.new/1` leaves it `nil`.
- `Lua.eval!/2,3` spec becomes `{[term()], t()} | {:suspended, [term()], t()}`.
  It still raises on errors; suspension is not an error.
- `Lua.call_function/3` spec becomes
  `{:ok, [term()], t()} | {:error, Exception.t(), t()} | {:suspended, [term()], t()}`;
  `Lua.call_function!/4` mirrors `eval!`.
- New `Lua.resume/2` and `Lua.resume!/2` with full `@doc` + doctests.
  Resuming consumes the continuation (the returned `%Lua{}` has
  `continuation: nil` unless the run suspends again, in which case the
  new continuation replaces it). Because continuations are immutable
  data, a host that copies the `%Lua{}` before resuming can branch.
- `deflua` contract extension, documented in `Lua.API` (`lib/lua/api.ex`):
  in addition to `value` and `{results, %Lua{}}`, a function may return
  `{:suspend, results}` or `{:suspend, results, %Lua{}}`. `results` are
  encoded Lua values yielded to the host; they are validated with
  `Util.list_encoded?/1` exactly like normal returns.

### Internal machinery

**New exception `Lua.VM.Suspend`** (`lib/lua/vm/suspend.ex`, new file):
`defexception values: [], state: nil, layers: nil`. `values` are the
encoded yield values; `state` is the `%Lua.VM.State{}` at the suspend
point (heap effects kept, like VM error exceptions); `layers` is `nil`
until a catch site attaches the continuation layer stack. It is
deliberately **not** one of the exception types `pcall` catches as a Lua
error (`RuntimeError`/`AssertionError`/`TypeError`/`ArgumentError`), and
it must not be wrapped by `Lua.RuntimeException` at the public boundary.
`Exception.message/1` should render something sane for stray cases.

**New struct `Lua.VM.Continuation`** (`lib/lua/vm/continuation.ex`, new
file): `defstruct [:layers]` — an opaque, unstable stack of machine
layers, innermost first. Each layer is a map:

- `%{engine: :executor, rest:, regs:, upvalues:, proto:, cont:, frames:,
     line:, instruction_count:, base:, result_count:, state:,
     open_upvalues:}` — everything `do_execute/9` threads, as in scope at
     the executor's call dispatch (`lib/lua/vm/executor.ex:1394-1543`).
     Saved frames already carry
     `%{rest, cont, regs, upvalues, proto, base, result_count,
     open_upvalues}` (`executor.ex:1458-1468`).
- `%{engine: :dispatcher, code:, pc:, regs:, upvalues:, proto:, cont:,
     frames:, cs:, cd:, ou:, base:, instruction_count:, state:}` — the
     `dispatch/11` parameters as in scope at the dispatcher's bridges
     (`lib/lua/vm/dispatcher.ex:2452-2576`).
- `%{engine: :pending_call}` — degenerate layer for a native suspended
  when called directly via `Lua.call_function/3` outside any Lua
  execution; resume returns the resume values as the call results.

**Plumbing choice: ride the exception channel, don't change loop return
shapes.** `do_execute/9` and `dispatch/11` return `{results, regs, state}`
/ `{results, state}` through dozens of internal tail-call sites. Threading
a `{:suspended, ...}` variant through all of them would touch the hot
path everywhere. Instead the native-call catch site attaches the layer
stack to the `Suspend` exception and reraises; the exception crosses
the (single) tail-recursive BEAM frame straight to the boundary. This
mirrors the existing error-state ferrying (`annotate_frame_state/2`,
`executor.ex:119-127`): VM exceptions already carry `:state` out of the
loop. `annotate_frame_state/2` only fills `:state` when nil, so a
`Suspend` carrying its own `state` passes through untouched.

### Catch sites (audit list — every `rescue`/`catch` that can see Suspend)

| # | Site | Action on `%Lua.VM.Suspend{}` |
|---|------|-------------------------------|
| 1 | Executor native-call branch rescue, `executor.ex:1494-1543` (`{:native_func, fun}` in the `do_execute` call dispatch) | `layers: nil` → build executor layer from in-scope machine state, attach, reraise. `layers` present → reraise `Lua.VM.RuntimeError` "attempt to suspend across a native call boundary" with `state: e.state` (re-entrant native: the fun called back into Lua and the inner machine suspended). |
| 2 | Executor `:compiled_closure` branch, `executor.ex:1394-1433` (bridges via `Dispatcher.execute/4`) | `layers` present → push an executor layer (the outer machine parked at the `Dispatcher.execute` call; resume injects the inner results via `continue_after_call/12`, `executor.ex:3091`). `layers: nil` cannot happen here (only natives raise bare `Suspend`). |
| 3 | Dispatcher native bridges `call_zero_bridge`/`call_one_bridge` (native clauses), `dispatcher.ex:2452-2576` | Same as #1 but build a dispatcher layer. |
| 4 | Dispatcher `:lua_closure` bridge clauses (`dispatcher.ex:2452-2540`) | `layers` present → push a dispatcher layer; resume places results exactly as the bridge's post-call code does (`dispatch(code, pc + 1, regs_with_results, …)`). |
| 5 | `pcall`/`xpcall` rescues, `lib/lua/vm/stdlib.ex:252-283` | Add one explicit clause **before** the catch-all: any `Suspend` → ordinary protected error `{[false, "attempt to suspend across a native call boundary"], State.unwind_to(state, e.state)}` (xpcall: run the message handler on that message, like the generic error path). Rationale: `pcall` is an Elixir native; the pcall'd closure runs in a nested `Executor.call_function/3`, and the Elixir frame between the inner machine and the outer machine is not capturable. This is the deliberate 5.2-style divergence. |
| 6 | `Executor.call_function/3` rescues (`executor.ex:176-180`, `:208-211`) and `Dispatcher.do_execute_top` rescue (`dispatcher.ex:206-213`) | Pass-through (annotate only fills nil `:state`; `Suspend` carries its own). Verify no clause wraps it. |
| 7 | `Lua.VM.execute/3` (`lib/lua/vm.ex`) | Convert `Suspend` with layers → `{:suspended, values, continuation}`; bare `Suspend` (metamethod/iterator context — no catch site built a layer) → raise `Lua.VM.RuntimeError` boundary error. Do **not** reset `instruction_count` on the resume path (see below). |
| 8 | `Lua.eval!` both clauses (`lib/lua.ex:528-620`) | Match the `{:suspended, values, continuation}` return; decode/wrap values per the `:decode` option exactly like normal results; return `{:suspended, values, %{lua | state: ..., continuation: ...}}`. Defensive rescue clause: bare `Suspend` → reraise as `Lua.RuntimeException` boundary error. |
| 9 | `Lua.do_call_function` / `finish_call` (`lib/lua.ex:822-800`, `:855-883`) | `{:native_func, fun}` clause: catch `Suspend` → `{:suspended, values, continuation}` where a bare `Suspend` gets the degenerate `:pending_call` layer. `finish_call` gains a clause wrapping it into `%Lua{}`. The interpreted/compiled clauses convert the engine's `{:suspended, ...}` similarly. |
| 10 | `Lua.eval!`/`call_function!` wrapping rescues (`lib/lua.ex:552-570`, `:935-940`) | `Suspend` must never reach these as a raise (converted at #7/#9); add a defensive clause converting to `Lua.RuntimeException` boundary error if it does. |

Also audit while implementing: `Lua.API.install/3` callback path,
`require` re-entry (`reset_instructions: false` — a suspend inside a
required module crosses the same native boundary as a re-entrant
`deflua` → boundary error per #1), and `Lua.VM.Stdlib` comparator/gsub
callbacks (they call back via `Executor.call_function/3`; a suspend
there surfaces as a bare `Suspend` at the enclosing native-call catch
→ boundary error per #1 — correct for v1).

### deflua wrapper changes (`lib/lua.ex`)

- `execute_function/4` (`lua.ex:1231-1279`) and `wrap_callback/3`
  (`lua.ex:1301-1330`): recognize `{:suspend, results}` and
  `{:suspend, results, %Lua{}}` alongside the existing return shapes;
  validate `results` with `Util.list_encoded?/1` (same error message as
  normal returns); then `raise Lua.VM.Suspend, values: results, state: <state>`.
- The `catch thrown_value` in `execute_function` (`lua.ex:1276-1278`)
  only catches `throw`, not raises — no change needed.

### Resume flow

`Lua.resume(%Lua{continuation: %Continuation{layers: layers}}, values)`:

1. `layers == nil` → raise `ArgumentError` ("no suspended continuation").
2. Set `continuation: nil` on the returned `%Lua{}` in every outcome.
3. Run the innermost layer with `values` as the pending call's results:
   - `:executor` layer → `Executor.resume_layer/3`: seed
     `state.open_upvalues` from the layer (do **not** reset to `%{}` the
     way `execute/5` does at `executor.ex:97-98` — the suspended machine
     owns live cells), seed `instruction_count` from the layer, then
     `continue_after_call(values, regs, rest, upvalues, proto, state,
     cont, frames, line, instruction_count, base, result_count)`
     (`executor.ex:3091`) — resume values land in registers with correct
     `-1`/`-2`/`0`/`1`/`n` result-count semantics, then the loop
     continues. Wrap with the same position save/restore hygiene as
     `execute/5` (`executor.ex:86-110`).
   - `:dispatcher` layer → `Dispatcher.resume_layer/3`: place `values`
     into `regs` at `base` exactly as the bridge's post-call code does,
     then `dispatch(code, pc + 1, …)`.
   - `:pending_call` layer → `{:ok, values, state}` directly.
4. Layer outcomes: `{:ok, results, state}` → pop the layer; if layers
   remain, inject `results` into the next layer's pending call (step 3
   again, same engine-specific placement); if none remain, that's the
   final result. `{:suspended, values, new_layers}` → return
   `{:suspended, values, lua_with_new_continuation}` (a layer stack may
   grow: a resumed run can suspend again, possibly in the other engine).
   VM error → unwind per the existing `recover_state/2` discipline.
5. `Lua.resume/2` wraps results as `{:ok, results, lua}`; `resume!/2`
   raises on error and returns `{results, lua} |
   {:suspended, values, lua}`.

Resume bypasses `Lua.VM.execute/3`'s `reset_instructions` (resume is
not a top-level eval); the layer carries the tally so `:max_instructions`
spans the whole suspend/resume cycle.

### Files

- `lib/lua/vm/suspend.ex` — new, `Lua.VM.Suspend` exception.
- `lib/lua/vm/continuation.ex` — new, `Lua.VM.Continuation` struct.
- `lib/lua/vm/executor.ex` — catch clauses (#1, #2), pass-throughs (#6),
  new `resume_layer/3`.
- `lib/lua/vm/dispatcher.ex` — catch clauses (#3, #4), pass-through (#6),
  new `resume_layer/3`.
- `lib/lua/vm/stdlib.ex` — `pcall`/`xpcall` clause (#5).
- `lib/lua/vm.ex` — boundary conversion (#7).
- `lib/lua.ex` — `%Lua{}` field, `eval!`, `call_function`,
  `call_function!`, `do_call_function`/`finish_call`, new `resume/2` +
  `resume!/2`, wrapper changes in `execute_function`/`wrap_callback`.
- `lib/lua/api.ex` — `deflua` `@doc` for the `{:suspend, ...}` contract.
- `test/lua/suspend_resume_test.exs` — new, the test matrix below.
- `CHANGELOG.md` — one entry under a new `Unreleased` section (additive
  feature; per ROADMAP sequencing this is 1.1.0-bound additive API, not
  part of the 1.0.0 freeze).

### Test matrix (`test/lua/suspend_resume_test.exs`)

1. Basic suspend: `eval!` returns `{:suspended, [42], lua}`; code after
   the call has not run (side-effect flag via another `deflua`).
2. Resume values become the call result (`x = yield(42); return x + 1`
   → resume `[10]` → `[11]`).
3. Multi-return placements: single, `local a, b =`, `return yield()`,
   `f(yield())` vararg expansion, tail position (`return yield()`).
4. Repeated suspension: a script that suspends three times resumes
   three times, accumulating locals across suspends.
5. Suspend deep in a Lua call stack (f → g → yield): frames, locals,
   and upvalues resume correctly.
6. Heap effects before suspend are kept: global/table writes visible in
   the suspended `%Lua{}` (via `Lua.get!`) and after resume.
7. Error after resume surfaces as `{:error, exception, lua}` /
   `resume!` raises with the rich render.
8. Suspend inside a loop (`while`/`for`) — CPS continuation stack
   (`cont`) resumes at the right back-edge.
9. `pcall(function() yield() end)` and `pcall(yield, 42)` →
   `{false, "attempt to suspend across a native call boundary"}`;
   state usable afterwards.
10. Re-entrant `deflua` (calls `Lua.call_function!` on a Lua function
    that suspends) → `{:error, exception, lua}` with the boundary
    message; catchable by in-Lua `pcall`.
11. Dispatcher path: a bytecode-compiled closure calling `yield`
    suspends and resumes (mirror the setup in
    `test/lua/vm/dispatcher_test.exs`).
12. Engine-boundary crossing: interpreted code calls a compiled closure
    that suspends; resume unwinds both layers and returns the final
    results (covers catch sites #2/#4).
13. `Lua.call_function(lua, [:scheduler, :yield], [42])` →
    `{:suspended, [42], lua}`; `Lua.resume(lua, [10])` →
    `{:ok, [10], lua}` (degenerate `:pending_call` layer).
14. `Lua.resume(Lua.new(), [])` raises `ArgumentError`.
15. `deflua` returning `{:suspend, [unencoded_map]}` → the existing
    "deflua functions must return encoded data" error.
16. `:max_instructions` spans suspend/resume: a budget that would be
    exceeded only after resume still raises "instruction budget
    exceeded" from `resume/2`.
17. `decode: false` → `{:suspended, raw_values, lua}` with display
    wrapping matching normal results.
18. Doctests on `Lua.resume/2` (run via `doctest Lua` in
    `test/lua_test.exs`).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua53_suite_test.exs --only lua53
```

Expected: `mix test` count goes up by the new file's tests (roughly
20-30), 0 failures. Suite count unchanged at 20/29 — `coroutine.lua`
remains a documented whole-file skip (capability non-goal until the
coroutine phase builds on this).

## Risks

- **Layer-stack resume across engine boundaries** is the delicate part.
  The dispatcher layer's result placement must match the bridge's
  post-call semantics exactly (multi-result calls, `pc + 1` advance).
  Test #12 is the guard; do not merge without it.
- **A missed rescue site silently swallows `Suspend`** as a generic
  error (the `pcall` catch-all would have done exactly that). The audit
  table above is the checklist; test #9/#10 guard the two most likely
  holes.
- **Hot path**: all catch clauses live in `rescue` blocks that already
  exist at the native-call sites — rescue clauses are zero-cost until
  raised, so the happy path is untouched. Verify with
  `mix test test/lua/vm/dispatcher_test.exs` and the existing
  `max_instructions_test.exs`/`limits_test.exs` (no behaviour change).
- **`open_upvalues` discipline**: `execute/5` resets
  `state.open_upvalues` to `%{}` on entry and restores on exit
  (`executor.ex:97-109`). The suspend snapshot must capture the live
  cells and `resume_layer` must seed them back, not reset — otherwise
  closures over suspended locals alias wrong cells (the exact bug class
  `A15` fixed at the `require` boundary).
- **API freeze**: this is additive public API (`%Lua{}` field,
  `eval!` union, `resume/2`). Per ROADMAP release sequencing it targets
  1.1.0, not the 1.0.0 freeze. The `eval!` spec change is an additive
  union; existing `{results, lua} = Lua.eval!(...)` matches keep working
  unless a suspend actually fires (then they `MatchError` loudly —
  acceptable and documented).
- **Snapshot purity**: layers hold only VM data (tuples/maps/lists and
  VM value tags). A native fun captured in a register keeps the snapshot
  in-memory-only (fine between processes on one node; not persistable).
  Document this on `Lua.VM.Continuation`.

## Implementation notes

Refinements made while building this (the design above held; these are
the deltas):

- **Layer stack is innermost-first, built by appending.** Catch sites
  fire innermost-first as the `Suspend` exception propagates outward, so
  each site *appends* its layer (`layers ++ [layer]`), keeping the head
  the machine to run first. The initial draft prepended, which left the
  stack outermost-first and resumed the wrong machine — caught by the
  VM-level smoke test before any public API existed.
- **The heap flows through the states, not the layers.**
  `Continuation.run/3` seeds the innermost layer from the host's
  `%Lua{}` state (`seed_first/2`: `instruction_count`, plus
  `open_upvalues` for executor layers); each layer's completion state
  feeds the next-outer layer, with `transition/2` popping
  `call_stack`/`call_depth` only for executor layers parked at the
  compiled-closure bridge (`pop_call_frame: true`). Dispatcher layers
  need no transition — their bridges continue with loop-carried
  `cs`/`cd`/`ou`.
- **`seed_first/2` has a catch-all** for the degenerate
  `%{engine: :pending_call}` layer (a native suspended when called
  directly via `Lua.call_function/3`): resume values are the results,
  nothing to seed.
- **A `deflua`/callback returning `{:suspended, values, lua}` is a
  boundary error.** That tuple means a *re-entrant* call suspended (the
  deflua called `Lua.call_function/3` on a Lua closure that parked);
  returning it cannot compose the inner continuation with the outer
  machine (resume would drop the inner machine's captured state), so
  `execute_function/4` and `wrap_callback/3` convert it to the boundary
  `Lua.VM.RuntimeError` instead of the generic "must return encoded
  data" validation error.
- **`run_xpcall_handler` converts a suspending handler** into the
  boundary `RuntimeError` (its catch-all would otherwise swallow the
  suspend as a handler failure).
- **`parse_and_execute_module` gained an `else` clause** mapping
  `Lua.VM.execute/3`'s new `{:suspended, _, _, state}` return to the
  boundary `RuntimeError` (a suspend inside a `require`d module crosses
  the `require` native boundary).
- **Suspend values are validated exactly like normal returns**
  (`Util.list_encoded?/1`, same "deflua functions must return encoded
  data" message) in `execute_function/4` and both `wrap_callback/3`
  arities; `{:suspend, data}` (no state) raises with the call-entry
  state, `{:suspend, data, %Lua{}}` with the threaded state.
- **`eval!` suspend values get the full result treatment**: decoded
  (`Value.decode_list/2`) and display-wrapped (`Display.wrap_results/3`)
  under the `:decode` option, in both the string and chunk clauses.
- **Audit sweep beyond the plan table**: `Lua.VM.Stdlib` re-entrant
  call sites are guarded with `Suspend.guard/1` — `load` reader
  (`collect_reader_chunks`), `require` preload loader
  (`load_from_preload`), `__tostring` (`value_to_string_with_mt`),
  `table.sort` comparator (`invoke_compare`), `string.gsub` replacement
  fn. Executor guards: `call_value` (covers generic-for iterators,
  `__call`, `dispatcher_call_value`), `invoke_metamethod`, and the
  `__index`/`__newindex`/`__call` sites (`call_mm` ×3, index/newindex
  wrappers).
- **Verification**: `mix test` 2917 passed (baseline 2870 + 44 new
  tests + 3 new doctests), 0 failures; lua53 suite unchanged at
  20/29 (`coroutine.lua` still a documented whole-file skip);
  `mix compile --warnings-as-errors` clean; `mix format` clean.
- **Pre-existing quirk (not a regression)**: a generic-for whose
  iterator expression is a bare function literal (`for i in function()
  ... end`) fails with "attempt to call a number value" on `main` too;
  suspend tests use the standard call form (`for i in iter()`).
