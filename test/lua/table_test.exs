defmodule Lua.TableTest do
  use ExUnit.Case, async: true

  doctest Lua.Table

  defmacro assert_table(table) do
    quote bind_quoted: [table: table] do
      assert output = Lua.Table.as_string(table)
      assert {[ret], _lua} = Lua.eval!("return " <> output)
      assert ret == table
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
  end
end
