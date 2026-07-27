defmodule Lua.Compiler.UpvalueDescriptorTest do
  @moduledoc """
  Pins one upvalue slot per captured variable, not one per reference.

  Lua 5.3 §3.5 gives a closure one upvalue per free variable it uses;
  `debug.getupvalue` numbering follows that list. Two references to the same
  free variable therefore share a slot. Closure creation already resolved
  identical descriptors to the same cell — `{:parent_local, reg, _}` through
  the single open-upvalue cell for `reg`, `{:parent_upvalue, i, _}` through
  the enclosing closure's slot `i` — so collapsing them changes only how many
  slots each closure carries, never which cell a read or write reaches.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Prototype
  alias Lua.Parser

  describe "upvalue_descriptors" do
    test "a variable referenced many times gets one slot" do
      [f] =
        prototypes_of("""
        local x = 10
        local function f() return x + x + x + x end
        return f()
        """)

      assert f.upvalue_descriptors == [{:parent_local, 0, "_ENV"}, {:parent_local, 1, "x"}]
      assert f.upvalue_names == ["_ENV", "x"]
    end

    test "a global referenced many times gets one _ENV slot" do
      [f] =
        prototypes_of("""
        local function f() return print, print, print end
        return f()
        """)

      assert f.upvalue_descriptors == [{:parent_local, 0, "_ENV"}]
    end

    test "a self-recursive local function captures itself once" do
      [fib] =
        prototypes_of("""
        local function fib(n)
          if n < 2 then return n end
          return fib(n - 1) + fib(n - 2)
        end
        return fib(10)
        """)

      assert fib.upvalue_descriptors == [{:parent_local, 0, "_ENV"}, {:parent_local, 1, "fib"}]
    end

    test "a grandparent capture is deduped at every level" do
      [outer] =
        prototypes_of("""
        local a = 1
        local function outer()
          return function() return a + a + a end
        end
        return outer()()
        """)

      [inner] = outer.prototypes

      assert outer.upvalue_descriptors == [{:parent_local, 0, "_ENV"}, {:parent_local, 1, "a"}]
      assert inner.upvalue_descriptors == [{:parent_upvalue, 0, "_ENV"}, {:parent_upvalue, 1, "a"}]
    end

    test "shadowed captures of the same name stay in their own function's list" do
      # `outer` captures the chunk's `x`; `inner` captures `outer`'s own `x`.
      # The two descriptors are equal tuples over different cells, so the
      # dedupe has to be per-function — a chunk-wide one would fuse them.
      [outer] =
        prototypes_of("""
        local x = 1
        local function outer()
          local seen = x
          local x = 2
          return function() return seen + x + x end
        end
        return outer()()
        """)

      [inner] = outer.prototypes

      assert outer.upvalue_descriptors == [{:parent_local, 0, "_ENV"}, {:parent_local, 1, "x"}]

      assert inner.upvalue_descriptors == [
               {:parent_upvalue, 0, "_ENV"},
               {:parent_local, 0, "seen"},
               {:parent_local, 1, "x"}
             ]

      assert {[5], _} =
               Lua.eval!("""
               local x = 1
               local function outer()
                 local seen = x
                 local x = 2
                 return function() return seen + x + x end
               end
               return outer()()
               """)
    end

    test "no prototype in the compilable surface carries a duplicate descriptor" do
      sources = Path.wildcard("test/lua53_tests/*.lua") ++ Path.wildcard("test/integration/**/*.lua")

      refute sources == []

      for path <- sources,
          {:ok, chunk} = Parser.parse_raw(File.read!(path)),
          {:ok, proto} = Compiler.compile(chunk, source: path),
          {sub_path, descriptors} <- descriptors_of(proto, path) do
        assert descriptors == Enum.uniq(descriptors), "duplicate upvalue descriptors in #{sub_path}"
      end
    end
  end

  describe "runtime behaviour is unchanged" do
    test "writes through a repeated capture are visible to every reader" do
      code = """
      local n = 0
      local function bump() n = n + 1 return n + n end
      local function read() return n end
      bump()
      bump()
      return read(), bump()
      """

      assert {[2, 6], _} = Lua.eval!(code)
    end

    test "debug.getupvalue numbers the deduped slots" do
      code = """
      local a, b = 1, 2
      local function f() return a + b + a end
      local out = {}
      local i = 1
      while true do
        local name = debug.getupvalue(f, i)
        if not name then break end
        out[#out + 1] = name
        i = i + 1
      end
      return table.concat(out, ",")
      """

      assert {["_ENV,a,b"], _} = Lua.eval!(code)
    end
  end

  defp prototypes_of(source) do
    {:ok, chunk} = Parser.parse_raw(source)
    {:ok, %Prototype{prototypes: prototypes}} = Compiler.compile(chunk)
    prototypes
  end

  defp descriptors_of(%Prototype{} = proto, path) do
    subs =
      proto.prototypes
      |> Enum.with_index()
      |> Enum.flat_map(fn {sub, index} -> descriptors_of(sub, "#{path}/#{index}") end)

    [{path, proto.upvalue_descriptors} | subs]
  end
end
