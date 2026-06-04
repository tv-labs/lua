# Focused micro-benchmark for the pcall heap-effect preservation change.
# Run on two checkouts and diff:
#   MIX_ENV=benchmark mix run benchmarks/scripts/pcall_state_bench.exs
#
# Covers the paths the change touches:
#   * fib(28)        — arithmetic hot path (widened safe_* helper arities)
#   * table writes   — t[i] = i loop (table_newindex fast path)
#   * concat loop    — concat_checked/concat_coerce widening
#   * pcall loop     — protected-call overhead incl. the new try wrappers
#   * closure for    — generic_for driven by a Lua-closure iterator, which is
#                      the path that gained a new per-iteration try block in
#                      executor.ex call_value/5 (lua_closure clause)
#
# memory_time is enabled so the per-call allocation/GC delta of the added try
# frames is observable, not just wall-clock time.

defmodule PcallStateBench do
  @moduledoc false
  def chunk(lua, code) do
    {chunk, _} = Lua.load_chunk!(lua, code)
    chunk
  end
end

lua = Lua.new()

{_, lua} =
  Lua.eval!(lua, """
  function fib(n)
    if n < 2 then return n end
    return fib(n-1) + fib(n-2)
  end
  """)

fib = PcallStateBench.chunk(lua, "return fib(28)")

table_writes =
  PcallStateBench.chunk(lua, """
  local t = {}
  for i = 1, 200000 do t[i] = i end
  return #t
  """)

concat_loop =
  PcallStateBench.chunk(lua, """
  local s = ""
  for i = 1, 5000 do s = s .. "x" end
  return #s
  """)

pcall_loop =
  PcallStateBench.chunk(lua, """
  local n = 0
  for i = 1, 50000 do
    local ok = pcall(function() n = n + 1 end)
  end
  return n
  """)

# A stateful Lua-closure iterator drives the generic_for loop, so each
# iteration routes through executor.ex call_value/5's lua_closure clause —
# the path that gained a new per-iteration try block in this change.
closure_for =
  PcallStateBench.chunk(lua, """
  local function range(limit)
    local i = 0
    return function()
      i = i + 1
      if i <= limit then return i end
    end
  end
  local sum = 0
  for v in range(50000) do sum = sum + v end
  return sum
  """)

Benchee.run(
  %{
    "fib(28)" => fn -> Lua.eval!(lua, fib) end,
    "table writes 200k" => fn -> Lua.eval!(lua, table_writes) end,
    "concat 5k" => fn -> Lua.eval!(lua, concat_loop) end,
    "pcall loop 50k" => fn -> Lua.eval!(lua, pcall_loop) end,
    "closure for 50k" => fn -> Lua.eval!(lua, closure_for) end
  },
  warmup: 1,
  time: 4,
  memory_time: 2
)
