# Quickstart: evaluate a Lua script and read the result back in Elixir.
#
# What to look at:
#   - `Lua.new/0` builds a fresh, sandboxed VM.
#   - `Lua.eval!/2` runs a script and returns `{results, lua}` where
#     `results` is the list of values the script `return`ed, already
#     decoded into Elixir terms.

# `eval!/1` spins up a throwaway VM for one-off scripts.
{[answer], _lua} = Lua.eval!("return 6 * 7")
IO.inspect(answer, label: "6 * 7")
# => 6 * 7: 42

# A script can return multiple values; they come back as a list.
{[sum, product], _lua} =
  Lua.eval!("""
  local a, b = 3, 4
  return a + b, a * b
  """)

IO.inspect(sum, label: "sum")
IO.inspect(product, label: "product")
# => sum: 7
# => product: 12

# Tables decode into Elixir key/value pairs. A Lua array is a table
# keyed by 1..n, so it decodes to `[{1, 10}, {2, 20}, {3, 30}]`.
{[table], _lua} = Lua.eval!("return {10, 20, 30}")
IO.inspect(table, label: "table")
# => table: [{1, 10}, {2, 20}, {3, 30}]
