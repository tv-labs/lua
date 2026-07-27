defmodule Lua.VM.CyclicTableTest do
  @moduledoc """
  Cyclic tables crossing the eval boundary must terminate.

  The common Lua OOP idiom `T.__index = T` creates a table that
  contains itself. Both boundary walks — `decode: true` (Value.decode)
  and `decode: false` (Display peek) — previously recursed forever on
  such values, growing memory without bound until the VM's
  `max_heap_size` (when set) killed the process.
  """

  use ExUnit.Case, async: true

  alias Lua.VM.Display.Table, as: DTable

  @self_cycle """
  local T = {}
  T.__index = T
  return T
  """

  @mutual_cycle """
  local a = {}
  local b = {a = a}
  a.b = b
  return a
  """

  describe "decode: false (Display peek)" do
    test "self-referential table peeks as :circular at the recurrence" do
      {[t], _} = Lua.eval!(Lua.new(), @self_cycle, decode: false)

      assert %DTable{id: id, peek: %{"__index" => inner}} = t
      assert %DTable{id: ^id, peek: :circular} = inner
      assert inspect(inner) == "#Lua.Table<id: #{id}, circular>"
    end

    test "mutually recursive tables terminate and render" do
      {[t], _} = Lua.eval!(Lua.new(), @mutual_cycle, decode: false)

      assert %DTable{id: a_id, peek: %{"b" => %DTable{peek: %{"a" => inner_a}}}} = t
      assert %DTable{id: ^a_id, peek: :circular} = inner_a
      assert inspect(t) =~ "circular"
    end

    test "shared non-cyclic references still peek fully" do
      code = """
      local shared = {x = 1}
      return {a = shared, b = shared}
      """

      {[t], _} = Lua.eval!(Lua.new(), code, decode: false)

      assert %DTable{
               peek: %{"a" => %DTable{peek: %{"x" => 1}}, "b" => %DTable{peek: %{"x" => 1}}}
             } =
               t
    end
  end

  describe "decode: true (Value.decode)" do
    test "self-referential table terminates with the table's reference at the recurrence" do
      {[decoded], _} = Lua.eval!(Lua.new(), @self_cycle)

      assert [{"__index", {:tref, id}}] = decoded
      assert is_integer(id)
    end

    test "mutually recursive tables terminate with a reference" do
      {[decoded], _} = Lua.eval!(Lua.new(), @mutual_cycle)

      assert [{"b", [{"a", {:tref, _}}]}] = decoded
    end

    test "shared non-cyclic references decode normally" do
      code = """
      local shared = {x = 1}
      return {a = shared, b = shared}
      """

      {[decoded], _} = Lua.eval!(Lua.new(), code)

      assert Enum.sort(decoded) == [{"a", [{"x", 1}]}, {"b", [{"x", 1}]}]
    end

    test "a table appearing under multiple sibling keys is not a false-positive cycle" do
      code = """
      local leaf = {v = 1}
      local mid = {l = leaf, r = leaf}
      return {left = mid, right = mid}
      """

      {[decoded], _} = Lua.eval!(Lua.new(), code)
      assert is_list(decoded)
    end
  end
end
