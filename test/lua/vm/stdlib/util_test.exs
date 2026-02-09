defmodule Lua.VM.Stdlib.UtilTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lua.VM.Stdlib.Util
  alias Lua.VM.State

  describe "typeof/1" do
    test "returns 'nil' for nil" do
      assert Util.typeof(nil) == "nil"
    end

    test "returns 'boolean' for booleans" do
      assert Util.typeof(true) == "boolean"
      assert Util.typeof(false) == "boolean"
    end

    test "returns 'number' for integers" do
      assert Util.typeof(0) == "number"
      assert Util.typeof(42) == "number"
      assert Util.typeof(-100) == "number"
    end

    test "returns 'number' for floats" do
      assert Util.typeof(0.0) == "number"
      assert Util.typeof(3.14) == "number"
      assert Util.typeof(-2.5) == "number"
    end

    test "returns 'string' for binaries" do
      assert Util.typeof("") == "string"
      assert Util.typeof("hello") == "string"
      assert Util.typeof("multi\nline") == "string"
    end

    test "returns 'table' for table references" do
      state = State.new()
      {tref, _state} = State.alloc_table(state)
      assert Util.typeof(tref) == "table"
    end

    test "returns 'function' for lua closures" do
      closure = {:lua_closure, %{}, []}
      assert Util.typeof(closure) == "function"
    end

    test "returns 'function' for native functions" do
      native_func = {:native_func, fn _, s -> {[], s} end}
      assert Util.typeof(native_func) == "function"
    end

    test "returns 'unknown' for other values" do
      assert Util.typeof({:unknown_type, :data}) == "unknown"
      assert Util.typeof(%{custom: :map}) == "unknown"
    end

    property "typeof always returns a string" do
      check all(
              value <-
                one_of([
                  constant(nil),
                  boolean(),
                  integer(),
                  float(),
                  string(:printable),
                  constant({:tref, 0}),
                  constant({:lua_closure, %{}, []}),
                  constant({:native_func, fn _, s -> {[], s} end})
                ])
            ) do
        result = Util.typeof(value)
        assert is_binary(result)
        assert result in ["nil", "boolean", "number", "string", "table", "function", "unknown"]
      end
    end
  end

  describe "to_lua_string/1" do
    test "converts nil to 'nil'" do
      assert Util.to_lua_string(nil) == "nil"
    end

    test "converts booleans to strings" do
      assert Util.to_lua_string(true) == "true"
      assert Util.to_lua_string(false) == "false"
    end

    test "converts strings to themselves" do
      assert Util.to_lua_string("hello") == "hello"
      assert Util.to_lua_string("") == ""
      assert Util.to_lua_string("with spaces") == "with spaces"
    end

    test "converts integers using Value.to_string" do
      assert Util.to_lua_string(0) == "0"
      assert Util.to_lua_string(42) == "42"
      assert Util.to_lua_string(-100) == "-100"
    end

    test "converts floats using Value.to_string" do
      result = Util.to_lua_string(3.14)
      assert is_binary(result)
      assert result =~ "3.14"
    end

    test "converts tables to 'table'" do
      state = State.new()
      {tref, _state} = State.alloc_table(state)
      assert Util.to_lua_string(tref) == "table"
    end

    test "converts functions to 'table'" do
      # Note: In the current implementation, functions fall through to the catch-all
      closure = {:lua_closure, %{}, []}
      assert Util.to_lua_string(closure) == "table"

      native_func = {:native_func, fn _, s -> {[], s} end}
      assert Util.to_lua_string(native_func) == "table"
    end

    test "converts unknown types to 'table'" do
      assert Util.to_lua_string({:unknown, :data}) == "table"
      assert Util.to_lua_string(%{custom: :map}) == "table"
    end

    property "to_lua_string always returns a string" do
      check all(
              value <-
                one_of([
                  constant(nil),
                  boolean(),
                  integer(),
                  float(),
                  string(:printable),
                  constant({:tref, 0}),
                  constant({:lua_closure, %{}, []})
                ])
            ) do
        result = Util.to_lua_string(value)
        assert is_binary(result)
      end
    end

    property "to_lua_string for strings is identity" do
      check all(str <- string(:printable)) do
        assert Util.to_lua_string(str) == str
      end
    end

    property "to_lua_string for integers produces parseable result" do
      check all(int <- integer()) do
        result = Util.to_lua_string(int)
        assert is_binary(result)
        # Should be parseable back to integer
        assert String.to_integer(result) == int
      end
    end
  end
end
