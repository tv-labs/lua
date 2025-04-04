defmodule LuerlTest do
  @moduledoc "For verifying underlying Luerl behavior"
  use ExUnit.Case, async: true

  test "it can run basic scripts" do
    assert {:ok, [22], _} = :luerl.do(~S[return 22], :luerl.init())

    assert {:ok, [{:tref, _} = table], luerl} =
             :luerl.do(~S[return { foo = "bar" }], :luerl.init())

    assert [{"foo", "bar"}] = :luerl.decode(table, luerl)
  end

  test "it can create top-level tables" do
    assert {:ok, luerl} = :luerl.set_table_keys(["a"], 22, :luerl.init())

    assert {:ok, [22], _} = :luerl.do(~S[return a], luerl)
  end

  test "it can create nested tables" do
    # {t1, luerl} = :luerl_emul.alloc_table([{"c", 22}], :luerl.init())
    # {t2, luerl} = :luerl_emul.alloc_table([{"b", t1}], luerl)
    # {:ok, luerl} = :luerl.set_table_keys(["a"], t2, luerl)
    {:ok, luerl} = :luerl.set_table_keys(["a", "b", "c"], 22, :luerl.init())

    {:ok, [22], luerl} = :luerl.do("return a.b.c", luerl)

    assert {:ok, 22, _luerl} = :luerl.get_table_keys(["a", "b", "c"], luerl)
    assert {:ok, nil, _luerl} = :luerl.get_table_keys(["not_a_key"], luerl)
  end

  test "it returns function refs uniformly" do
    assert {:ok, [{:erl_mfa, :luerl_lib_string, :lower, :undefined}], _luerl} =
             :luerl.do("return string.lower", :luerl.init())

    assert {:ok, [{:funref, 0, [:not_used]}], _luerl} =
             :luerl.do(
               """
               function double(val)
                 return 2 * val
               end

               return double
               """,
               :luerl.init()
             )

    assert {:ok, [{:luerl_lib_string, :lower, :undefined}], _luerl} =
             :luerl.do_dec("return string.lower", :luerl.init())

    assert {:ok, [func], _luerl} =
             :luerl.do_dec(
               """
               function double(val)
                 return 2 * val
               end

               return double
               """,
               :luerl.init()
             )

    assert is_function(func)
  end
end
