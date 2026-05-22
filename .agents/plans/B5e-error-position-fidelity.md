---
id: B5e
title: Error position fidelity for compiled prototypes
issue: null
pr: null
branch: perf/erlang-codegen-errors
base: main
status: ready
direction: B
unlocks:
  - parity with interpreter on every error message test
  - removes the only remaining semantic gap between compiled and
    interpreted execution
---

## Blocked on

- B5a (foundation), B5b (lifecycle), B5c (tables), B5d (closures).
  Error fidelity is the last piece — easier to do once every
  opcode has a compiled lowering.

## Goal

Make compiled prototypes raise exceptions with the same `line:`,
`source:`, and stack-trace information the interpreter raises with.
After this PR, no error-message test can distinguish a compiled
prototype from an interpreted one.

## Why now

Earlier B5 plans (B5a through B5d) ship a placeholder: compiled
prototypes raise errors carrying the line of the last `:source_line`
opcode they passed through. This is approximately right but misses
detail: a raise from inside a metamethod calls back through the
interpreter, which already threads the right position via the
process dictionary — but pure-compiled raises don't. Tests that
assert specific line numbers in raises may pin the compiled path to
a slightly different line than the interpreter.

This PR uses the parent plan's recommended try/catch approach (B5
plan line 191-198): pay nothing on the success path, restore line
info on the failure path from a pc-to-line table that lives on the
prototype.

## Out of scope

- Improving the interpreter's error positions. Already done in A18
  and A19.
- Adding error-context tracking that the interpreter doesn't have.
  This is fidelity, not enhancement.

## Success criteria

- [ ] `Lua.Compiler.Prototype` gains a `pc_to_line` field (or
      similar) mapping the compiled function's internal label
      structure back to source lines. Populated at codegen time.
- [ ] Every codegen lowering wraps potentially-raising operations
      (arithmetic on non-numeric, index into non-table, call of
      non-callable, etc.) with a try/catch that, on raise,
      re-throws with corrected `line:` / `source:` info from the
      pc_to_line table.
- [ ] Every error-message test in
      `test/lua/error_message_test.exs` and similar passes against
      a compiled prototype with the same line numbers as the
      interpreter produces.
- [ ] No measurable performance regression — the try/catch costs
      nothing on the success path.
- [ ] `mix test` passes; no regression.
- [ ] `mix test --only lua53` does not regress (suite has many
      error-position tests).

## Implementation notes

### Strategy

For each potentially-raising opcode, wrap the call site:

```erlang
try
    %% opcode lowering as usual
catch
    error:Reason:Stack ->
        Line = maps:get(PcOrLabel, PcToLine),
        Source = proto:source(),
        erlang:raise(error, augment_reason(Reason, Line, Source), Stack)
end
```

`augment_reason/3` updates the exception struct's `line:` and
`source:` fields. For raises that already include line info
(e.g. those that came from `Lua.VM.Executor.index_value/6`), this
is a no-op. For raises from purely-compiled code (e.g. an `:add`
on two non-numeric registers), this is where the position is
attached.

The try/catch lives **per loop body**, not per opcode. Erlang's
JIT optimises try/catch well at function-scope granularity but
penalises tight per-statement nesting. One try around each
recursive helper body, one try around the main function body.

### pc_to_line table

A map from "codegen-time label" to source line. Built during
codegen as it walks the instruction stream. Stored on
`%Prototype{}` as `pc_to_line :: %{atom() => non_neg_integer()}`.

Each `:source_line` opcode in the instruction stream becomes the
authoritative line for every subsequent opcode until the next
`:source_line`. The codegen tracks this.

### Stack trace shape

Compiled modules show up in stack traces as
`:lua_proto_<hash>.execute/3`. This is noise from a user's
perspective. `Lua.RuntimeException`'s stack pruning
(`lib/lua/runtime_exception.ex:prune_internal_frames/1` —
introduced in A20/A21) already trims known internal frames. Extend
the prune list to include any module starting with
`lua_proto_<build_hash>_`. Frames stay informative (the calling
`Lua.eval!/2` is still visible) without exposing compilation
internals.

### Files

- `lib/lua/compiler/prototype.ex` — add `pc_to_line` field.
- `lib/lua/compiler/erlang.ex` — emit try/catch wrappers around
  loop bodies; populate `pc_to_line` during codegen walk.
- `lib/lua/compiler/erlang/errors.ex` (new) — `augment_reason/3`
  and friends. Pure functions, no state.
- `lib/lua/runtime_exception.ex` — extend prune list.
- `test/lua/compiler/erlang_errors_test.exs` (new) — golden tests
  asserting that compiled raises produce identical line/source to
  interpreted raises.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/error_message_test.exs

# Confirm zero perf cost on success path.
LUA_BENCH_MODE=full mix run benchmarks/fibonacci.exs   # no regression
LUA_BENCH_MODE=full mix run benchmarks/table_ops.exs   # no regression
```

## Risks

- **try/catch granularity.** Per-statement try/catch tanks
  performance. Per-function is fine. There's a middle ground (per
  loop body) that may be necessary if function-scope try/catch
  proves too coarse for correct attribution. Profile during
  implementation; adjust.
- **Stack-trace pruning could hide useful info.** If the prune
  list accidentally trims user code, debugging gets harder. Test
  with a stack trace that contains user code + compiled code +
  stdlib; assert user code is preserved.
- **Hot-reload may produce stale stack-trace prune patterns.**
  Build-hash already in module names from B5b; this stays
  consistent across reloads as long as B5b's build-hash logic is
  correct.
- **Some Lua 5.3 suite tests assert specific error messages
  including line numbers.** These should all match the interpreter
  after this PR. If they don't, it means the codegen has a subtle
  line-tracking bug; fix the bug, don't change the test.

## Discoveries

(populated during implementation)
