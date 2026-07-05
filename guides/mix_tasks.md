# Mix tasks

One Mix task ships with this library — `mix lua.eval` — for running
Lua source from the command line.

## `mix lua.eval` — run a Lua file

Evaluates a Lua source file (or stdin) in a fresh `Lua.new()` VM and
prints any returned values.

```bash
# Run a file
mix lua.eval test/fixtures/returns_value.lua
# => [5]

# Pipe source from stdin
echo "return 1 + 2" | mix lua.eval -
# => [3]
```

Lua's built-in `print()` writes to stdout as usual; the task's
printed return value appears after that:

```bash
echo 'print("hello"); return "world"' | mix lua.eval -
# => hello
# => ["world"]
```

Runtime and compile errors are written to stderr and the task exits
with status `1`. The error source defaults to the basename of the
file (or `<stdin>` for `-`); pass `--source NAME` to override.

```
$ echo "return notdefined()" | mix lua.eval -
Lua runtime error: ...
  at <stdin>:1:
  attempt to call a nil value
$ echo $?
1
```

The task runs in your default Mix environment. Calls to `require`,
`io.*`, `file.*`, most of `os.*`, and a few others are sandboxed by
default — see `Lua.new/1`'s `:sandboxed` option.

## Contributor-only tasks

The following tasks are only available when working inside a checkout
of this repository. They are not shipped to Hex and won't be visible
to projects that depend on `:lua`.

### `mix lua.suite` — run the Lua 5.3 official suite

Runs every `.lua` file in `test/lua53_tests/` **unmodified** against this
VM and prints a pass / fail / timeout summary. Because it applies no skip
ranges, its pass count is lower than the canonical suite count — it is a
triage and exploration tool for spotting files whose skip ranges in
`test/lua53_skips.exs` could be narrowed or removed.

```bash
# Run all files
mix lua.suite

# Run a subset
mix lua.suite --filter math

# Run from a different directory
mix lua.suite --dir test/lua53_tests

# Show full error messages, not just the first line
mix lua.suite --verbose

# Adjust per-file timeout (default 30s; long-running files like
# `big.lua` and `closure.lua` need more, while CI may want less)
mix lua.suite --timeout 60000

# Per-file conformance summary read from the skips file (no tests run)
mix lua.suite --status

# Re-run each skip entry with it removed, flagging stale/promotable ranges
mix lua.suite --audit
```

Sample output (raw run — no skip ranges applied):

```
passing: 9
failing: 17
timeout: 3

passing files: api, bitwise, code, locals, nextvar, simple_test, tpack, utf8, vararg

failing files (top reason):
  all.lua        Lua runtime error: loadfile(_) is sandboxed
  math.lua       Lua runtime error: bad argument in arithmetic expression
  ...

timed out:
  big.lua         > 30000ms
  closure.lua     > 30000ms
  constructs.lua  > 30000ms
```

Each file is run in its own monitored task so an infinite loop in
one file can't hang the run.

Unlike `mix test --only lua53`, this task does **not** apply the per-file
skip ranges in `test/lua53_skips.exs` or the `@deferred_permanent` list in
`test/lua53_suite_test.exs` — it just runs everything raw. Use
`mix test --only lua53` for the canonical green-bar set (**20/29** files
passing, with the 9 documented exclusions), and use `mix lua.suite` (and
its `--status` / `--audit` modes) for exploration and triage.

Exit status:

- `0` — at least one file passed.
- `1` — directory missing, filter matched nothing, or no files
  passed.

### `mix lua.bench` — run benchmark workloads

Wraps the Benchee scripts under `benchmarks/`. Each script compares
this VM against [Luerl](https://github.com/rvirding/luerl), and
against C Lua via [`:luaport`](https://hex.pm/packages/luaport) when
available.

```bash
# Run every workload
mix lua.bench

# Run one
mix lua.bench --workload fibonacci

# Run several
mix lua.bench --workload fibonacci --workload closures

# List available workloads
mix lua.bench --list
```

The task re-runs each script under `MIX_ENV=benchmark` because the
Benchee, Luerl, and luaport deps are gated to that environment in
`mix.exs`. Make sure deps are installed there once:

```bash
MIX_ENV=benchmark mix deps.get
```

If `:luaport` fails to start (e.g. on a system without C Lua
installed), the workload prints a warning and skips that target; the
Elixir-vs-Luerl comparison still runs.
