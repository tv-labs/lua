---
id: A29
title: Mix tasks — lua.eval, lua.bench, lua.suite
issue: null
pr: 220
branch: dx/mix-tasks
base: main
status: review
direction: A
unlocks:
  - one-line invocations from a Mix project
  - CI integration for suite & bench
---

## Goal

Three Mix tasks, each a thin wrapper over functionality that already
exists:

- `mix lua.eval <file-or-stdin>` — evaluate a Lua source file (or
  stdin) against a fresh `Lua.new()` and print return values + any
  captured `print()` output. Useful for "run this Lua file under our
  VM."
- `mix lua.bench [--workload NAME] [--vs luerl|puc-lua|both]` — wrap
  the existing benchee harness in `benchmarks/`. Without args, runs
  the full suite against all reference VMs.
- `mix lua.suite [--include-skipped] [--filter PATTERN]` — run the
  Lua 5.3 official suite and print a pass/skip/fail summary.
  `--filter` runs a subset.

## Out of scope

- A separate REPL (`mix lua` with an interactive prompt). Possible
  follow-up.
- New benchmarks; we wrap whatever's already in `benchmarks/`.
- Replacing `mix test --only lua53`. The new task complements it.

## Success criteria

- [ ] `mix help lua.eval`, `mix help lua.bench`, `mix help lua.suite`
      each produce a useful description.
- [ ] `echo "return 1 + 2" | mix lua.eval -` prints `[3]` (or
      similar) and exits 0.
- [ ] `mix lua.eval test/fixtures/returns_value.lua` works.
- [ ] `mix lua.bench` runs the existing benchee harness and produces
      its standard output.
- [ ] `mix lua.suite` produces a summary like:
      ```
      passing: 5
      failing: 24
      skipped: 0

      passing files: simple_test, api, bitwise, code, vararg
      failing files (top reason):
        main.lua          os.execute() is sandboxed
        files.lua         os.getenv(_) is sandboxed
        ...
      ```
- [ ] `mix lua.suite --filter math` runs only files matching `math`.
- [ ] `mix test` passes.
- [ ] All three tasks are documented in `guides/mix_tasks.md` (or
      README).

## Implementation notes

### `Mix.Tasks.Lua.Eval`

```elixir
defmodule Mix.Tasks.Lua.Eval do
  @moduledoc """
  Evaluates a Lua source file or stdin.

      mix lua.eval path/to/script.lua
      echo "return 1+2" | mix lua.eval -
  """
  use Mix.Task

  @shortdoc "Evaluates a Lua source file"

  def run(args) do
    Mix.Task.run("app.start")

    source =
      case args do
        ["-"] -> IO.read(:stdio, :eof) |> to_string()
        [path] -> File.read!(path)
        _ -> Mix.raise("usage: mix lua.eval <path|->")
      end

    case Lua.eval(Lua.new(), source) do
      {result, _state} ->
        IO.inspect(result, label: "return", pretty: true)

      {:error, reason} ->
        Mix.raise("Lua error: #{inspect(reason)}")
    end
  end
end
```

### `Mix.Tasks.Lua.Bench`

Wrap whatever benchee invocation `benchmarks/` exposes. If there's a
`benchmarks/run.exs`, this task mostly just calls
`Code.eval_file/1`. Add `--workload` and `--vs` options as
`OptionParser.parse!/2`.

### `Mix.Tasks.Lua.Suite`

Programmatically iterate `test/lua53_tests/*.lua`, evaluate each in a
fresh `Lua.new()` matching `LuaTestCase`'s sandbox config, capture
pass/fail/skip with reason. This is similar to what
`test/lua53_suite_test.exs` does, but as a one-shot runner with a
prettier summary.

### Files

- `lib/mix/tasks/lua/eval.ex` (new)
- `lib/mix/tasks/lua/bench.ex` (new)
- `lib/mix/tasks/lua/suite.ex` (new)
- `test/mix/tasks/*_test.exs` (new) — at least one test per task,
  using `Mix.Task.rerun/2` and IO capture.
- `guides/mix_tasks.md` (new) — how-to.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix help lua.eval
mix help lua.bench
mix help lua.suite
echo "return 42" | mix lua.eval -
mix lua.suite
```

## Risks

- `Mix.Task.run("app.start")` is the magic that loads compiled code;
  forgetting it makes the task crash with cryptic errors. Don't.
- `benchmarks/` might require deps that aren't in the default env.
  If so, the task should refuse with a clear message ("run `mix
  deps.get` in `:benchmark` env first") rather than crash.

## What changed

- New `lib/mix/tasks/lua.eval.ex` — the only task shipped to Hex.
- New `tasks/lua.suite.ex`, `tasks/lua.bench.ex`,
  `tasks/lua.get_tests.ex` — contributor-only Mix tasks. `tasks/` is
  already on the `:dev` (and therefore `:test`) compile path
  (`mix.exs:39`), but isn't in the `package.files` whitelist, so
  these tasks are available locally and excluded from the Hex
  release.
- New shared module `tasks/suite_runner.ex` (`Lua.SuiteRunner`)
  extracted from `test/support/lua_test_case.ex` so the Mix suite
  task and the ExUnit suite test share one sandbox implementation.
  Marked `@moduledoc false` because it's internal to this repo.
- `test/support/lua_test_case.ex` shrinks from ~127 to ~25 lines and
  delegates to `Lua.SuiteRunner`. Also marked `@moduledoc false`.
- New tests: 9 in `test/mix/tasks/lua.eval_test.exs`, 6 in
  `lua.suite_test.exs`, 2 in `lua.bench_test.exs`. Total mix test
  count: 1654 → 1671, 0 failures.
- New guide: `guides/mix_tasks.md`. Reworded to make the
  "ships to Hex" vs "contributor-only" split explicit.
- No regression in `mix test --only lua53` (6 passing, 23 skipped,
  same as before).

## Discoveries

- **No `Lua.eval/2`** — only `Lua.eval!/2,3` exists. The plan's sketch
  showed `case Lua.eval(...) do {result, _state} -> ...; {:error, _} -> ...`,
  but in reality `eval!` raises `Lua.CompilerException` or
  `Lua.RuntimeException`. `Mix.Tasks.Lua.Eval` uses `try/rescue` and
  exits `{:shutdown, 1}` on error, writing the message to stderr.
- **Default `inspect` treats `[42]` as a charlist** (`~c"*"` for the
  ASCII `*`). `Mix.Tasks.Lua.Eval` forces `charlists: :as_lists` so
  numeric return values render as actual lists.
- **Suite needs per-file timeouts.** The first full-suite smoke test
  hung indefinitely on `big.lua` / `closure.lua` (well-known
  long-runners on this VM). Added `--timeout MS` (default 30000) that
  wraps `Lua.SuiteRunner.run_file/1` in a `Task` and kills it on
  expiry, reporting `timeout:` in the summary.
- **Sandbox config was test-only.** The shared sandbox setup
  (unsandbox `package`/`require`, install `dostring`/`load`/`checkerr`
  helpers) lived in `test/support/lua_test_case.ex`, which isn't on
  the `:dev`/`:prod` compile path. Extracted into a new
  `Lua.SuiteRunner` module under `lib/lua/` so both `Lua.TestCase`
  and `Mix.Tasks.Lua.Suite` can share it without duplication.
- **Skipped the `--vs luerl|puc-lua|both` flag.** The plan suggested
  it, but every benchmark script in `benchmarks/` already runs all
  three targets unconditionally (with luaport gracefully skipping if
  C Lua isn't available). The flag would have no current effect.
  Added `--list` and `--workload NAME` (repeatable) instead.
- **Only `lua.eval` belongs in the Hex package.** Initial review
  shipped `lua.bench`, `lua.suite`, `lua.get_tests`, and
  `Lua.SuiteRunner` from `lib/`, which means they would have been
  published to Hex. All three are broken-by-design for downstream
  consumers:
    * `lua.bench` hardcodes `benchmarks/` (resolved against the
      consumer's CWD, not this repo) and shells out to
      `MIX_ENV=benchmark` for deps the consumer doesn't have.
    * `lua.suite` defaults to `test/lua53_tests/` and references
      `mix lua.get_tests` to populate it — both of which only make
      sense inside this repo.
    * `Lua.SuiteRunner` installs `dostring`/`load`/`checkerr` globals
      specific to the PUC-Lua 5.3 official test suite.
  Moved all four files under `tasks/`, which is on the `:dev`/`:test`
  compile path but not in `package.files`. Verified with
  `mix hex.build` that only `lib/mix/tasks/lua.eval.ex` ships.
