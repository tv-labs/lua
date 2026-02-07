defmodule Lua.Compiler.IntegrationTest do
  use ExUnit.Case, async: true

  alias Lua.{Parser, Compiler, VM}

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
end
