# iex recipes

Short, practical examples for poking at a `Lua` state from `iex`.

Run `iex -S mix` from the project root, then try any of the snippets
below. Each block is self-contained — paste it in and watch the
result.

## Read a Lua global

```elixir
iex> lua = Lua.set!(Lua.new(), [:greeting], "hello")
iex> Lua.get!(lua, [:greeting])
"hello"
```

Nested keys work too:

```elixir
iex> lua = Lua.set!(Lua.new(), [:user, :name], "ada")
iex> Lua.get!(lua, [:user, :name])
"ada"
```

## Call a Lua function from Elixir

The stdlib lives behind named scopes (`string`, `math`, `table`, etc.)
and is reachable via `Lua.call_function/3`:

```elixir
iex> {:ok, [ret], _} = Lua.call_function(Lua.new(), [:string, :upper], ["hi"])
iex> ret
"HI"
```

User-defined Lua functions are reachable the same way once you've
evaluated the source:

```elixir
iex> {_, lua} = Lua.eval!(Lua.new(), "function double(x) return x * 2 end")
iex> {:ok, [ret], _} = Lua.call_function(lua, [:double], [21])
iex> ret
42
```

You can also keep a closure handle directly off `eval!` and call it
later:

```elixir
iex> {[c], lua} = Lua.eval!(Lua.new(), "return function(x) return x + 1 end")
iex> c
#Lua.Closure<source: "<eval>", line: 1, arity: 1>
iex> {:ok, [10], _} = Lua.call_function(lua, c, [9])
```

## Inspect a table

A table returned through default decode mode comes back as a list of
`{key, value}` tuples:

```elixir
iex> {[t], _} = Lua.eval!(Lua.new(), "return {a = 1, b = 2}")
iex> Enum.sort(t)
[{"a", 1}, {"b", 2}]
```

Pass `decode: false` to keep the table as a wrapped reference. The
display struct shows the table id and a peek of its contents:

```elixir
iex> {[t], _} = Lua.eval!(Lua.new(), "return {10, 20, 30}", decode: false)
iex> t
#Lua.Table<id: 11, [10, 20, 30]>
```

`Lua.unwrap/1` recovers the raw `{:tref, id}` tuple if you need to
hand the reference to a tool that expects the encoded form:

```elixir
iex> {[t], _} = Lua.eval!(Lua.new(), "return {1}", decode: false)
iex> match?({:tref, _}, Lua.unwrap(t))
true
```

## Modify state and re-run

`eval!/2` returns the updated state, so you can thread evaluations
together to inspect intermediate values:

```elixir
iex> lua = Lua.new()
iex> {_, lua} = Lua.eval!(lua, "x = 1")
iex> {_, lua} = Lua.eval!(lua, "x = x * 10")
iex> {[10], _} = Lua.eval!(lua, "return x")
```

You can also drop into Lua, mutate state from Elixir, and continue:

```elixir
iex> {_, lua} = Lua.eval!(Lua.new(), "x = 1")
iex> lua = Lua.set!(lua, [:multiplier], 100)
iex> {[100], _} = Lua.eval!(lua, "return x * multiplier")
```

## Debug a script with `Lua.dbg/2`

`Lua.dbg/2` runs Lua exactly like `eval!/2` but prints a structured
summary alongside the return tuple. It captures `print()` output via
a temporary group-leader swap, so you can see what a script wrote
without scrolling through interleaved iex output:

```
iex> Lua.dbg(Lua.new(), ~S{print("hi"); return 1, 2})
--- Lua.dbg ---
source:  print("hi"); return 1, 2
return:  [1, 2]
elapsed: 0 ms
prints:
  hi
---------------
{[1, 2], #Lua<>}
```

If the script raises, `dbg/2` records the exception under `raised:`
and re-raises so the original stack trace is preserved.

`dbg/2` is intended for `iex` only — it does its own `IO.puts/1` and
swaps the calling process's group leader. Use `eval!/2` directly in
production code paths.

## Skim what's in a library table

Want to see what's in `string`? Iterate over its keys with Lua, then
return the names as a sequence:

```elixir
iex> {[entries], _} = Lua.eval!(Lua.new(), ~S"""
...> local out = {}
...> for k, _ in pairs(string) do out[#out + 1] = k end
...> return out
...> """)
iex> names = entries |> Enum.map(&elem(&1, 1))
iex> "upper" in names
true
```

Lua tables come back as a list of `{key, value}` tuples even when
the keys are sequential integers — `Enum.map(&elem(&1, 1))` strips
the indices.

The same pattern works for `math`, `table`, `os`, etc. Avoid running
this against `_G` directly: the global environment refers back to
itself (via `_G._G`), and a default-decode walk over a self-referential
table doesn't terminate.

## Build a small "tool" function in Elixir

`Lua.set!/3` accepts an Elixir function and exposes it to Lua. The
function receives a list of decoded args and must return a list of
encoded values:

```elixir
iex> lua = Lua.set!(Lua.new(), [:words_in], fn [s] -> [String.split(s) |> length()] end)
iex> {[3], _} = Lua.eval!(lua, ~S{return words_in("the quick fox")})
```

The two-arity form gets the `Lua` state too, so you can read or
mutate the VM from inside the helper:

```elixir
iex> lua = Lua.set!(Lua.new(), [:bump], fn [], state ->
...>   current = Lua.get!(state, [:counter]) || 0
...>   {[], Lua.set!(state, [:counter], current + 1)}
...> end)
iex> {_, lua} = Lua.eval!(lua, "bump(); bump(); bump()")
iex> Lua.get!(lua, [:counter])
3
```
