---
id: A19
title: Stdlib bad-argument raises read source position from process dict
issue: null
pr: 215
branch: fix/error-line-info-stdlib
base: main
status: review
direction: A
unlocks:
  - line numbers on `string.upper(nil)`, `table.insert(t, nil, 5)`, etc.
  - consistent line info across all stdlib raise sites
---

## Goal

A18 wired `assert` and `error` (the most common stdlib raise paths) to
the executor's process-dict-backed source position. This plan extends
that pattern to every other raise site in `lib/lua/vm/stdlib*.ex` —
mostly bad-argument type checks in `table.*`, `string.*`, `math.*`,
and `coroutine.*`.

## Out of scope

- Changing the public Elixir callback signature (`fn args, state -> ... end`).
- Anything A18 covered (opcode-level raises, `assert`, `error`).
- New behavior — only the structured fields on existing exceptions.

## Success criteria

- [x] `mix test` still passes (1577 → 1585, +8 new tests).
- [x] `mix test --only lua53` passes 5/29 (no regression).
- [x] New tests: representative bad-arg raises from each stdlib file
      have `:line` and `:source` populated.
      - [x] `string.upper(nil)` → TypeError with line/source.
      - [x] `table.insert(t, nil)` (bad pos) → has line/source.
      - [x] `math.floor("x")` → has line/source.
- [x] No measurable perf regression on the benchee harness vs A18.
      fib(28) and a 1000-iteration string-ops workload measured on
      both `main` and this branch with fresh builds: medians within
      ~1% (within noise floor). Exception modules are off the hot
      path; `Process.get` only fires when an exception is actually
      being constructed.

## Implementation notes

Pattern: every `raise TypeError`/`RuntimeError` in `lib/lua/vm/stdlib*.ex`
(except for `lua_assert` and `lua_error` which A18 already updated)
should read source position from `Lua.VM.Executor.current_position/0`
and pass it as `line:`/`source:` opts.

A small helper in stdlib (or each stdlib module) to avoid repetition:

```elixir
defp bad_arg!(msg, kind \\ nil) do
  {line, source} = Executor.current_position()
  raise TypeError, value: msg, line: line, source: source, error_kind: kind
end
```

### Files

- `lib/lua/vm/stdlib.ex` — top-level stdlib raises beyond `assert`/`error`.
- `lib/lua/vm/stdlib/string.ex` — `string.*` bad-arg raises.
- `lib/lua/vm/stdlib/table.ex` — `table.*` bad-arg raises.
- `lib/lua/vm/stdlib/math.ex` — `math.*` bad-arg raises.
- `lib/lua/vm/stdlib/library.ex` — library helpers.
- (others as discovered)

The mechanism (process dict written at `:native_func` call boundary,
restored after) is already in place from A18 — this plan just propagates
the read pattern through the remaining stdlib raise sites.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- Sprawling change touching ~50 stdlib raise sites. Mostly mechanical
  but easy to miss one.
- If a stdlib raise happens outside a Lua execution (e.g. someone calls
  `Lua.VM.Stdlib.some_helper/2` directly from Elixir), `current_position/0`
  returns `{nil, nil}` and the message just omits the location. That's
  the correct behavior — better than crashing.

## Discoveries

The plan anticipated touching ~50 stdlib raise sites individually with
a `bad_arg!` helper. During implementation, a much cleaner approach
emerged: have the **exception modules themselves** auto-populate
`:line`/`:source` from `Executor.current_position/0` inside
`exception/1` when not given.

This means **zero callsite changes** for the ~80 `ArgumentError`
raises across `math`, `string`, `table`, etc. — they all picked up
line/source for free. Same for the bare `raise RuntimeError, value:
"..."` sites.

Explicit opts still win: every executor raise that already passes
`:line`/`:source` (e.g. divide-by-zero at executor.ex:1864) is
unaffected because of `Keyword.get(opts, :line) || auto_line`.

Two pre-existing oddities surfaced during smoke testing, neither
introduced by this change:

- `table.insert(t, nil, 5)` reports the wrong arg number in its "bad
  argument" message (says `#1`, should be `#2` — the `nil` is at
  position 2). Logged as a candidate for an A24 sub-plan.
- `setmetatable(5, {})` on line 1 of a script reports `line 0`. Same
  `source_line` off-by-one A18 already flagged in its Discoveries.

## What changed

PR: [#215](https://github.com/tv-labs/lua/pull/215)

Files touched:

- `lib/lua/vm/argument_error.ex` — added `:line` / `:source` /
  `:call_stack` fields, auto-populate from `Executor.current_position/0`,
  render through `Lua.VM.ErrorFormatter` for consistency with the
  other exception types.
- `lib/lua/vm/runtime_error.ex` — auto-populate when `:line`/`:source`
  not given.
- `lib/lua/vm/type_error.ex` — auto-populate.
- `lib/lua/vm/assertion_error.ex` — auto-populate.
- `test/lua/error_messages_test.exs` — 8 new tests under
  "stdlib bad-argument raises carry line and source", covering
  `string.upper(nil)`, `math.floor("x")`, `table.insert` bad pos,
  `select` non-numeric index, `setmetatable` non-table, the defensive
  outside-Lua case, the explicit-override case, and a stdlib
  `RuntimeError` (`select(0, ...)`).

Test count: 1577 → 1585 (+8). 0 failures.
Suite count: 5/29, unchanged.
Bench: no measurable regression vs main.
