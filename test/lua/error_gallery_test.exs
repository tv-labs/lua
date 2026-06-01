defmodule Lua.ErrorGalleryTest do
  @moduledoc """
  Locks the user-visible rendered output for every error category a Lua
  program can hit. Each case evaluates a snippet and compares the public
  `Exception.message/1` against an expected string defined inline next to
  the source.

  The suite runs with ANSI disabled, so the expected text is stable across
  terminals. When the format changes on purpose, update the `expected`
  string for the affected case.
  """

  use ExUnit.Case, async: true

  # {name, lua source, eval opts, expected rendered message}. A finite
  # max_call_depth is set on the stack-overflow case so the recursion
  # terminates deterministically.
  @cases [
    {"arithmetic_on_non_number", "local x = nil\nprint(x + 1)", [],
     """
     Lua runtime error: at gallery.lua:2:

       attempt to perform arithmetic on a nil value (local 'x')

     Suggestion:
       Arithmetic requires numbers. Make sure both operands are numbers (or strings that can be coerced to numbers).\
     """},
    {"index_nil", "local t = nil\nprint(t.field)", [],
     """
     Lua runtime error: at gallery.lua:2:

       attempt to index a nil value (local 't')

     Suggestion:
       You can only index tables. Make sure the value you're indexing is a table, not a nil.\
     """},
    {"call_nil", "local f = nil\nf()", [],
     """
     Lua runtime error: at gallery.lua:2:

       attempt to call a nil value (local 'f')

     Suggestion:
       The value you're trying to call as a function is nil. Check that the function exists and is defined before this point.\
     """},
    {"concat_non_string", "local t = {}\nprint(t .. \"x\")", [],
     """
     Lua runtime error: at gallery.lua:2:

       attempt to concatenate a table value

     Suggestion:
       Concatenation (..) requires strings or numbers. Convert other values with tostring() first.\
     """},
    {"compare_incompatible", "print(1 < \"x\")", [],
     """
     Lua runtime error: at gallery.lua:1:

       attempt to compare number with string

     Suggestion:
       Relational operators (< <= > >=) only compare two numbers or two strings. Convert one operand so both sides share a type.\
     """},
    {"stdlib_bad_arg", "string.upper(nil)", [],
     """
     Lua runtime error: at gallery.lua:1:

       bad argument #1 to 'string.upper' (string expected, got nil)\
     """},
    {"assert_with_message", "assert(false, \"boom\")", [],
     """
     Lua runtime error: at gallery.lua:1:

       assertion failed: boom\
     """},
    {"assert_no_message", "assert(false)", [],
     """
     Lua runtime error: at gallery.lua:1:

       assertion failed: assertion failed!\
     """},
    {"error_string", "error(\"something broke\")", [],
     """
     Lua runtime error: at gallery.lua:1:

       runtime error: something broke\
     """},
    {"error_table", "error({code = 1})", [],
     """
     Lua runtime error: at gallery.lua:1:

       runtime error: (error object is a table value)\
     """},
    {"stack_overflow", "local function f(n) return 1 + f(n + 1) end\nf(1)", [max_call_depth: 30],
     """
     Lua runtime error: runtime error: stack overflow

     Stack trace:
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       ... 20 more frames ...
       gallery.lua:0: in function 'f'
       gallery.lua:0: in function 'f'
       gallery.lua:2: in function 'f'\
     """}
  ]

  setup do
    refute IO.ANSI.enabled?(), "gallery assumes ANSI is disabled in the test env"
    :ok
  end

  for {name, source, opts, expected} <- @cases do
    test "gallery: #{name}" do
      source = unquote(source)
      opts = unquote(opts)
      expected = unquote(expected)

      assert render(source, opts) == expected
    end
  end

  defp render(source, opts) do
    lua = Lua.new(opts)

    try do
      Lua.eval!(lua, source, source: "gallery.lua")
      flunk("expected #{inspect(source)} to raise")
    rescue
      e -> Exception.message(e)
    end
  end
end
