defmodule Lua.VM.UpvalueTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp run_lua(code) do
    assert {:ok, ast} = Parser.parse(code)
    assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    VM.execute(proto, state)
  end

  # Regression test for plan A15.
  #
  # Bug: when a local function L was followed by a sibling/descendant closure
  # that captured L by name, codegen emitted set_open_upvalue for L's
  # register at the local-function definition site. Since L's own closure
  # didn't capture itself (non-recursive), no upvalue cell existed yet for
  # that register, and set_open_upvalue crashed at runtime with
  # `key N not found in: %{}`.
  #
  # The fix: only emit set_open_upvalue when the local function's *own*
  # closure captures itself (the recursive case). Sibling captures create
  # their own cells lazily when their closures execute.

  describe "non-recursive local function captured by a later sibling closure" do
    test "shrunken repro from test/lua53_tests/sort.lua" do
      # Original failure path: sort.lua defines `checkerror` (a non-recursive
      # local function), calls it once, then later defines `check` which
      # captures `checkerror` as an upvalue. The first call to `checkerror`
      # crashed at set_open_upvalue with `key 0 not found in: %{}`.
      #
      # The original used table.insert/table.sort but the bug is purely about
      # codegen for `local function` followed by a sibling closure capturing
      # it. Any non-trivial body and any non-recursive callable suffices.
      code = """
      local function checkerror (f, ...)
        pcall(f, ...)
      end

      local function noop() end
      checkerror(noop, 1, 2)

      local function check ()
        local function f(a, b) return true end
        checkerror(noop, f)
      end

      return "ok"
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["ok"], _state} = VM.execute(proto, state)
    end

    test "later closure references the local but never calls it" do
      code = """
      local function helper(x) return x + 1 end
      helper(10)

      local function uses_helper()
        return helper
      end

      return helper(5), uses_helper() == helper
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [6, true], _state} = VM.execute(proto, state)
    end

    test "multiple non-recursive locals captured by a single later closure" do
      code = """
      local function add(a, b) return a + b end
      local function sub(a, b) return a - b end
      local x = add(2, 3) + sub(10, 4)

      local function combine(a, b)
        return add(a, b) + sub(a, b)
      end

      return x, combine(7, 2)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [11, 14], _state} = VM.execute(proto, state)
    end
  end

  describe "recursive local function still works" do
    test "factorial via direct recursion" do
      code = """
      local function fact(n)
        if n <= 1 then return 1 end
        return n * fact(n - 1)
      end
      return fact(5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [120], _state} = VM.execute(proto, state)
    end

    test "recursive local also captured by a later closure" do
      # The local function is both recursive (its own closure captures it)
      # AND captured by a later sibling. set_open_upvalue must still fire so
      # the recursive reference resolves to the final closure value.
      code = """
      local function loop(n)
        if n <= 0 then return 0 end
        return 1 + loop(n - 1)
      end

      local function caller()
        return loop(3)
      end

      return loop(5), caller()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [5, 3], _state} = VM.execute(proto, state)
    end
  end

  describe "closures created in the same block share upvalue cells" do
    test "two later closures capture the same earlier local" do
      code = """
      local function base(x) return x * 2 end

      local function caller_a() return base(3) end
      local function caller_b() return base(4) end

      return caller_a(), caller_b()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [6, 8], _state} = VM.execute(proto, state)
    end
  end

  describe "FuncDecl on a captured table-chain target" do
    # Codegen for `function obj.method() end` reads `obj` from a captured-local
    # cell when `obj` is captured by a later closure. Same crash shape as the
    # LocalFunc bug: the cell hasn't been created yet at the FuncDecl site.
    # The executor fallback (read register when no cell exists) handles this.
    test "function obj.method() end where obj is captured by a later closure" do
      code = """
      local obj = {}
      function obj.method() return 42 end

      local function check() return obj.method() end

      return obj.method(), check()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [42, 42], _state} = VM.execute(proto, state)
    end
  end

  # Lua 5.3 §3.4.10: when a block ends, any open-upvalue cell over a register
  # the block's locals occupied must be detached so a later sibling block
  # reusing the same register slot binds a fresh cell. Without the block-exit
  # close, the second block's captured local resolves through the first
  # block's stale cell — e.g. an integer where a table is expected, crashing
  # with `attempt to index a number value`.
  describe "open upvalues close at block exit so sibling blocks do not share cells" do
    test "two sibling do blocks reusing the same register for a captured local" do
      code = """
      do
        local res = 1
        local function fact(n)
          if n == 0 then return res else return n * fact(n - 1) end
        end
        assert(fact(5) == 120)
      end

      do
        local a = {x = 100}
        local function read_a() return a.x end
        assert(read_a() == 100, "expected 100, got stale-cell value")
      end

      return "ok"
      """

      assert {:ok, ["ok"], _state} = run_lua(code)
    end

    test "two sibling if blocks reusing the same register for a captured local" do
      code = """
      if true then
        local res = 1
        local function fact(n)
          if n == 0 then return res else return n * fact(n - 1) end
        end
        assert(fact(5) == 120)
      end

      if true then
        local a = {x = 100}
        local function read_a() return a.x end
        assert(read_a() == 100, "expected 100, got stale-cell value")
      end

      return "ok"
      """

      assert {:ok, ["ok"], _state} = run_lua(code)
    end

    test "then and else branches reusing the same register for a captured local" do
      code = """
      local function pick(flag)
        if flag then
          local a = {x = 11}
          local function get() return a.x end
          return get()
        else
          local b = {y = 22}
          local function get() return b.y end
          return get()
        end
      end

      return pick(true), pick(false)
      """

      assert {:ok, [11, 22], _state} = run_lua(code)
    end

    test "two sibling while blocks reusing the same register for a captured local" do
      code = """
      local n = 0
      while n < 1 do
        n = n + 1
        local res = 1
        local function f() return res end
        assert(f() == 1)
      end

      while n < 2 do
        n = n + 1
        local a = {x = 5}
        local function g() return a.x end
        assert(g() == 5, "stale cell leaked from the previous while block")
      end

      return "ok"
      """

      assert {:ok, ["ok"], _state} = run_lua(code)
    end

    test "two sibling repeat blocks reusing the same register for a captured local" do
      code = """
      local n = 0
      repeat
        n = n + 1
        local res = 1
        local function f() return res end
        assert(f() == 1)
      until n >= 1

      repeat
        n = n + 1
        local a = {x = 7}
        local function g() return a.x end
        assert(g() == 7, "stale cell leaked from the previous repeat block")
      until n >= 2

      return "ok"
      """

      assert {:ok, ["ok"], _state} = run_lua(code)
    end

    test "two sibling numeric for blocks reusing the same register for a captured local" do
      code = """
      for _ = 1, 1 do
        local res = 1
        local function f() return res end
        assert(f() == 1)
      end

      for _ = 1, 1 do
        local a = {x = 9}
        local function g() return a.x end
        assert(g() == 9, "stale cell leaked from the previous for block")
      end

      return "ok"
      """

      assert {:ok, ["ok"], _state} = run_lua(code)
    end

    test "two sibling generic for blocks reusing the same register for a captured local" do
      code = """
      for _ in ipairs({1}) do
        local res = 1
        local function f() return res end
        assert(f() == 1)
      end

      for _ in ipairs({1}) do
        local a = {x = 13}
        local function g() return a.x end
        assert(g() == 13, "stale cell leaked from the previous for-in block")
      end

      return "ok"
      """

      assert {:ok, ["ok"], _state} = run_lua(code)
    end

    test "numeric for: each iteration's closure captures that iteration's value" do
      # Cells must persist within an iteration and close on the iteration
      # boundary — a closure created in iteration N must observe iteration N's
      # value, not leak the next iteration's value.
      code = """
      local fns = {}
      for i = 1, 3 do
        local v = i * 10
        fns[i] = function() return v end
      end
      return fns[1](), fns[2](), fns[3]()
      """

      assert {:ok, [10, 20, 30], _state} = run_lua(code)
    end

    test "loop closure created mid-iteration sees the live value later in the same iteration" do
      code = """
      local total = 0
      for i = 1, 3 do
        local v = i
        local function add() total = total + v end
        v = v * 100
        add()
      end
      return total
      """

      assert {:ok, [600], _state} = run_lua(code)
    end
  end
end
