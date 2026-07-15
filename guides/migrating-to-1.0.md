# Migrating to 1.0

`1.0.0` is the first stable release of `Lua` on its own Elixir-native Lua
5.3 virtual machine. The Luerl backend is gone — Luerl is no longer a
runtime dependency — and the public API is now frozen.

This guide is written for the jump straight from `0.4.0` (the last public
release) to `1.0.0`. If you tracked the release candidates, you have
already absorbed most of this; the per-rc detail lives in the
[CHANGELOG](CHANGELOG.md).

The good news first: **most code built on the high-level `Lua` API keeps
working unchanged.** `Lua.new/1`, `Lua.eval!/2`, `Lua.set!/3`, `deflua`,
and `Lua.load_api/2` behave the same. The default sandbox, `_G`/`_ENV`
semantics, metatables, and the standard-library surface are all
compatible. The breaking changes are concentrated at two boundaries: how
values are **encoded**, and how errors are **surfaced**.

## Bump the dependency

```elixir
# mix.exs
def deps do
  [
    # was: {:lua, "~> 0.4"}
    {:lua, "~> 1.0"}
  ]
end
```

Luerl was a transitive runtime dependency in `0.x`. It no longer is — if
you depended on `:luerl` directly (or called into it), you now need to
declare it yourself, but in almost all cases you should not need it at all.

## Encoded value tags changed

Encoded Lua values used to carry Luerl's internal tags. The new VM uses its
own representation:

| Value               | `0.4.0` (Luerl)      | `1.0.0`                  |
| ------------------- | -------------------- | ------------------------ |
| Table reference     | `:luerl.tref()`      | `{:tref, integer()}`     |
| Userdata reference  | `:luerl.usdref()`    | `{:udref, integer()}`    |
| Elixir callable     | `:luerl.erl_func()`  | `{:native_func, fun}`    |
| Compiled Lua func   | —                    | `{:lua_closure, _, _}`   |

If you pattern-matched the old tuples, update the patterns. **Better: stop
matching the internal shape at all.** Treat encoded references as opaque
and round-trip them through `Lua.decode!/2` to get plain Elixir data:

```elixir
# Fragile — matches an internal representation that can change:
case value do
  {:tref, _} -> handle_table(value)
end

# Durable — decode to plain Elixir and match that:
case Lua.decode!(lua, value) do
  map when is_map(map) -> handle_table(map)
end
```

The corresponding guards (`is_table/1`, `is_userdata/1`, `is_lua_func/1`)
are still available in `deflua` callbacks.

## MFA callback encoding was removed

`Lua.encode!/2` no longer accepts the `{module, function, args}` MFA tuple
form, and the `is_mfa/1` guard has been removed from `Lua.API` (it was a
Luerl-era shim that always returned `false`).

```elixir
# 0.4.0 — MFA tuple:
Lua.set!(lua, [:add], {MyModule, :add, []})

# 1.0.0 — a function literal:
Lua.set!(lua, [:add], fn args -> [MyModule.add(args)] end)

# …or a deflua callback in a use Lua.API module:
defmodule MyAPI do
  use Lua.API

  deflua add(a, b), do: a + b
end
```

Remove any `when is_mfa(value)` clauses — they never matched anything on
`1.0.0` and now reference an undefined guard.

## Bare struct encoding now raises

Encoding a bare Elixir struct used to silently succeed: `Lua.encode!/2`
(and `Lua.set!/3`) matched the struct as a plain map and produced a Lua
table carrying a `"__struct__"` key — a lossy, accidental conversion. That
now raises. Convert the struct explicitly first, selecting the fields Lua
needs:

```elixir
# 0.4.0 — silently encoded {..., "__struct__" => "Elixir.User"}:
Lua.set!(lua, [:user], %User{name: "Ada", age: 36})

# 1.0.0 — convert first:
Lua.set!(lua, [:user], Map.from_struct(%User{name: "Ada", age: 36}))
# or pick fields: %{name: user.name, age: user.age}
```

## Errors are now exception structs, not strings

This is the largest behavioural change for host code that inspects errors.

The public runtime exception is now solely `Lua.RuntimeException`. The
internal VM error structs (`Lua.VM.RuntimeError`, `Lua.VM.TypeError`,
`Lua.VM.ArgumentError`, `Lua.VM.AssertionError`, `Lua.VM.InternalError`)
are wrapped into `Lua.RuntimeException` before crossing any API boundary.
To discriminate a failure, read the wrapper's `:kind` field
(`:error | :type | :argument | :assertion | :internal`); the underlying VM
struct is on `:original`.

The `{:error, _}`-returning APIs now hand back the exception struct itself
rather than a pre-rendered message string, so the caller owns rendering:

```elixir
# 0.4.0 — reason was a formatted string:
case Lua.call_function(lua, [:boom], []) do
  {:error, reason, _lua} when is_binary(reason) -> Logger.error(reason)
end

# 1.0.0 — reason is a Lua.RuntimeException; render it yourself:
case Lua.call_function(lua, [:boom], []) do
  {:error, %Lua.RuntimeException{} = ex, _lua} ->
    Logger.error(Exception.message(ex))
end
```

`Lua.call_function/3` returns `{:error, exception, lua}` where the raised
Lua value (`error(42)`, a table, `nil`, `false`) is preserved on the
exception's `:value` field, matching what `pcall` hands back inside Lua.
`Lua.parse_chunk/1` now returns `{:error, %Lua.CompilerException{}}`
instead of `{:error, [String.t()]}`; its `:errors` field carries the bare,
ANSI-free messages for programmatic inspection.

Render messages through `Exception.message/1`. There is no `:message`
struct field to read — the message is composed lazily from the exception's
semantic fields (`:kind`, `:value`, `:original`, `:line`, `:source`) at
render time:

```elixir
# The only way to render:
Exception.message(exception)

# There is no exception.message field — inspect :kind / :value / :original
# for programmatic access instead.
```

## Parser error messages have a new format

The native parser no longer produces Luerl's
`"Line 1: syntax error before: ';'"` wording. Messages now read like
`"Expected expression"`. If you have test assertions that string-match the
old wording, update them. For tooling that needs to render parse errors,
use the structured API instead of matching strings:

```elixir
case Lua.Parser.parse_structured(source) do
  {:ok, chunk} -> chunk
  {:error, errors} -> Enum.map(errors, &Lua.Parser.Error.to_map/1)
end
```

## 64-bit integers wrap on overflow

Arithmetic and bitwise operations now follow Lua 5.3 §3.4.1: integers are
64-bit and wrap around at 2^63 instead of widening to arbitrary-precision
bignums as Luerl did. Code that relied on Luerl returning bignum results
for large integer math will now see wrapped values.

## Chunks are self-contained

`Lua.Chunk` now holds a compiled prototype and is reusable across
`Lua.eval!/2` calls; there is no separate load step. If you cached a loaded
chunk in `0.x`, you can pass the compiled `Lua.Chunk` directly to
`Lua.eval!/2` and reuse it.

## What did *not* change

- The high-level API: `Lua.new/1`, `Lua.eval!/2`, `Lua.set!/3`,
  `Lua.get!/2`, `deflua`, `Lua.load_api/2`.
- The default sandbox and its allow-list.
- `_G` / `_ENV` global-access semantics.
- Metatables and metamethod dispatch.
- The standard-library surface (`string`, `table`, `math`, `os`, `io`
  stubs, `package`/`require`).

If your code only touches those, the dependency bump is likely the only
change you need.
