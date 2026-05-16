---
id: A29
title: Mix tasks — lua.eval, lua.bench, lua.suite
issue: null
pr: null
branch: dx/mix-tasks
base: main
status: in-progress
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

## Discoveries

(populated during implementation)
