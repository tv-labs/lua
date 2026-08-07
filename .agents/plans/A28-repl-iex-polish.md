---
id: A28
title: REPL/iex polish — Lua.dbg, doctest support, debugging recipes
issue: null
pr: 219
branch: dx/iex-polish
base: main
status: review
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
2. **Doctest support** — `Lua.eval!/2` examples in module docs run
   as doctests with deterministic output. The output formatting must
   be stable enough to commit.
3. **Recipes** — a short guide showing how to poke at a `Lua` state
   from iex (read globals, call functions, list tables).

## Out of scope

- A separate `:lua` command-line REPL. (Could be a follow-up.)
- IO interception in production code paths. `Lua.dbg/2` is for
  debugging, not the public API.
- Replacing `IEx.Helpers`.

## Success criteria

- [ ] `Lua.dbg(state, source)` returns the same as `Lua.eval!/2` but
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

  # Capture stdout from print() by temporarily swapping the calling
  # process's group leader to a StringIO process. Lua's `print`
  # writes through Erlang's normal IO protocol, which honours the
  # caller's group leader, so all output flows into our buffer.
  {:ok, capture} = StringIO.open("")
  original_gl = Process.group_leader()

  result =
    try do
      Process.group_leader(self(), capture)
      Lua.eval!(state, source)
    after
      Process.group_leader(self(), original_gl)
    end

  {output, _} = StringIO.contents(capture)
  StringIO.close(capture)

  {return, new_state} = result

  elapsed_ms =
    System.convert_time_unit(
      System.monotonic_time() - start,
      :native,
      :millisecond
    )

  IO.puts(format_summary(source, return, elapsed_ms, output))

  {return, new_state}
end
```

#### Why not `ExUnit.CaptureIO`

The original draft of this plan suggested wrapping eval in
`ExUnit.CaptureIO.with_io/1`. We rejected that: pulling
`:ex_unit` into a runtime/production code path is a non-starter
for an embedded library. Group-leader swap is plain OTP, no test
infra, and works because Lua's `print` is synchronous and runs in
the calling process — anything it emits goes through that
process's group leader.

#### Caveats of the group-leader approach

- It only captures output emitted from `self()`. If a future
  feature has `print` spawn a task and write from there, capture
  breaks. Currently `Lua.VM.Stdlib.lua_print/2` is synchronous
  in-process, so this is fine.
- The group leader is restored in an `after` block so a Lua error
  during eval still leaves the process's IO untouched on the way
  out.

### Doctest examples

The repo's public eval function is `Lua.eval!/2` (the bang variant).
There is no non-bang `Lua.eval/2`. Doctests use `eval!`:

```elixir
@doc """
Evaluates a Lua source string.

## Examples

    iex> {result, _state} = Lua.eval!(Lua.new(), "return 1 + 2")
    iex> result
    [3]

    iex> {[table], lua} = Lua.eval!(Lua.new(), "return {a = 1, b = 2}", decode: false)
    iex> Lua.decode!(lua, table) |> Enum.sort()
    [{"a", 1}, {"b", 2}]
"""
```

A27 shipped `Lua.unwrap/1` and the four `Lua.VM.Display.*` structs,
so closures, tables, native funcs, and userdata already render
legibly in `iex`. Doctests can rely on those impls without any
extra work. For values that are sensitive to map-iteration order
(stdlib globals, table contents), wrap the assertion in `Enum.sort/1`
or pin a specific key to keep doctests deterministic.

### Files

- `lib/lua.ex` — add `dbg/1,2` + at least 5 doctests across the
  public eval/encode/decode/get/set/call_function surface. The plan
  originally asked for ≥3 here and ≥2 on `lib/lua/vm.ex`, but
  `Lua.VM.execute/2` takes a compiled `Prototype` which is awkward
  to build in a 1–2 line doctest setup. Concentrating on `Lua.*`
  reads more naturally and keeps the doctest count at the same
  bar (5+).
- `guides/iex_recipes.md` (new) — recipes for reading globals,
  calling functions, inspecting tables, modifying state and
  re-running.
- `test/lua/dbg_test.exs` (new) — covers `Lua.dbg/2` output shape.
  Uses `ExUnit.CaptureIO` (test-only, fine) to assert on the dbg
  summary that `dbg` prints to stdout.

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
{[1, 2], #Lua<>}
```

## Risks

- `Lua.dbg/2` printing to stdout in test environments could make
  test output noisy. Mitigation: it's `dbg`, users only call it from
  iex; tests for `dbg` itself capture stdout to assert on the
  formatted summary.
- The group-leader swap relies on `print` running synchronously in
  the calling process. Documented as a known limitation — if a
  future feature makes `print` spawn a task and write from there,
  capture would silently miss those writes. Worth a comment in the
  `dbg` source pointing at this assumption.
- Doctests with non-deterministic output (`elapsed`, table iteration
  order, function references) flake. Stick to deterministic shape:
  pin specific keys, sort lists before comparing, never test the
  formatted dbg summary text.
- Capturing IO via group leader is per-process. If `Lua.dbg/2` is
  called concurrently from the same process (it cannot be, since
  Elixir is single-threaded per process, but worth noting), the
  second call's group-leader swap would clobber the first. The
  `try/after` ensures restoration but does not provide reentrancy.

## Discoveries

- `IO.puts/1` writes to `:stdio`, which IS the calling process's
  group leader — but `StringIO.contents/1` returns `{input, output}`,
  not `{output, input}`. The first draft of `dbg/2` reversed those
  and saw an empty capture. Fixed by destructuring `{_input, output}`.
- `Kernel.dbg/2` exists in Elixir 1.14+, so `defmodule Lua` had to
  `import Kernel, except: [dbg: 2]` to shadow it.
- `inspect/1` formats lists of small integers as charlists by
  default (`[7]` → `~c"\a"`). The dbg summary uses
  `inspect(x, charlists: :as_lists)` to keep return values
  unambiguous.
- A27's `Lua.VM.Display.peek_table/3` recurses into nested tables.
  This deadlocks when applied to self-referential tables like `_G`
  (where `_G._G == _G`). Discovered while drafting the `_G` recipe;
  worked around in the recipe by encouraging users to iterate with
  `pairs(library)` in Lua and only return the keys. The recursion
  bug itself is filed as a follow-up plan: `A27a-display-cycle-guard.md`.
- The `eval!/2` doctest pattern needed adjustment for tables: I
  added 3 new doctests covering multi-return, table decode, and the
  closure-display struct — all using `Enum.sort/1` on table results
  to keep iteration order out of the assertion.
- ExUnit.CaptureIO is fine in test files (it's exactly what it's for)
  but the dbg `iex>` doctest had to become a fenced non-iex example
  in the docstring, because doctest parsing recognises `iex>` lines
  inside fenced blocks too.

## What changed

PR: [#219](https://github.com/tv-labs/lua/pull/219)

Files touched:

- `lib/lua.ex` — `dbg/1,2` implementation (group-leader swap with
  StringIO capture, restored in an `after` block); imports
  `Kernel, except: [dbg: 2]` to shadow `Kernel.dbg/2`; three new
  doctests on `eval!/2` covering multi-return, table decode, and
  the closure display struct.
- `test/lua/dbg_test.exs` (new) — 14 tests covering output shape,
  capture, the error path, group-leader restoration on error, and
  the `dbg/1` default-state form.
- `guides/iex_recipes.md` (new) — self-contained recipes for
  reading globals, calling Lua functions, inspecting tables in
  both decode modes, modifying state, dbg debugging, skimming a
  library via `pairs()`, and exposing an Elixir tool function.
- `lib/lua/vm/display/{closure,native_func,table,userdata}.ex`,
  `lib/lua/vm/display.ex` — drop stale `Lua.eval/2` doc references
  (function is the bang variant; `mix docs` was warning).
- `.agents/plans/A27a-display-cycle-guard.md` (new) — follow-up
  plan for the cyclic-peek bug discovered while drafting the `_G`
  recipe.

Suite delta: 1626 → 1668 tests passing, 0 failures (no Lua 5.3
suite regressions; lua53 still 29 passing, 23 skipped).
