defmodule Lua.VM.PcallStatePreservationTest do
  @moduledoc """
  Pins Lua 5.3 §2.3 / §6.1 protected-call semantics: `pcall`/`xpcall` trap
  the error and unwind the stack, but heap effects performed before the
  error — global writes, table field mutations, upvalue assignments,
  metatable changes — are kept, never rolled back.

  Reference behavior (PUC Lua 5.3):

      $ lua -e 'x = 1; pcall(function() x = 2; error("boom") end); print(x)'
      2

  Each case runs under both execution engines: the default compile path
  (closures carry bytecode and run on the dispatcher) and with bytecode
  recursively stripped (closures run on the instruction interpreter).
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp run(code, engine, state_fun \\ &Function.identity/1) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")

    proto =
      case engine do
        :compiled -> proto
        :interpreted -> strip_bytecode(proto)
      end

    state = state_fun.(Stdlib.install(State.new()))
    {:ok, results, state} = VM.execute(proto, state)
    {results, state}
  end

  # Forces every closure onto the instruction interpreter — the closure
  # tag flips on `proto.bytecode`, so stripping it recursively keeps the
  # whole program off the dispatcher.
  defp strip_bytecode(%Prototype{} = proto) do
    %{proto | bytecode: nil, prototypes: Enum.map(proto.prototypes, &strip_bytecode/1)}
  end

  for engine <- [:compiled, :interpreted] do
    @engine engine

    describe "pcall keeps heap effects on error (#{engine} engine)" do
      test "global write before error() is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok, err = pcall(function()
              x = 2
              error("boom")
            end)
            return x, ok, err
            """,
            @engine
          )

        assert [2, false, err] = results
        assert err =~ "boom"
      end

      test "table field write before error() is kept" do
        {results, _state} =
          run(
            """
            local t = {}
            local ok = pcall(function()
              t.a = 1
              error("e")
            end)
            return t.a, ok
            """,
            @engine
          )

        assert [1, false] = results
      end

      test "upvalue write before error() is kept" do
        {results, _state} =
          run(
            """
            local v = 1
            local ok = pcall(function()
              v = 2
              error("e")
            end)
            return v, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "global write before an arithmetic type error is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok = pcall(function()
              x = 2
              return nil + 1
            end)
            return x, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "table write before an index-nil error is kept" do
        {results, _state} =
          run(
            """
            local t = {}
            local ok = pcall(function()
              t.a = 1
              local y = nil
              return y.field
            end)
            return t.a, ok
            """,
            @engine
          )

        assert [1, false] = results
      end

      test "global write before a concat type error is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok = pcall(function()
              x = 2
              return "a" .. nil
            end)
            return x, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "global write before assert(false) is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok = pcall(function()
              x = 2
              assert(false)
            end)
            return x, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "global write before a stdlib bad-argument error is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok = pcall(function()
              x = 2
              return string.rep()
            end)
            return x, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "gsub callback heap mutation before an invalid-return error is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok = pcall(function()
              return string.gsub("ab", ".", function(c)
                x = 2
                return {}
              end)
            end)
            return x, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "table.sort comparator mutation before its error is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local t = {3, 1, 2}
            local ok = pcall(function()
              table.sort(t, function(a, b)
                x = 2
                error("bad comparator")
              end)
            end)
            return x, ok
            """,
            @engine
          )

        assert [2, false] = results
      end

      test "pairs loop-body mutation before its error is kept" do
        {results, _state} =
          run(
            """
            x = 0
            local t = {a = 1, b = 2}
            local ok = pcall(function()
              for _k, _v in pairs(t) do
                x = x + 1
                error("loop")
              end
            end)
            return x, ok
            """,
            @engine
          )

        assert [1, false] = results
      end

      test "mutation before error() with a table error object is kept" do
        {results, _state} =
          run(
            """
            x = 1
            local ok, err = pcall(function()
              x = 2
              error({code = 1})
            end)
            return x, ok, err ~= nil
            """,
            @engine
          )

        assert [2, false, true] = results
      end

      test "nested pcall keeps mutations at every level" do
        {results, _state} =
          run(
            """
            local ok_outer = pcall(function()
              a = 1
              local ok_inner = pcall(function()
                b = 2
                error("inner")
              end)
              c = ok_inner == false and 3 or -1
              error("outer")
            end)
            return a, b, c, ok_outer
            """,
            @engine
          )

        assert [1, 2, 3, false] = results
      end

      test "setmetatable before error is kept" do
        {results, _state} =
          run(
            """
            local t = {}
            local ok = pcall(function()
              setmetatable(t, {__index = function() return 42 end})
              error("e")
            end)
            return ok, t.missing
            """,
            @engine
          )

        assert [false, 42] = results
      end

      test "call stack unwinds cleanly after recursion errors under pcall" do
        {results, state} =
          run(
            """
            x = 0
            local function deep(n)
              x = x + 1
              if n == 0 then error("bottom") end
              deep(n - 1)
            end
            local ok = pcall(deep, 5)
            local function f() return x end
            return ok, f(), x
            """,
            @engine
          )

        assert [false, 6, 6] = results
        # No leaked frames from the unwound protected call.
        assert state.call_depth == 0
        assert state.call_stack == []
      end

      test "closure captured before pcall still reads the kept upvalue after" do
        {results, _state} =
          run(
            """
            local v = 1
            local function get() return v end
            local function set(n) v = n end
            local ok = pcall(function()
              set(2)
              error("e")
            end)
            return ok, get(), v
            """,
            @engine
          )

        assert [false, 2, 2] = results
      end

      test "mutations before a stack-overflow error are kept" do
        {results, _state} =
          run(
            """
            x = 0
            local function loop()
              x = x + 1
              loop()
              return 1
            end
            local ok = pcall(loop)
            return ok, x > 1
            """,
            @engine,
            fn state -> %{state | max_call_depth: 30} end
          )

        assert [false, true] = results
      end

      test "pcall that errors without mutating leaves prior state untouched" do
        {results, _state} =
          run(
            """
            z = 9
            local ok = pcall(function()
              error("e")
            end)
            return z, ok
            """,
            @engine
          )

        assert [9, false] = results
      end

      test "pcall success path is unchanged" do
        {results, _state} =
          run(
            """
            x = 1
            local ok, v = pcall(function()
              x = 2
              return 7
            end)
            return x, ok, v
            """,
            @engine
          )

        assert [2, true, 7] = results
      end
    end

    describe "xpcall keeps heap effects on error (#{engine} engine)" do
      test "message handler observes mutations made before the error" do
        {results, _state} =
          run(
            """
            x = 1
            local ok, seen = xpcall(function()
              x = 2
              error("e")
            end, function(msg)
              return x
            end)
            return ok, seen, x
            """,
            @engine
          )

        assert [false, 2, 2] = results
      end

      test "mutations are kept even when the handler itself errors" do
        {results, _state} =
          run(
            """
            x = 1
            local ok = xpcall(function()
              x = 2
              error("first")
            end, function(msg)
              h = 5
              error("handler")
            end)
            return x, h, ok
            """,
            @engine
          )

        assert [2, 5, false] = results
      end
    end
  end

  describe "Elixir API error path" do
    test "Lua.call_function/3 returns state retaining pre-error mutations" do
      lua = Lua.new()

      {_, lua} =
        Lua.eval!(lua, """
        x = 1
        function f()
          x = 2
          error("boom")
        end
        """)

      assert {:error, reason, lua} = Lua.call_function(lua, [:f], [])
      assert reason =~ "boom"
      assert Lua.get!(lua, [:x]) == 2
    end
  end
end
