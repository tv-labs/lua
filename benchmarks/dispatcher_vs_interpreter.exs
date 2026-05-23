# Compares the dispatcher vs interpreter on the same fib(25) workload.
# Strips `proto.bytecode` to force the interpreter path on an otherwise-
# identical Lua VM state. Used by perf-gate verification for B5a-v2.

Code.require_file("helpers.exs", __DIR__)

fib_def = """
function fib(n)
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
"""

# Compile once, get a clean state with `fib` installed as a global.
lua_dispatcher = Lua.new() |> Lua.eval!(fib_def) |> elem(1)

strip_bytecode = fn walker, %Lua.Compiler.Prototype{} = p ->
  %{p | bytecode: nil, prototypes: Enum.map(p.prototypes, &walker.(walker, &1))}
end

# Strip bytecode from fib so the call routes through the interpreter.
strip_state = fn state ->
  case Lua.VM.State.get_global(state, "fib") do
    {:compiled_closure, proto, upvalues} ->
      stripped = strip_bytecode.(strip_bytecode, proto)
      Lua.VM.State.set_global(state, "fib", {:lua_closure, stripped, upvalues})

    {:lua_closure, proto, upvalues} ->
      stripped = strip_bytecode.(strip_bytecode, proto)
      Lua.VM.State.set_global(state, "fib", {:lua_closure, stripped, upvalues})
  end
end

lua_interpreter = %{lua_dispatcher | state: strip_state.(lua_dispatcher.state)}

IO.puts("\n--- closure tags ---")
{:compiled_closure, _, _} = Lua.VM.State.get_global(lua_dispatcher.state, "fib")
{:lua_closure, _, _} = Lua.VM.State.get_global(lua_interpreter.state, "fib")
IO.puts("dispatcher: :compiled_closure")
IO.puts("interpreter: :lua_closure")

# Correctness sanity check.
{[result_d], _} = Lua.eval!(lua_dispatcher, "return fib(20)")
{[result_i], _} = Lua.eval!(lua_interpreter, "return fib(20)")
IO.puts("\nfib(20) dispatcher=#{result_d} interpreter=#{result_i} match=#{result_d == result_i}\n")

call_fib = "return fib(25)"
{chunk_d, _} = Lua.load_chunk!(lua_dispatcher, call_fib)
{chunk_i, _} = Lua.load_chunk!(lua_interpreter, call_fib)

Benchee.run(
  %{
    "dispatcher fib(25)" => fn -> Lua.eval!(lua_dispatcher, chunk_d) end,
    "interpreter fib(25)" => fn -> Lua.eval!(lua_interpreter, chunk_i) end
  },
  Bench.opts()
)
