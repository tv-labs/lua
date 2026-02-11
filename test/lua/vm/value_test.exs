defmodule Lua.VM.ValueTest do
  use ExUnit.Case, async: true

  alias Lua.VM.State
  alias Lua.VM.Value

  defp new_state, do: State.new()

  describe "encode/2 primitives" do
    test "nil passes through" do
      assert {nil, _state} = Value.encode(nil, new_state())
    end

    test "booleans pass through" do
      assert {true, _state} = Value.encode(true, new_state())
      assert {false, _state} = Value.encode(false, new_state())
    end

    test "integers pass through" do
      assert {42, _state} = Value.encode(42, new_state())
      assert {-1, _state} = Value.encode(-1, new_state())
      assert {0, _state} = Value.encode(0, new_state())
    end

    test "floats pass through" do
      assert {3.14, _state} = Value.encode(3.14, new_state())
      {val, _state} = Value.encode(0.0, new_state())
      assert val == 0.0
    end

    test "strings pass through" do
      assert {"hello", _state} = Value.encode("hello", new_state())
      assert {"", _state} = Value.encode("", new_state())
    end
  end

  describe "encode/2 functions" do
    test "function/2 wraps as native_func" do
      fun = fn args, state -> {args, state} end
      assert {{:native_func, ^fun}, _state} = Value.encode(fun, new_state())
    end

    test "function/1 wraps with adapter" do
      fun = fn [x] -> x * 2 end
      {{:native_func, wrapper}, state} = Value.encode(fun, new_state())

      assert {[10], ^state} = wrapper.([5], state)
    end

    test "function/1 wraps non-list return in list" do
      fun = fn _args -> 42 end
      {{:native_func, wrapper}, state} = Value.encode(fun, new_state())

      assert {[42], ^state} = wrapper.([], state)
    end
  end

  describe "encode/2 maps" do
    test "encodes map with string keys" do
      {{:tref, id}, state} = Value.encode(%{"x" => 1, "y" => 2}, new_state())

      table = Map.fetch!(state.tables, id)
      assert table.data["x"] == 1
      assert table.data["y"] == 2
    end

    test "encodes map with atom keys (converted to strings)" do
      {{:tref, id}, state} = Value.encode(%{name: "Alice", age: 30}, new_state())

      table = Map.fetch!(state.tables, id)
      assert table.data["name"] == "Alice"
      assert table.data["age"] == 30
    end

    test "encodes empty map" do
      {{:tref, id}, state} = Value.encode(%{}, new_state())

      table = Map.fetch!(state.tables, id)
      assert table.data == %{}
    end

    test "recursively encodes nested maps" do
      {{:tref, id}, state} = Value.encode(%{inner: %{x: 1}}, new_state())

      table = Map.fetch!(state.tables, id)
      {:tref, inner_id} = table.data["inner"]
      inner_table = Map.fetch!(state.tables, inner_id)
      assert inner_table.data["x"] == 1
    end
  end

  describe "encode/2 lists" do
    test "encodes plain list with 1-based integer keys" do
      {{:tref, id}, state} = Value.encode(["a", "b", "c"], new_state())

      table = Map.fetch!(state.tables, id)
      assert table.data[1] == "a"
      assert table.data[2] == "b"
      assert table.data[3] == "c"
    end

    test "encodes empty list" do
      {{:tref, id}, state} = Value.encode([], new_state())

      table = Map.fetch!(state.tables, id)
      assert table.data == %{}
    end

    test "encodes keyword list with string keys" do
      {{:tref, id}, state} = Value.encode([name: "Bob", age: 25], new_state())

      table = Map.fetch!(state.tables, id)
      assert table.data["name"] == "Bob"
      assert table.data["age"] == 25
    end

    test "recursively encodes list elements" do
      {{:tref, id}, state} = Value.encode([%{x: 1}], new_state())

      table = Map.fetch!(state.tables, id)
      {:tref, inner_id} = table.data[1]
      inner_table = Map.fetch!(state.tables, inner_id)
      assert inner_table.data["x"] == 1
    end
  end

  describe "encode_list/2" do
    test "encodes a list of values threading state" do
      {encoded, state} = Value.encode_list([1, "hello", %{a: 1}], new_state())

      assert [1, "hello", {:tref, id}] = encoded
      table = Map.fetch!(state.tables, id)
      assert table.data["a"] == 1
    end

    test "encodes empty list" do
      assert {[], _state} = Value.encode_list([], new_state())
    end
  end

  describe "decode/2 primitives" do
    test "nil passes through" do
      assert Value.decode(nil, new_state()) == nil
    end

    test "booleans pass through" do
      assert Value.decode(true, new_state()) == true
      assert Value.decode(false, new_state()) == false
    end

    test "integers pass through" do
      assert Value.decode(42, new_state()) == 42
    end

    test "floats pass through" do
      assert Value.decode(3.14, new_state()) == 3.14
    end

    test "strings pass through" do
      assert Value.decode("hello", new_state()) == "hello"
    end
  end

  describe "decode/2 tables" do
    test "decodes table to list of {key, value} tuples" do
      {tref, state} = State.alloc_table(new_state(), %{"x" => 1, "y" => 2})

      result = Value.decode(tref, state)
      assert Enum.sort(result) == [{"x", 1}, {"y", 2}]
    end

    test "decodes empty table to empty list" do
      {tref, state} = State.alloc_table(new_state(), %{})

      assert Value.decode(tref, state) == []
    end

    test "recursively decodes nested tables" do
      {inner_tref, state} = State.alloc_table(new_state(), %{"x" => 1})
      {outer_tref, state} = State.alloc_table(state, %{"inner" => inner_tref})

      result = Value.decode(outer_tref, state)
      assert [{"inner", inner_decoded}] = result
      assert Enum.sort(inner_decoded) == [{"x", 1}]
    end

    test "decodes table with integer keys" do
      {tref, state} = State.alloc_table(new_state(), %{1 => "a", 2 => "b", 3 => "c"})

      result = Value.decode(tref, state)
      assert Enum.sort(result) == [{1, "a"}, {2, "b"}, {3, "c"}]
    end
  end

  describe "decode/2 functions" do
    test "lua_closure passes through" do
      closure = {:lua_closure, :proto, :env}
      assert Value.decode(closure, new_state()) == closure
    end

    test "native_func passes through" do
      func = {:native_func, fn _, s -> {[], s} end}
      assert Value.decode(func, new_state()) == func
    end
  end

  describe "decode_list/2" do
    test "decodes a list of values" do
      {tref, state} = State.alloc_table(new_state(), %{"a" => 1})

      result = Value.decode_list([42, "hello", tref], state)
      assert [42, "hello", decoded_table] = result
      assert decoded_table == [{"a", 1}]
    end

    test "decodes empty list" do
      assert Value.decode_list([], new_state()) == []
    end
  end

  describe "encode/decode round-trip" do
    test "primitives round-trip" do
      state = new_state()

      for value <- [nil, true, false, 42, 3.14, "hello"] do
        {encoded, state} = Value.encode(value, state)
        assert Value.decode(encoded, state) == value
      end
    end

    test "map round-trips to key-value list with string keys" do
      {encoded, state} = Value.encode(%{a: 1, b: 2}, new_state())

      result = Value.decode(encoded, state)
      assert Enum.sort(result) == [{"a", 1}, {"b", 2}]
    end

    test "plain list round-trips to integer-keyed tuples" do
      {encoded, state} = Value.encode([10, 20, 30], new_state())

      result = Value.decode(encoded, state)
      assert Enum.sort(result) == [{1, 10}, {2, 20}, {3, 30}]
    end

    test "keyword list round-trips to string-keyed tuples" do
      {encoded, state} = Value.encode([name: "Alice"], new_state())

      result = Value.decode(encoded, state)
      assert result == [{"name", "Alice"}]
    end

    test "nested structure round-trips" do
      input = %{
        users: [
          %{name: "Alice", age: 30},
          %{name: "Bob", age: 25}
        ]
      }

      {encoded, state} = Value.encode(input, new_state())
      result = Value.decode(encoded, state)

      assert [{"users", users}] = result
      users = Enum.sort_by(users, fn {k, _v} -> k end)
      assert [{1, user1}, {2, user2}] = users

      user1 = Enum.sort(user1)
      user2 = Enum.sort(user2)
      assert user1 == [{"age", 30}, {"name", "Alice"}]
      assert user2 == [{"age", 25}, {"name", "Bob"}]
    end
  end
end
