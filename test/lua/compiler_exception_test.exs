defmodule Lua.CompilerExceptionTest do
  use ExUnit.Case, async: true

  test "compile errors include the 'Failed to compile' header" do
    assert_raise Lua.CompilerException, ~r/Failed to compile Lua/, fn ->
      Lua.eval!(Lua.new(), "local x =;")
    end
  end

  test "compile errors include source location (line and column)" do
    e =
      try do
        Lua.eval!(Lua.new(), "local x =;")
      rescue
        e in Lua.CompilerException -> e
      end

    msg = Exception.message(e)

    # The parser emits rich source context in its formatted error string,
    # which `CompilerException.message/1` then forwards under the "Failed
    # to compile Lua!" header. Assert the location bits survive.
    assert msg =~ "Failed to compile Lua!"
    assert msg =~ ~r/line\s+1/
    assert msg =~ ~r/column\s+\d+/
  end

  test "compile errors include the offending source line as context" do
    e =
      try do
        Lua.eval!(Lua.new(), "local x =;")
      rescue
        e in Lua.CompilerException -> e
      end

    msg = Exception.message(e)

    # The parser's error formatter renders the source line itself with a
    # caret pointing at the failure column.
    assert msg =~ "local x =;"
  end

  test "exception/1 accepts a binary error" do
    e = Lua.CompilerException.exception("oops")

    assert Exception.message(e) =~ "Failed to compile Lua!"
    assert Exception.message(e) =~ "oops"
  end

  test "exception/1 accepts a list of errors" do
    e = Lua.CompilerException.exception(["one", "two"])

    msg = Exception.message(e)
    assert msg =~ "one"
    assert msg =~ "two"
  end

  test "bare expression at statement level renders with location" do
    # Regression: this case previously produced
    # `(no position information)` because the parser dropped the
    # offending expression's position when raising the
    # `:unexpected_expression` error.
    e =
      try do
        Lua.eval!(Lua.new(), "2 + 2")
      rescue
        e in Lua.CompilerException -> e
      end

    msg = Exception.message(e)

    assert msg =~ "Failed to compile Lua!"
    assert msg =~ ~r/line\s+1/
    assert msg =~ ~r/column\s+\d+/
    assert msg =~ "bare arithmetic"
    refute msg =~ "(no position information)"
  end

  test "string-keyed table renders with location and a bracketed-key suggestion" do
    # Regression: `{ "ok" = 5 }` previously fell through the parser's
    # catch-all converter and rendered as raw Elixir terms with no
    # position. Now it renders with location and a suggestion pointing
    # the user at the bracketed-key form `{ ["ok"] = 5 }`.
    e =
      try do
        Lua.eval!(Lua.new(), ~S|return { "ok" = 5 }|)
      rescue
        e in Lua.CompilerException -> e
      end

    msg = Exception.message(e)

    assert msg =~ "Failed to compile Lua!"
    assert msg =~ ~r/line\s+1/
    assert msg =~ ~r/column\s+\d+/
    assert msg =~ "Expected ',' or '}' in table"
    assert msg =~ "Suggestion"
    assert msg =~ ~S(["key"] = value)
    refute msg =~ "(no position information)"
    refute msg =~ ":unexpected_token"
  end
end
