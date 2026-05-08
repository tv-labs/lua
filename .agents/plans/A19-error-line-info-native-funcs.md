---
id: A19
title: Stdlib bad-argument raises read source position from process dict
issue: null
pr: null
branch: fix/error-line-info-stdlib
base: main
status: ready
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

- [ ] `mix test` still passes.
- [ ] `mix test --only lua53` passes 5/29 (no regression).
- [ ] New tests: representative bad-arg raises from each stdlib file
      have `:line` and `:source` populated.
      - [ ] `string.upper(nil)` → TypeError with line/source.
      - [ ] `table.insert(t, nil)` (bad pos) → has line/source.
      - [ ] `math.floor("x")` → has line/source.
- [ ] No measurable perf regression on the benchee harness vs A18.

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
