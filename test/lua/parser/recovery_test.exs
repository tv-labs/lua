defmodule Lua.Parser.RecoveryTest do
  use ExUnit.Case, async: true

  alias Lua.Parser.Recovery
  alias Lua.Parser.Error

  describe "recover_at_statement/2" do
    test "recovers at semicolon" do
      tokens = [
        {:delimiter, :semicolon, %{line: 1, column: 5}},
        {:keyword, :end, %{line: 1, column: 7}},
        {:eof, %{line: 1, column: 10}}
      ]

      error = Error.new(:unexpected_token, "Unexpected token", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_at_statement(tokens, error)
      assert [{:delimiter, :semicolon, _} | _] = rest
    end

    test "recovers at end keyword" do
      tokens = [
        {:keyword, :end, %{line: 1, column: 1}},
        {:eof, %{line: 1, column: 4}}
      ]

      error = Error.new(:unexpected_token, "Test error", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_at_statement(tokens, error)
      assert [{:keyword, :end, _} | _] = rest
    end

    test "recovers at statement keywords" do
      keywords = [:if, :while, :for, :function, :local, :do, :repeat]

      for kw <- keywords do
        tokens = [
          {:keyword, kw, %{line: 1, column: 1}},
          {:eof, %{line: 1, column: 10}}
        ]

        error = Error.new(:unexpected_token, "Test", %{line: 1, column: 1})
        assert {:recovered, _, [^error]} = Recovery.recover_at_statement(tokens, error)
      end
    end

    test "recovers when only EOF remains (EOF is a boundary)" do
      tokens = [
        {:identifier, "x", %{line: 1, column: 1}},
        {:operator, :assign, %{line: 1, column: 3}},
        {:eof, %{line: 1, column: 5}}
      ]

      error = Error.new(:unexpected_token, "Test", %{line: 1, column: 1})

      # EOF is actually a statement boundary, so this recovers
      assert {:recovered, rest, [^error]} = Recovery.recover_at_statement(tokens, error)
      assert length(rest) >= 1
    end

    test "recovers at EOF" do
      tokens = [{:eof, %{line: 1, column: 1}}]
      error = Error.new(:unexpected_token, "Test", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_at_statement(tokens, error)
      assert [{:eof, _}] = rest
    end
  end

  describe "recover_unclosed_delimiter/3" do
    test "finds closing parenthesis" do
      tokens = [
        {:delimiter, :rparen, %{line: 1, column: 10}},
        {:eof, %{line: 1, column: 11}}
      ]

      error = Error.new(:unclosed_delimiter, "Unclosed (", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_unclosed_delimiter(tokens, :lparen, error)
      assert [{:eof, _}] = rest
    end

    test "finds closing bracket" do
      tokens = [
        {:delimiter, :rbracket, %{line: 1, column: 10}},
        {:eof, %{line: 1, column: 11}}
      ]

      error = Error.new(:unclosed_delimiter, "Unclosed [", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_unclosed_delimiter(tokens, :lbracket, error)
      assert [{:eof, _}] = rest
    end

    test "finds closing brace" do
      tokens = [
        {:delimiter, :rbrace, %{line: 1, column: 10}},
        {:eof, %{line: 1, column: 11}}
      ]

      error = Error.new(:unclosed_delimiter, "Unclosed {", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_unclosed_delimiter(tokens, :lbrace, error)
      assert [{:eof, _}] = rest
    end

    test "handles nested delimiters" do
      tokens = [
        {:delimiter, :lparen, %{line: 1, column: 2}},
        {:delimiter, :rparen, %{line: 1, column: 3}},
        {:delimiter, :rparen, %{line: 1, column: 4}},
        {:eof, %{line: 1, column: 5}}
      ]

      error = Error.new(:unclosed_delimiter, "Test", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_unclosed_delimiter(tokens, :lparen, error)
      assert [{:eof, _}] = rest
    end

    test "falls back to statement boundary if delimiter not found" do
      tokens = [
        {:keyword, :end, %{line: 1, column: 5}},
        {:eof, %{line: 1, column: 8}}
      ]

      error = Error.new(:unclosed_delimiter, "Test", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_unclosed_delimiter(tokens, :lparen, error)
      assert [{:keyword, :end, _} | _] = rest
    end
  end

  describe "recover_missing_keyword/3" do
    test "finds the missing keyword" do
      tokens = [
        {:identifier, "x", %{line: 1, column: 1}},
        {:keyword, :then, %{line: 1, column: 3}},
        {:keyword, :end, %{line: 1, column: 8}}
      ]

      error = Error.new(:expected_token, "Expected then", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_missing_keyword(tokens, :then, error)
      assert [{:keyword, :then, _} | _] = rest
    end

    test "falls back to statement boundary if keyword not found" do
      tokens = [
        {:keyword, :end, %{line: 1, column: 1}},
        {:eof, %{line: 1, column: 4}}
      ]

      error = Error.new(:expected_token, "Expected then", %{line: 1, column: 1})

      assert {:recovered, rest, [^error]} = Recovery.recover_missing_keyword(tokens, :then, error)
      assert [{:keyword, :end, _} | _] = rest
    end
  end

  describe "skip_to_statement/1" do
    test "skips to statement boundary" do
      tokens = [
        {:identifier, "x", %{line: 1, column: 1}},
        {:operator, :assign, %{line: 1, column: 3}},
        {:keyword, :end, %{line: 1, column: 5}},
        {:eof, %{line: 1, column: 8}}
      ]

      rest = Recovery.skip_to_statement(tokens)
      assert [{:keyword, :end, _} | _] = rest
    end

    test "returns empty list if no boundary found" do
      tokens = [
        {:identifier, "x", %{line: 1, column: 1}},
        {:operator, :assign, %{line: 1, column: 3}}
      ]

      assert [] = Recovery.skip_to_statement(tokens)
    end

    test "returns tokens if already at boundary" do
      tokens = [
        {:keyword, :end, %{line: 1, column: 1}},
        {:eof, %{line: 1, column: 4}}
      ]

      assert ^tokens = Recovery.skip_to_statement(tokens)
    end
  end

  describe "is_statement_boundary?/1" do
    test "recognizes delimiters" do
      assert Recovery.is_statement_boundary?({:delimiter, :semicolon, %{line: 1, column: 1}})
    end

    test "recognizes block terminators" do
      terminators = [:end, :else, :elseif, :until]

      for term <- terminators do
        assert Recovery.is_statement_boundary?({:keyword, term, %{line: 1, column: 1}})
      end
    end

    test "recognizes statement starters" do
      starters = [:if, :while, :for, :function, :local, :do, :repeat]

      for starter <- starters do
        assert Recovery.is_statement_boundary?({:keyword, starter, %{line: 1, column: 1}})
      end
    end

    test "recognizes EOF" do
      assert Recovery.is_statement_boundary?({:eof, %{line: 1, column: 1}})
    end

    test "rejects non-boundaries" do
      refute Recovery.is_statement_boundary?({:identifier, "x", %{line: 1, column: 1}})
      refute Recovery.is_statement_boundary?({:number, 42, %{line: 1, column: 1}})
      refute Recovery.is_statement_boundary?({:operator, :add, %{line: 1, column: 1}})
    end
  end

  describe "DelimiterStack" do
    alias Recovery.DelimiterStack

    test "creates empty stack" do
      stack = DelimiterStack.new()
      assert DelimiterStack.empty?(stack)
    end

    test "pushes delimiter" do
      stack = DelimiterStack.new()
      stack = DelimiterStack.push(stack, :lparen, %{line: 1, column: 1})
      refute DelimiterStack.empty?(stack)
    end

    test "pops matching delimiter" do
      stack = DelimiterStack.new()
      stack = DelimiterStack.push(stack, :lparen, %{line: 1, column: 1})

      assert {:ok, stack} = DelimiterStack.pop(stack, :rparen)
      assert DelimiterStack.empty?(stack)
    end

    test "fails on mismatched delimiter" do
      stack = DelimiterStack.new()
      stack = DelimiterStack.push(stack, :lparen, %{line: 1, column: 1})

      assert {:error, :mismatched, :lparen} = DelimiterStack.pop(stack, :rbracket)
    end

    test "fails on empty stack" do
      stack = DelimiterStack.new()
      assert {:error, :empty} = DelimiterStack.pop(stack, :rparen)
    end

    test "peeks at top delimiter" do
      stack = DelimiterStack.new()
      stack = DelimiterStack.push(stack, :lparen, %{line: 1, column: 1})

      assert {:ok, :lparen, %{line: 1, column: 1}} = DelimiterStack.peek(stack)
    end

    test "peek returns empty on empty stack" do
      stack = DelimiterStack.new()
      assert :empty = DelimiterStack.peek(stack)
    end

    test "handles nested delimiters" do
      stack = DelimiterStack.new()
      stack = DelimiterStack.push(stack, :lparen, %{line: 1, column: 1})
      stack = DelimiterStack.push(stack, :lbracket, %{line: 1, column: 5})
      stack = DelimiterStack.push(stack, :lbrace, %{line: 1, column: 10})

      assert {:ok, stack} = DelimiterStack.pop(stack, :rbrace)
      assert {:ok, stack} = DelimiterStack.pop(stack, :rbracket)
      assert {:ok, stack} = DelimiterStack.pop(stack, :rparen)
      assert DelimiterStack.empty?(stack)
    end

    test "handles keyword delimiters" do
      stack = DelimiterStack.new()
      stack = DelimiterStack.push(stack, :function, %{line: 1, column: 1})

      assert {:ok, stack} = DelimiterStack.pop(stack, :end)
      assert DelimiterStack.empty?(stack)
    end

    test "matches all delimiter pairs" do
      pairs = [
        {:lparen, :rparen},
        {:lbracket, :rbracket},
        {:lbrace, :rbrace},
        {:function, :end},
        {:if, :end},
        {:while, :end},
        {:for, :end},
        {:do, :end}
      ]

      for {open, close} <- pairs do
        stack = DelimiterStack.new()
        stack = DelimiterStack.push(stack, open, %{line: 1, column: 1})
        assert {:ok, _} = DelimiterStack.pop(stack, close)
      end
    end
  end
end
