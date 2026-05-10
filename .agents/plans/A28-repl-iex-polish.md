---
id: A28
title: REPL/iex polish — Lua.dbg, doctest support, debugging recipes
issue: null
pr: null
branch: dx/iex-polish
base: main
status: in-progress
direction: A
unlocks:
  - cleaner debugging from iex
  - doctest coverage for Lua.eval examples
---

## Goal

Make iex a first-class debugging surface for embedded Lua. Three
deliverables:

1. **`Lua.dbg/2`** — a debug helper that runs Lua with stdout/stderr
   captured and prints a structured summary (return values, state
   diff, time elapsed, captured prints).
2. **Doctest support** — `Lua.eval/2` examples in module docs run as
   doctests with deterministic output. The output formatting must be
   stable enough to commit.
3. **Recipes** — a short guide showing how to poke at a `Lua` state
   from iex (read globals, call functions, list tables).

## Out of scope

- A separate `:lua` command-line REPL. (Could be a follow-up.)
- IO interception in production code paths. `Lua.dbg/2` is for
  debugging, not the public API.
- Replacing `IEx.Helpers`.

## Success criteria

- [ ] `Lua.dbg(state, source)` returns the same as `Lua.eval/2` but
      also prints a summary to stdout including:
      - source preview (first 2 lines of input).
      - return values.
      - any captured `print()` output.
      - elapsed time.
- [ ] At least 5 module doctests under `lib/lua.ex` and `lib/lua/vm.ex`
      that pass `mix test --include-docs` (or whatever the project's
      doctest runner is).
- [ ] A `guides/iex_recipes.md` file (or section in README) covering:
      reading a Lua global, calling a Lua function from Elixir,
      inspecting a table, modifying state and re-running.
- [ ] `mix test` passes.

## Implementation notes

### Lua.dbg/2

```elixir
def dbg(state \\ Lua.new(), source) when is_binary(source) do
  start = System.monotonic_time()

  # Capture stdout from print() calls.
  {output, {result, new_state}} =
    ExUnit.CaptureIO.with_io(fn -> Lua.eval(state, source) end)

  elapsed_ms = System.convert_time_unit(
    System.monotonic_time() - start, :native, :millisecond
  )

  IO.puts("""
  --- Lua.dbg ---
  source:  #{preview(source)}
  return:  #{inspect(result, pretty: true, limit: 10)}
  elapsed: #{elapsed_ms} ms
  prints:  #{output |> String.trim() |> indent(2)}
  ---------------
  """)

  {result, new_state}
end
```

`ExUnit.CaptureIO` is a runtime dep (`:ex_unit` is always loaded);
keep this fine for now. If we want a non-ExUnit version, defer.

### Doctest examples

```elixir
@doc """
Evaluates a Lua source string.

## Examples

    iex> {result, _state} = Lua.eval(Lua.new(), "return 1 + 2")
    iex> result
    [3]

    iex> {[table], _} = Lua.eval(Lua.new(), "return {a = 1, b = 2}")
    iex> Lua.unwrap(table)
    %{"a" => 1, "b" => 2}
"""
```

A27's `Inspect` polish makes some of these renderable. Where a value
needs to be unwrapped for display, use `Lua.unwrap/1` (add this
helper if not present).

### Files

- `lib/lua.ex` — add `dbg/1,2` + at least 3 doctests on public funcs.
- `lib/lua/vm.ex` — at least 2 doctests on public funcs.
- `guides/iex_recipes.md` (new) — recipes.
- `test/lua/dbg_test.exs` (new) — covers `Lua.dbg/2` output shape.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix docs
```

Manual:

```elixir
iex> Lua.dbg(Lua.new(), ~S{print("hi"); return 1, 2})
--- Lua.dbg ---
source:  print("hi"); return 1, 2
return:  [1, 2]
elapsed: 1 ms
prints:  hi
---------------
{[1, 2], #Lua.State<...>}
```

## Risks

- `Lua.dbg/2` printing to stdout in test environments could make
  test output noisy. Mitigation: it's `dbg`, users will only call it
  from iex.
- Doctests with non-deterministic output (`elapsed`, table order) are
  flaky. Stick to determinism: only test return values, never the
  formatted summary.

## Discoveries

(populated during implementation)
