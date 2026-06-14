defmodule Lua.VM.LazyCallInfoTest do
  @moduledoc """
  Guards the lazily-rebuilt `call_stack` on the executor's Lua->Lua call path.

  The executor tracks in-flight Lua frames in its `frames` argument and only
  materializes `state.call_stack` at the boundaries that read it: native-call
  dispatch (where `debug.getinfo`/`debug.traceback` read the stack LIVE during
  successful execution), the dispatcher hand-off, the `generic_for` iterator
  call, the `__call` metamethod dispatch, and error raise sites. These golden
  values were captured from the previous eager-`call_info` executor and must
  remain byte-identical.

  Two distinct executor materialization sites are covered:

    * The compiled `:compiled_closure` hand-off — exercised by plain
      `function f() ... end` / `setmetatable` closures, whose sub-prototypes
      compile WITH bytecode and so route through `Dispatcher.execute/4`. The
      per-call source line is baked into the call opcode, so the live frame's
      `currentline` resolves on this path; caller frames reached across the
      hand-off still report `0` / `-1`.
    * The lazy `:lua_closure` interpreter path — the branch this module's name
      refers to, where `state.call_stack` is left untouched and entries are
      synthesized from `frames` only at a read boundary. Sub-prototypes only
      route here when they can NOT be lowered to bytecode, so the
      lazy-variant tests below sprinkle a short-circuit op (`1 and 2`, whose
      `test_and` opcode is not bytecode-encodable) into each function to force
      the interpreter path. On this path the live call-site line survives, so
      the golden `currentline` / traceback line numbers differ from the
      compiled path.
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.RuntimeError, as: LuaRuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib
  alias Lua.VM.TypeError, as: LuaTypeError

  defp run(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    VM.execute(proto, state)
  end

  defp run!(code) do
    {:ok, results, _state} = run(code)
    results
  end

  describe "debug.getinfo reads the live executor stack" do
    test "name/namewhat/currentline for a nested Lua->Lua call chain" do
      code = """
      function outer()
        return inner()
      end
      function inner()
        local info = debug.getinfo(2, "nSl")
        return info.name, info.namewhat, info.currentline, info.source, info.what
      end
      return outer()
      """

      assert run!(code) == ["outer", "global", 0, "test.lua", "Lua"]
    end

    test "name/namewhat/currentline on the forced-lazy interpreter path" do
      # The `1 and 2` short-circuit op is not bytecode-encodable, so both
      # functions fall onto the `:lua_closure` interpreter path. Unlike the compiled
      # hand-off above, the live call-site `line` survives, so `currentline`
      # is 3 (the `return inner()` site) rather than 0.
      code = """
      function outer()
        local _ = 1 and 2
        return inner()
      end
      function inner()
        local _ = 1 and 2
        local info = debug.getinfo(2, "nSl")
        return info.name, info.namewhat, info.currentline, info.source, info.what
      end
      return outer()
      """

      assert run!(code) == ["outer", "global", 3, "test.lua", "Lua"]
    end

    test "level 1 currentline" do
      # On the compiled hand-off the per-call source line is now baked into
      # the call opcode (feat: plumb per-call source lines through the
      # compiled dispatcher), so level-1 `currentline` resolves to the live
      # `debug.getinfo` call site (line 2) rather than the stripped `-1`.
      code = """
      function f()
        return debug.getinfo(1, "Sl").currentline
      end
      return f()
      """

      assert run!(code) == [2]
    end

    test "level 1 currentline on the forced-lazy interpreter path" do
      # On the lazy `:lua_closure` path the call site survives, so level-1
      # `currentline` is the live line (3) rather than -1.
      code = """
      function f()
        local _ = 1 and 2
        return debug.getinfo(1, "Sl").currentline
      end
      return f()
      """

      assert run!(code) == [3]
    end

    test "three-deep chain resolves distinct levels" do
      code = """
      function a() return b() end
      function b() return c() end
      function c()
        local l2 = debug.getinfo(2, "n").name
        local l3 = debug.getinfo(3, "n").name
        return l2, l3
      end
      return a()
      """

      assert run!(code) == ["b", "a"]
    end

    test "three-deep chain resolves distinct levels on the forced-lazy path" do
      code = """
      function a() local _ = 1 and 2 return b() end
      function b() local _ = 1 and 2 return c() end
      function c()
        local _ = 1 and 2
        local l2 = debug.getinfo(2, "n").name
        local l3 = debug.getinfo(3, "n").name
        return l2, l3
      end
      return a()
      """

      assert run!(code) == ["b", "a"]
    end
  end

  describe "debug.traceback reads the live executor stack" do
    test "renders one line per active Lua frame" do
      code = """
      function outer() return inner() end
      function inner() return debug.traceback() end
      return outer()
      """

      assert run!(code) == ["stack traceback:\n\ttest.lua:0: in ?\n\ttest.lua:3: in ?"]
    end

    test "renders the live call-site lines on the forced-lazy path" do
      # The compiled path above strips the line to 0; the lazy `:lua_closure`
      # path preserves each frame's call-site line (outer at 1, inner at 3).
      code = """
      function outer() local _ = 1 and 2 return inner() end
      function inner() local _ = 1 and 2 return debug.traceback() end
      return outer()
      """

      assert run!(code) == ["stack traceback:\n\ttest.lua:1: in ?\n\ttest.lua:3: in ?"]
    end
  end

  describe "__call metamethod dispatch materializes the executor stack" do
    # The `:call` opcode's `__call` branch dispatches through `call_function/3`.
    # The enclosing executor frames are tracked lazily, so they must be
    # materialized into `state.call_stack` for the duration of the metamethod
    # call exactly like the native-dispatch and dispatcher hand-off boundaries.
    # Without it, a callback reading the stack sees a truncated traceback and a
    # `currentline` of -1 instead of the live call-site line.

    test "debug.traceback inside a __call callback sees the calling frame" do
      code = """
      local t = setmetatable({}, {__call = function(self)
        return debug.traceback("cm")
      end})
      function p()
        return t()
      end
      return p()
      """

      assert run!(code) == ["cm\nstack traceback:\n\ttest.lua:7: in ?"]
    end

    test "debug.traceback inside a __call callback on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__call = function(self)
        local _ = 1 and 2
        return debug.traceback("cm")
      end})
      function p()
        local _ = 1 and 2
        return t()
      end
      return p()
      """

      assert run!(code) == ["cm\nstack traceback:\n\ttest.lua:9: in ?"]
    end

    test "debug.getinfo currentline inside a __call callback is the call site" do
      code = """
      local t = setmetatable({}, {__call = function(self)
        return debug.getinfo(2, "nl").currentline
      end})
      function p()
        return t()
      end
      return p()
      """

      assert run!(code) == [7]
    end

    test "debug.getinfo currentline inside a __call callback on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__call = function(self)
        local _ = 1 and 2
        return debug.getinfo(2, "nl").currentline
      end})
      function p()
        local _ = 1 and 2
        return t()
      end
      return p()
      """

      assert run!(code) == [9]
    end

    test "call_stack is restored to empty after a __call dispatch" do
      code = """
      local t = setmetatable({}, {__call = function(self) return 7 end})
      local function outer() return t() end
      return outer()
      """

      assert {:ok, [7], state} = run(code)
      assert state.call_stack == []
      assert state.call_depth == 0
    end

    test "call_stack is restored to empty after a __call dispatch on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__call = function(self) local _ = 1 and 2 return 7 end})
      local function outer() local _ = 1 and 2 return t() end
      return outer()
      """

      assert {:ok, [7], state} = run(code)
      assert state.call_stack == []
      assert state.call_depth == 0
    end
  end

  describe "metamethod dispatch materializes the executor stack" do
    # `__index`/`__newindex`/arithmetic metamethods re-enter via
    # `call_function/3` from inside the interpreter opcode clauses, where the
    # enclosing Lua frames are tracked lazily in the `frames` argument and are
    # NOT in `state.call_stack`. They must be materialized for the duration of
    # the metamethod call exactly like the native-dispatch and `__call`
    # boundaries — otherwise a callback reading the stack sees a truncated
    # traceback (the enclosing frame gone) and `currentline` of -1.

    test "debug.traceback inside an __index callback sees the enclosing frame" do
      code = """
      local t = setmetatable({}, {__index = function(self, k)
        return debug.traceback("im")
      end})
      function p()
        return t.foo
      end
      return p()
      """

      assert run!(code) == ["im\nstack traceback:\n\ttest.lua:7: in ?"]
    end

    test "debug.traceback inside an __index callback on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__index = function(self, k)
        local _ = 1 and 2
        return debug.traceback("im")
      end})
      function p()
        local _ = 1 and 2
        return t.foo
      end
      return p()
      """

      assert run!(code) == ["im\nstack traceback:\n\ttest.lua:9: in ?"]
    end

    test "debug.getinfo currentline inside an __index callback is the call site" do
      code = """
      local t = setmetatable({}, {__index = function(self, k)
        return debug.getinfo(2, "nl").currentline
      end})
      function p()
        return t.foo
      end
      return p()
      """

      assert run!(code) == [7]
    end

    test "debug.getinfo currentline inside an __index callback on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__index = function(self, k)
        local _ = 1 and 2
        return debug.getinfo(2, "nl").currentline
      end})
      function p()
        local _ = 1 and 2
        return t.foo
      end
      return p()
      """

      assert run!(code) == [9]
    end

    test "debug.traceback inside a __newindex callback on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__newindex = function(self, k, v)
        local _ = 1 and 2
        _G.captured = debug.traceback("nm")
      end})
      function p()
        local _ = 1 and 2
        t.foo = 1
      end
      p()
      return _G.captured
      """

      assert run!(code) == ["nm\nstack traceback:\n\ttest.lua:9: in ?"]
    end

    test "debug.traceback inside an arithmetic metamethod on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__add = function(a, b)
        local _ = 1 and 2
        return debug.traceback("am")
      end})
      function p()
        local _ = 1 and 2
        return t + 1
      end
      return p()
      """

      assert run!(code) == ["am\nstack traceback:\n\ttest.lua:9: in ?"]
    end

    test "call_stack is restored to empty after an __index dispatch on the forced-lazy path" do
      code = """
      local t = setmetatable({}, {__index = function(self, k) local _ = 1 and 2 return 5 end})
      local function outer() local _ = 1 and 2 return t.foo end
      return outer()
      """

      assert {:ok, [5], state} = run(code)
      assert state.call_stack == []
      assert state.call_depth == 0
    end
  end

  describe "generic_for iterator dispatch materializes the executor stack" do
    # `call_iterator/6` materializes the lazy `frames` into `state.call_stack`
    # for a `for _ in iter, ... do` iterator call. The iterator can read the
    # live stack via `debug.*`, so the enclosing `for`-loop frame must be
    # visible — and the inherited stack restored afterward.

    test "debug.traceback inside the iterator sees the enclosing frame" do
      code = """
      local function iter(s, c)
        if c < 1 then return c + 1, debug.traceback("it") end
      end
      function driver()
        for _, v in iter, nil, 0 do
          return v
        end
      end
      return driver()
      """

      assert run!(code) == ["it\nstack traceback:\n\ttest.lua:9: in ?"]
    end

    test "debug.traceback inside the iterator on the forced-lazy path" do
      code = """
      local function iter(s, c)
        local _ = 1 and 2
        if c < 1 then return c + 1, debug.traceback("it") end
      end
      function driver()
        local _ = 1 and 2
        for _, v in iter, nil, 0 do
          return v
        end
      end
      return driver()
      """

      assert run!(code) == ["it\nstack traceback:\n\ttest.lua:11: in ?"]
    end

    test "call_stack is restored to empty after a generic_for loop on the forced-lazy path" do
      code = """
      local function iter(s, c)
        local _ = 1 and 2
        if c < 1 then return c + 1, c end
      end
      local function driver()
        local _ = 1 and 2
        local sum = 0
        for _, v in iter, nil, 0 do sum = sum + v end
        return sum
      end
      return driver()
      """

      assert {:ok, [0], state} = run(code)
      assert state.call_stack == []
      assert state.call_depth == 0
    end
  end

  describe "error tracebacks materialize the executor stack" do
    test "attempt to call a nil value from a nested call" do
      code = """
      function outer()
        return inner()
      end
      function inner()
        return notafunction()
      end
      return outer()
      """

      assert_raise LuaTypeError, ~r/attempt to call a nil value \(global 'notafunction'\)/, fn ->
        run(code)
      end
    end

    test "attempt to call a nil value from a nested call on the forced-lazy path" do
      code = """
      function outer()
        local _ = 1 and 2
        return inner()
      end
      function inner()
        local _ = 1 and 2
        return notafunction()
      end
      return outer()
      """

      assert_raise LuaTypeError, ~r/attempt to call a nil value \(global 'notafunction'\)/, fn ->
        run(code)
      end
    end
  end

  describe "call_stack stays balanced" do
    test "is empty after a successful nested-call program" do
      code = """
      local function nested() return 42 end
      local function outer() return nested() end
      return outer()
      """

      assert {:ok, [42], state} = run(code)
      assert state.call_stack == []
    end

    test "is empty after a program that invokes a native callback mid-stack" do
      # The native `debug.getinfo` call materializes the executor frames into
      # call_stack for its duration; it must be restored afterward.
      code = """
      local function deep()
        debug.getinfo(1, "l")
        return true
      end
      local function outer() return deep() end
      return outer()
      """

      assert {:ok, [true], state} = run(code)
      assert state.call_stack == []
    end

    test "is empty after a native callback mid-stack on the forced-lazy path" do
      # Same as above but the bitwise op forces both functions onto the
      # `:lua_closure` path, where the native-dispatch boundary materializes
      # the lazy `frames` into call_stack and must restore the inherited
      # (empty) stack afterward.
      code = """
      local function deep()
        local _ = 1 and 2
        debug.getinfo(1, "l")
        return true
      end
      local function outer() local _ = 1 and 2 return deep() end
      return outer()
      """

      assert {:ok, [true], state} = run(code)
      assert state.call_stack == []
      assert state.call_depth == 0
    end

    test "call_depth returns to zero after recursion" do
      code = """
      local fact
      fact = function(n)
        if n <= 1 then return 1 else return n * fact(n - 1) end
      end
      return fact(6)
      """

      assert {:ok, [720], state} = run(code)
      assert state.call_depth == 0
      assert state.call_stack == []
    end
  end

  describe "max_call_depth still fires off the O(1) counter" do
    test "recursion past the limit raises stack overflow" do
      code = """
      local function rec(n) return rec(n + 1) end
      return rec(0)
      """

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = %{Stdlib.install(State.new()) | max_call_depth: 50}

      assert_raise LuaRuntimeError, ~r/stack overflow/, fn ->
        VM.execute(proto, state)
      end
    end
  end
end
