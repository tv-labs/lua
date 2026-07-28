# Run with: mix run benchmarks/metamethods.exs
#
# Benchmarks metatable-driven dispatch. oop.exs already covers the shallow
# case — one `setmetatable` + a single-level `__index` table lookup, with
# methods invoked as plain field calls (`Animal.speak(a)`). This script covers
# the three things that shape real Lua OOP code and that the shallow case
# leaves untouched:
#
#   - methods:  method calls written with the `:` sugar (`v:len2()`), so the
#               receiver is threaded as an implicit `self` argument, plus a
#               chained call on a freshly constructed receiver
#               (`v:scaled(2):len2()`). This is the self-call path; the plain
#               `T.f(obj)` form in oop.exs does not reach it.
#   - inherit:  a three-level prototype chain (Rect -> Polygon -> Shape) built
#               the idiomatic way, with `setmetatable` on the class tables
#               themselves. Each call resolves at a different depth: one hit on
#               the leaf, one two hops up, one three hops up — so the cost of
#               walking a chain is separated from the cost of a single hit.
#   - arith:    arithmetic and relational metamethods (`__add`, `__sub`,
#               `__lt`, `__eq`) plus `__tostring`. These route through the
#               metamethod fallback in the arithmetic/comparison opcodes rather
#               than through table indexing, which is a different VM path from
#               `__index` entirely.
#
# Each workload runs n=200 iterations per invocation.
#
# Compares:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua 5.4 development headers and a small in-tree
# patch (its 1.6.3 release defaults to LuaJIT and uses LUA_GLOBALSINDEX which
# was removed in Lua 5.2). On macOS:
#   brew install lua@5.4
#   ./benchmarks/setup_luaport.sh           # idempotent; patches + builds
#   MIX_ENV=benchmark mix run benchmarks/metamethods.exs
# If luaport fails to start, the benchmark prints a notice and skips it.
#
# Run modes (see benchmarks/helpers.exs):
#   default                — quick mode (~4 s per Benchee.run)
#   LUA_BENCH_MODE=full    — long windows + memory_time, for publishable numbers

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

meta_def = """
-- Self-call dispatch via the `:` sugar, including a chained call.
Vec = {}
Vec.__index = Vec

function Vec.new(x, y)
  return setmetatable({ x = x, y = y }, Vec)
end

function Vec:len2()
  return self.x * self.x + self.y * self.y
end

function Vec:scaled(k)
  return Vec.new(self.x * k, self.y * k)
end

function run_methods(n)
  local v = Vec.new(3, 4)
  local acc = 0
  for i = 1, n do
    acc = acc + v:len2()
    acc = acc + v:scaled(2):len2()
  end
  return acc
end

-- Three-level prototype chain; the three calls below resolve at depth 1, 2
-- and 3 respectively, so a chain walk is measured alongside a direct hit.
Shape = {}
Shape.__index = Shape

function Shape:kind() return "shape" end
function Shape:area() return 0 end

Polygon = setmetatable({}, { __index = Shape })
Polygon.__index = Polygon

function Polygon:sides() return 0 end

Rect = setmetatable({}, { __index = Polygon })
Rect.__index = Rect

function Rect.new(w, h)
  return setmetatable({ w = w, h = h }, Rect)
end

function Rect:sides() return 4 end

function run_inherit(n)
  local r = Rect.new(3, 4)
  local acc = 0
  for i = 1, n do
    acc = acc + r:sides()
    acc = acc + r:area()
    acc = acc + #r:kind()
  end
  return acc
end

-- Arithmetic / relational / tostring metamethods.
Money = {}
Money.__index = Money
Money.__add = function(a, b) return Money.new(a.cents + b.cents) end
Money.__sub = function(a, b) return Money.new(a.cents - b.cents) end
Money.__lt = function(a, b) return a.cents < b.cents end
Money.__eq = function(a, b) return a.cents == b.cents end
Money.__tostring = function(m) return "$" .. tostring(m.cents) end

function Money.new(cents)
  return setmetatable({ cents = cents }, Money)
end

function run_arith(n)
  local acc = Money.new(0)
  local flags = 0
  local last = ""
  for i = 1, n do
    acc = acc + Money.new(i)
    acc = acc - Money.new(1)
    if Money.new(i) < Money.new(i + 1) then flags = flags + 1 end
    if Money.new(i) == Money.new(i) then flags = flags + 1 end
    last = tostring(acc)
  end
  return acc.cents, flags, #last
end
"""

call_methods = "return run_methods(200)"
call_inherit = "return run_inherit(200)"
call_arith = "return run_arith(200)"

# --- This Lua implementation ---
# The state returned by `load_chunk!/2` is threaded through each call rather
# than discarded: a loaded chunk may be a reference *into* the state it was
# loaded against, so dropping that state can invalidate the chunk. Threading it
# is correct on every release and costs nothing.
lua = Lua.new()
{_, lua} = Lua.eval!(lua, meta_def)
{methods_chunk, lua} = Lua.load_chunk!(lua, call_methods)
{inherit_chunk, lua} = Lua.load_chunk!(lua, call_inherit)
{arith_chunk, lua} = Lua.load_chunk!(lua, call_arith)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(meta_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:meta_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, meta_def)

      {
        fn func -> %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, func, [200]) end} end,
        fn -> :luaport.despawn(:meta_bench) end
      }

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {fn _func -> %{} end, fn -> :ok end}
  end

bench = fn name, call_str, chunk, c_lua_func ->
  Bench.banner(name)

  Benchee.run(
    Map.merge(
      %{
        "lua (eval)" => fn -> Lua.eval!(lua, call_str) end,
        "lua (chunk)" => fn -> Lua.eval!(lua, chunk) end,
        "luerl" => fn -> :luerl.do(call_str, luerl_state) end
      },
      c_lua.(c_lua_func)
    ),
    Bench.opts()
  )
end

bench.("metamethods: self-call method dispatch (n=200)", call_methods, methods_chunk, :run_methods)
bench.("metamethods: 3-level __index chain (n=200)", call_inherit, inherit_chunk, :run_inherit)
bench.("metamethods: arithmetic/relational metamethods (n=200)", call_arith, arith_chunk, :run_arith)

c_lua_cleanup.()
