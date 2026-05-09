defmodule Lua.VM.DisplayTest do
  @moduledoc """
  Inspect protocol for VM values surfaced at the `Lua.eval/2` /
  `Lua.eval!/2` boundary.
  """

  use ExUnit.Case, async: true

  alias Lua.VM.Display
  alias Lua.VM.Display.Closure
  alias Lua.VM.Display.NativeFunc
  alias Lua.VM.Display.Table, as: DTable
  alias Lua.VM.Display.Userdata

  describe "Lua.VM.Display.Table inspect" do
    test "renders a sequence-like table as a list" do
      {[t], _} = Lua.eval!(Lua.new(), "return {10, 20, 30}", decode: false)

      assert %DTable{id: id, peek: [10, 20, 30]} = t
      assert is_integer(id)
      assert inspect(t) == "#Lua.Table<id: #{id}, [10, 20, 30]>"
    end

    test "renders a mixed-key table as a map" do
      {[t], _} = Lua.eval!(Lua.new(), "return {a = 1, b = 2}", decode: false)

      assert %DTable{peek: peek} = t
      assert peek == %{"a" => 1, "b" => 2}
      assert inspect(t) =~ ~r/^#Lua\.Table<id: \d+, %\{"a" => 1, "b" => 2\}>$/
    end

    test "stores the underlying tref on :ref so Lua.unwrap recovers it" do
      {[t], _} = Lua.eval!(Lua.new(), "return {}", decode: false)

      assert match?({:tref, _}, Lua.unwrap(t))
      assert Lua.unwrap(t) == t.ref
    end

    test "renders empty tables" do
      {[t], _} = Lua.eval!(Lua.new(), "return {}", decode: false)

      assert %DTable{peek: peek} = t
      # Empty table renders as the underlying empty map, since it is
      # not sequence-like.
      assert peek == %{}
      assert inspect(t) =~ "#Lua.Table<id: "
    end

    test "respects Inspect.Opts (limit truncates large peeks)" do
      {[t], _} =
        Lua.eval!(
          Lua.new(),
          "local t = {}; for i = 1, 50 do t[i] = i end; return t",
          decode: false
        )

      tight = inspect(t, limit: 5)
      loose = inspect(t, limit: 50)

      # The tight render must show a truncation marker; the loose
      # render shows everything and is therefore strictly longer.
      assert tight =~ "..."
      assert byte_size(tight) < byte_size(loose)
    end
  end

  describe "Lua.VM.Display.Closure inspect" do
    test "wraps Lua closures returned in default decode mode" do
      {[c], _} = Lua.eval!(Lua.new(), "return function(a, b) return a + b end")

      assert %Closure{
               source: "<eval>",
               line: 1,
               arity: 2,
               vararg?: false,
               ref: {:lua_closure, _, _}
             } = c

      assert inspect(c) == "#Lua.Closure<source: \"<eval>\", line: 1, arity: 2>"
    end

    test "wraps Lua closures returned in decode: false mode" do
      {[c], _} = Lua.eval!(Lua.new(), "return function() end", decode: false)

      assert %Closure{ref: {:lua_closure, _, _}} = c
      assert inspect(c) =~ "#Lua.Closure<"
    end

    test "marks variadic closures with +..." do
      {[c], _} = Lua.eval!(Lua.new(), "return function(a, ...) return a end")

      assert %Closure{arity: 1, vararg?: true} = c
      assert inspect(c) =~ "arity: 1+..."
    end

    test "honours custom :source from the eval option" do
      {[c], _} =
        Lua.eval!(
          Lua.new(),
          "return function() end",
          source: "my_script.lua"
        )

      assert %Closure{source: "my_script.lua"} = c
      assert inspect(c) =~ ~s|source: "my_script.lua"|
    end
  end

  describe "Lua.VM.Display.NativeFunc inspect" do
    test "wraps native functions returned in default decode mode" do
      {[f], _} = Lua.eval!(Lua.new(), "return string.lower")

      assert %NativeFunc{ref: {:native_func, _}} = f
      assert inspect(f) =~ "#Lua.NativeFunc<"
    end

    test "wraps user-defined Elixir functions installed via Lua.set!/3" do
      lua = Lua.set!(Lua.new(), [:double], fn [n] -> [n * 2] end)
      {[f], _} = Lua.eval!(lua, "return double")

      assert %NativeFunc{ref: {:native_func, _}} = f
      assert inspect(f) =~ "#Lua.NativeFunc<"
    end
  end

  describe "Lua.VM.Display.Userdata inspect" do
    test "wraps userdata refs in decode: false mode" do
      lua = Lua.set!(Lua.new(), [:opaque], {:userdata, %{secret: 42}})
      {[u], _} = Lua.eval!(lua, "return opaque", decode: false)

      assert %Userdata{
               id: id,
               term: %{secret: 42},
               ref: {:udref, _}
             } = u

      assert is_integer(id)
      assert inspect(u) =~ "#Lua.Userdata<id: #{id}, term: %{secret: 42}>"
    end

    test "default decode preserves the legacy {:userdata, term} shape" do
      lua = Lua.set!(Lua.new(), [:opaque], {:userdata, :marker})
      {[u], _} = Lua.eval!(lua, "return opaque")

      # decode: true is the default. Userdata stays as the
      # backwards-compatible {:userdata, term} tuple.
      assert u == {:userdata, :marker}
    end
  end

  describe "Lua.unwrap/1" do
    test "returns the underlying tref for tables" do
      {[t], _} = Lua.eval!(Lua.new(), "return {1}", decode: false)

      assert match?({:tref, _}, Lua.unwrap(t))
    end

    test "returns the underlying lua_closure for closures" do
      {[c], _} = Lua.eval!(Lua.new(), "return function() end")

      assert match?({:lua_closure, _, _}, Lua.unwrap(c))
    end

    test "returns the underlying native_func for native funcs" do
      {[f], _} = Lua.eval!(Lua.new(), "return string.lower")

      assert match?({:native_func, _}, Lua.unwrap(f))
    end

    test "returns the underlying udref for userdata" do
      lua = Lua.set!(Lua.new(), [:opaque], {:userdata, :anything})
      {[u], _} = Lua.eval!(lua, "return opaque", decode: false)

      assert match?({:udref, _}, Lua.unwrap(u))
    end

    test "passes plain values through unchanged" do
      assert Lua.unwrap(42) == 42
      assert Lua.unwrap("hello") == "hello"
      assert Lua.unwrap(nil) == nil
      assert Lua.unwrap({:tref, 7}) == {:tref, 7}
    end
  end

  describe "round-tripping wrapped values back into the VM" do
    test "Lua.set!/3 accepts a wrapped table" do
      {[t], lua} = Lua.eval!(Lua.new(), "return {a = 1}", decode: false)
      lua = Lua.set!(lua, [:saved], t)

      assert {[1], _} = Lua.eval!(lua, "return saved.a")
    end

    test "Lua.set!/3 accepts a wrapped closure" do
      {[c], lua} = Lua.eval!(Lua.new(), "return function(x) return x + 1 end")
      lua = Lua.set!(lua, [:f], c)

      assert {[6], _} = Lua.eval!(lua, "return f(5)")
    end

    test "Lua.call_function/3 accepts a wrapped closure" do
      {[c], lua} = Lua.eval!(Lua.new(), "return function(x) return x * 3 end")

      assert {:ok, [21], _} = Lua.call_function(lua, c, [7])
    end

    test "Lua.call_function/3 accepts a wrapped native func" do
      {[f], lua} = Lua.eval!(Lua.new(), "return string.upper")

      assert {:ok, ["HELLO"], _} = Lua.call_function(lua, f, ["hello"])
    end

    test "Lua.encode!/2 accepts a wrapped value" do
      {[t], lua} = Lua.eval!(Lua.new(), "return {1, 2}", decode: false)
      assert {{:tref, _}, _} = Lua.encode!(lua, t)
    end

    test "Lua.decode!/2 accepts a wrapped value" do
      {[t], lua} = Lua.eval!(Lua.new(), "return {1, 2}", decode: false)
      decoded = Lua.decode!(lua, t)

      assert Enum.sort(decoded) == [{1, 1}, {2, 2}]
    end
  end

  describe "Lua.VM.Display.display_struct?/1" do
    test "recognises every display struct" do
      assert Display.display_struct?(%DTable{id: 0, peek: [], ref: {:tref, 0}})
      assert Display.display_struct?(%Userdata{id: 0, term: nil, ref: {:udref, 0}})

      assert Display.display_struct?(%Closure{
               source: "x",
               line: 0,
               arity: 0,
               vararg?: false,
               ref: {:lua_closure, nil, nil}
             })

      assert Display.display_struct?(%NativeFunc{
               fun: fn _, s -> {[], s} end,
               ref: {:native_func, fn _, s -> {[], s} end}
             })
    end

    test "rejects ordinary values" do
      refute Display.display_struct?(42)
      refute Display.display_struct?("hello")
      refute Display.display_struct?({:tref, 0})
      refute Display.display_struct?({:lua_closure, nil, nil})
      refute Display.display_struct?({:native_func, fn _, _ -> nil end})
      refute Display.display_struct?({:udref, 0})
    end
  end

  describe "no regression for default decode" do
    test "tables still come back as a list of {key, value} tuples" do
      {[result], _} = Lua.eval!(Lua.new(), "return {a = 1, b = 2}")

      assert is_list(result)
      assert Enum.sort(result) == [{"a", 1}, {"b", 2}]
    end

    test "userdata still comes back as {:userdata, term}" do
      lua = Lua.set!(Lua.new(), [:opaque], {:userdata, %{x: 1}})
      {[result], _} = Lua.eval!(lua, "return opaque")

      assert result == {:userdata, %{x: 1}}
    end
  end
end
