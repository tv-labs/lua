defmodule Lua.VM.NumericForTest do
  @moduledoc """
  Pins the Lua 5.3 §3.3.5 contract for `for var = init, limit, step` loops.

  Per the spec, the three control values are evaluated once and converted
  to numbers using the same rules as arithmetic operators. Then:

    * If both init and step are integers (after coercion), the loop runs
      with integers.
    * Otherwise, init is promoted to float and the loop runs with floats.

  This module locks down string-to-number coercion of the control values
  and the int/float typing of the loop variable.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.TypeError

  defp run!(code) do
    {results, _state} = Lua.eval!(Lua.new(), code)
    results
  end

  defp execute(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    VM.execute(proto, State.new())
  end

  describe "string control values are coerced to numbers" do
    # nextvar.lua line 510: `for i="10","1","-2" do a=a+1 end; assert(a==5)`
    test "all-string integer init/limit/step (nextvar.lua line 510)" do
      code = ~S"""
      local a = 0
      for i = "10", "1", "-2" do a = a + 1 end
      return a
      """

      assert run!(code) == [5]
    end

    test "string init counts upward with default step" do
      code = ~S"""
      local sum = 0
      for i = "1", 5 do sum = sum + i end
      return sum
      """

      assert run!(code) == [15]
    end

    test "string limit is coerced to a number" do
      code = ~S"""
      local sum = 0
      for i = 1, "10" do sum = sum + i end
      return sum
      """

      assert run!(code) == [55]
    end

    test "string step is coerced to a number" do
      code = ~S"""
      local count = 0
      for i = 10, 0, "-2" do count = count + 1 end
      return count
      """

      assert run!(code) == [6]
    end

    test "string with surrounding whitespace coerces (matches arithmetic rule)" do
      # Lua 5.3 tonumber accepts leading/trailing whitespace; the for-loop
      # coercion rule is the same as the arithmetic operator rule, which
      # delegates to the same parser.
      code = ~S"""
      local count = 0
      for i = 0, " -3.4  ", -1 do count = count + 1 end
      return count
      """

      assert run!(code) == [4]
    end
  end

  describe "float/integer typing of the loop variable" do
    test "integer init and integer step keep the loop variable an integer" do
      code = ~S"""
      local out = {}
      for i = 1, 3 do out[#out + 1] = math.type(i) end
      return out[1], out[2], out[3]
      """

      assert run!(code) == ["integer", "integer", "integer"]
    end

    test "float init promotes the loop variable to float" do
      code = ~S"""
      local out = {}
      for i = 1.0, 3 do out[#out + 1] = math.type(i) end
      return out[1], out[2], out[3]
      """

      assert run!(code) == ["float", "float", "float"]
    end

    test "float step promotes the loop variable to float" do
      code = ~S"""
      local out = {}
      for i = -1, -3, -1.0 do out[#out + 1] = math.type(i) end
      return out[1], out[2], out[3]
      """

      assert run!(code) == ["float", "float", "float"]
    end

    test "string-to-float init promotes the loop variable to float" do
      code = ~S"""
      local out = {}
      for i = "1.0", 3 do out[#out + 1] = math.type(i) end
      return out[1], out[2], out[3]
      """

      assert run!(code) == ["float", "float", "float"]
    end

    test "string-to-int init keeps the loop variable an integer" do
      code = ~S"""
      local out = {}
      for i = "1", 3 do out[#out + 1] = math.type(i) end
      return out[1], out[2], out[3]
      """

      assert run!(code) == ["integer", "integer", "integer"]
    end

    test "string-to-float limit does not affect typing of loop variable" do
      # Lua 5.3 §3.3.5: the limit's type does not affect the int/float
      # rule. Only init and step matter. nextvar.lua line 540.
      code = ~S"""
      local out = {}
      for i = 1, "10.8" do out[#out + 1] = math.type(i) end
      return #out, out[1], out[10]
      """

      assert run!(code) == [10, "integer", "integer"]
    end
  end

  describe "non-coercible control values raise TypeError" do
    test "non-numeric string init raises with reference message" do
      code = ~S"""
      for i = "abc", 5 do end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      assert_raise TypeError, ~r/'for' initial value must be a number/, fn ->
        VM.execute(proto, State.new())
      end
    end

    test "non-numeric string limit raises with reference message" do
      code = ~S"""
      for i = 1, "abc" do end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      assert_raise TypeError, ~r/'for' limit must be a number/, fn ->
        VM.execute(proto, State.new())
      end
    end

    test "non-numeric string step raises with reference message" do
      code = ~S"""
      for i = 1, 5, "abc" do end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      assert_raise TypeError, ~r/'for' step must be a number/, fn ->
        VM.execute(proto, State.new())
      end
    end

    test "nil init raises a number-required TypeError" do
      code = ~S"""
      local x
      for i = x, 5 do end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      assert_raise TypeError, ~r/'for' initial value must be a number/, fn ->
        VM.execute(proto, State.new())
      end
    end

    test "boolean step raises a number-required TypeError" do
      code = ~S"""
      for i = 1, 5, true do end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      assert_raise TypeError, ~r/'for' step must be a number/, fn ->
        VM.execute(proto, State.new())
      end
    end
  end

  describe "coercion happens once at loop start" do
    # Coercion is a one-shot at loop entry, not per iteration. This is
    # observable: if we somehow re-coerced on each iteration, mutating the
    # control register from inside the body would change things — but the
    # internal counter/limit/step are register-private to the loop, not
    # observable from inside the body. We can still pin that the loop
    # produces a stable count when the body returns large objects.
    test "loop count matches even when body allocates and assigns" do
      code = ~S"""
      local count = 0
      for i = "1", "100" do
        local t = { foo = i }
        count = count + 1
      end
      return count
      """

      assert {:ok, [100], _state} = execute(code)
    end
  end
end
