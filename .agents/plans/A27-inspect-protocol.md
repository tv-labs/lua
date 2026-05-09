---
id: A27
title: Inspect protocol for VM values
issue: null
pr: 218
branch: dx/inspect-protocol
base: main
status: review
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

- [ ] In `iex`, `Lua.eval!(Lua.new(), "return {1, 2, 3}", decode: false)`
      shows table contents (e.g. `#Lua.Table<id: 1, [1, 2, 3]>` or
      similar) instead of `{:tref, 1}`.
- [ ] In `iex`, the return value of
      `Lua.eval!(Lua.new(), "return function() end")` (default
      `decode: true`) shows `#Lua.Closure<...>` instead of
      `{:lua_closure, _, _}`. Same for native funcs:
      `#Lua.NativeFunc<...>` instead of `{:native_func, _}`.
- [ ] In `iex`, `Lua.eval!(Lua.new(), "return userdata", decode: false)`
      shows `#Lua.Userdata<id: 3, term: %MyStruct{...}>` instead of
      `{:udref, 3}`. (Default decode currently returns
      `{:userdata, term}` and continues to do so — out of scope.)
- [ ] Inspect output respects the `Inspect.Opts` (limit, pretty,
      width).
- [ ] No regression in default-decode (`decode: true`) shape: tables
      still come back as a list of `{key, value}` tuples; `userdata`
      still comes back as `{:userdata, term}`. The wrap layer only
      changes `decode: false` shape (for tref/udref) and the
      always-leaked `lua_closure`/`native_func` tags.
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
wrap each VM tag in a thin struct: `%Lua.VM.Display.Table{id: id, peek: ...}`,
`%Lua.VM.Display.Closure{...}`, etc. The struct exists *only* for outbound
display; internally we still use the tuple.

This is cleaner because:
- Inspect impls live on the structs, not on `Tuple`.
- The struct can carry a snapshot of the table contents (peek) so
  the inspect doesn't need access to live VM state.
- Internal pattern matches don't change.

The wrap happens in `Lua.eval/2` and `Lua.eval!/2` return paths
(`encode/decode`-ish). It does *not* happen for values stored in
state or for native-function arguments.

### Decode behaviour

The wrap layer in `eval/eval!` is conditional on which value tag is
crossing the boundary AND on `decode:`:

| Tag                  | `decode: true` (default)                          | `decode: false`                          |
|----------------------|---------------------------------------------------|------------------------------------------|
| `{:tref, _}`         | list of `{k, v}` tuples (UNCHANGED — preserves API) | `%Lua.VM.Display.Table{}` (NEW)         |
| `{:udref, _}`        | `{:userdata, term}` (UNCHANGED — preserves API)   | `%Lua.VM.Display.Userdata{}` (NEW)      |
| `{:lua_closure, _, _}` | `%Lua.VM.Display.Closure{}` (NEW)               | `%Lua.VM.Display.Closure{}` (NEW)       |
| `{:native_func, _}`  | `%Lua.VM.Display.NativeFunc{}` (NEW)             | `%Lua.VM.Display.NativeFunc{}` (NEW)    |

This minimises the API break: tables/userdata in default decode mode
keep their list-of-tuples / `{:userdata, term}` shape, so existing
tests and downstream `deflua` consumers don't change. Only `decode: false`
callers see new shapes for tables/userdata, and closures/native_funcs
become friendlier in every mode (because they're *already* leaking raw
tuples in default decode mode today).

### Naming

`Lua.Table` is already taken (it's a public utility module for
treating decoded tables as lists/maps). Display structs live under
`Lua.VM.Display.*` to make the namespace clear and avoid collisions:

- `Lua.VM.Display.Table` — `[:id, :peek]`
- `Lua.VM.Display.Closure` — `[:source, :line, :arity, :ref]`
- `Lua.VM.Display.NativeFunc` — `[:fun]`
- `Lua.VM.Display.Userdata` — `[:id, :term]`

Inspect output uses the short forms (`#Lua.Table<...>`,
`#Lua.Closure<...>`, etc.) regardless of full module path.

### Files

- `lib/lua/vm/display.ex` (new) — boundary wrap helpers
  (`wrap_for_eval/3`).
- `lib/lua/vm/display/table.ex` (new) — `defstruct [:id, :peek]` + `Inspect`.
- `lib/lua/vm/display/closure.ex` (new) — `defstruct [:source, :line, :arity, :ref]`.
- `lib/lua/vm/display/native_func.ex` (new) — `defstruct [:fun]`.
- `lib/lua/vm/display/userdata.ex` (new) — `defstruct [:id, :term]`.
- `lib/lua.ex` — call `Display.wrap_for_eval/3` on `eval/2`/`eval!/2` return.
- `test/lua/vm/display_test.exs` (new) — covers each impl + boundary wrap.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
```

Manual:

```elixir
# Default decode: tables stay as decoded list-of-tuples
iex> {[t], _} = Lua.eval!(Lua.new(), "return {a = 1, b = 2}")
iex> t
[{"a", 1}, {"b", 2}]

# decode: false: tables wrap as display struct
iex> {[t], _} = Lua.eval!(Lua.new(), "return {a = 1, b = 2}", decode: false)
iex> t
#Lua.Table<id: 1, %{"a" => 1, "b" => 2}>

# Closures wrap in either mode
iex> {[c], _} = Lua.eval!(Lua.new(), "return function(x) return x * 2 end")
iex> c
#Lua.Closure<source: "<eval>", line: 1, arity: 1>

# Native funcs wrap in either mode
iex> {[f], _} = Lua.eval!(Lua.new(), "return string.lower")
iex> f
#Lua.NativeFunc<...>
```

## Risks

- API surface change: `decode: false` callers that pattern-match on
  `{:tref, _}` or `{:udref, _}` from `eval` results will break.
  `decode: true` callers (the vast majority — including all
  `deflua` flows and the existing doctests) are unaffected. This is
  `1.0.0-rc.1`, the right window for this change.
- Closure / native_func shape changes in BOTH decode modes (because
  default decode passed them through as raw tuples already). Code
  that pattern-matches on `{:lua_closure, _, _}` or `{:native_func, _}`
  in eval results will break. Internal pattern matches inside the VM
  are unaffected because the wrap is at the eval boundary, not in
  state.
- Table peek can be expensive for very large tables. Cap the peek at
  `Inspect.Opts.limit` entries and show `…` if truncated.
- Closure refs need stable display for the success criterion that
  shows `source: "demo.lua", line: 5, arity: 2`. The Lua proto
  carries this info; the wrap layer reads from `proto.source`,
  `proto.line` (or first instruction's line), and `proto.param_count`.

## Discoveries

- `Lua.Table` already exists as a public utility module (for casting
  decoded tables to lists/maps). Display structs live under
  `Lua.VM.Display.*` to avoid the collision; the inspect output still
  uses the short forms (`#Lua.Table<...>`, etc.).
- Closures need source/line/arity at display time. The existing
  `Lua.Compiler.Prototype` struct carries `:source`, `:lines`,
  `:param_count`, and `:is_vararg` — no proto changes needed.
- Round-trip support (`Lua.set!/3`, `Lua.encode!/2`, `Lua.decode!/2`,
  `Lua.call_function/3`) had to be added to keep the wrap transparent
  for existing flows. Each entry point calls `Display.unwrap/1`. A
  public `Lua.unwrap/1` is also exposed for callers that need the raw
  VM tag directly.
- `Lua.encode!/2` got an opportunistic `Util.encoded?/1` shortcut so
  unwrapping a table struct (whose `:ref` is `{:tref, _}`, already
  encoded) does not try to re-encode through `Value.encode/2`.
- Two pre-existing tests pattern-matched on `{:tref, _}` from
  `decode: false` (`test/lua/util_test.exs` and `test/lua_test.exs`).
  Both updated to match the new `%Lua.VM.Display.Table{}` shape and
  exercise `Lua.unwrap/1`. No other downstream pattern matches in
  the suite.

## What changed

PR: [#218](https://github.com/tv-labs/lua/pull/218)

Files touched:

- `lib/lua/vm/display.ex` (new)
- `lib/lua/vm/display/table.ex` (new)
- `lib/lua/vm/display/closure.ex` (new)
- `lib/lua/vm/display/native_func.ex` (new)
- `lib/lua/vm/display/userdata.ex` (new)
- `lib/lua.ex` — wraps results on `eval/eval!` return; unwraps on
  `set!`, `encode!`, `decode!`, `call_function`; adds public
  `Lua.unwrap/1`.
- `test/lua/vm/display_test.exs` (new) — 28 tests covering each
  Inspect impl, the boundary wrap, round-tripping, and decode-mode
  invariants.
- `test/lua/util_test.exs`, `test/lua_test.exs` — updated to match
  the new `decode: false` wrap shape.

Suite delta: 1626 → 1654 tests, 0 failures (no Lua 5.3 suite
regressions).
