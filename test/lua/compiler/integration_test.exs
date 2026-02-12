defmodule Lua.Compiler.IntegrationTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.AssertionError
  alias Lua.VM.Stdlib
  alias Lua.VM.TypeError
  alias Lua.VM.Value

  describe "end-to-end compilation and execution" do
    test "return 42" do
      code = "return 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "return true" do
      code = "return true"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return false" do
      code = "return false"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "return nil" do
      code = "return nil"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end

    test "return string" do
      code = ~s[return "hello world"]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["hello world"]
    end

    test "return 3.14" do
      code = "return 3.14"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3.14]
    end
  end

  describe "arithmetic operations" do
    test "return 2 + 3" do
      code = "return 2 + 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end

    test "return 2 + 3 * 4" do
      code = "return 2 + 3 * 4"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [14]
    end

    test "return 10 - 3" do
      code = "return 10 - 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [7]
    end

    test "return 6 * 7" do
      code = "return 6 * 7"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "return 10 / 2" do
      code = "return 10 / 2"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5.0]
    end

    test "return 10 // 3" do
      code = "return 10 // 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "return 10 % 3" do
      code = "return 10 % 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "return 2 ^ 8" do
      code = "return 2 ^ 8"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [256.0]
    end

    test "return -5" do
      code = "return -5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [-5]
    end
  end

  describe "comparison operations" do
    test "return 5 == 5" do
      code = "return 5 == 5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return 5 == 6" do
      code = "return 5 == 6"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "return 3 < 5" do
      code = "return 3 < 5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return 5 <= 5" do
      code = "return 5 <= 5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end
  end

  describe "bitwise operations" do
    test "return 5 & 3" do
      code = "return 5 & 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "return 5 | 3" do
      code = "return 5 | 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [7]
    end

    test "return 5 ~ 3" do
      code = "return 5 ~ 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [6]
    end

    test "return 1 << 3" do
      code = "return 1 << 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [8]
    end

    test "return 8 >> 2" do
      code = "return 8 >> 2"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [2]
    end

    test "return ~5" do
      code = "return ~5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [-6]
    end
  end

  describe "logical operations" do
    test "return not true" do
      code = "return not true"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "return not false" do
      code = "return not false"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return not nil" do
      code = "return not nil"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return not 5" do
      code = "return not 5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end
  end

  describe "string operations" do
    test "return #'hello'" do
      code = "return #'hello'"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end

    test "string concatenation" do
      code = ~s[return "hello" .. " " .. "world"]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["hello world"]
    end

    test "string concatenation with number coercion" do
      code = ~s[return "count: " .. 42]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["count: 42"]
    end

    test "concatenation of two numbers" do
      code = "return 1 .. 2"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["12"]
    end

    test "chained concatenation" do
      code = ~s[return "x" .. "y" .. "z"]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["xyz"]
    end
  end

  describe "global variables" do
    test "assign and return global variable" do
      code = "x = 42\nreturn x"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, state} = VM.execute(proto)

      assert results == [42]
      assert state.globals["x"] == 42
    end

    test "multiple global assignments" do
      code = "a = 1\nb = 2\nreturn a + b"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, state} = VM.execute(proto)

      assert results == [3]
      assert state.globals["a"] == 1
      assert state.globals["b"] == 2
    end

    test "reassign global variable" do
      code = "x = 10\nx = x + 5\nreturn x"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [15]
    end

    test "undefined global returns nil" do
      code = "return undefined_var"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end

    test "global with arithmetic expression" do
      code = "result = 2 * 3 + 4\nreturn result"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [10]
    end
  end

  describe "local variables" do
    test "simple local variable" do
      code = "local x = 42\nreturn x"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "local variable with arithmetic" do
      code = "local x = 1\nreturn x + 2"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "multiple local variables" do
      code = "local a = 5\nlocal b = 3\nreturn a * b"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [15]
    end

    test "local variable reassignment via new declaration" do
      code = "local x = 10\nlocal x = 20\nreturn x"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [20]
    end

    test "local variable with expression" do
      code = "local x = 2 + 3\nreturn x * 4"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [20]
    end

    test "multiple locals in one declaration" do
      code = "local a, b = 1, 2\nreturn a + b"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "local with fewer values than names (implicit nil)" do
      code = "local a, b = 1\nreturn b"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end
  end

  describe "conditionals" do
    test "simple if-then" do
      code = "if true then return 1 end"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "if-then-else (true)" do
      code = "if true then return 1 else return 2 end"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "if-then-else (false)" do
      code = "if false then return 1 else return 2 end"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [2]
    end

    test "if with comparison" do
      code = "local x = 5\nif x > 3 then return 10 else return 20 end"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [10]
    end

    test "if-elseif-else" do
      code = """
      local x = 2
      if x == 1 then
        return 100
      elseif x == 2 then
        return 200
      elseif x == 3 then
        return 300
      else
        return 400
      end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [200]
    end

    test "nested if statements" do
      code = """
      local x = 5
      if x > 0 then
        if x > 10 then
          return 1
        else
          return 2
        end
      else
        return 3
      end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [2]
    end
  end

  describe "short-circuit operators" do
    test "and operator (both true)" do
      code = "return true and 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "and operator (first false)" do
      code = "return false and 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "and operator (first nil)" do
      code = "return nil and 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end

    test "or operator (first true)" do
      code = "return true or 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "or operator (first false)" do
      code = "return false or 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "or operator (first nil)" do
      code = "return nil or 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "chained and operators" do
      code = "return 1 and 2 and 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "chained or operators" do
      code = "return nil or false or 5"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end

    test "mixed and/or operators" do
      code = "return false and 10 or 20"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [20]
    end
  end

  describe "while loops" do
    test "simple while loop" do
      code = """
      local i = 0
      while i < 5 do
        i = i + 1
      end
      return i
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end

    test "while loop with sum" do
      code = """
      local sum = 0
      local i = 1
      while i <= 10 do
        sum = sum + i
        i = i + 1
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [55]
    end

    test "while loop never executes" do
      code = """
      local x = 0
      while false do
        x = x + 1
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [0]
    end
  end

  describe "repeat loops" do
    test "simple repeat loop" do
      code = """
      local i = 0
      repeat
        i = i + 1
      until i >= 5
      return i
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end

    test "repeat executes at least once" do
      code = """
      local x = 0
      repeat
        x = x + 1
      until true
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end
  end

  describe "numeric for loops" do
    test "simple for loop" do
      code = """
      local sum = 0
      for i = 1, 10 do
        sum = sum + i
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [55]
    end

    test "for loop with step" do
      code = """
      local sum = 0
      for i = 1, 10, 2 do
        sum = sum + i
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      # 1 + 3 + 5 + 7 + 9
      assert results == [25]
    end

    test "for loop counting down" do
      code = """
      local sum = 0
      for i = 10, 1, -1 do
        sum = sum + i
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [55]
    end

    test "for loop with zero iterations" do
      code = """
      local x = 0
      for i = 10, 1 do
        x = x + 1
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [0]
    end

    test "for loop variable" do
      code = """
      local last = 0
      for i = 1, 5 do
        last = i
      end
      return last
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end
  end

  describe "functions" do
    test "simple function definition and call" do
      code = """
      local f = function(x)
        return x + 1
      end
      return f(5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [6]
    end

    test "function with multiple parameters" do
      code = """
      local add = function(a, b)
        return a + b
      end
      return add(3, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [7]
    end

    test "function with no parameters" do
      code = """
      local f = function()
        return 42
      end
      return f()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "function modifying globals" do
      code = """
      x = 10
      local double = function()
        x = x * 2
      end
      double()
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [20]
    end

    test "function called multiple times" do
      code = """
      local counter = 0
      local inc = function()
        counter = counter + 1
      end
      inc()
      inc()
      inc()
      return counter
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "function as argument to another function" do
      code = """
      local apply = function(f, x)
        return f(x)
      end
      local double = function(n)
        return n * 2
      end
      return apply(double, 5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [10]
    end

    test "recursive function via global" do
      code = """
      factorial = function(n)
        if n <= 1 then
          return 1
        end
        return n * factorial(n - 1)
      end
      return factorial(5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [120]
    end

    test "native function call" do
      code = """
      return add(3, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      native_add =
        {:native_func,
         fn args, state ->
           [a, b] = args
           {[a + b], state}
         end}

      state = %Lua.VM.State{globals: %{"add" => native_add}}
      assert {:ok, results, _state} = VM.execute(proto, state)

      assert results == [7]
    end

    test "function returning function" do
      code = """
      local make_adder = function(n)
        return function(x)
          return x + n
        end
      end
      local add5 = make_adder(5)
      return add5(10)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [15]
    end
  end

  describe "tables" do
    test "empty table" do
      code = """
      local t = {}
      return t
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [{:tref, _id}], _state} = VM.execute(proto)
    end

    test "array access" do
      code = """
      local t = {1, 2, 3}
      return t[2]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [2]
    end

    test "field access" do
      code = """
      local t = {a = 1, b = 2}
      return t.a
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "field assignment" do
      code = """
      local t = {}
      t.x = 10
      return t.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [10]
    end

    test "index assignment" do
      code = """
      local t = {}
      t[1] = "a"
      return t[1]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["a"]
    end

    test "table length" do
      code = """
      local t = {1, 2, 3}
      return #t
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "mixed constructor" do
      code = """
      local t = {1, 2, 3, a = 4, ["b"] = 5}
      return t[1] + t[2] + t[3] + t.a + t["b"]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [15]
    end

    test "table as function argument and return value" do
      code = """
      local get_x = function(t)
        return t.x
      end
      local t = {x = 42}
      return get_x(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "nested tables" do
      code = """
      local t = {inner = {x = 1}}
      return t.inner.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "table reference semantics" do
      code = """
      local a = {}
      local b = a
      b.x = 1
      return a.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "method call" do
      code = """
      local obj = {}
      obj.greet = function(self, name)
        return name
      end
      return obj:greet("world")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == ["world"]
    end

    test "computed key access" do
      code = """
      local t = {}
      local key = "hello"
      t[key] = 99
      return t[key]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [99]
    end

    test "table length with gaps" do
      code = """
      local t = {1, 2, 3}
      return #t
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end
  end

  describe "native function calls" do
    test "native function registered via set_global" do
      code = "return double(21)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      state =
        VM.State.register_function(VM.State.new(), "double", fn [n], state -> {[n * 2], state} end)

      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "native function with multiple arguments" do
      code = "return add(10, 20, 30)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      state =
        VM.State.register_function(VM.State.new(), "add", fn args, state ->
          {[Enum.sum(args)], state}
        end)

      assert {:ok, [60], _state} = VM.execute(proto, state)
    end

    test "native function with no arguments" do
      code = "return get_answer()"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      state =
        VM.State.register_function(VM.State.new(), "get_answer", fn _args, state -> {[42], state} end)

      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "native function modifying state" do
      code = """
      set_x(99)
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      state =
        VM.State.register_function(VM.State.new(), "set_x", fn [val], state ->
          {[], VM.State.set_global(state, "x", val)}
        end)

      assert {:ok, [99], _state} = VM.execute(proto, state)
    end

    test "native function receiving table" do
      code = """
      local t = {x = 42}
      return get_field(t, "x")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      state =
        VM.State.register_function(VM.State.new(), "get_field", fn [{:tref, id}, key], state ->
          table = Map.fetch!(state.tables, id)
          {[Map.get(table.data, key)], state}
        end)

      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "native function creating table" do
      code = """
      local t = make_table()
      return t.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      state =
        VM.State.register_function(VM.State.new(), "make_table", fn _args, state ->
          {tref, state} = VM.State.alloc_table(state, %{"x" => 100})
          {[tref], state}
        end)

      assert {:ok, [100], _state} = VM.execute(proto, state)
    end

    test "calling nil value raises" do
      code = "return foo()"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      assert_raise TypeError, ~r/attempt to call a nil value/, fn ->
        VM.execute(proto)
      end
    end

    test "calling number value raises" do
      code = """
      local x = 42
      return x()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      assert_raise TypeError, ~r/attempt to call a number value/, fn ->
        VM.execute(proto)
      end
    end
  end

  describe "standard library" do
    setup do
      state = Stdlib.install(VM.State.new())
      {:ok, state: state}
    end

    test "type() on various values", %{state: state} do
      tests = [
        {"return type(42)", "number"},
        {"return type(3.14)", "number"},
        {~s[return type("hello")], "string"},
        {"return type(true)", "boolean"},
        {"return type(nil)", "nil"},
        {"return type({})", "table"},
        {"return type(type)", "function"}
      ]

      for {code, expected} <- tests do
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast)
        assert {:ok, [^expected], _state} = VM.execute(proto, state), "type() failed for: #{code}"
      end
    end

    test "tostring() converts values", %{state: state} do
      tests = [
        {"return tostring(42)", "42"},
        {"return tostring(nil)", "nil"},
        {"return tostring(true)", "true"},
        {"return tostring(false)", "false"},
        {~s[return tostring("hello")], "hello"}
      ]

      for {code, expected} <- tests do
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast)

        assert {:ok, [^expected], _state} = VM.execute(proto, state),
               "tostring() failed for: #{code}"
      end
    end

    test "tonumber() converts strings", %{state: state} do
      tests = [
        {~s[return tonumber("42")], 42},
        {~s[return tonumber("3.14")], 3.14},
        {"return tonumber(42)", 42},
        {~s[return tonumber("hello")], nil},
        {~s[return tonumber("0xff")], 255}
      ]

      for {code, expected} <- tests do
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast)

        assert {:ok, [^expected], _state} = VM.execute(proto, state),
               "tonumber() failed for: #{code}"
      end
    end

    test "tonumber() with base", %{state: state} do
      code = ~s[return tonumber("ff", 16)]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [255], _state} = VM.execute(proto, state)
    end

    test "print() outputs to console", %{state: state} do
      code = ~s[print("hello", "world")]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          VM.execute(proto, state)
        end)

      assert output == "hello\tworld\n"
    end

    test "error() raises", %{state: state} do
      code = ~s[error("something went wrong")]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      assert_raise Lua.VM.RuntimeError, ~r/runtime error: something went wrong/, fn ->
        VM.execute(proto, state)
      end
    end

    test "assert() passes with truthy value", %{state: state} do
      code = "return assert(42)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "assert() raises with falsy value", %{state: state} do
      code = ~s[assert(false, "expected true")]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      assert_raise AssertionError, ~r/assertion failed: expected true/, fn ->
        VM.execute(proto, state)
      end
    end

    test "assert() raises default message with nil", %{state: state} do
      code = "assert(nil)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)

      assert_raise AssertionError, ~r/assertion failed: assertion failed!/, fn ->
        VM.execute(proto, state)
      end
    end

    test "rawget() accesses table fields", %{state: state} do
      code = """
      local t = {x = 42}
      return rawget(t, "x")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "rawset() sets table fields", %{state: state} do
      code = """
      local t = {}
      rawset(t, "x", 99)
      return t.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [99], _state} = VM.execute(proto, state)
    end

    test "rawlen() returns sequence length", %{state: state} do
      code = """
      local t = {1, 2, 3, 4, 5}
      return rawlen(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [5], _state} = VM.execute(proto, state)
    end

    test "rawlen() on string", %{state: state} do
      code = ~s[return rawlen("hello")]

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [5], _state} = VM.execute(proto, state)
    end

    test "rawequal() compares values", %{state: state} do
      code = "return rawequal(1, 1)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [true], _state} = VM.execute(proto, state)
    end

    test "rawequal() returns false for different values", %{state: state} do
      code = "return rawequal(1, 2)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [false], _state} = VM.execute(proto, state)
    end

    test "native function as callback from Lua", %{state: state} do
      code = """
      local apply = function(f, x)
        return f(x)
      end
      return apply(tostring, 42)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, ["42"], _state} = VM.execute(proto, state)
    end

    test "chaining stdlib calls", %{state: state} do
      code = """
      local t = {1, 2, 3}
      return rawlen(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3], _state} = VM.execute(proto, state)
    end

    test "next() returns first key for non-empty table", %{state: state} do
      code = """
      local t = {a = 1}
      local k = next(t)
      return k
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, ["a"], _state} = VM.execute(proto, state)
    end

    test "next() returns nil for empty table", %{state: state} do
      code = """
      local t = {}
      local k = next(t)
      return k
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "ipairs() iterates sequential keys", %{state: state} do
      code = """
      local sum = 0
      for i, v in ipairs({10, 20, 30}) do
        sum = sum + v
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [60], _state} = VM.execute(proto, state)
    end

    test "pairs() iterates all entries", %{state: state} do
      code = """
      local sum = 0
      for k, v in pairs({a = 1, b = 2}) do
        sum = sum + v
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3], _state} = VM.execute(proto, state)
    end

    test "pairs() on empty table does nothing", %{state: state} do
      code = """
      local count = 0
      for k, v in pairs({}) do
        count = count + 1
      end
      return count
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [0], _state} = VM.execute(proto, state)
    end
  end

  describe "multiple returns" do
    test "return multiple values" do
      code = "return 1, 2, 3"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2, 3], _state} = VM.execute(proto)
    end

    test "return multiple expressions" do
      code = "return 1 + 2, 3 * 4"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3, 12], _state} = VM.execute(proto)
    end
  end

  describe "varargs" do
    test "function(...) return ... end" do
      code = """
      local f = function(...)
        return ...
      end
      return f(1, 2, 3)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2, 3], _state} = VM.execute(proto)
    end

    test "function(a, b, ...) return ... end" do
      code = """
      local f = function(a, b, ...)
        return ...
      end
      return f(1, 2, 3, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3, 4], _state} = VM.execute(proto)
    end

    test "vararg in local assignment" do
      code = """
      local f = function(...)
        local x = ...
        return x
      end
      return f(1, 2, 3)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1], _state} = VM.execute(proto)
    end
  end

  describe "generic for loops" do
    setup do
      state = Stdlib.install(VM.State.new())
      {:ok, state: state}
    end

    test "for i, v in ipairs({10, 20, 30})", %{state: state} do
      code = """
      local sum = 0
      for i, v in ipairs({10, 20, 30}) do
        sum = sum + v
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [60], _state} = VM.execute(proto, state)
    end

    test "for k, v in pairs({a=1, b=2})", %{state: state} do
      code = """
      local sum = 0
      for k, v in pairs({a = 1, b = 2}) do
        sum = sum + v
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3], _state} = VM.execute(proto, state)
    end

    test "generic for on empty table", %{state: state} do
      code = """
      local count = 0
      for k, v in pairs({}) do
        count = count + 1
      end
      return count
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [0], _state} = VM.execute(proto, state)
    end

    test "ipairs collects indices and values", %{state: state} do
      code = """
      local keys = 0
      local vals = 0
      for i, v in ipairs({10, 20, 30}) do
        keys = keys + i
        vals = vals + v
      end
      return keys, vals
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [6, 60], _state} = VM.execute(proto, state)
    end

    test "generic for with single variable", %{state: state} do
      code = """
      local count = 0
      for k in pairs({a = 1, b = 2, c = 3}) do
        count = count + 1
      end
      return count
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3], _state} = VM.execute(proto, state)
    end
  end

  describe "value encode/decode round-trip" do
    test "encode Elixir map as global, execute Lua, decode result" do
      # Encode an Elixir map into state as a global
      state = Stdlib.install(VM.State.new())
      {tref, state} = Value.encode(%{x: 10, y: 20}, state)
      state = VM.State.set_global(state, "config", tref)

      # Execute Lua code that reads from the encoded table
      code = "return config.x + config.y"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [30], _state} = VM.execute(proto, state)
    end

    test "encode list as global, iterate in Lua, decode result" do
      state = Stdlib.install(VM.State.new())
      {tref, state} = Value.encode([10, 20, 30], state)
      state = VM.State.set_global(state, "items", tref)

      code = """
      local sum = 0
      for i, v in ipairs(items) do
        sum = sum + v
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [60], _state} = VM.execute(proto, state)
    end

    test "Lua produces table, decode to Elixir" do
      state = Stdlib.install(VM.State.new())

      code = """
      local t = {a = 1, b = 2}
      return t
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [tref], state} = VM.execute(proto, state)

      decoded = Value.decode(tref, state)
      assert Enum.sort(decoded) == [{"a", 1}, {"b", 2}]
    end
  end

  describe "local function declarations" do
    test "basic local function" do
      code = """
      local function add(a, b)
        return a + b
      end
      return add(3, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [7]
    end

    test "local function with closure" do
      code = """
      local function make_counter()
        local count = 0
        local function increment()
          count = count + 1
          return count
        end
        return increment
      end
      local counter = make_counter()
      return counter(), counter(), counter()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1, 2, 3]
    end

    test "local function recursive (requires self-reference upvalue support)" do
      code = """
      local function factorial(n)
        if n <= 1 then
          return 1
        else
          return n * factorial(n - 1)
        end
      end
      return factorial(5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [120]
    end

    test "local function can be reassigned" do
      code = """
      local function f()
        return 1
      end
      local x = f()
      f = function() return 2 end
      local y = f()
      return x, y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1, 2]
    end
  end

  describe "do...end blocks" do
    test "basic do block" do
      code = """
      local x = 1
      do
        local y = 2
        x = x + y
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "do block creates new scope (requires proper scope cleanup)" do
      code = """
      local x = 1
      do
        local x = 2
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "nested do blocks" do
      code = """
      local x = 1
      do
        x = 2
        do
          x = 3
        end
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "empty do block" do
      code = """
      local x = 1
      do
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "do block with return" do
      code = """
      do
        return 42
      end
      return 99
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end
  end

  describe "multi-assignment" do
    test "basic multi-assignment" do
      code = """
      local a, b, c
      a, b, c = 1, 2, 3
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2, 3], _state} = VM.execute(proto)
    end

    test "more targets than values fills with nil" do
      code = """
      local a, b, c
      a, b, c = 1, 2
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2, nil], _state} = VM.execute(proto)
    end

    test "more values than targets discards extras" do
      code = """
      local a, b
      a, b = 1, 2, 3
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2], _state} = VM.execute(proto)
    end

    @tag :skip
    test "multi-assign evaluates all RHS before assigning (swap)" do
      # Lua semantics require all RHS to be evaluated before any assignment.
      # This requires snapshotting RHS values into temp registers.
      code = """
      local a, b = 10, 20
      a, b = b, a
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [20, 10], _state} = VM.execute(proto)
    end

    test "multi-assign with global variables" do
      code = """
      a, b = 10, 20
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 20], _state} = VM.execute(proto)
    end

    test "multi-assign to table fields" do
      code = """
      local t = {}
      t.x, t.y = 1, 2
      return t.x, t.y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2], _state} = VM.execute(proto)
    end

    test "multi-assign to table indices" do
      code = """
      local t = {}
      t[1], t[2], t[3] = 10, 20, 30
      return t[1], t[2], t[3]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 20, 30], _state} = VM.execute(proto)
    end

    test "multi-assign with function call expanding multiple returns" do
      code = """
      local function two_vals()
        return 10, 20
      end
      local a, b
      a, b = two_vals()
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 20], _state} = VM.execute(proto)
    end

    test "multi-assign with call expansion fills remaining targets" do
      code = """
      local function three_vals()
        return 1, 2, 3
      end
      local a, b, c
      a, b, c = three_vals()
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2, 3], _state} = VM.execute(proto)
    end

    test "multi-assign with call in last position and preceding values" do
      code = """
      local function two_vals()
        return 20, 30
      end
      local a, b, c
      a, b, c = 10, two_vals()
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 20, 30], _state} = VM.execute(proto)
    end

    test "multi-assign with single value to multiple targets" do
      code = """
      local a, b, c
      a, b, c = 42
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [42, nil, nil], _state} = VM.execute(proto)
    end
  end

  describe "local multi-assignment with multiple returns" do
    test "local multi-assign with function returning multiple values" do
      code = """
      local function two_vals()
        return 10, 20
      end
      local a, b = two_vals()
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 20], _state} = VM.execute(proto)
    end

    test "local multi-assign with call expanding to fill all names" do
      code = """
      local function three_vals()
        return 1, 2, 3
      end
      local a, b, c = three_vals()
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2, 3], _state} = VM.execute(proto)
    end

    test "local multi-assign: preceding values plus call expansion" do
      code = """
      local function two_vals()
        return 20, 30
      end
      local a, b, c = 10, two_vals()
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 20, 30], _state} = VM.execute(proto)
    end

    test "local multi-assign: call returns fewer than needed fills nil" do
      code = """
      local function one_val()
        return 42
      end
      local a, b, c = one_val()
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [42, nil, nil], _state} = VM.execute(proto)
    end

    test "local multi-assign: call not in last position is truncated to one" do
      code = """
      local function two_vals()
        return 10, 20
      end
      local a, b = two_vals(), 99
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10, 99], _state} = VM.execute(proto)
    end

    test "local multi-assign: excess return values are discarded" do
      code = """
      local function three_vals()
        return 1, 2, 3
      end
      local a, b = three_vals()
      return a, b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1, 2], _state} = VM.execute(proto)
    end

    test "local multi-assign followed by more code" do
      code = """
      local function vals()
        return 10, 20
      end
      local a, b = vals()
      local c = a + b
      return c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [30], _state} = VM.execute(proto)
    end
  end

  describe "break statement" do
    test "break exits while loop" do
      code = """
      local i = 0
      while true do
        i = i + 1
        if i == 5 then break end
      end
      return i
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [5], _state} = VM.execute(proto)
    end

    test "break exits repeat loop" do
      code = """
      local i = 0
      repeat
        i = i + 1
        if i == 3 then break end
      until false
      return i
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [3], _state} = VM.execute(proto)
    end

    test "break exits numeric for loop" do
      code = """
      local last = 0
      for i = 1, 100 do
        last = i
        if i == 7 then break end
      end
      return last
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [7], _state} = VM.execute(proto)
    end

    test "break exits generic for loop", %{} do
      state = Stdlib.install(VM.State.new())

      code = """
      local sum = 0
      for i, v in ipairs({10, 20, 30, 40, 50}) do
        sum = sum + v
        if i == 3 then break end
      end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [60], _state} = VM.execute(proto, state)
    end

    test "break only exits innermost loop" do
      code = """
      local total = 0
      for i = 1, 3 do
        for j = 1, 10 do
          if j > 2 then break end
          total = total + 1
        end
      end
      return total
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [6], _state} = VM.execute(proto)
    end

    test "break inside if-else within loop" do
      code = """
      local x = 0
      for i = 1, 10 do
        if i > 5 then
          break
        else
          x = x + i
        end
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      # 1+2+3+4+5 = 15
      assert {:ok, [15], _state} = VM.execute(proto)
    end

    test "break inside elseif within loop" do
      code = """
      local result = 0
      for i = 1, 100 do
        if i == 3 then
          result = result + 100
        elseif i == 5 then
          break
        else
          result = result + i
        end
      end
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      # i=1: +1, i=2: +2, i=3: +100, i=4: +4, i=5: break
      assert {:ok, [107], _state} = VM.execute(proto)
    end

    test "break with code after loop continues normally" do
      code = """
      local x = 0
      while true do
        x = 10
        break
      end
      x = x + 5
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [15], _state} = VM.execute(proto)
    end

    test "immediate break in loop body" do
      code = """
      local x = 0
      for i = 1, 1000 do
        break
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [0], _state} = VM.execute(proto)
    end
  end

  describe "goto and label" do
    test "simple forward goto" do
      code = """
      local x = 1
      goto skip
      x = 2
      ::skip::
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1], _state} = VM.execute(proto)
    end

    test "goto skips multiple statements" do
      code = """
      local a = 0
      goto done
      a = a + 1
      a = a + 2
      a = a + 3
      ::done::
      return a
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [0], _state} = VM.execute(proto)
    end

    @tag :skip
    test "goto inside if-then jumps to label after the if block" do
      # Requires goto to propagate out of test blocks like break does
      code = """
      local x = 0
      if true then
        goto skip
      end
      x = 99
      ::skip::
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [0], _state} = VM.execute(proto)
    end

    @tag :skip
    test "goto with label after conditional" do
      # Requires goto propagation out of test blocks
      code = """
      local x = 0
      local flag = true
      if flag then
        goto found
      end
      x = -1
      ::found::
      x = x + 1
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [1], _state} = VM.execute(proto)
    end

    @tag :skip
    test "backward goto (jump to earlier label)" do
      # Requires backward label search
      code = """
      local x = 0
      goto second
      ::first::
      x = x + 1
      goto done
      ::second::
      x = x + 10
      goto first
      ::done::
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [11], _state} = VM.execute(proto)
    end

    test "goto used for simple state machine" do
      code = """
      local result = ""
      goto state_a
      ::state_a::
      result = result .. "a"
      goto state_b
      ::state_b::
      result = result .. "b"
      goto state_c
      ::state_c::
      result = result .. "c"
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, ["abc"], _state} = VM.execute(proto)
    end

    test "goto label inside conditional branch" do
      code = """
      local x = 0
      local cond = false
      if cond then
        ::target::
        x = x + 1
      end
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      # cond is false, so we don't enter the if branch, x stays 0
      assert {:ok, [0], _state} = VM.execute(proto)
    end

    test "label at end of block" do
      code = """
      local x = 10
      goto finish
      x = 20
      ::finish::
      return x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast)
      assert {:ok, [10], _state} = VM.execute(proto)
    end
  end
end
