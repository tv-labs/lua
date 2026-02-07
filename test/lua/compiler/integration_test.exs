defmodule Lua.Compiler.IntegrationTest do
  use ExUnit.Case, async: true

  alias Lua.{Parser, Compiler, VM}

  describe "end-to-end compilation and execution" do
    test "return 42" do
      code = "return 42"

      # Parse
      {:ok, ast} = Parser.parse(code)

      # Compile
      {:ok, proto} = Compiler.compile(ast)

      # Execute
      {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "return true" do
      code = "return true"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return false" do
      code = "return false"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "return nil" do
      code = "return nil"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end

    test "return string" do
      code = ~s[return "hello world"]

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == ["hello world"]
    end

    test "return 3.14" do
      code = "return 3.14"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [3.14]
    end
  end

  describe "arithmetic operations" do
    test "return 2 + 3" do
      code = "return 2 + 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end

    test "return 2 + 3 * 4" do
      code = "return 2 + 3 * 4"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [14]
    end

    test "return 10 - 3" do
      code = "return 10 - 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [7]
    end

    test "return 6 * 7" do
      code = "return 6 * 7"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "return 10 / 2" do
      code = "return 10 / 2"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [5.0]
    end

    test "return 10 // 3" do
      code = "return 10 // 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "return 10 % 3" do
      code = "return 10 % 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "return 2 ^ 8" do
      code = "return 2 ^ 8"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [256.0]
    end

    test "return -5" do
      code = "return -5"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [-5]
    end
  end

  describe "comparison operations" do
    test "return 5 == 5" do
      code = "return 5 == 5"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return 5 == 6" do
      code = "return 5 == 6"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "return 3 < 5" do
      code = "return 3 < 5"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return 5 <= 5" do
      code = "return 5 <= 5"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end
  end

  describe "bitwise operations" do
    test "return 5 & 3" do
      code = "return 5 & 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [1]
    end

    test "return 5 | 3" do
      code = "return 5 | 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [7]
    end

    test "return 5 ~ 3" do
      code = "return 5 ~ 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [6]
    end

    test "return 1 << 3" do
      code = "return 1 << 3"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [8]
    end

    test "return 8 >> 2" do
      code = "return 8 >> 2"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [2]
    end

    test "return ~5" do
      code = "return ~5"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [-6]
    end
  end

  describe "logical operations" do
    test "return not true" do
      code = "return not true"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end

    test "return not false" do
      code = "return not false"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return not nil" do
      code = "return not nil"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [true]
    end

    test "return not 5" do
      code = "return not 5"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [false]
    end
  end

  describe "string operations" do
    test "return #'hello'" do
      code = "return #'hello'"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [5]
    end
  end

  describe "global variables" do
    test "assign and return global variable" do
      code = "x = 42\nreturn x"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, state} = VM.execute(proto)

      assert results == [42]
      assert state.globals["x"] == 42
    end

    test "multiple global assignments" do
      code = "a = 1\nb = 2\nreturn a + b"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, state} = VM.execute(proto)

      assert results == [3]
      assert state.globals["a"] == 1
      assert state.globals["b"] == 2
    end

    test "reassign global variable" do
      code = "x = 10\nx = x + 5\nreturn x"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [15]
    end

    test "undefined global returns nil" do
      code = "return undefined_var"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end

    test "global with arithmetic expression" do
      code = "result = 2 * 3 + 4\nreturn result"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [10]
    end
  end

  describe "local variables" do
    test "simple local variable" do
      code = "local x = 42\nreturn x"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [42]
    end

    test "local variable with arithmetic" do
      code = "local x = 1\nreturn x + 2"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "multiple local variables" do
      code = "local a = 5\nlocal b = 3\nreturn a * b"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [15]
    end

    test "local variable reassignment via new declaration" do
      code = "local x = 10\nlocal x = 20\nreturn x"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [20]
    end

    test "local variable with expression" do
      code = "local x = 2 + 3\nreturn x * 4"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [20]
    end

    test "multiple locals in one declaration" do
      code = "local a, b = 1, 2\nreturn a + b"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [3]
    end

    test "local with fewer values than names (implicit nil)" do
      code = "local a, b = 1\nreturn b"

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast)
      {:ok, results, _state} = VM.execute(proto)

      assert results == [nil]
    end
  end
end
