---
id: A27a
title: Cycle-safe peek for Lua.VM.Display.Table
issue: null
pr: null
branch: fix/display-cycle-guard
base: main
status: ready
direction: A
unlocks:
  - inspect _G and other self-referential tables without hanging
  - safer Display.Table for unknown user data
---

## Goal

`Lua.VM.Display.peek_table/3` (added in A27) recursively walks a
table's contents to build the `:peek` field on `%Lua.VM.Display.Table{}`.
Self-referential tables — `_G` is the canonical example, since
`_G._G == _G` — cause infinite recursion and a hung process.

Discovered while drafting iex recipes for A28: the obvious "what's
in the global env?" recipe (`Lua.eval!(lua, "return _G", decode: false)`)
hangs the BEAM. A28 worked around this by recommending `pairs(_G)`
in Lua instead, but the underlying bug remains.

## Out of scope

- Changing the data shape of `:peek`. Continue returning a list (for
  sequence-like tables) or a map (for keyed tables). Cycles render
  as a special placeholder, not a partial result.
- Tuning the recursion depth limit beyond a sensible default. A
  follow-up plan can tune if needed.
- Tracking cycles in the inspect output for `Lua.VM.Display.Userdata`.
  That struct stores the term verbatim, and the term's own `Inspect`
  impl (or the user's) is responsible for cycle handling.

## Success criteria

- [ ] `Lua.eval!(Lua.new(), "return _G", decode: false)` returns in
      under a second and produces a `%Lua.VM.Display.Table{}` whose
      peek shows top-level keys but renders nested self-references
      as a placeholder (e.g. `#Lua.Table<cycle>` or `:cycle`).
- [ ] Manually-constructed cycles (`local t = {}; t.self = t; return t`)
      render without hanging.
- [ ] No regression for non-cyclic tables: existing
      `test/lua/vm/display_test.exs` still passes.
- [ ] Add tests for cycle handling in `test/lua/vm/display_test.exs`.
- [ ] `mix test` passes.

## Implementation notes

The simplest correct approach is to track the set of `tref` ids
currently being peeked, and short-circuit when we hit one we've
already entered. Sketch:

```elixir
defp peek_table(state, id, decode?, seen \\ MapSet.new()) do
  if MapSet.member?(seen, id) do
    :cycle  # or a small struct, e.g. %Display.Cycle{id: id}
  else
    seen = MapSet.put(seen, id)

    case Map.fetch(state.tables, id) do
      {:ok, table} ->
        data = table.data

        if sequence_like?(data) do
          1..map_size(data)
          |> Enum.map(&wrap_value(Map.fetch!(data, &1), state, decode?, seen))
        else
          Map.new(data, fn {k, v} -> {k, wrap_value(v, state, decode?, seen)} end)
        end

      :error ->
        []
    end
  end
end
```

`wrap_value/3` in `Lua.VM.Display` becomes `wrap_value/4` with a
`seen` accumulator threaded through. The boundary entry (`wrap_results/3`,
`wrap_value/3` at the eval call site) starts with `MapSet.new()`.

A depth limit (e.g. 8 levels) is a reasonable second guard for
deeply nested non-cyclic tables; tunable via an option later.

## Files

- `lib/lua/vm/display.ex` — thread `seen` through `wrap_value` and
  `peek_table`; render cycles as a placeholder.
- `test/lua/vm/display_test.exs` — add a `describe "cycles"` block
  with `_G` and a hand-built cycle test.
- (Optional) `lib/lua/vm/display/cycle.ex` — if we want a real
  struct rather than the bare `:cycle` atom for the placeholder.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
```

Manual:

```elixir
iex> {[g], _} = Lua.eval!(Lua.new(), "return _G", decode: false)
iex> g                       # should not hang, should render in O(top-level keys)
iex> {[t], _} = Lua.eval!(Lua.new(), "local t = {}; t.self = t; return t", decode: false)
iex> t.peek["self"]
:cycle  # or %Display.Cycle{...}, depending on representation
```

## Risks

- Picking a placeholder representation that future plans regret.
  Recommendation: bare atom `:cycle` for now, escalate to a struct
  if a downstream consumer needs more metadata.
- Threading `seen` widens the function arity. Acceptable: it's
  internal to `Lua.VM.Display`.

## Discoveries

(populated during implementation)
