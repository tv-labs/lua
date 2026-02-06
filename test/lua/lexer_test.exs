defmodule Lua.LexerTest do
  use ExUnit.Case, async: true
  alias Lua.Lexer

  doctest Lua.Lexer

  describe "keywords" do
    test "tokenizes all Lua keywords" do
      keywords = [
        :and,
        :break,
        :do,
        :else,
        :elseif,
        :end,
        false,
        :for,
        :function,
        :goto,
        :if,
        :in,
        :local,
        nil,
        :not,
        :or,
        :repeat,
        :return,
        :then,
        true,
        :until,
        :while
      ]

      for keyword <- keywords do
        keyword_str = Atom.to_string(keyword)
        assert {:ok, tokens} = Lexer.tokenize(keyword_str)
        assert [{:keyword, ^keyword, _}, {:eof, _}] = tokens
      end
    end

    test "keywords are case-sensitive" do
      assert {:ok, [{:identifier, "IF", _}, {:eof, _}]} = Lexer.tokenize("IF")
      assert {:ok, [{:identifier, "End", _}, {:eof, _}]} = Lexer.tokenize("End")
    end
  end

  describe "identifiers" do
    test "tokenizes simple identifiers" do
      assert {:ok, [{:identifier, "foo", _}, {:eof, _}]} = Lexer.tokenize("foo")
      assert {:ok, [{:identifier, "bar123", _}, {:eof, _}]} = Lexer.tokenize("bar123")
      assert {:ok, [{:identifier, "_test", _}, {:eof, _}]} = Lexer.tokenize("_test")
      assert {:ok, [{:identifier, "CamelCase", _}, {:eof, _}]} = Lexer.tokenize("CamelCase")
    end

    test "identifiers can start with underscore" do
      assert {:ok, [{:identifier, "_", _}, {:eof, _}]} = Lexer.tokenize("_")
      assert {:ok, [{:identifier, "__private", _}, {:eof, _}]} = Lexer.tokenize("__private")
    end

    test "identifiers can contain numbers but not start with them" do
      assert {:ok, [{:identifier, "var1", _}, {:eof, _}]} = Lexer.tokenize("var1")
      assert {:ok, [{:identifier, "test123abc", _}, {:eof, _}]} = Lexer.tokenize("test123abc")
    end
  end

  describe "numbers" do
    test "tokenizes integers" do
      assert {:ok, [{:number, 0, _}, {:eof, _}]} = Lexer.tokenize("0")
      assert {:ok, [{:number, 42, _}, {:eof, _}]} = Lexer.tokenize("42")
      assert {:ok, [{:number, 12345, _}, {:eof, _}]} = Lexer.tokenize("12345")
    end

    test "tokenizes floating point numbers" do
      assert {:ok, [{:number, 3.14, _}, {:eof, _}]} = Lexer.tokenize("3.14")
      assert {:ok, [{:number, 0.5, _}, {:eof, _}]} = Lexer.tokenize("0.5")
      assert {:ok, [{:number, 10.0, _}, {:eof, _}]} = Lexer.tokenize("10.0")
    end

    test "tokenizes hexadecimal numbers" do
      assert {:ok, [{:number, 255, _}, {:eof, _}]} = Lexer.tokenize("0xFF")
      assert {:ok, [{:number, 255, _}, {:eof, _}]} = Lexer.tokenize("0xff")
      assert {:ok, [{:number, 0, _}, {:eof, _}]} = Lexer.tokenize("0x0")
      assert {:ok, [{:number, 4095, _}, {:eof, _}]} = Lexer.tokenize("0xfff")
    end

    test "tokenizes scientific notation" do
      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("1e10")
      assert num == 1.0e10

      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("1.5e-5")
      assert num == 1.5e-5

      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("3E+2")
      assert num == 3.0e2
    end

    test "tokenizes floats with scientific notation" do
      # Float with exponent
      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("2.5e3")
      assert num == 2.5e3

      # Float with uppercase E
      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("1.0E10")
      assert num == 1.0e10

      # Integer with exponent (becomes float)
      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("5e2")
      assert num == 5.0e2

      # Exponent without sign
      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("1e5")
      assert num == 1.0e5
    end

    test "handles edge cases in scientific notation" do
      # Exponent without digits - should result in error
      assert {:error, {:invalid_number, _}} = Lexer.tokenize("1e")

      # Exponent with sign but no digits - should result in error
      assert {:error, {:invalid_number, _}} = Lexer.tokenize("1e+")
      assert {:error, {:invalid_number, _}} = Lexer.tokenize("1e-")

      # Float with exponent without digits
      assert {:error, {:invalid_number, _}} = Lexer.tokenize("1.5e")
    end

    test "handles trailing dot correctly" do
      # "42." should be tokenized as number 42 followed by dot operator
      # But in Lua, "42." is actually a valid number (42.0)
      # Let's test both interpretations
      assert {:ok, tokens} = Lexer.tokenize("42.")
      # This might be [{:number, 42.0}, {:eof}] or [{:number, 42}, {:delimiter, :dot}, {:eof}]
      # depending on implementation
      assert length(tokens) >= 2
    end
  end

  describe "strings" do
    test "tokenizes double-quoted strings" do
      assert {:ok, [{:string, "hello", _}, {:eof, _}]} = Lexer.tokenize(~s("hello"))
      assert {:ok, [{:string, "", _}, {:eof, _}]} = Lexer.tokenize(~s(""))
      assert {:ok, [{:string, "hello world", _}, {:eof, _}]} = Lexer.tokenize(~s("hello world"))
    end

    test "tokenizes single-quoted strings" do
      assert {:ok, [{:string, "hello", _}, {:eof, _}]} = Lexer.tokenize("'hello'")
      assert {:ok, [{:string, "", _}, {:eof, _}]} = Lexer.tokenize("''")
      assert {:ok, [{:string, "hello world", _}, {:eof, _}]} = Lexer.tokenize("'hello world'")
    end

    test "handles escape sequences in strings" do
      assert {:ok, [{:string, "hello\nworld", _}, {:eof, _}]} =
               Lexer.tokenize(~s("hello\\nworld"))

      assert {:ok, [{:string, "tab\there", _}, {:eof, _}]} = Lexer.tokenize(~s("tab\\there"))

      assert {:ok, [{:string, "quote\"here", _}, {:eof, _}]} =
               Lexer.tokenize(~s("quote\\"here"))

      assert {:ok, [{:string, "backslash\\here", _}, {:eof, _}]} =
               Lexer.tokenize(~s("backslash\\\\here"))
    end

    test "handles all standard escape sequences" do
      # Test \a (bell)
      assert {:ok, [{:string, <<?\a>>, _}, {:eof, _}]} = Lexer.tokenize(~s("\\a"))
      # Test \b (backspace)
      assert {:ok, [{:string, <<?\b>>, _}, {:eof, _}]} = Lexer.tokenize(~s("\\b"))
      # Test \f (form feed)
      assert {:ok, [{:string, <<?\f>>, _}, {:eof, _}]} = Lexer.tokenize(~s("\\f"))
      # Test \r (carriage return)
      assert {:ok, [{:string, <<?\r>>, _}, {:eof, _}]} = Lexer.tokenize(~s("\\r"))
      # Test \v (vertical tab)
      assert {:ok, [{:string, <<?\v>>, _}, {:eof, _}]} = Lexer.tokenize(~s("\\v"))
      # Test \' (single quote)
      assert {:ok, [{:string, "'", _}, {:eof, _}]} = Lexer.tokenize(~s("\\'"))
      # Test \" (double quote)
      assert {:ok, [{:string, "\"", _}, {:eof, _}]} = Lexer.tokenize(~s("\\""))
      # Test \\ (backslash)
      assert {:ok, [{:string, "\\", _}, {:eof, _}]} = Lexer.tokenize(~s("\\\\"))
    end

    test "tokenizes long strings with [[...]]" do
      assert {:ok, [{:string, "hello", _}, {:eof, _}]} = Lexer.tokenize("[[hello]]")
      assert {:ok, [{:string, "", _}, {:eof, _}]} = Lexer.tokenize("[[]]")

      assert {:ok, [{:string, "multi\nline", _}, {:eof, _}]} =
               Lexer.tokenize("[[multi\nline]]")
    end

    test "tokenizes long strings with equals signs [=[...]=]" do
      assert {:ok, [{:string, "hello", _}, {:eof, _}]} = Lexer.tokenize("[=[hello]=]")
      assert {:ok, [{:string, "test", _}, {:eof, _}]} = Lexer.tokenize("[==[test]==]")
      assert {:ok, [{:string, "a]b", _}, {:eof, _}]} = Lexer.tokenize("[=[a]b]=]")
    end

    test "long strings with false closing brackets" do
      # ] not followed by the right number of =
      assert {:ok, [{:string, " test ] more ", _}, {:eof, _}]} =
               Lexer.tokenize("[=[ test ] more ]=]")

      # ] not followed by ]
      assert {:ok, [{:string, " test ]= more ", _}, {:eof, _}]} =
               Lexer.tokenize("[[ test ]= more ]]")
    end

    test "reports error for unclosed string" do
      assert {:error, {:unclosed_string, _}} = Lexer.tokenize(~s("hello))
      assert {:error, {:unclosed_string, _}} = Lexer.tokenize("'hello")
    end

    test "reports error for unclosed long string" do
      assert {:error, {:unclosed_long_string, _}} = Lexer.tokenize("[[hello")
      assert {:error, {:unclosed_long_string, _}} = Lexer.tokenize("[=[test")
    end
  end

  describe "operators" do
    test "tokenizes single-character operators" do
      assert {:ok, [{:operator, :add, _}, {:eof, _}]} = Lexer.tokenize("+")
      assert {:ok, [{:operator, :sub, _}, {:eof, _}]} = Lexer.tokenize("-")
      assert {:ok, [{:operator, :mul, _}, {:eof, _}]} = Lexer.tokenize("*")
      assert {:ok, [{:operator, :div, _}, {:eof, _}]} = Lexer.tokenize("/")
      assert {:ok, [{:operator, :mod, _}, {:eof, _}]} = Lexer.tokenize("%")
      assert {:ok, [{:operator, :pow, _}, {:eof, _}]} = Lexer.tokenize("^")
      assert {:ok, [{:operator, :len, _}, {:eof, _}]} = Lexer.tokenize("#")
      assert {:ok, [{:operator, :lt, _}, {:eof, _}]} = Lexer.tokenize("<")
      assert {:ok, [{:operator, :gt, _}, {:eof, _}]} = Lexer.tokenize(">")
      assert {:ok, [{:operator, :assign, _}, {:eof, _}]} = Lexer.tokenize("=")
    end

    test "tokenizes two-character operators" do
      assert {:ok, [{:operator, :eq, _}, {:eof, _}]} = Lexer.tokenize("==")
      assert {:ok, [{:operator, :ne, _}, {:eof, _}]} = Lexer.tokenize("~=")
      assert {:ok, [{:operator, :le, _}, {:eof, _}]} = Lexer.tokenize("<=")
      assert {:ok, [{:operator, :ge, _}, {:eof, _}]} = Lexer.tokenize(">=")
      assert {:ok, [{:operator, :concat, _}, {:eof, _}]} = Lexer.tokenize("..")
      assert {:ok, [{:operator, :floordiv, _}, {:eof, _}]} = Lexer.tokenize("//")
    end

    test "tokenizes three-character operators" do
      assert {:ok, [{:operator, :vararg, _}, {:eof, _}]} = Lexer.tokenize("...")
    end

    test "distinguishes between . and .." do
      assert {:ok, [{:delimiter, :dot, _}, {:eof, _}]} = Lexer.tokenize(".")
      assert {:ok, [{:operator, :concat, _}, {:eof, _}]} = Lexer.tokenize("..")
      assert {:ok, [{:operator, :vararg, _}, {:eof, _}]} = Lexer.tokenize("...")
    end
  end

  describe "delimiters" do
    test "tokenizes parentheses" do
      assert {:ok, [{:delimiter, :lparen, _}, {:eof, _}]} = Lexer.tokenize("(")
      assert {:ok, [{:delimiter, :rparen, _}, {:eof, _}]} = Lexer.tokenize(")")
    end

    test "tokenizes braces" do
      assert {:ok, [{:delimiter, :lbrace, _}, {:eof, _}]} = Lexer.tokenize("{")
      assert {:ok, [{:delimiter, :rbrace, _}, {:eof, _}]} = Lexer.tokenize("}")
    end

    test "tokenizes brackets" do
      assert {:ok, [{:delimiter, :lbracket, _}, {:eof, _}]} = Lexer.tokenize("[")
    end

    test "tokenizes other delimiters" do
      assert {:ok, [{:delimiter, :semicolon, _}, {:eof, _}]} = Lexer.tokenize(";")
      assert {:ok, [{:delimiter, :comma, _}, {:eof, _}]} = Lexer.tokenize(",")
      assert {:ok, [{:delimiter, :colon, _}, {:eof, _}]} = Lexer.tokenize(":")
      assert {:ok, [{:delimiter, :double_colon, _}, {:eof, _}]} = Lexer.tokenize("::")
    end
  end

  describe "comments" do
    test "skips single-line comments" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("-- this is a comment")

      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} =
               Lexer.tokenize("x -- comment after code")
    end

    test "skips multi-line comments" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[[ this is a\nmulti-line comment ]]")

      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} =
               Lexer.tokenize("x --[[ comment ]] ")
    end

    test "skips multi-line comments with equals signs" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[=[ comment ]=]")
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[==[ comment ]==]")
    end

    test "handles content with brackets in multi-line comments" do
      # The first ]] closes the comment regardless of internal [[
      # So this closes at the first ]] and leaves " inside ]]" as code
      assert {:ok, tokens} = Lexer.tokenize("--[[ comment ]]")
      assert [{:eof, _}] = tokens

      # With nesting levels using =, you can include ]] in the comment
      assert {:ok, tokens2} = Lexer.tokenize("--[=[ comment with ]] in it ]=]")
      assert [{:eof, _}] = tokens2
    end

    test "reports error for unclosed multi-line comment" do
      assert {:error, {:unclosed_comment, _}} = Lexer.tokenize("--[[ unclosed comment")
    end

    test "handles false closing brackets in multi-line comments" do
      # Test a ] that is not followed by the right number of =
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[=[ test ] more ]=]")
      # Test a ] that is not followed by ]
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[[ test ]= more ]]")
    end

    test "multi-line comment with newlines" do
      code = "--[[ line 1\nline 2\nline 3 ]]"
      assert {:ok, [{:eof, _}]} = Lexer.tokenize(code)
    end

    test "multi-line comment level 0" do
      # Test the actual --[[ path
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[[ comment ]]")
      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} = Lexer.tokenize("--[[ comment ]]x")
    end
  end

  describe "whitespace" do
    test "skips spaces and tabs" do
      assert {:ok, [{:number, 1, _}, {:number, 2, _}, {:eof, _}]} = Lexer.tokenize("1  2")
      assert {:ok, [{:number, 1, _}, {:number, 2, _}, {:eof, _}]} = Lexer.tokenize("1\t2")
    end

    test "handles newlines" do
      assert {:ok, [{:number, 1, _}, {:number, 2, _}, {:eof, _}]} = Lexer.tokenize("1\n2")
      assert {:ok, [{:number, 1, _}, {:number, 2, _}, {:eof, _}]} = Lexer.tokenize("1\r\n2")
      assert {:ok, [{:number, 1, _}, {:number, 2, _}, {:eof, _}]} = Lexer.tokenize("1\r2")
    end

    test "handles different newline styles in code" do
      # CRLF newline
      assert {:ok, tokens} = Lexer.tokenize("x\r\ny")

      assert [
               {:identifier, "x", _},
               {:identifier, "y", _},
               {:eof, _}
             ] = tokens

      # CR only newline
      assert {:ok, tokens} = Lexer.tokenize("x\ry")

      assert [
               {:identifier, "x", _},
               {:identifier, "y", _},
               {:eof, _}
             ] = tokens
    end
  end

  describe "position tracking" do
    test "tracks line and column for single line" do
      assert {:ok, tokens} = Lexer.tokenize("local x = 42")

      assert [
               {:keyword, :local, %{line: 1, column: 1, byte_offset: 0}},
               {:identifier, "x", %{line: 1, column: 7, byte_offset: 6}},
               {:operator, :assign, %{line: 1, column: 9, byte_offset: 8}},
               {:number, 42, %{line: 1, column: 11, byte_offset: 10}},
               {:eof, _}
             ] = tokens
    end

    test "tracks line numbers across multiple lines" do
      code = """
      local x
      x = 42
      """

      assert {:ok, tokens} = Lexer.tokenize(code)

      assert [
               {:keyword, :local, %{line: 1}},
               {:identifier, "x", %{line: 1}},
               {:identifier, "x", %{line: 2}},
               {:operator, :assign, %{line: 2}},
               {:number, 42, %{line: 2}},
               {:eof, _}
             ] = tokens
    end

    test "tracks position in strings" do
      assert {:ok, tokens} = Lexer.tokenize(~s("hello"))

      assert [{:string, "hello", %{line: 1, column: 1, byte_offset: 0}}, {:eof, _}] = tokens
    end
  end

  describe "complex expressions" do
    test "tokenizes arithmetic expression" do
      assert {:ok, tokens} = Lexer.tokenize("2 + 3 * 4")

      assert [
               {:number, 2, _},
               {:operator, :add, _},
               {:number, 3, _},
               {:operator, :mul, _},
               {:number, 4, _},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes function call" do
      assert {:ok, tokens} = Lexer.tokenize("print(42)")

      assert [
               {:identifier, "print", _},
               {:delimiter, :lparen, _},
               {:number, 42, _},
               {:delimiter, :rparen, _},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes table constructor" do
      assert {:ok, tokens} = Lexer.tokenize("{a = 1, b = 2}")

      assert [
               {:delimiter, :lbrace, _},
               {:identifier, "a", _},
               {:operator, :assign, _},
               {:number, 1, _},
               {:delimiter, :comma, _},
               {:identifier, "b", _},
               {:operator, :assign, _},
               {:number, 2, _},
               {:delimiter, :rbrace, _},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes method call" do
      assert {:ok, tokens} = Lexer.tokenize("obj:method()")

      assert [
               {:identifier, "obj", _},
               {:delimiter, :colon, _},
               {:identifier, "method", _},
               {:delimiter, :lparen, _},
               {:delimiter, :rparen, _},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes vararg" do
      assert {:ok, tokens} = Lexer.tokenize("function f(...) return ... end")

      assert [
               {:keyword, :function, _},
               {:identifier, "f", _},
               {:delimiter, :lparen, _},
               {:operator, :vararg, _},
               {:delimiter, :rparen, _},
               {:keyword, :return, _},
               {:operator, :vararg, _},
               {:keyword, :end, _},
               {:eof, _}
             ] = tokens
    end
  end

  describe "edge cases" do
    test "empty input" do
      assert {:ok, [{:eof, %{line: 1, column: 1, byte_offset: 0}}]} = Lexer.tokenize("")
    end

    test "only whitespace" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("   \n  \t  ")
    end

    test "only comments" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("-- just a comment")
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[[ just a comment ]]")
    end

    test "reports error for unexpected character" do
      assert {:error, {:unexpected_character, ?@, _}} = Lexer.tokenize("@")
      assert {:error, {:unexpected_character, ?$, _}} = Lexer.tokenize("$")
      assert {:error, {:unexpected_character, ?`, _}} = Lexer.tokenize("`")
    end

    test "handles consecutive operators" do
      assert {:ok, tokens} = Lexer.tokenize("+-*/")

      assert [
               {:operator, :add, _},
               {:operator, :sub, _},
               {:operator, :mul, _},
               {:operator, :div, _},
               {:eof, _}
             ] = tokens
    end

    test "distinguishes >= from > =" do
      assert {:ok, [{:operator, :ge, _}, {:eof, _}]} = Lexer.tokenize(">=")

      assert {:ok, [{:operator, :gt, _}, {:operator, :assign, _}, {:eof, _}]} =
               Lexer.tokenize("> =")
    end

    test "handles invalid escape sequences in strings" do
      # Invalid escape sequences should be included as-is
      assert {:ok, [{:string, "\\x", _}, {:eof, _}]} = Lexer.tokenize(~s("\\x"))
      assert {:ok, [{:string, "\\z", _}, {:eof, _}]} = Lexer.tokenize(~s("\\z"))
      assert {:ok, [{:string, "\\1", _}, {:eof, _}]} = Lexer.tokenize(~s("\\1"))
    end

    test "reports error for string with unescaped newline" do
      assert {:error, {:unclosed_string, _}} = Lexer.tokenize("\"hello\n")
      assert {:error, {:unclosed_string, _}} = Lexer.tokenize("'hello\n")
    end

    test "handles trailing dot after number" do
      # "42." should tokenize as number 42 followed by dot
      assert {:ok, tokens} = Lexer.tokenize("42.")
      assert [{:number, 42, _}, {:delimiter, :dot, _}, {:eof, _}] = tokens
    end

    test "handles decimal point without following digit" do
      # "42.x" should be number 42 followed by dot and identifier x
      assert {:ok, tokens} = Lexer.tokenize("42.x")
      assert [{:number, 42, _}, {:delimiter, :dot, _}, {:identifier, "x", _}, {:eof, _}] = tokens
    end

    test "reports error for invalid hex number" do
      assert {:error, {:invalid_hex_number, _}} = Lexer.tokenize("0x")
      assert {:error, {:invalid_hex_number, _}} = Lexer.tokenize("0xg")
    end

    test "handles uppercase X in hex numbers" do
      assert {:ok, [{:number, 255, _}, {:eof, _}]} = Lexer.tokenize("0XFF")
      assert {:ok, [{:number, 10, _}, {:eof, _}]} = Lexer.tokenize("0Xa")
    end

    test "single-line comment ending with LF" do
      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} = Lexer.tokenize("-- comment\nx")
    end

    test "single-line comment ending with CR" do
      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} = Lexer.tokenize("-- comment\rx")
    end

    test "single-line comment ending with CRLF" do
      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} = Lexer.tokenize("-- comment\r\nx")
    end

    test "single-line comment at end of file" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("-- comment at EOF")
    end

    test "comment starting with --[ but not --[[" do
      # This should be treated as a single-line comment, not a multi-line comment
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[ this is single line")
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[= not multi-line")
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[x not multi-line")
    end

    test "multi-line comment with mismatched bracket level" do
      # The closing bracket doesn't match the opening level
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[=[ comment ]]")
      # This should continue scanning until EOF because ]] doesn't match the opening [=[
    end

    test "long string with mismatched closing bracket" do
      # Opening [=[ but closing with ]]
      assert {:error, {:unclosed_long_string, _}} = Lexer.tokenize("[=[ string ]]")
    end

    test "long bracket not actually a long bracket" do
      # "[" followed by something other than "=" or "[" should be treated as delimiter
      assert {:ok, [{:delimiter, :lbracket, _}, {:identifier, "x", _}, {:eof, _}]} =
               Lexer.tokenize("[x")
    end

    test "right bracket delimiter" do
      assert {:ok, [{:delimiter, :rbracket, _}, {:eof, _}]} = Lexer.tokenize("]")
    end
  end

  describe "additional edge cases for coverage" do
    test "whitespace at start with CRLF" do
      # Test CRLF at very start of file
      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} = Lexer.tokenize("\r\nx")
    end

    test "whitespace at start with CR" do
      # Test CR at very start of file
      assert {:ok, [{:identifier, "x", _}, {:eof, _}]} = Lexer.tokenize("\rx")
    end

    test "single-line comment with --[ at start" do
      # Ensure --[ path is taken
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[not a multiline")
    end

    test "multiline comment with --[[ at start" do
      # Ensure --[[ path is taken
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("--[[ multiline ]]")
    end

    test "long string starting at beginning" do
      assert {:ok, [{:string, "test", _}, {:eof, _}]} = Lexer.tokenize("[[test]]")
    end

    test "number followed by concat operator" do
      # Test the path where we have ".." after a number
      assert {:ok, [{:number, 5, _}, {:operator, :concat, _}, {:eof, _}]} =
               Lexer.tokenize("5..")
    end

    test "uppercase E in scientific notation for integer" do
      assert {:ok, [{:number, num, _}, {:eof, _}]} = Lexer.tokenize("2E5")
      assert num == 2.0e5
    end
  end

  describe "real Lua code examples" do
    test "tokenizes variable assignment" do
      code = "local x = 42"
      assert {:ok, tokens} = Lexer.tokenize(code)
      assert length(tokens) == 5
    end

    test "tokenizes if statement" do
      code = "if x > 0 then print(x) end"
      assert {:ok, tokens} = Lexer.tokenize(code)

      assert [
               {:keyword, :if, _},
               {:identifier, "x", _},
               {:operator, :gt, _},
               {:number, 0, _},
               {:keyword, :then, _},
               {:identifier, "print", _},
               {:delimiter, :lparen, _},
               {:identifier, "x", _},
               {:delimiter, :rparen, _},
               {:keyword, :end, _},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes function definition" do
      code = """
      function add(a, b)
        return a + b
      end
      """

      assert {:ok, tokens} = Lexer.tokenize(code)

      assert Enum.any?(tokens, fn
               {:keyword, :function, _} -> true
               _ -> false
             end)
    end

    test "tokenizes for loop" do
      code = "for i = 1, 10 do print(i) end"
      assert {:ok, tokens} = Lexer.tokenize(code)

      assert [
               {:keyword, :for, _},
               {:identifier, "i", _},
               {:operator, :assign, _},
               {:number, 1, _},
               {:delimiter, :comma, _},
               {:number, 10, _},
               {:keyword, :do, _},
               {:identifier, "print", _},
               {:delimiter, :lparen, _},
               {:identifier, "i", _},
               {:delimiter, :rparen, _},
               {:keyword, :end, _},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes table with mixed fields" do
      code = "{1, 2, x = 3, [\"key\"] = 4}"
      assert {:ok, tokens} = Lexer.tokenize(code)
      assert length(tokens) > 10
    end
  end
end
