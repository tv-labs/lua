---
id: A30
title: examples/ directory — runnable, linked from README
issue: 264
pr: 300
branch: docs/examples
base: main
status: merged
direction: A
unlocks:
  - "embedding patterns are obvious" promise
  - A31 (README rewrite needs example links)
---

## Goal

Add a top-level `examples/` directory with 5-8 runnable, end-to-end
Elixir scripts demonstrating the core embedding patterns. Each
example is a single file that can be run with `mix run
examples/<name>.exs` and produces clear output.

The examples make the library's promises concrete. Right now a new
user reads docstrings and has to assemble the picture themselves.

## Out of scope

- Mix project-style examples (`mix new`-able). Single-file `.exs`
  scripts are enough.
- Long-form tutorials. Keep each file under 100 lines, with comments
  explaining intent.
- An `examples/` framework or test harness. They run via `mix run`.

## Success criteria

- [ ] `examples/` exists and contains at least 5 runnable scripts:
      - [ ] `01_quickstart.exs` — eval some Lua, get the result.
      - [ ] `02_userdata.exs` — pass an Elixir struct to Lua, call
            methods on it from Lua.
      - [ ] `03_custom_stdlib.exs` — add an Elixir-defined function
            to the Lua state, call it from Lua.
      - [ ] `04_sandboxing.exs` — show the default sandbox + how to
            allow specific os.* operations explicitly.
      - [ ] `05_chunks.exs` — compile once, eval many times against
            different states.
      - [ ] `06_error_handling.exs` — show pcall, the structured
            exception fields, source/line attribution.
- [ ] Optional bonus examples (any of these welcome):
      - [ ] `07_metatables.exs` — define __index/__newindex from
            Elixir, drive from Lua.
      - [ ] `08_repl.exs` — a tiny iex-based REPL with state
            persistence between inputs.
- [ ] Each file runs successfully with `mix run examples/<name>.exs`.
- [ ] Each file has a top-of-file comment explaining what it
      demonstrates and what to look at.
- [ ] A `examples/README.md` lists them with one-line summaries.
- [ ] `mix test` passes (no test changes — examples are not tested
      automatically beyond a smoke test).

## Implementation notes

### Smoke test

Add one test that runs each example via `Code.eval_file/1` and
asserts no exceptions. Sandbox `IO.puts` redirection to keep test
output clean.

```elixir
# test/examples_test.exs
defmodule ExamplesTest do
  use ExUnit.Case
  for path <- Path.wildcard("examples/*.exs") do
    @path path
    test "examples/#{Path.basename(@path)} runs without errors" do
      assert {_result, _bindings} = Code.eval_file(@path), Path.basename(@path)
    end
  end
end
```

### Example shapes

Keep them concrete. No "imagine you have a" — show the real code.

```elixir
# examples/02_userdata.exs
# Demonstrates passing an Elixir struct as userdata, calling
# Elixir-defined methods on it from Lua.

defmodule Counter do
  defstruct count: 0
end

state = Lua.new()
state = Lua.set!(state, [:counter], %Counter{})
state = Lua.set_function!(state, [:Counter, :inc], fn [%Counter{} = c], s ->
  {[%Counter{c | count: c.count + 1}], s}
end)
...

{[result], _} = Lua.eval!(state, ~S{
  counter = Counter.inc(counter)
  counter = Counter.inc(counter)
  return counter
})

IO.inspect(result, label: "counter after 2 incs")
# => counter after 2 incs: %Counter{count: 2}
```

### Files

- `examples/01_quickstart.exs` (new)
- `examples/02_userdata.exs` (new)
- `examples/03_custom_stdlib.exs` (new)
- `examples/04_sandboxing.exs` (new)
- `examples/05_chunks.exs` (new)
- `examples/06_error_handling.exs` (new)
- `examples/README.md` (new)
- `test/examples_test.exs` (new) — smoke test.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
for f in examples/*.exs; do mix run "$f" || echo "FAIL: $f"; done
```

## Risks

- Examples drift as the API evolves. Mitigation: the smoke test
  catches breakage; keep examples small enough that updating them is
  a 5-minute task per API change.
- Smoke tests that print output pollute test runs. Capture or
  redirect.

## Discoveries

- Userdata reaches a native function as an opaque reference
  (`{:udref, _}`), not the wrapped `{:userdata, struct}`. Native
  functions must use the 2-arity form and `Lua.decode!/2` the
  reference back into the struct (and `Lua.encode!/2` a new one to
  return). `02_userdata.exs` uses this pattern.
- A struct literal (`%Counter{}`) cannot appear in the same `.exs`
  file that defines the struct, because the file is compiled as a
  single unit. `02_userdata.exs` builds/updates the struct with
  `struct/2` and map-update syntax, and documents why.
- Lua source containing `{`/`}` clashes with `~S{...}`. Examples use
  heredoc strings (`"""..."""`) for multi-line Lua so braces pass
  through.
- README linking is left to A31 (README rewrite); this PR's scope is
  the `examples/` directory and its smoke test only.

## What changed

- Added six Livebook examples under `guides/examples/`
  (`quickstart`, `userdata`, `custom_stdlib`, `sandboxing`, `chunks`,
  `error_handling`) covering eval, userdata, custom Elixir functions,
  sandboxing, chunk reuse, and error handling. Each follows Livebook
  conventions (`Mix.install`, `##` section headers, persisted output
  blocks) so the examples render in the HexDocs sidebar and run in
  Livebook.
- Wired the notebooks into `mix.exs` `docs` via `extras` and a
  `groups_for_extras` "Examples" group alongside the existing
  `working-with-lua.livemd` guide.
- Review feedback (#300): the initial `examples/*.exs` scripts,
  `examples/README.md`, and `test/examples_test.exs` smoke test were
  replaced by the Livebook notebooks per reviewer request to
  integrate the examples directly into the documentation.
- PR: #300.
