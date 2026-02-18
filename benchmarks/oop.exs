# Run with: mix run benchmarks/oop.exs
#
# Benchmarks object-oriented patterns using Lua tables and metatables.
# Uses assignment-style method definitions (e.g. Animal.speak = function(self) ... end)
# which are compatible with this Lua implementation's current feature set.
# Creates 50 Animal instances per iteration and calls a method on each.
#
# Patterns tested:
#   - Table creation and field assignment
#   - setmetatable / __index prototype chain lookup
#   - Closure creation per object (factory pattern variant)
#
# Compares:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua development headers. On macOS with Homebrew:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix deps.compile luaport
# Then run:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix run benchmarks/oop.exs

Application.ensure_all_started(:luerl)

oop_def = """
Animal = {}
Animal.__index = Animal

Animal.new = function(name, sound)
  local obj = {}
  obj.name = name
  obj.sound = sound
  setmetatable(obj, Animal)
  return obj
end

Animal.speak = function(self)
  return self.name .. " says " .. self.sound
end

Animal.getName = function(self)
  return self.name
end

function run_oop(n)
  local result = ""
  for i = 1, n do
    local a = Animal.new("Animal" .. tostring(i), "sound" .. tostring(i))
    result = Animal.speak(a)
  end
  return result
end
"""

call_oop = "return run_oop(50)"

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, oop_def)
{oop_chunk, _} = Lua.load_chunk!(lua, call_oop)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(oop_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_benchmarks, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:oop_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, oop_def)

      benchmarks = %{
        "C Lua (luaport)" => fn -> :luaport.call(port_pid, :run_oop, [50]) end
      }

      {benchmarks, fn -> :luaport.despawn(:oop_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {%{}, fn -> :ok end}
  end

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_oop) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, oop_chunk) end,
      "luerl" => fn -> :luerl.do(call_oop, luerl_state) end
    },
    c_lua_benchmarks
  ),
  time: 10,
  warmup: 2,
  memory_time: 1
)

c_lua_cleanup.()
