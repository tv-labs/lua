# Mix tasks

Three Mix tasks ship with this library for working with Lua from the
command line and from CI. None of them require code; they are thin
wrappers over the public API and the test suite.

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

## `mix lua.suite` — run the Lua 5.3 official suite

Runs every `.lua` file in `test/lua53_tests/` against this VM and
prints a pass / fail / timeout summary. Use it to spot newly-passing
suite files (candidates to promote into `@ready_tests`) or to
sanity-check the suite set during development.

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
```

Sample output:

```
passing: 6
failing: 21
timeout: 2

passing files: api, bitwise, code, simple_test, tpack, vararg

failing files (top reason):
  attrib.lua      Lua runtime error: 'require' is sandboxed
  big.lua         Lua runtime error: attempt to compare a string with a number
  ...

timed out:
  big.lua      > 30000ms
  closure.lua  > 30000ms
```

Each file is run in its own monitored task so an infinite loop in
one file can't hang the run.

Unlike `mix test --only lua53`, this task does **not** consult the
hand-curated `@ready_tests` / `@deferred_permanent` lists in
`test/lua53_suite_test.exs`. It just runs everything. Use
`mix test --only lua53` for the canonical green-bar set, and use
`mix lua.suite` for exploration and triage.

Exit status:

- `0` — at least one file passed.
- `1` — directory missing, filter matched nothing, or no files
  passed.

## `mix lua.bench` — run benchmark workloads

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
