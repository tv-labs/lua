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

      # native function
      {func, _lua} = Lua.encode!(Lua.new(), fn a -> a end)
      assert Lua.Util.encoded?(func)

      # Lua closure
      {[closure], _lua} =
        Lua.eval!(
          """
          function addOne(val)
             return val + 1
          end

          return addOne
          """,
          decode: false
        )

      assert Lua.Util.encoded?(closure)
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
    @tag :pending
    test "it pretty prints a stacktrace" do
      # Stacktrace formatting not yet implemented for new VM
    end

    @tag :pending
    test "it can show function arities" do
      # Stacktrace formatting not yet implemented for new VM
    end
  end
end
