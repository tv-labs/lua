defmodule Lua.UtilTest do
  use ExUnit.Case, async: true

  doctest Lua.Util, import: true

  describe "format_stacktrace/1" do
    test "it pretty prints a stacktrace" do
      stacktrace = [
        {nil, [], [file: "-no-file-", line: 1]},
        {"foo", [], [file: "-no-file-", line: 2]},
        {"-no-name-", [], [file: "-no-file-", line: 6]}
      ]

      assert Lua.Util.format_stacktrace(stacktrace, %{}) ==
               String.trim("""
               script line 2: <unknown function>()
               script line 6: foo()
               """)
    end

    test "it can show function arities" do
      stacktrace = [
        {nil, ["dude"], [file: "-no-file-", line: 1]},
        {"foo", [2, "dude"], [file: "-no-file-", line: 2]},
        {"bar", [1], [file: "-no-file-", line: 8]},
        {"-no-name-", [], [file: "-no-file-", line: 11]}
      ]

      assert Lua.Util.format_stacktrace(stacktrace, %{}) ==
               String.trim("""
               script line 2: <unknown function>(\"dude\")
               script line 8: foo(2, "dude\")
               script line 11: bar(1)
               """)
    end
  end
end
