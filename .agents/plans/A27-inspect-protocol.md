---
id: A27
title: Inspect protocol for VM values
issue: null
pr: null
branch: dx/inspect-protocol
base: main
status: in-progress
direction: A
unlocks:
  - readable iex output for Lua values
  - cleaner docs
  - debuggable userdata
---

## Goal

Implement `Inspect` for the four opaque VM value tags so `iex` shows
something useful instead of a tuple soup. Today, a `{:tref, 7}` in
the iex output tells the user nothing about what's in the table; a
`{:lua_closure, _, _}` tells them nothing about the function.

Targets:

- `{:tref, integer()}` — table reference. Should render contents (or
  a short summary if large) and the table id.
- `{:lua_closure, _proto, _upvalues}` — Lua function. Should render
  source location and arity.
- `{:native_func, fun}` — Elixir-defined Lua callable. Should render
  module/function/arity.
- `{:udref, integer()}` — userdata reference. Should render the
  underlying Elixir term and the udref id.

## Out of scope

- Changing the internal tuple representation.
- Pretty-printing for very large tables (over 50 keys: just show
  count + first few).
- Protocol consolidation — keep the impls inside `Lua.VM.*` modules.
- A new `Lua.dbg/2` helper — that's A28.

## Success criteria

- [ ] In `iex`, `Lua.eval!(Lua.new(), "return {1, 2, 3}")` shows the
      table contents (e.g. `#Lua.Table<id: 1, [1, 2, 3]>` or similar)
      instead of `{:tref, 1}`.
- [ ] Calling `inspect/1` on a `{:lua_closure, ...}` shows
      `#Lua.Closure<source: "demo.lua", line: 5, arity: 2>` (or
      similar shape).
- [ ] Calling `inspect/1` on a `{:native_func, &Mod.fun/2}` shows
      `#Lua.NativeFunc<&Mod.fun/2>`.
- [ ] Calling `inspect/1` on a `{:udref, 3}` shows the wrapped term
      (e.g. `#Lua.Userdata<id: 3, term: %MyStruct{...}>`).
- [ ] Inspect output respects the `Inspect.Opts` (limit, pretty,
      width).
- [ ] No regression: existing pattern matches on `{:tref, _}` etc.
      still work — we add `Inspect` impls, not new structs.
- [ ] `mix test` passes; new tests cover each impl in
      `test/lua/inspect_test.exs`.

## Implementation notes

The Inspect protocol can be implemented for tagged tuples by
defining `Inspect` for the *first* element if it's an atom, but the
more idiomatic approach is `Inspect.Algebra`-based renderers wrapped
in dedicated structs.

Two options:

### Option A — protocol on the tagged tuple

```elixir
defimpl Inspect, for: Tuple do
  def inspect({:tref, id}, opts) when is_integer(id) do
    state = Process.get(:__lua_state__)  # set by Lua.eval/2 entry
    contents = if state, do: peek_table(state, id), else: "<no state>"
    concat(["#Lua.Table<id: ", to_string(id), ", ", contents, ">"])
  end
  ...
end
```

Problem: this clobbers `Inspect` for *all* tuples globally. Bad.

### Option B — wrap on the boundary (recommended)

When a Lua value crosses out to Elixir (`Lua.eval!` return value),
wrap each VM tag in a thin struct: `%Lua.Table{id: id, peek: ...}`,
`%Lua.Closure{...}`, etc. The struct exists *only* for outbound
display; internally we still use the tuple.

This is cleaner because:
- Inspect impls live on the structs, not on `Tuple`.
- The struct can carry a snapshot of the table contents (peek) so
  the inspect doesn't need access to live VM state.
- Internal pattern matches don't change.

The wrap happens in `Lua.eval/2` and `Lua.eval!/2` return paths
(`encode/decode`-ish). It does *not* happen for values stored in
state or for native-function arguments.

### Files

- `lib/lua/table.ex` (new) — `defstruct [:id, :peek]` + `Inspect`.
- `lib/lua/closure.ex` (new) — `defstruct [:source, :line, :arity]`.
- `lib/lua/native_func.ex` (new) — `defstruct [:fun]`.
- `lib/lua/userdata.ex` (new) — `defstruct [:id, :term]`.
- `lib/lua.ex` — wrap on `eval/2`/`eval!/2` return.
- `test/lua/inspect_test.exs` (new) — covers each impl.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
```

Manual:

```elixir
iex> {[t], _} = Lua.eval(Lua.new(), "return {a = 1, b = 2}")
iex> t
#Lua.Table<id: 1, %{"a" => 1, "b" => 2}>
```

## Risks

- Wrapping return values is a small but observable API change. Code
  that pattern-matched on `{:tref, _}` from `Lua.eval/2` results
  would break. Mitigation: this is `1.0.0-rc.1`, this is the time to
  make this change. Document in CHANGELOG and consider a public
  helper `Lua.unwrap/1` if anyone needs the raw tuple.
- Table peek can be expensive for large tables. Limit to `Inspect.Opts.limit`
  entries.

## Discoveries

(populated during implementation)
