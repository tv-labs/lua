# Userdata: hand an Elixir struct to Lua as an opaque reference and
# call Elixir-defined "methods" on it from Lua code.
#
# What to look at:
#   - Structs travel through Lua as `{:userdata, term}`. Inside Lua the
#     value is an opaque reference — Lua cannot index or mutate it.
#   - Native functions registered with `Lua.set!/3` use the 2-arity
#     form `fn args, state -> {results, state} end` so they can
#     `Lua.decode!/2` the reference back into the struct and
#     `Lua.encode!/2` a new one to return.
#
# Note: struct literals (`%Counter{}`) can't appear in the same file
# that defines the struct when the file is compiled as one unit, so
# this example builds and updates the struct with `struct/2` and map
# update syntax instead.

defmodule Counter do
  defstruct count: 0
end

# Encode the struct as userdata and expose it as a global `counter`.
{counter_ref, lua} = Lua.encode!(Lua.new(), {:userdata, struct(Counter, count: 0)})
lua = Lua.set!(lua, [:counter], counter_ref)

# Counter.inc(c) returns a new userdata reference with count + 1.
lua =
  Lua.set!(lua, [:Counter, :inc], fn [ref], state ->
    {:userdata, c} = Lua.decode!(state, ref)
    {new_ref, state} = Lua.encode!(state, {:userdata, %{c | count: c.count + 1}})
    {[new_ref], state}
  end)

# Counter.value(c) reads the count out as a plain integer.
lua =
  Lua.set!(lua, [:Counter, :value], fn [ref], state ->
    {:userdata, c} = Lua.decode!(state, ref)
    {[c.count], state}
  end)

{[result], _lua} =
  Lua.eval!(lua, """
  counter = Counter.inc(counter)
  counter = Counter.inc(counter)
  return Counter.value(counter)
  """)

IO.inspect(result, label: "counter after 2 incs")
# => counter after 2 incs: 2
