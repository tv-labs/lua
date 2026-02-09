defmodule Lua.VM.StringTest do
  use ExUnit.Case, async: true

  alias Lua.{Parser, Compiler, VM}
  alias Lua.VM.State

  describe "string.lower and string.upper" do
    test "string.lower converts to lowercase" do
      code = "return string.lower(\"HELLO World\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["hello world"], _state} = VM.execute(proto, state)
    end

    test "string.upper converts to uppercase" do
      code = "return string.upper(\"hello World\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["HELLO WORLD"], _state} = VM.execute(proto, state)
    end

    test "string.lower raises on non-string" do
      code = "return string.lower(123)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert_raise Lua.VM.RuntimeError, ~r/string expected/, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "string.len" do
    test "string.len returns length of string" do
      code = "return string.len(\"hello\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [5], _state} = VM.execute(proto, state)
    end

    test "string.len works with empty string" do
      code = "return string.len(\"\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [0], _state} = VM.execute(proto, state)
    end
  end

  describe "string.sub" do
    test "string.sub extracts substring" do
      code = "return string.sub(\"hello world\", 7, 11)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["world"], _state} = VM.execute(proto, state)
    end

    test "string.sub with negative indices" do
      code = "return string.sub(\"hello\", -4, -2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["ell"], _state} = VM.execute(proto, state)
    end

    test "string.sub without end index" do
      code = "return string.sub(\"hello world\", 7)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["world"], _state} = VM.execute(proto, state)
    end

    test "string.sub with out of range indices returns empty string" do
      code = "return string.sub(\"hello\", 10, 20)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end
  end

  describe "string.rep" do
    test "string.rep repeats string" do
      code = "return string.rep(\"ha\", 3)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["hahaha"], _state} = VM.execute(proto, state)
    end

    test "string.rep with separator" do
      code = "return string.rep(\"ha\", 3, \"-\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["ha-ha-ha"], _state} = VM.execute(proto, state)
    end

    test "string.rep with zero returns empty string" do
      code = "return string.rep(\"ha\", 0)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end
  end

  describe "string.reverse" do
    test "string.reverse reverses string" do
      code = "return string.reverse(\"hello\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["olleh"], _state} = VM.execute(proto, state)
    end

    test "string.reverse works with empty string" do
      code = "return string.reverse(\"\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end
  end

  describe "string.byte" do
    test "string.byte returns single byte value" do
      code = "return string.byte(\"A\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [65], _state} = VM.execute(proto, state)
    end

    test "string.byte with index" do
      code = "return string.byte(\"hello\", 2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [101], _state} = VM.execute(proto, state)
    end

    test "string.byte with range returns multiple values" do
      code = "return string.byte(\"hello\", 1, 3)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [104, 101, 108], _state} = VM.execute(proto, state)
    end

    test "string.byte with negative index" do
      code = "return string.byte(\"hello\", -1)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [111], _state} = VM.execute(proto, state)
    end
  end

  describe "string.char" do
    test "string.char creates string from byte values" do
      code = "return string.char(72, 101, 108, 108, 111)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Hello"], _state} = VM.execute(proto, state)
    end

    test "string.char with no arguments returns empty string" do
      code = "return string.char()"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end

    test "string.char raises on out of range value" do
      code = "return string.char(256)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert_raise Lua.VM.RuntimeError, ~r/out of range/, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "string.format" do
    test "string.format with %s specifier" do
      code = "return string.format(\"Hello, %s!\", \"world\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Hello, world!"], _state} = VM.execute(proto, state)
    end

    test "string.format with %d specifier" do
      code = "return string.format(\"Number: %d\", 42)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Number: 42"], _state} = VM.execute(proto, state)
    end

    test "string.format with %f specifier" do
      code = "return string.format(\"Float: %f\", 3.14)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [result], _state} = VM.execute(proto, state)
      assert result =~ "3.14"
    end

    test "string.format with %x specifier" do
      code = "return string.format(\"Hex: %x\", 255)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Hex: ff"], _state} = VM.execute(proto, state)
    end

    test "string.format with %X specifier" do
      code = "return string.format(\"Hex: %X\", 255)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Hex: FF"], _state} = VM.execute(proto, state)
    end

    test "string.format with %o specifier" do
      code = "return string.format(\"Octal: %o\", 8)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Octal: 10"], _state} = VM.execute(proto, state)
    end

    test "string.format with %c specifier" do
      code = "return string.format(\"Char: %c\", 65)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Char: A"], _state} = VM.execute(proto, state)
    end

    test "string.format with %q specifier" do
      code = "return string.format(\"Quoted: %q\", \"hello\\nworld\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [result], _state} = VM.execute(proto, state)
      assert result == "Quoted: \"hello\\nworld\""
    end

    test "string.format with %% escapes percent" do
      code = "return string.format(\"100%% done\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["100% done"], _state} = VM.execute(proto, state)
    end

    test "string.format with multiple specifiers" do
      code = "return string.format(\"%s: %d (%x)\", \"Value\", 255, 255)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["Value: 255 (ff)"], _state} = VM.execute(proto, state)
    end
  end

  describe "string table access" do
    test "string functions are accessible via string table" do
      code = """
      local s = string
      return s.upper("hello")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, ["HELLO"], _state} = VM.execute(proto, state)
    end
  end
end
