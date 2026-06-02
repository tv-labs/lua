# Lua

[![Hex.pm](https://img.shields.io/hexpm/v/lua.svg)](https://hex.pm/packages/lua)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/lua)
[![CI](https://github.com/tv-labs/lua/actions/workflows/ci.yml/badge.svg)](https://github.com/tv-labs/lua/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/lua.svg)](https://github.com/tv-labs/lua/blob/main/LICENSE)

<!-- MDOC !-->

Embed a sandboxed Lua 5.3 scripting runtime in your Elixir application — no NIFs, no C, no Erlang runtime dependency.

`Lua` is a Lua 5.3 virtual machine implemented entirely in Elixir. The lexer,
parser, register-based VM, and standard library all run directly on the BEAM,
so there is nothing to compile and no foreign code in your release. It exists
to let you safely run untrusted scripts — AI-agent–authored code, game logic,
user-defined rules, configuration, plugins — with a small, idiomatic Elixir API
for passing data and functions across the boundary. Giving an AI agent a
sandboxed runtime where it can only call the Elixir functions you expose is a
primary use case. Scripts are sandboxed by default, errors carry source and
line information, and each `Lua` value is plain immutable Elixir state with no
shared mutable globals.

## Installation

Add `lua` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lua, "~> 1.0.0-rc"}
  ]
end
```

## Quickstart

Evaluate Lua with `Lua.eval!/2`. It returns `{results, lua}` where `results`
is the list of returned values and `lua` is the updated state:

    iex> {[4], _lua} = Lua.eval!("return 2 + 2")

You can thread state across multiple evaluations, set globals from Elixir, and
read them back:

    iex> lua = Lua.set!(Lua.new(), [:name], "world")
    iex> {[greeting], _lua} = Lua.eval!(lua, ~S[return "hello, " .. name])
    iex> greeting
    "hello, world"

## Tour

### Error messages with source and line

Runtime errors raise `Lua.RuntimeException`, which carries the failing
`:source` and `:line` so you can report exactly where a script broke:

```elixir
try do
  Lua.eval!(~LUA"""
  local x = 1
  error("something went wrong")
  """)
rescue
  e in Lua.RuntimeException ->
    e.line    # => 2
    e.source  # => "<eval>" (chunk name)

    # e.message is a formatted, colorized frame (ANSI codes elided here):
    #
    #   Lua runtime error: Runtime Error
    #
    #     at <eval>:2:
    #
    #     runtime error: something went wrong
    e.message
end
```

Lua-level error handling works too — `pcall` catches the error and returns it
as a value:

    iex> {[false, "nope"], _lua} = Lua.eval!(~S[return pcall(function() error("nope") end)])

### Calling Elixir functions from Lua

The quickest way to expose an Elixir function is `Lua.set!/3`:

    iex> lua = Lua.set!(Lua.new(), [:sum], fn args -> [Enum.sum(args)] end)
    iex> {[10], _lua} = Lua.eval!(lua, "return sum(1, 2, 3, 4)")

For richer APIs, define a module with `use Lua.API` and the `deflua` macro,
then load it with `Lua.load_api/2`:

```elixir
defmodule MyAPI do
  use Lua.API

  deflua double(v), do: 2 * v
end

lua = Lua.new() |> Lua.load_api(MyAPI)

{[10], _lua} = Lua.eval!(lua, "return double(5)")
```

### Userdata

Pass an arbitrary Elixir term across the boundary as a `{:userdata, term}`
tuple. It round-trips opaquely — Lua can hold the reference and hand it back,
but cannot inspect or dereference it:

    iex> lua = Lua.set!(Lua.new(), [:thing], {:userdata, %{secret: 42}})
    iex> {[{:userdata, %{secret: 42}}], _lua} = Lua.eval!(lua, "return thing")

### Sandboxing

`Lua.new/1` sandboxes dangerous stdlib paths by default, including
`os.execute`, `os.exit`, `os.getenv`, file I/O (`io.*`), `require`, `load`, and
`dofile`. Calling a sandboxed function raises rather than touching the host:

```elixir
Lua.eval!(~S[os.execute("rm -rf /")])
# ** (Lua.RuntimeException) Lua runtime error: os.execute(_) is sandboxed
```

To allow a specific operation, exclude it from the sandbox explicitly:

    iex> lua = Lua.new(exclude: [[:os, :getenv]])
    iex> {[value], _lua} = Lua.eval!(lua, ~S[return os.getenv("HOME")])
    iex> is_binary(value)
    true

### Resource limits

Sandboxing controls *which* functions a script may call, but it does not stop
a script from spinning forever or recursing without bound. Two options on
`Lua.new/1` give you deterministic limits without wrapping each evaluation in a
host `Task` plus a wall-clock timeout. Both default to `:infinity` (no limit)
and raise catchable runtime errors, so `pcall` recovers from them in-band:

- `:max_call_depth` caps nested function-call depth; exceeding it raises
  `"stack overflow"`.
- `:max_steps` caps the number of VM instructions a single evaluation may
  execute; exceeding it raises `"instruction budget exceeded"`.

    iex> lua = Lua.new(max_steps: 1000)
    iex> {[false, message], _lua} = Lua.eval!(lua, ~S[return pcall(function() while true do end end)])
    iex> message =~ "instruction budget exceeded"
    true

See the [Sandboxing guide](guides/examples/sandboxing.livemd) for details.

### Metatables and metamethods

Full metamethod dispatch is supported (`__index`, `__newindex`, `__call`,
arithmetic, comparison, length, concatenation, and `__tostring`), so idiomatic
Lua object patterns work as written:

    iex> {[result], _lua} = Lua.eval!(~LUA"""
    ...> local Vec = {}
    ...> Vec.__index = Vec
    ...> Vec.__add = function(a, b) return setmetatable({x = a.x + b.x}, Vec) end
    ...> local a = setmetatable({x = 1}, Vec)
    ...> local b = setmetatable({x = 2}, Vec)
    ...> return (a + b).x
    ...> """)
    iex> result
    3

## Coverage and status

`Lua` targets Lua 5.3. The lexer, parser, register-based VM, value
encoding/decoding, varargs, multiple returns, `_G`/`_ENV`, metatables, the
string-pattern engine (`find`/`match`/`gmatch`/`gsub`), and the `string`,
`table`, `math`, `os`, and `debug` standard libraries are implemented.

As a sandboxed *embedded* VM, some standalone-interpreter behavior is a
deliberate non-goal rather than a missing feature:

- **Standalone interpreter / `os.execute`** — there is no shell-out to the host.
- **Host filesystem access** — `Lua` does not read your host filesystem. The
  `io.*` library and `require`/`dofile` are sandboxed by default and raise
  rather than touching disk; there is no host-OS file or module resolution.
- **Coroutines**, **garbage collection / weak tables**, and the **full
  `debug` library**.

For the live Lua 5.3 official test-suite pass count and the rationale behind
each deferral, see the
[`ROADMAP.md`](https://github.com/tv-labs/lua/blob/main/ROADMAP.md). This
release is `1.0.0-rc.0`.

## Examples

Runnable, end-to-end scripts live in
[`examples/`](https://github.com/tv-labs/lua/blob/main/examples/README.md). Run
any of them with `mix run examples/<name>.exs`:

- [`examples/01_quickstart.exs`](https://github.com/tv-labs/lua/blob/main/examples/01_quickstart.exs) — eval some Lua and get the result.
- [`examples/02_userdata.exs`](https://github.com/tv-labs/lua/blob/main/examples/02_userdata.exs) — pass an Elixir struct as userdata and call methods on it from Lua.
- [`examples/03_custom_stdlib.exs`](https://github.com/tv-labs/lua/blob/main/examples/03_custom_stdlib.exs) — add an Elixir-defined function to the state and call it from Lua.
- [`examples/04_sandboxing.exs`](https://github.com/tv-labs/lua/blob/main/examples/04_sandboxing.exs) — the default sandbox plus allowing specific `os.*` ops explicitly.
- [`examples/05_chunks.exs`](https://github.com/tv-labs/lua/blob/main/examples/05_chunks.exs) — compile once, eval many times.
- [`examples/06_error_handling.exs`](https://github.com/tv-labs/lua/blob/main/examples/06_error_handling.exs) — `pcall`, structured exception fields, source/line attribution.

## Documentation

- Full API reference on [HexDocs](https://hexdocs.pm/lua).
- The [Working with Lua](guides/working-with-lua.livemd) guide is a Livebook
  walkthrough of the embedding patterns.
- The [`~LUA` sigil and Mix tasks](https://github.com/tv-labs/lua/blob/main/guides/mix_tasks.md)
  guide covers compile-time validation and tooling.
- The [Security and sandboxing](guides/sandboxing.md) guide covers the sandbox,
  allocation guards, recursion limits, and bounding CPU and memory.

> #### Lua the Elixir library vs Lua the language {: .info}
> When referring to this library, `Lua` is stylized as a link. References to
> Lua the language are in plaintext and not linked.

## Security and sandboxing

`Lua` is built to run untrusted scripts. By default, `Lua.new/1` installs
a sandbox that blocks the dangerous standard-library paths (`io`, `file`,
`os.execute`/`exit`/`getenv`, `package`, `require`, `load`, …), and the VM
guards against allocation-bomb denial-of-service by refusing oversized
`string.rep`, `table.unpack`/`concat`/`move`, and string concatenations
before they allocate.

```elixir
# os.exit is sandboxed by default — calling it raises (catchable)
iex> {[false, message], _} = Lua.eval!(Lua.new(), "return pcall(os.exit)")
iex> message =~ "sandboxed"
true
```

Capability sandboxing (`:sandboxed`, `:exclude`, `Lua.sandbox/2`),
recursion limits (`:max_call_depth`), the built-in allocation guards, and
the host-level pattern for bounding CPU time and total memory are all
covered in the [Security and sandboxing](guides/sandboxing.md) guide.

## Compatibility and credits

`Lua` started as an ergonomic Elixir wrapper around Robert Virding's
[Luerl](https://github.com/rvirding/luerl) project. As of `1.0.0` it is a full
Elixir-native reimplementation of the Lua 5.3 lexer, parser, and virtual
machine, with a public API designed to feel idiomatic from Elixir.

Compared to Luerl: `Lua` is pure Elixir with no shared mutable state (each
`Lua` value is plain immutable state you thread explicitly), ships richer error
messages with source and line attribution, and benchmarks competitively.
Luerl deserves credit as the prior art that made this possible — its design
informed many decisions in the new VM, and we benchmark against it.

## License

Released under the Apache-2.0 license. See
[`LICENSE`](https://github.com/tv-labs/lua/blob/main/LICENSE).
