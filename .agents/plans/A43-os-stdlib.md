---
id: A43
title: "Add Lua.VM.Stdlib.Os with time / date / clock / difftime / getenv"
issue: 280
pr: null
branch: feat/os-stdlib
base: main
status: ready
direction: A
unlocks:
  - constructs.lua (lines 237, 248)
---

## Goal

Install the side-effect-free portion of the Lua 5.3 `os` library so
that `os.time()`, `os.date()`, `os.clock()`, `os.difftime()`, and
`os.getenv()` are callable. The side-effectful entries (`execute`,
`exit`, `remove`, `rename`, `tmpname`) keep their existing
default-sandbox stubs in `lib/lua.ex:45-50`.

This unblocks `constructs.lua:237` (`_ENV.GLOB1 = math.floor(os.time()) % 2`)
and any other suite line that uses `os.time` for seeding. It is the
fix-now half of the A42 triage follow-up (parent: #280).

## Out of scope

- `os.execute`, `os.exit`, `os.remove`, `os.rename`, `os.tmpname` —
  these stay sandboxed; embedding them is a separate decision.
- Locale-aware `os.date` format strings beyond what
  `Calendar.strftime/2` supports out of the box (POSIX `%`-codes only).
- `os.setlocale` — not in the immediate Lua 5.3 surface we need.

## Success criteria

- [ ] New module `lib/lua/vm/stdlib/os.ex` implements the five
      functions listed above, installed via
      `Lua.VM.Stdlib.install/1` (`lib/lua/vm/stdlib.ex:52`,
      between `Debug` and `preload_stdlib_modules`).
- [ ] New unit-test file `test/lua/vm/stdlib/os_test.exs` covers each
      function: `time/0,1`, `date/0,1,2` (the `*t` and `!*t` table
      forms plus a `%`-format string), `clock/0` (returns a
      non-negative float), `difftime/2` (`difftime(t2, t1) == t2 - t1`),
      and `getenv/1` (returns `nil` for the unset-by-default case).
- [ ] `test/lua53_skips.exs` `constructs.lua` entries drop the
      `lines: 237..237` and `lines: 248..248` ranges (issue #280).
      The remaining three ranges (debug.getinfo, level=4 short-circuit
      harness, checkload) stay.
- [ ] `mix test` and `mix test --only lua53` pass with no
      regressions.

## Implementation notes

Files to touch:

- `lib/lua/vm/stdlib/os.ex` — new. Mirror the structure of
  `lib/lua/vm/stdlib/math.ex`: `@behaviour Lua.VM.Stdlib.Library`,
  `lib_name` returns `"os"`, `install/1` builds a table of
  `{:native_func, &os_*/2}` entries and registers it as the global
  `os`.

- `lib/lua/vm/stdlib.ex:52` — add `|> install_library(Lua.VM.Stdlib.Os)`
  between `Debug` and `preload_stdlib_modules/1`. Because
  `install_library/2` writes to globals first, the side-effectful
  stub installation in `lib/lua.ex` (which runs in `Lua.new/1`
  *after* `Lua.VM.Stdlib.install/1`) will continue to overlay
  raise-on-call stubs onto the same `os` table — no ordering change
  needed.

- `test/lua/vm/stdlib/os_test.exs` — new. Use `Lua.eval!/2` against
  a `Lua.new(sandboxed: [])` VM (the safe entries should not be
  sandboxed in tests).

- `test/lua53_skips.exs:86-115` — drop the two `os.time`-related
  entries.

Function shapes:

```elixir
defp os_time([], state) do
  {[:os.system_time(:second)], state}
end

defp os_time([{:tref, _} = tref | _], state) do
  # Lua 5.3 §6.9: os.time(table) builds time from {year, month, day, hour, min, sec, ...}.
  table = State.get_table(state, tref)
  # Read fields, build a NaiveDateTime, convert to system seconds.
  ...
end

defp os_clock(_args, state) do
  {runtime_ms, _since_last} = :erlang.statistics(:runtime)
  {[runtime_ms / 1000.0], state}
end

defp os_difftime([t2, t1 | _], state), do: {[t2 - t1], state}

defp os_date([], state), do: os_date(["%c"], state)
defp os_date([format | rest], state) do
  # If format starts with "!", use UTC; else local.
  # If format is "*t" or "!*t", return a table; else a string.
  ...
end

defp os_getenv(_args, state), do: {[nil], state}
```

For `os.date("*t")`, build a table with the standard Lua fields:
`year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, `isdst`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

After this lands, `constructs.lua` reports either 15-line
skipped (three remaining ranges) or, if the harness/checkload
gaps get cleaned up in their own plans, fewer.

## Risks

- `Calendar.strftime/2` does not implement every `strftime(3)`
  code. Stick to `%Y`, `%m`, `%d`, `%H`, `%M`, `%S`, `%c`, `%x`,
  `%X`, `%j`, `%w` — document the gap if any suite test uses an
  uncovered code.

- `:os.system_time(:second)` is monotonic-ish but not wall-clock
  on systems where `:os.set_time/1` was called. For Lua's
  `os.time()` semantics this is fine; Lua only promises "a number
  representing the current time".

- `os.clock` returning runtime (`:erlang.statistics(:runtime)`)
  measures BEAM scheduler time, which is the closest analogue to
  CPU time available in pure Erlang. Document the choice in
  `@moduledoc`.

## Discoveries

(filled in during implementation)

## What changed

(filled in by `/open-pr`)
