defmodule Lua.UtilTest do
  use ExUnit.Case, async: true

  doctest Lua.Util, import: true

  describe "encoded?/1" do
    test "returns true for encoded values" do
      assert Lua.Util.encoded?(nil)
      assert Lua.Util.encoded?(true)
      assert Lua.Util.encoded?(false)
      assert Lua.Util.encoded?("")
      assert Lua.Util.encoded?("hello")
      assert Lua.Util.encoded?(<<1, 2, 3>>)
      assert Lua.Util.encoded?(0)
      assert Lua.Util.encoded?(Enum.random(1..1000))
      assert Lua.Util.encoded?(:rand.uniform())

      # tref
      {{:tref, _} = table, _lua} = Lua.encode!(Lua.new(), %{a: 1, b: 2})
      assert Lua.Util.encoded?(table)

      # Userdata
      {{:usdref, _} = userdata, _lua} = Lua.encode!(Lua.new(), {:userdata, 1234})
      assert Lua.Util.encoded?(userdata)

      # erlang function
      {{:erl_func, _} = erl_func, _lua} = Lua.encode!(Lua.new(), fn a -> a end)
      assert Lua.Util.encoded?(erl_func)

      # erl mfa
      {[{:erl_mfa, _, _, _} = erl_mfa], _lua} = Lua.eval!("return string.lower", decode: false)
      assert Lua.Util.encoded?(erl_mfa)

      # Function ref
      {[{:funref, _, _} = funref], _lua} =
        Lua.eval!(
          """
          function addOne(val)
             return val + 1
          end

          return addOne
          """,
          decode: false
        )

      assert Lua.Util.encoded?(funref)
    end

    test "returns false for non decoded values" do
      refute Lua.Util.encoded?(%{a: 1})
      refute Lua.Util.encoded?({:not, :valid, :lua})
      refute Lua.Util.encoded?([])
      refute Lua.Util.encoded?([:a, :b, :c])
      refute Lua.Util.encoded?(["a", "b", :c])
      refute Lua.Util.encoded?(["a", "b", "c"])
      refute Lua.Util.encoded?(self())
      refute Lua.Util.encoded?(&Enum.map/2)
      refute Lua.Util.encoded?(make_ref())
      refute Lua.Util.encoded?(fn a -> a end)
      refute Lua.Util.encoded?({:userdata, 1})
      refute Lua.Util.encoded?([1, 2, [3]])
    end
  end

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
