defmodule Lua.VM.StringTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.ArgumentError
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  describe "string.lower and string.upper" do
    test "string.lower converts to lowercase" do
      code = "return string.lower(\"HELLO World\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello world"], _state} = VM.execute(proto, state)
    end

    test "string.upper converts to uppercase" do
      code = "return string.upper(\"hello World\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["HELLO WORLD"], _state} = VM.execute(proto, state)
    end

    test "string.lower raises on non-string" do
      code = "return string.lower(123)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, ~r/string expected/, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "string.len" do
    test "string.len returns length of string" do
      code = "return string.len(\"hello\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [5], _state} = VM.execute(proto, state)
    end

    test "string.len works with empty string" do
      code = "return string.len(\"\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [0], _state} = VM.execute(proto, state)
    end
  end

  describe "string.sub" do
    test "string.sub extracts substring" do
      code = "return string.sub(\"hello world\", 7, 11)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["world"], _state} = VM.execute(proto, state)
    end

    test "string.sub with negative indices" do
      code = "return string.sub(\"hello\", -4, -2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["ell"], _state} = VM.execute(proto, state)
    end

    test "string.sub without end index" do
      code = "return string.sub(\"hello world\", 7)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["world"], _state} = VM.execute(proto, state)
    end

    test "string.sub with out of range indices returns empty string" do
      code = "return string.sub(\"hello\", 10, 20)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end
  end

  describe "string.rep" do
    test "string.rep repeats string" do
      code = "return string.rep(\"ha\", 3)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hahaha"], _state} = VM.execute(proto, state)
    end

    test "string.rep with separator" do
      code = ~s{return string.rep("ha", 3, "-")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["ha-ha-ha"], _state} = VM.execute(proto, state)
    end

    test "string.rep with zero returns empty string" do
      code = "return string.rep(\"ha\", 0)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end
  end

  describe "string.reverse" do
    test "string.reverse reverses string" do
      code = "return string.reverse(\"hello\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["olleh"], _state} = VM.execute(proto, state)
    end

    test "string.reverse works with empty string" do
      code = "return string.reverse(\"\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end
  end

  describe "string.byte" do
    test "string.byte returns single byte value" do
      code = "return string.byte(\"A\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [65], _state} = VM.execute(proto, state)
    end

    test "string.byte with index" do
      code = "return string.byte(\"hello\", 2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [101], _state} = VM.execute(proto, state)
    end

    test "string.byte with range returns multiple values" do
      code = "return string.byte(\"hello\", 1, 3)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [104, 101, 108], _state} = VM.execute(proto, state)
    end

    test "string.byte with negative index" do
      code = "return string.byte(\"hello\", -1)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [111], _state} = VM.execute(proto, state)
    end
  end

  describe "string.char" do
    test "string.char creates string from byte values" do
      code = "return string.char(72, 101, 108, 108, 111)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Hello"], _state} = VM.execute(proto, state)
    end

    test "string.char with no arguments returns empty string" do
      code = "return string.char()"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [""], _state} = VM.execute(proto, state)
    end

    test "string.char raises on out of range value" do
      code = "return string.char(256)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, ~r/out of range/, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "string.format" do
    test "string.format with %s specifier" do
      code = ~s{return string.format("Hello, %s!", "world")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Hello, world!"], _state} = VM.execute(proto, state)
    end

    test "string.format with %d specifier" do
      code = "return string.format(\"Number: %d\", 42)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Number: 42"], _state} = VM.execute(proto, state)
    end

    test "string.format with %f specifier" do
      code = "return string.format(\"Float: %f\", 3.14)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [result], _state} = VM.execute(proto, state)
      assert result =~ "3.14"
    end

    test "string.format with %x specifier" do
      code = "return string.format(\"Hex: %x\", 255)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Hex: ff"], _state} = VM.execute(proto, state)
    end

    test "string.format with %X specifier" do
      code = "return string.format(\"Hex: %X\", 255)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Hex: FF"], _state} = VM.execute(proto, state)
    end

    test "string.format with %o specifier" do
      code = "return string.format(\"Octal: %o\", 8)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Octal: 10"], _state} = VM.execute(proto, state)
    end

    test "string.format with %c specifier" do
      code = "return string.format(\"Char: %c\", 65)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["Char: A"], _state} = VM.execute(proto, state)
    end

    test "string.format with %q specifier" do
      code = ~s{return string.format("Quoted: %q", "hello\\nworld")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [result], _state} = VM.execute(proto, state)
      assert result == "Quoted: \"hello\\nworld\""
    end

    test "string.format with %% escapes percent" do
      code = "return string.format(\"100%% done\")"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["100% done"], _state} = VM.execute(proto, state)
    end

    test "string.format with multiple specifiers" do
      code = ~s{return string.format("%s: %d (%x)", "Value", 255, 255)}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
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
      state = Stdlib.install(State.new())
      assert {:ok, ["HELLO"], _state} = VM.execute(proto, state)
    end
  end

  describe "property tests" do
    property "string.lower always returns a string" do
      check all(str <- string(:printable)) do
        code = "return string.lower(\"#{escape_string(str)}\")"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert is_binary(result)
        assert result == String.downcase(str)
      end
    end

    property "string.upper always returns a string" do
      check all(str <- string(:printable)) do
        code = "return string.upper(\"#{escape_string(str)}\")"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert is_binary(result)
        assert result == String.upcase(str)
      end
    end

    property "string.len returns non-negative integer" do
      check all(str <- string(:printable)) do
        code = "return string.len(\"#{escape_string(str)}\")"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert is_integer(result)
        assert result >= 0
        assert result == byte_size(str)
      end
    end

    property "string.reverse twice gives original (ASCII)" do
      # Note: Lua operates on bytes, not graphemes, so we test with ASCII only
      # Multi-byte UTF-8 characters would be reversed incorrectly by Lua's string.reverse
      check all(str <- string(:ascii)) do
        code = "return string.reverse(string.reverse(\"#{escape_string(str)}\"))"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert result == str
      end
    end

    property "string.rep with 0 returns empty string" do
      check all(str <- string(:printable)) do
        code = "return string.rep(\"#{escape_string(str)}\", 0)"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [""], _state} = VM.execute(proto, state)
      end
    end

    property "string.rep with 1 returns original" do
      check all(str <- string(:printable, max_length: 10)) do
        code = "return string.rep(\"#{escape_string(str)}\", 1)"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert result == str
      end
    end

    property "string.byte/char round-trip for single bytes" do
      check all(byte <- integer(0..255)) do
        code = "return string.char(string.byte(string.char(#{byte})))"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert result == <<byte>>
      end
    end

    property "string.sub with full range returns original" do
      check all(str <- string(:printable, max_length: 10)) do
        len = byte_size(str)
        code = "return string.sub(\"#{escape_string(str)}\", 1, #{len})"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert result == str
      end
    end

    property "string.format %s always produces string" do
      check all(str <- string(:printable, max_length: 20)) do
        code = "return string.format(\"Result: %s\", \"#{escape_string(str)}\")"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert is_binary(result)
        assert String.starts_with?(result, "Result: ")
      end
    end

    property "string.format %d works with integers" do
      check all(int <- integer(-1000..1000)) do
        code = "return string.format(\"Number: %d\", #{int})"
        assert {:ok, ast} = Parser.parse(code)
        assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = Stdlib.install(State.new())
        assert {:ok, [result], _state} = VM.execute(proto, state)
        assert result == "Number: #{int}"
      end
    end
  end

  # Helper to escape strings for Lua code
  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
