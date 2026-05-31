# Custom stdlib: expose Elixir functions to Lua and call them like any
# other Lua function.
#
# What to look at:
#   - `Lua.set!/3` installs a function at a path. A 1-arity function
#     `fn args -> results end` is enough when you don't need the VM
#     state; the 2-arity form `fn args, state -> {results, state} end`
#     is for functions that read or modify Lua state.
#   - Nested paths like `[:math, :clamp]` build the intermediate table,
#     so you can extend existing libraries (here, `math`).

lua = Lua.new()

# A plain function, exposed as a global.
lua = Lua.set!(lua, [:greet], fn [name] -> ["Hello, #{name}!"] end)

# Add a function into the existing `math` table.
lua =
  Lua.set!(lua, [:math, :clamp], fn [value, low, high] ->
    [value |> max(low) |> min(high)]
  end)

# A function that reads existing Lua state via the 2-arity form.
lua = Lua.set!(lua, [:base], 100)

lua =
  Lua.set!(lua, [:add_base], fn [n], state ->
    base = Lua.get!(state, [:base])
    {[n + base], state}
  end)

{[greeting], _} = Lua.eval!(lua, ~S[return greet("Lua")])
IO.inspect(greeting, label: "greet")
# => greet: "Hello, Lua!"

{[clamped], _} = Lua.eval!(lua, "return math.clamp(42, 0, 10)")
IO.inspect(clamped, label: "math.clamp(42, 0, 10)")
# => math.clamp(42, 0, 10): 10

{[total], _} = Lua.eval!(lua, "return add_base(5)")
IO.inspect(total, label: "add_base(5)")
# => add_base(5): 105
