---
id: A18
title: Threaded line/source info reaches every runtime error message
issue: null
pr: null
branch: fix/error-line-source-info
base: main
status: in-progress
direction: A
unlocks:
  - faster suite triage (failures point at a specific line)
  - meets the "great error messages" promise of the library
---

## Goal

Every Lua runtime error a user sees should include the source file and
line number where the offending operation lives. Today the executor
threads `line` through every CPS dispatch, the compiler emits
`{:source_line, _, _}` markers, and the exception structs carry
`:line` / `:source` / `:call_stack` fields — but most `raise` sites in
the VM omit those fields, and the public `Lua.RuntimeException` wrapper
re-raises with only the formatted message string, dropping the
structured fields entirely.

This plan closes the gap for every `raise` site in the executor where
`line` is in scope, fixes the wrapper to preserve structured fields,
and threads `source:` through `Lua.eval!`. Native-function raise sites
(`assert`, `error`, stdlib type checks) are deferred to A19 — they need
a separate mechanism since native callees don't currently receive
line.

## Out of scope

- `assert()`, `error()`, and other stdlib raises that have no `line` in
  scope. These need an architectural change (push the calling line into
  `state` before invoking native funcs, or thread it as an argument).
  That goes in a follow-up plan A19.
- Improving `call_stack` content (we just propagate what's already
  there).
- Changing the formatted error layout. We only ensure the data is
  populated; the formatter already renders `at <source>:<line>:` when
  given non-nil values.
- Source-mapping past macro expansion or `load()` chunks. We use the
  source name the compiler was given and the line the executor is
  currently at; nothing fancier.

## Success criteria

- [ ] `mix test` passes (≥ 1670, currently 1670 + 51 prop + 52 doctest).
- [ ] `mix test test/lua/error_messages_test.exs` passes (it already does;
      this guards against regression).
- [ ] New test: every arithmetic/concat/index/compare TypeError raised
      during execution has non-nil `:line` and matching `:source`.
- [ ] New test: `Lua.eval!(Lua.new(), src)` where `src` triggers a
      type error produces an exception whose `:line` and `:source`
      fields are populated (i.e. the wrapper doesn't strip them).
- [ ] New test: `Lua.eval!` with a `source:` opt threads that name to
      `proto.source` so errors say `at script.lua:N:` instead of
      `at -no-source-:N:`.
- [ ] `mix test --only lua53` still passes 5/29 (we don't regress; some
      previously-mute assertion failures may now print line info but
      the file-level pass/fail count won't change for this plan).
- [ ] Manual smoke (in `iex -S mix`):
      ```
      Lua.eval!(Lua.new(), "local z = nil\nz()", source: "demo.lua")
      ```
      Error message contains `at demo.lua:2:`.

## Implementation notes

### Phase 1 — wrapper preserves structured fields

`lib/lua.ex:447-487` (and the `eval!/3` variant at L489+) re-raise
`TypeError` / `RuntimeError` / `AssertionError` as `Lua.RuntimeException`
using only `Exception.message(e)`. Change the wrapper to:

1. Extend `Lua.RuntimeException` to carry `:line`, `:source`,
   `:call_stack` fields (mirror `Lua.VM.TypeError`).
2. In the rescue clauses, copy those fields from the original exception
   so consumers can pattern-match on them.
3. Keep the existing `:message` string for backward compat — the formatter
   already includes `at <src>:<line>:` when present.

### Phase 2 — `eval!` passes a source name

`lib/lua.ex:452` calls `Lua.Compiler.compile(ast)` with no opts, so
`proto.source` is nil and the formatter prints `-no-source-`. Add an
optional `source:` opt to `Lua.eval!/2,3` and forward it to
`Lua.Compiler.compile/2`. Default to something reasonable like
`"<eval>"` when not given.

### Phase 3 — populate line/source on every executor raise

The audit (see Discoveries below) found ~30 raise sites in
`lib/lua/vm/executor.ex` that omit `line:` / `source:` / `call_stack:`
even though `line` is bound in the calling clause. Pattern:

```elixir
defp do_execute([{:add, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
  ...
  {result, new_state} =
    try_binary_metamethod("__add", val_a, val_b, state, fn -> safe_add(val_a, val_b) end)
  ...
end

defp safe_add(a, b) do
  ...
  raise TypeError,
    value: "...",
    error_kind: :arithmetic_on_non_number,
    value_type: value_type(val)
end
```

Two strategies, pick whichever is cleaner per site:

**(a) Pass error context into helpers.** Change `safe_add/2` etc. to
take a `ctx` keyword (line, source, call_stack) and include it in the
raise. Slightly noisier signatures.

**(b) Wrap the helper invocation in `try`/`rescue` that re-raises with
the missing fields.** Less invasive, but the rescue boilerplate stacks
up. Probably best as a private helper in the executor:

```elixir
defp with_error_context(line, proto, state, fun) do
  fun.()
rescue
  e in [TypeError, RuntimeError, AssertionError] ->
    reraise add_context(e, line, proto.source, state.call_stack), __STACKTRACE__
end
```

Recommend (b) — single helper, every opcode that calls
`safe_*`/`concat_coerce`/etc. wraps its body once. That also catches
the case where a metamethod invocation deep inside `try_binary_metamethod`
raises — the helper picks up the current opcode's line.

### Phase 4 — sites where `line` isn't in scope yet

A handful of `raise` sites are in functions that genuinely don't
receive line (`call_function/3` at the top of executor.ex, the
`__index`/`__newindex` chain-too-long checks). For those, keep them
as best-effort but do not block this plan on them; fold them into A19.

### Files touched (estimate)

- `lib/lua.ex` — wrapper rescue clauses + `eval!` source option (~40 lines).
- `lib/lua/runtime_exception.ex` — add `line`, `source`, `call_stack`
  fields and propagate in `exception/1` (~15 lines).
- `lib/lua/vm/executor.ex` — add `with_error_context/4`, wrap each
  arithmetic/concat/index/compare opcode body (~50 lines added,
  ~25 raise sites updated).
- `test/lua/error_messages_test.exs` — extend with end-to-end coverage
  for wrapper and source threading (~80 lines added, ~5 new tests).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/error_messages_test.exs
mix test --only lua53
```

Manual:

```elixir
iex> Lua.eval!(Lua.new(), "local z = nil\nz()", source: "demo.lua")
** (Lua.RuntimeException) ... at demo.lua:2: attempt to call a nil value ...
```

Expected on the rescued exception struct: `e.line == 2`,
`e.source == "demo.lua"`.

## Risks

- **API change** to `Lua.RuntimeException` (added fields). Adding
  optional fields is non-breaking; pattern-matching on the struct's
  shape with `%Lua.RuntimeException{}` still works. Pattern-matching on
  exact field set would break, but no one should do that.
- **Performance.** `try`/`rescue` in the hot arithmetic path on the
  BEAM is cheap when no exception is raised, but it's not free. Measure
  with the benchee harness in `benchmarks/` after Phase 3 — if
  arithmetic regresses noticeably, fall back to strategy (a) for the
  hottest opcodes.
- **`source:` default.** Picking `"<eval>"` vs `"chunk"` vs nil-and-let-
  formatter-pick is bikeshed-territory. Match what the Lua reference
  interpreter does (it uses `[string "..."]` for inline chunks).
- **Wrapper field copy regressions.** If `Exception.message/1` was the
  only contract anyone relied on, fine. If anyone destructured
  `%Lua.RuntimeException{message: m}` they keep working.

## Discoveries

(populated during implementation)

Initial audit (before implementation):

- ~6 of ~40 raise sites in `lib/lua/vm/{executor,stdlib}.ex` and
  `lib/lua.ex` include `line:`/`source:`/`call_stack:`. The rest don't.
- The infrastructure (exception structs, `ErrorFormatter`,
  `:source_line` opcode, threaded `line` param) is fully in place — this
  is a wiring problem, not a design problem.
- `Lua.eval!` calls `Lua.Compiler.compile(ast)` with no opts, so all
  `eval!` errors say `at -no-source-:N:` even when line is correct.
- The existing test `test "tracks line numbers"` in
  `error_messages_test.exs` calls `VM.execute` directly (not via
  `Lua.eval!`), so it tests the unwrapped exception and didn't catch
  that the public path drops line/source.
