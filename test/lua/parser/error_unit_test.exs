defmodule Lua.Parser.ErrorUnitTest do
  use ExUnit.Case, async: true

  alias Lua.Parser.Error

  describe "new/4" do
    test "creates error with all fields" do
      position = %{line: 1, column: 5, byte_offset: 0}
      related = [Error.new(:unexpected_token, "related error", nil)]

      error =
        Error.new(
          :unexpected_token,
          "test message",
          position,
          suggestion: "test suggestion",
          source_lines: ["line 1", "line 2"],
          related: related
        )

      assert error.type == :unexpected_token
      assert error.message == "test message"
      assert error.position == position
      assert error.suggestion == "test suggestion"
      assert error.source_lines == ["line 1", "line 2"]
      assert error.related == related
    end

    test "creates error with minimal fields" do
      error = Error.new(:expected_token, "minimal error")

      assert error.type == :expected_token
      assert error.message == "minimal error"
      assert error.position == nil
      assert error.suggestion == nil
      assert error.source_lines == []
      assert error.related == []
    end

    test "creates error with position but no opts" do
      position = %{line: 2, column: 10, byte_offset: 15}
      error = Error.new(:invalid_syntax, "with position", position)

      assert error.type == :invalid_syntax
      assert error.message == "with position"
      assert error.position == position
      assert error.suggestion == nil
      assert error.source_lines == []
      assert error.related == []
    end
  end

  describe "unexpected_token/4" do
    test "creates error for delimiter token" do
      position = %{line: 1, column: 5, byte_offset: 0}
      error = Error.unexpected_token(:delimiter, ")", position, "expression")

      assert error.type == :unexpected_token
      assert String.contains?(error.message, "Unexpected ')'")
      assert String.contains?(error.message, "in expression")
      assert error.position == position
      assert error.suggestion == "Check for missing operators or keywords before this delimiter"
    end

    test "creates error for token in expression context" do
      position = %{line: 2, column: 3, byte_offset: 10}
      error = Error.unexpected_token(:keyword, "end", position, "primary expression")

      assert error.type == :unexpected_token
      assert String.contains?(error.message, "in primary expression")
      assert error.position == position

      assert error.suggestion ==
               "Expected an expression here (variable, number, string, table, function, etc.)"
    end

    test "creates error for token in statement context" do
      position = %{line: 3, column: 1, byte_offset: 20}
      error = Error.unexpected_token(:number, 42, position, "statement")

      assert error.type == :unexpected_token
      assert String.contains?(error.message, "in statement")
      assert error.position == position

      assert error.suggestion ==
               "Expected a statement here (assignment, function call, if, while, for, etc.)"
    end

    test "creates error with no specific suggestion" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.unexpected_token(:identifier, "foo", position, "block")

      assert error.type == :unexpected_token
      assert error.position == position
      assert error.suggestion == nil
    end
  end

  describe "expected_token/5" do
    test "creates error for expected 'end' keyword" do
      position = %{line: 10, column: 1, byte_offset: 100}
      error = Error.expected_token(:keyword, :end, :eof, nil, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected 'end'")
      assert String.contains?(error.message, "but got end of input")
      assert error.position == position

      assert String.contains?(
               error.suggestion,
               "Add 'end' to close the block. Check that all opening keywords"
             )
    end

    test "creates error for expected 'then' keyword" do
      position = %{line: 5, column: 20, byte_offset: 50}
      error = Error.expected_token(:keyword, :then, :identifier, "x", position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected 'then'")
      assert String.contains?(error.message, "but got identifier 'x'")

      assert String.contains?(
               error.suggestion,
               "Add 'then' after the condition. Lua requires 'then' after if/elseif conditions."
             )
    end

    test "creates error for expected 'do' keyword" do
      position = %{line: 7, column: 15, byte_offset: 75}
      error = Error.expected_token(:keyword, :do, :keyword, :end, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected 'do'")
      assert String.contains?(error.message, "but got 'end'")

      assert String.contains?(
               error.suggestion,
               "Add 'do' to start the loop body. Lua requires 'do' after while/for conditions."
             )
    end

    test "creates error for expected ')' delimiter" do
      position = %{line: 3, column: 12, byte_offset: 30}
      error = Error.expected_token(:delimiter, :rparen, :delimiter, :comma, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected 'rparen'")
      assert String.contains?(error.message, "but got 'comma'")
      assert String.contains?(error.suggestion, "Add ')' to close the parentheses")
    end

    test "creates error for expected ']' delimiter" do
      position = %{line: 4, column: 8, byte_offset: 40}
      error = Error.expected_token(:delimiter, :rbracket, :eof, nil, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected 'rbracket'")
      assert String.contains?(error.message, "but got end of input")
      assert String.contains?(error.suggestion, "Add ']' to close the brackets")
    end

    test "creates error for expected '}' delimiter" do
      position = %{line: 6, column: 5, byte_offset: 60}
      error = Error.expected_token(:delimiter, :rbrace, :keyword, :end, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected 'rbrace'")
      assert String.contains?(error.message, "but got 'end'")
      assert String.contains?(error.suggestion, "Add '}' to close the table constructor")
    end

    test "creates error for expected assignment operator" do
      position = %{line: 2, column: 7, byte_offset: 15}
      error = Error.expected_token(:operator, :assign, :number, 42, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected operator 'assign'")
      assert String.contains?(error.message, "but got number 42")
      assert String.contains?(error.suggestion, "Add '=' for assignment")
    end

    test "creates error for identifier when got keyword" do
      position = %{line: 8, column: 10, byte_offset: 80}
      error = Error.expected_token(:identifier, nil, :keyword, :if, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected identifier")
      assert String.contains?(error.message, "but got 'if'")
      assert String.contains?(error.suggestion, "Cannot use Lua keyword as identifier")
    end

    test "creates error with no specific suggestion" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:operator, :plus, :operator, :minus, position)

      assert error.type == :expected_token
      assert String.contains?(error.message, "Expected operator 'plus'")
      assert String.contains?(error.message, "but got operator 'minus'")
      assert error.suggestion == nil
    end
  end

  describe "unclosed_delimiter/3" do
    test "creates error for unclosed lparen" do
      position = %{line: 3, column: 5, byte_offset: 25}
      error = Error.unclosed_delimiter(:lparen, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed opening parenthesis '('")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing ')'")
      assert String.contains?(error.suggestion, "line 3")
    end

    test "creates error for unclosed lbracket" do
      position = %{line: 5, column: 2, byte_offset: 50}
      error = Error.unclosed_delimiter(:lbracket, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed opening bracket '['")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing ']'")
      assert String.contains?(error.suggestion, "line 5")
    end

    test "creates error for unclosed lbrace" do
      position = %{line: 7, column: 10, byte_offset: 75}
      error = Error.unclosed_delimiter(:lbrace, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed opening brace '{'")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing '}'")
      assert String.contains?(error.suggestion, "line 7")
    end

    test "creates error for unclosed function block" do
      position = %{line: 10, column: 1, byte_offset: 100}
      error = Error.unclosed_delimiter(:function, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed 'function' block")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing 'end'")
      assert String.contains?(error.suggestion, "line 10")
    end

    test "creates error for unclosed if statement" do
      position = %{line: 12, column: 1, byte_offset: 120}
      error = Error.unclosed_delimiter(:if, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed 'if' statement")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing 'end'")
      assert String.contains?(error.suggestion, "line 12")
    end

    test "creates error for unclosed while loop" do
      position = %{line: 15, column: 1, byte_offset: 150}
      error = Error.unclosed_delimiter(:while, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed 'while' loop")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing 'end'")
      assert String.contains?(error.suggestion, "line 15")
    end

    test "creates error for unclosed for loop" do
      position = %{line: 18, column: 1, byte_offset: 180}
      error = Error.unclosed_delimiter(:for, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed 'for' loop")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing 'end'")
      assert String.contains?(error.suggestion, "line 18")
    end

    test "creates error for unclosed do block" do
      position = %{line: 20, column: 1, byte_offset: 200}
      error = Error.unclosed_delimiter(:do, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed 'do' block")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing 'end'")
      assert String.contains?(error.suggestion, "line 20")
    end

    test "creates error for unknown delimiter (default case)" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.unclosed_delimiter(:unknown_delim, position)

      assert error.type == :unclosed_delimiter
      assert String.contains?(error.message, "Unclosed unknown_delim")
      assert error.position == position
      assert String.contains?(error.suggestion, "Add a closing matching delimiter")
      assert String.contains?(error.suggestion, "line 1")
    end

    test "creates error with close position different from open position" do
      open_pos = %{line: 3, column: 5, byte_offset: 25}
      close_pos = %{line: 10, column: 1, byte_offset: 100}
      error = Error.unclosed_delimiter(:lparen, open_pos, close_pos)

      assert error.type == :unclosed_delimiter
      assert error.position == close_pos
      assert String.contains?(error.suggestion, "line 3")
    end
  end

  describe "unexpected_end/2" do
    test "creates error with position" do
      position = %{line: 5, column: 1, byte_offset: 50}
      error = Error.unexpected_end("function body", position)

      assert error.type == :unexpected_end
      assert String.contains?(error.message, "Unexpected end of input")
      assert String.contains?(error.message, "while parsing function body")
      assert error.position == position

      assert String.contains?(
               error.suggestion,
               "Check for missing closing delimiters or keywords like 'end'"
             )
    end

    test "creates error without position" do
      error = Error.unexpected_end("expression")

      assert error.type == :unexpected_end
      assert String.contains?(error.message, "Unexpected end of input")
      assert String.contains?(error.message, "while parsing expression")
      assert error.position == nil
      assert error.suggestion != nil
    end
  end

  describe "format_token/2 (via expected_token)" do
    test "formats keyword token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:keyword, :if, :keyword, :while, position)

      assert String.contains?(error.message, "'if'")
      assert String.contains?(error.message, "'while'")
    end

    test "formats identifier token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:identifier, "foo", :identifier, "bar", position)

      assert String.contains?(error.message, "identifier 'foo'")
      assert String.contains?(error.message, "identifier 'bar'")
    end

    test "formats number token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:number, 123, :number, 456, position)

      assert String.contains?(error.message, "number 123")
      assert String.contains?(error.message, "number 456")
    end

    test "formats string token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:string, "hello", :string, "world", position)

      assert String.contains?(error.message, "string \"hello\"")
      assert String.contains?(error.message, "string \"world\"")
    end

    test "formats operator token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:operator, :plus, :operator, :minus, position)

      assert String.contains?(error.message, "operator 'plus'")
      assert String.contains?(error.message, "operator 'minus'")
    end

    test "formats delimiter token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:delimiter, "(", :delimiter, ")", position)

      assert String.contains?(error.message, "'('")
      assert String.contains?(error.message, "')'")
    end

    test "formats eof token" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:keyword, :end, :eof, nil, position)

      assert String.contains?(error.message, "end of input")
    end

    test "formats unknown token type (default case)" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.expected_token(:unknown_type, "value", :other_type, "value2", position)

      assert String.contains?(error.message, "unknown_type")
      assert String.contains?(error.message, "other_type")
    end
  end

  describe "format/2" do
    test "formats error with position and context" do
      source_code = """
      local x = 1
      local y = 2 +
      local z = 3
      """

      position = %{line: 2, column: 14, byte_offset: 26}
      error = Error.new(:unexpected_token, "Unexpected token", position)
      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "Parse Error")
      assert String.contains?(formatted, "at line 2, column 14")
      assert String.contains?(formatted, "Unexpected token")
      assert String.contains?(formatted, "local x = 1")
      assert String.contains?(formatted, "local y = 2 +")
      assert String.contains?(formatted, "local z = 3")
      assert String.contains?(formatted, "^")
    end

    test "formats error without position" do
      source_code = "local x = 1"
      error = Error.new(:unexpected_end, "Unexpected end")
      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "Parse Error")
      assert String.contains?(formatted, "(no position information)")
      assert String.contains?(formatted, "Unexpected end")
      refute String.contains?(formatted, "^")
    end

    test "formats error with suggestion" do
      source_code = "local x = 1"
      position = %{line: 1, column: 5, byte_offset: 0}

      error =
        Error.new(:expected_token, "Expected something", position,
          suggestion: "Try adding a semicolon"
        )

      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "Suggestion:")
      assert String.contains?(formatted, "Try adding a semicolon")
    end

    test "formats error without suggestion" do
      source_code = "local x = 1"
      position = %{line: 1, column: 5, byte_offset: 0}
      error = Error.new(:invalid_syntax, "Invalid syntax", position)
      formatted = Error.format(error, source_code)

      refute String.contains?(formatted, "Suggestion:")
    end

    test "formats error with related errors" do
      source_code = "local x = 1"
      position = %{line: 1, column: 5, byte_offset: 0}
      related_pos = %{line: 1, column: 10, byte_offset: 5}

      related = [Error.new(:unexpected_token, "Related issue", related_pos)]
      error = Error.new(:expected_token, "Main error", position, related: related)
      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "Related errors:")
      assert String.contains?(formatted, "Related issue")
    end

    test "formats error without related errors" do
      source_code = "local x = 1"
      position = %{line: 1, column: 5, byte_offset: 0}
      error = Error.new(:unexpected_token, "Simple error", position)
      formatted = Error.format(error, source_code)

      refute String.contains?(formatted, "Related errors:")
    end

    test "formats error at start of file (line 1)" do
      source_code = """
      function foo()
        x = 1
      end
      """

      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.new(:unexpected_token, "Error at start", position)
      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "at line 1, column 1")
      assert String.contains?(formatted, "function foo()")
      assert String.contains?(formatted, "x = 1")
    end

    test "formats error at end of file" do
      source_code = """
      line 1
      line 2
      line 3
      line 4
      line 5
      """

      position = %{line: 5, column: 6, byte_offset: 30}
      error = Error.new(:unexpected_end, "Error at end", position)
      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "at line 5, column 6")
      assert String.contains?(formatted, "line 3")
      assert String.contains?(formatted, "line 4")
      assert String.contains?(formatted, "line 5")
    end

    test "formats error with empty source code" do
      source_code = ""
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.new(:unexpected_end, "Empty file", position)
      formatted = Error.format(error, source_code)

      assert String.contains?(formatted, "Parse Error")
      assert String.contains?(formatted, "Empty file")
      # Even with empty source, it will show context if position exists
      # The format_context function will handle empty lines gracefully
    end

    test "formats error showing context lines" do
      source_code = """
      line 1
      line 2
      line 3
      line 4
      line 5
      line 6
      line 7
      """

      position = %{line: 4, column: 3, byte_offset: 21}
      error = Error.new(:unexpected_token, "Error in middle", position)
      formatted = Error.format(error, source_code)

      # Should show 2 lines before and after (lines 2, 3, 4, 5, 6)
      assert String.contains?(formatted, "line 2")
      assert String.contains?(formatted, "line 3")
      assert String.contains?(formatted, "line 4")
      assert String.contains?(formatted, "line 5")
      assert String.contains?(formatted, "line 6")
      refute String.contains?(formatted, "line 1\n")
      refute String.contains?(formatted, "line 7\n")
    end

    test "formats error with pointer at correct column" do
      source_code = "local x = 1 + 2"
      position = %{line: 1, column: 15, byte_offset: 14}
      error = Error.new(:unexpected_token, "Error", position)
      formatted = Error.format(error, source_code)

      lines = String.split(formatted, "\n")
      error_line_idx = Enum.find_index(lines, &String.contains?(&1, "local x = 1 + 2"))
      pointer_line = Enum.at(lines, error_line_idx + 1)

      # Pointer should be at column 15
      assert String.contains?(pointer_line, "^")
      # Count spaces before ^
      spaces_before = pointer_line |> String.split("^") |> hd() |> String.length()
      # Should account for line number formatting (4 digits + " │ " = 7 chars) + column - 1
      assert spaces_before >= 20
    end
  end

  describe "format_multiple/2" do
    test "formats single error" do
      source_code = "local x = 1"
      position = %{line: 1, column: 5, byte_offset: 0}
      error = Error.new(:unexpected_token, "Error 1", position)
      formatted = Error.format_multiple([error], source_code)

      assert String.contains?(formatted, "Found 1 parse error")
      refute String.contains?(formatted, "1 parse errors")
      assert String.contains?(formatted, "Error 1:")
      assert String.contains?(formatted, "Error 1")
    end

    test "formats multiple errors" do
      source_code = """
      local x = 1
      local y = 2
      local z = 3
      """

      position1 = %{line: 1, column: 5, byte_offset: 0}
      position2 = %{line: 2, column: 5, byte_offset: 12}

      error1 = Error.new(:unexpected_token, "First error", position1)
      error2 = Error.new(:expected_token, "Second error", position2)

      formatted = Error.format_multiple([error1, error2], source_code)

      assert String.contains?(formatted, "Found 2 parse errors")
      assert String.contains?(formatted, "Error 1:")
      assert String.contains?(formatted, "First error")
      assert String.contains?(formatted, "Error 2:")
      assert String.contains?(formatted, "Second error")
    end

    test "formats three errors" do
      source_code = "x"
      position = %{line: 1, column: 1, byte_offset: 0}

      error1 = Error.new(:unexpected_token, "E1", position)
      error2 = Error.new(:expected_token, "E2", position)
      error3 = Error.new(:invalid_syntax, "E3", position)

      formatted = Error.format_multiple([error1, error2, error3], source_code)

      assert String.contains?(formatted, "Found 3 parse errors")
      assert String.contains?(formatted, "Error 1:")
      assert String.contains?(formatted, "Error 2:")
      assert String.contains?(formatted, "Error 3:")
    end
  end
end
