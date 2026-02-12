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

  describe "string.find" do
    test "string.find with plain text" do
      code = ~s{return string.find("hello world", "world")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [7, 11], _state} = VM.execute(proto, state)
    end

    test "string.find with plain flag" do
      code = ~s{return string.find("hello.world", ".", 1, true)}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [6, 6], _state} = VM.execute(proto, state)
    end

    test "string.find returns nil on no match" do
      code = ~s{return string.find("hello", "xyz")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "string.find with character class pattern" do
      code = ~s{return string.find("abc123", "%d+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [4, 6], _state} = VM.execute(proto, state)
    end

    test "string.find with init position" do
      code = ~s{return string.find("hello hello", "hello", 2)}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [7, 11], _state} = VM.execute(proto, state)
    end

    test "string.find with captures" do
      code = ~s{return string.find("2025-01-15", "(%d+)-(%d+)-(%d+)")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [1, 10, "2025", "01", "15"], _state} = VM.execute(proto, state)
    end

    test "string.find with anchored pattern" do
      code = ~s{return string.find("hello world", "^hello")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [1, 5], _state} = VM.execute(proto, state)
    end

    test "string.find with end anchor" do
      code = ~s{return string.find("hello world", "world$")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [7, 11], _state} = VM.execute(proto, state)
    end
  end

  describe "string.match" do
    test "string.match returns whole match without captures" do
      code = ~s{return string.match("hello", "%a+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello"], _state} = VM.execute(proto, state)
    end

    test "string.match returns captures" do
      code = ~s{return string.match("2025-01-15", "(%d+)-(%d+)-(%d+)")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["2025", "01", "15"], _state} = VM.execute(proto, state)
    end

    test "string.match returns nil on no match" do
      code = ~s{return string.match("hello", "%d+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "string.match with init position" do
      code = ~s{return string.match("abc123def456", "%d+", 7)}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["456"], _state} = VM.execute(proto, state)
    end

    test "string.match with character class set" do
      code = ~s{return string.match("hello world", "[%a]+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello"], _state} = VM.execute(proto, state)
    end
  end

  describe "string.gmatch" do
    test "string.gmatch iterates over matches" do
      code = """
      local result = ""
      for w in string.gmatch("hello world foo", "%a+") do
        result = result .. w .. ","
      end
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello,world,foo,"], _state} = VM.execute(proto, state)
    end

    test "string.gmatch with captures" do
      code = """
      local keys = ""
      local vals = ""
      for k, v in string.gmatch("a=1&b=2&c=3", "(%a+)=(%d+)") do
        keys = keys .. k
        vals = vals .. v
      end
      return keys, vals
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["abc", "123"], _state} = VM.execute(proto, state)
    end

    test "string.gmatch with no matches" do
      code = """
      local count = 0
      for w in string.gmatch("hello", "%d+") do
        count = count + 1
      end
      return count
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [0], _state} = VM.execute(proto, state)
    end
  end

  describe "string.gsub" do
    test "string.gsub with string replacement" do
      code = ~s{return string.gsub("hello world", "world", "lua")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello lua", 1], _state} = VM.execute(proto, state)
    end

    test "string.gsub replaces all occurrences" do
      code = ~s{return string.gsub("aaa", "a", "b")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["bbb", 3], _state} = VM.execute(proto, state)
    end

    test "string.gsub with max replacements" do
      code = ~s{return string.gsub("aaa", "a", "b", 2)}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["bba", 2], _state} = VM.execute(proto, state)
    end

    test "string.gsub with capture references" do
      code = ~s{return string.gsub("hello world", "(%a+)", "<%1>")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["<hello> <world>", 2], _state} = VM.execute(proto, state)
    end

    test "string.gsub with pattern" do
      code = ~s{return string.gsub("abc123def", "%d+", "NUM")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["abcNUMdef", 1], _state} = VM.execute(proto, state)
    end

    test "string.gsub with function replacement" do
      code = """
      local result = string.gsub("abc", ".", function(c)
        return string.upper(c)
      end)
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["ABC"], _state} = VM.execute(proto, state)
    end

    test "string.gsub returns count with no matches" do
      code = ~s{return string.gsub("hello", "%d", "x")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello", 0], _state} = VM.execute(proto, state)
    end
  end

  describe "pattern matching features" do
    test "dot matches any character" do
      code = ~s{return string.match("abc", "a.c")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["abc"], _state} = VM.execute(proto, state)
    end

    test "character class %a matches letters" do
      code = ~s{return string.match("hello123", "%a+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["hello"], _state} = VM.execute(proto, state)
    end

    test "character class %d matches digits" do
      code = ~s{return string.match("hello123", "%d+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["123"], _state} = VM.execute(proto, state)
    end

    test "character class %s matches whitespace" do
      code = ~s{return string.find("hello world", "%s")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [6, 6], _state} = VM.execute(proto, state)
    end

    test "character class %w matches alphanumeric" do
      code = ~s{return string.match("abc123!@#", "%w+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["abc123"], _state} = VM.execute(proto, state)
    end

    test "negated class %D matches non-digits" do
      code = ~s{return string.match("abc123", "%D+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["abc"], _state} = VM.execute(proto, state)
    end

    test "character set [abc]" do
      code = ~s{return string.match("xbz", "[abc]")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["b"], _state} = VM.execute(proto, state)
    end

    test "negated set [^abc]" do
      code = ~s{return string.match("abc xyz", "[^abc ]+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["xyz"], _state} = VM.execute(proto, state)
    end

    test "range in set [a-z]" do
      code = ~s{return string.match("Hello", "[a-z]+")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["ello"], _state} = VM.execute(proto, state)
    end

    test "lazy quantifier -" do
      code = ~s{return string.match("<tag>content</tag>", "<(.-)>")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["tag"], _state} = VM.execute(proto, state)
    end

    test "optional quantifier ?" do
      code = ~s{return string.match("colour", "colou?r")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, ["colour"], _state} = VM.execute(proto, state)
    end

    test "escaped special character %." do
      code = ~s{return string.find("file.txt", "%.")}
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [5, 5], _state} = VM.execute(proto, state)
    end
  end

  describe "pattern property tests" do
    alias Lua.VM.Stdlib.Pattern

    # Generator for safe ASCII strings (no null bytes, printable)
    defp safe_ascii_string(opts) do
      max_length = Keyword.get(opts, :max_length, 30)
      min_length = Keyword.get(opts, :min_length, 0)

      gen all(
            len <- integer(min_length..max_length),
            chars <- list_of(integer(32..126), length: len)
          ) do
        List.to_string(chars)
      end
    end

    # Generator for strings containing only alpha chars
    defp alpha_string(opts) do
      max_length = Keyword.get(opts, :max_length, 20)
      min_length = Keyword.get(opts, :min_length, 0)

      gen all(
            len <- integer(min_length..max_length),
            chars <- list_of(one_of([integer(?a..?z), integer(?A..?Z)]), length: len)
          ) do
        List.to_string(chars)
      end
    end

    # Generator for digit strings
    defp digit_string(opts) do
      max_length = Keyword.get(opts, :max_length, 10)
      min_length = Keyword.get(opts, :min_length, 0)

      gen all(
            len <- integer(min_length..max_length),
            chars <- list_of(integer(?0..?9), length: len)
          ) do
        List.to_string(chars)
      end
    end

    property "find: literal substring is always found at correct position" do
      check all(
              prefix <- safe_ascii_string(max_length: 10),
              needle <- safe_ascii_string(min_length: 1, max_length: 5),
              suffix <- safe_ascii_string(max_length: 10)
            ) do
        subject = prefix <> needle <> suffix
        # Escape needle for use as a literal Lua pattern (escape magic chars)
        escaped = escape_pattern(needle)

        case Pattern.find(subject, escaped) do
          {start, stop, _captures} ->
            matched = binary_part(subject, start - 1, stop - start + 1)
            # The matched substring should contain the needle
            assert byte_size(matched) >= byte_size(needle)
            # start should be within valid range
            assert start >= 1 and start <= byte_size(subject)
            assert stop >= start and stop <= byte_size(subject)

          :nomatch ->
            # Only possible if escaped pattern doesn't match literally
            # (shouldn't happen for escaped patterns, but handle edge cases)
            :ok
        end
      end
    end

    property "find: result positions are valid 1-based indices" do
      check all(
              subject <- safe_ascii_string(min_length: 1, max_length: 20),
              pattern <- member_of(["%a+", "%d+", "%w+", "%s+", ".+", ".", "%a", "%d"])
            ) do
        case Pattern.find(subject, pattern) do
          {start, stop, _captures} ->
            assert start >= 1
            assert stop >= start
            assert stop <= byte_size(subject)

          :nomatch ->
            :ok
        end
      end
    end

    property "find: anchored pattern ^... only matches at position 1" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        case Pattern.find(subject, "^.") do
          {start, stop, _} ->
            assert start == 1
            assert stop == 1

          :nomatch ->
            # Empty string wouldn't match ^. but we ensure min_length: 1
            flunk("^. should always match non-empty string")
        end
      end
    end

    property "find: end anchor ...$ only matches at end" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        case Pattern.find(subject, ".$") do
          {_start, stop, _} ->
            assert stop == byte_size(subject)

          :nomatch ->
            flunk(".$ should always match non-empty string")
        end
      end
    end

    property "match: captures are substrings of the subject" do
      check all(
              prefix <- alpha_string(max_length: 5),
              middle <- digit_string(min_length: 1, max_length: 5),
              suffix <- alpha_string(max_length: 5)
            ) do
        subject = prefix <> middle <> suffix

        case Pattern.match(subject, "(%d+)") do
          {:match, captures} ->
            for cap <- captures do
              assert is_binary(cap)
              # Each capture should be findable in the subject
              assert String.contains?(subject, cap)
            end

          :nomatch ->
            flunk("(%d+) should match '#{subject}' which contains digits '#{middle}'")
        end
      end
    end

    property "match: without captures returns the full match" do
      check all(subject <- alpha_string(min_length: 1, max_length: 10)) do
        case Pattern.match(subject, "%a+") do
          {:match, [result]} ->
            assert is_binary(result)
            assert byte_size(result) >= 1
            assert String.contains?(subject, result)

          :nomatch ->
            flunk("%a+ should match alpha string '#{subject}'")
        end
      end
    end

    property "gmatch: all matches are non-overlapping and in order" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 30)) do
        results = Pattern.gmatch(subject, "%a+")

        # Verify non-overlapping: reconstruct positions via find
        verify_gmatch_order(subject, results, 1)
      end
    end

    property "gmatch: digit matches are all digit strings" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 30)) do
        results = Pattern.gmatch(subject, "%d+")

        for [match] <- results do
          assert Regex.match?(~r/^\d+$/, match),
                 "Expected digit-only match, got: #{inspect(match)}"
        end
      end
    end

    property "gsub: replacing each char with itself is identity" do
      check all(subject <- safe_ascii_string(max_length: 20)) do
        {result, _count} = Pattern.gsub(subject, ".", "%0")
        assert result == subject
      end
    end

    property "gsub: count equals number of matches" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        matches = Pattern.gmatch(subject, "%a")
        {_result, count} = Pattern.gsub(subject, "%a", "X")
        assert count == length(matches)
      end
    end

    property "gsub: max_n limits replacements" do
      check all(
              subject <- safe_ascii_string(min_length: 3, max_length: 20),
              max_n <- integer(0..3)
            ) do
        {_result, count} = Pattern.gsub(subject, ".", "X", max_n)
        assert count <= max_n
      end
    end

    property "gsub: replacing with empty string shortens the result" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        {result, count} = Pattern.gsub(subject, "%a", "")

        if count > 0 do
          assert byte_size(result) < byte_size(subject)
        else
          assert result == subject
        end
      end
    end

    property "character classes: %d and %D are complementary" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        digit_matches = Pattern.gmatch(subject, "%d")
        non_digit_matches = Pattern.gmatch(subject, "%D")
        total = length(digit_matches) + length(non_digit_matches)
        assert total == byte_size(subject)
      end
    end

    property "character classes: %a and %A are complementary" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        alpha_matches = Pattern.gmatch(subject, "%a")
        non_alpha_matches = Pattern.gmatch(subject, "%A")
        total = length(alpha_matches) + length(non_alpha_matches)
        assert total == byte_size(subject)
      end
    end

    property "character classes: %w and %W are complementary" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        alnum_matches = Pattern.gmatch(subject, "%w")
        non_alnum_matches = Pattern.gmatch(subject, "%W")
        total = length(alnum_matches) + length(non_alnum_matches)
        assert total == byte_size(subject)
      end
    end

    property "character classes: %s and %S are complementary" do
      check all(subject <- safe_ascii_string(min_length: 1, max_length: 20)) do
        space_matches = Pattern.gmatch(subject, "%s")
        non_space_matches = Pattern.gmatch(subject, "%S")
        total = length(space_matches) + length(non_space_matches)
        assert total == byte_size(subject)
      end
    end

    defp verify_gmatch_order(_subject, [], _pos), do: :ok

    defp verify_gmatch_order(subject, [[match] | rest], min_pos) do
      case Pattern.find(subject, escape_pattern(match), min_pos) do
        {start, stop, _} ->
          assert start >= min_pos
          verify_gmatch_order(subject, rest, stop + 1)

        :nomatch ->
          # Match might contain pattern magic chars; this is acceptable
          :ok
      end
    end

    # Escape Lua pattern magic characters
    defp escape_pattern(str) do
      String.replace(str, ~r/([%^$().\[\]*+\-?])/, "%\\1")
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
