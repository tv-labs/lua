defmodule Lua.TableTest do
  use ExUnit.Case, async: true

  import Lua, only: [sigil_LUA: 2]

  doctest Lua.Table

  defmacro assert_table(table, expected \\ :reflect) do
    quote generated: true, bind_quoted: [table: table, expected: Macro.escape(expected)] do
      assert output = Lua.Table.as_string(table)
      assert {[ret], _lua} = Lua.eval!("return " <> output)

      case expected do
        :reflect -> assert ret == table
        expected -> assert ret == expected
      end

      output
    end
  end

  describe "as_string" do
    test "it can convert basic tables to strings" do
      assert assert_table([]) == "{}"
      assert assert_table([{"a", 1}, {"b", 2}]) == "{a = 1, b = 2}"
      assert assert_table([{"a b", "value"}, {"b", 2}]) == ~S<{["a b"] = "value", b = 2}>
    end

    test "lists are converted" do
      assert assert_table([{1, "foo"}, {2, "bar"}]) == ~S[{"foo", "bar"}]
    end

    test "it can handle tables with many keys" do
      big_table =
        for {letter, index} <- Enum.with_index(?a..?z) do
          {to_string([letter]), index}
        end

      assert_table(big_table)
    end

    test "it can handle lists of values" do
      list = ["a", "b", "c", "d"]
      assert_table(list, [{1, "a"}, {2, "b"}, {3, "c"}, {4, "d"}])
    end

    test "it can handle useradata" do
      table = [{"a", 1}, {"b", {:userdata, ~D[2024-09-22]}}]

      assert Lua.Table.as_string(table) == ~S[{a = 1, b = "<userdata>"}]

      assert Lua.Table.as_string(table,
               formatter: fn
                 _, {:userdata, value} -> inspect(value)
                 _, value -> value
               end
             ) ==
               ~S<{a = 1, b = "~D[2024-09-22]"}>
    end

    test "it can handle nested maps" do
      table = [a: 1, b: 2, c: %{d: %{e: 5}}]

      assert Lua.Table.as_string(table) == "{a = 1, b = 2, c = {d = {e = 5}}}"
    end

    # We can't handle self-referential tables as
    # Luerl cannot decode them
    @tag :skip
    test "it can handle self-referential tables" do
      assert {[_table], _lua} =
               Lua.eval!(~LUA"""
               local table = { a = 1 }
               table.nested = table
               return table
               """)
    end

    test "it can handle other table references" do
      assert {[table], _lua} =
               Lua.eval!(~LUA"""
               local other = { c = 3 }
               local table = { a = 1, b = other }
               return table
               """)

      assert assert_table(table) == "{a = 1, b = {c = 3}}"
    end
  end
end
