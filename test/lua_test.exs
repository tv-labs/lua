defmodule LuaTest do
  use ExUnit.Case

  alias Lua

  doctest Lua

  require Lua.Util

  alias Lua.Util

  describe "messing with Luerl functions" do
    test "it can access useful data" do
      lua = Lua.new()

      lua =
        Lua.set!(lua, [:foo], fn [value] ->
          [1 + value]
        end)

      global_table_data =
        lua.state
        |> Util.luerl(:g)
        |> :luerl_heap.get_table(lua.state)
        |> Util.table(:d)

      user_functions =
        :ttdict.filter(
          fn
            _key, {:erl_func, _} -> true
            _, _ -> false
          end,
          global_table_data
        )
        |> :ttdict.fetch_keys()

      assert user_functions == ["foo"]

      assert {:erl_func, func} = :ttdict.fetch("foo", global_table_data)

      assert is_function(func)

      # These are the datastructures Luerl uses for managing tables
      # :ttdict.from_list([{:a, 1}, {:b, 2}, {:c, 3}, {:d, 4}, {:e, 5}, {:f, 6}, {:g, 7}])
      # :ttsets.from_list([{:a, 1}, {:b, 2}, {:c, 3}, {:d, 4}, {:e, 5}, {:f, 6}, {:g, 7}])
    end
  end

  describe "inspect" do
    test "shows all functions in the lua state" do
      lua = Lua.new()

      lua =
        Lua.set!(lua, [:foo], fn [value] ->
          [1 + value]
        end)

      lua = Lua.set!(lua, [:bar, :my_func], fn _, _ -> [] end)

      assert inspect(lua) == "#Lua<functions:[bar.my_func(_, _), foo(_)]>"
    end
  end

  describe "load_lua_file/2" do
    test "loads the lua file into the state" do
      path = Path.join(["test", "fixtures", "test_api"])

      assert lua = Lua.load_lua_file!(Lua.new(), path)

      assert {["Hi ExUnit!"], _} =
               Lua.eval!(lua, """
               return foo("ExUnit!")
               """)
    end

    test "non-existent files are not loaded" do
      assert_raise RuntimeError, "Cannot load lua file, \"bananas.lua\" does not exist", fn ->
        Lua.load_lua_file!(Lua.new(), "bananas")
      end
    end
  end

  describe "eval!/1" do
    test "it can register functions as table values and call them" do
      lua = Lua.new()

      lua =
        Lua.set!(lua, [:foo], fn [value] ->
          [1 + value]
        end)

      assert {[], _} = Lua.eval!(lua, "foo(5)")
      assert {[2], _} = Lua.eval!(lua, "return foo(1)")
    end

    test "invalid functions raise" do
      lua = Lua.new()

      error = """
      Lua runtime error: undefined function

      script line 1: <unknown function>()
      """

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!(lua, "bogus()")
      end
    end

    test "parsing errors raise" do
      lua = Lua.new()

      assert_raise Lua.CompilerException, ~r/Failed to compile Lua script/, fn ->
        Lua.eval!(lua, """
        local map = {a="1", b="2"}

        -- missing assignment or return
        map["c"]
        """)
      end
    end

    test "sandboxed functions show a nice error message" do
      lua = Lua.new()

      message = """
      Lua runtime error: sandboxed function

      script line 1: sandboxed(1)
      """

      assert_raise Lua.RuntimeException, message, fn ->
        Lua.eval!(lua, """
        os.exit(1)
        """)
      end
    end
  end

  describe "error messages" do
    test "function doesn't exist" do
      lua = Lua.new()

      error = """
      Lua runtime error: undefined function

      script line 2: <unknown function>("yuup")
      """

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!(lua, """
        local foo = 1 + 1
        nope("yuup")
        """)
      end
    end

    test "missing quote" do
      lua = Lua.new()

      error = """
      Failed to compile Lua script

      Line 1: failed to tokenize due to illegal token: ")

      """

      assert_raise Lua.CompilerException, error, fn ->
        Lua.eval!(lua, """
        print(yuup")
        """)
      end

      error = """
      Failed to compile Lua script

      Line 1: failed to tokenize due to illegal token: "yuup)

      """

      assert_raise Lua.CompilerException, error, fn ->
        Lua.eval!(lua, """
        print("yuup)
        """)
      end
    end

    test "method that references property" do
      lua = Lua.new()

      error = """
      Lua runtime error: undefined function "a"

      "a" with arguments ("b")
      ^--- self is incorrect for object with keys "name"


      script line 15

      """

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!(lua, """
        Thing = {}
        Thing.__index = Thing

        function Thing.new(name)
          local self = setmetatable({}, Thing)
          self.name = name
          return self
        end

        function Thing:name()
          return self.name
        end

        local foo = Thing.new("a")
        foo:name("b")
        """)
      end
    end

    test "function doesn't exist in nested function" do
      lua = Lua.new()

      error = """
      Lua runtime error: undefined function

      script line 2: <unknown function>(\"dude\")
      script line 6: foo(2, \"dude\")
      script line 9: bar(1)
      """

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!(lua, """
        function foo(thing, name)
          doesnt_exist(name)
        end

        function bar(thing)
          foo(thing + 1, "dude")
        end

        bar(1)
        """)
      end
    end

    test "api function that doesn't exist" do
      error = """
      Lua runtime error: invalid index "nope"

      script line 5: thing()
      """

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!("""
        function thing()
          module.nope()
        end

        thing()
        """)
      end
    end

    test "erlang function called with the wrong arity" do
      defmodule Test do
        use Lua.API, scope: "test"

        deflua foo(a) do
          a
        end

        deflua bar(a, b), _state do
          a + b
        end

        deflua bar(a, b, c), _state do
          a + b + c
        end
      end

      lua = Lua.inject_module(Lua.new(), Test, Test.scope())

      error = "Lua runtime error: test.foo() failed, expected 1 arguments, got 2"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!(lua, """
        test.foo("a", "b")
        """)
      end

      error = "Lua runtime error: test.bar() failed, expected 2 or 3 arguments, got 1"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.eval!(lua, """
        test.bar("a")
        """)
      end
    end
  end

  describe "set!/2 and get!/2" do
    setup do
      {:ok, lua: Lua.new()}
    end

    test "sets and gets a simple value", %{lua: lua} do
      lua = Lua.set!(lua, [:hello], "world")
      assert "world" == Lua.get!(lua, [:hello])
    end

    test "sets and gets nested values", %{lua: lua} do
      lua = Lua.set!(lua, [:a, :b, :c], "nested")
      assert "nested" == Lua.get!(lua, [:a, :b, :c])
    end

    test "returns nil for non-existent keys", %{lua: lua} do
      assert nil == Lua.get!(lua, [:non_existent_key])
    end
  end

  describe "inject_module/2 and inject_module/3" do
    defmodule TestModule do
      use Lua.API

      deflua(foo(arg), do: arg)

      @variadic true
      deflua(bar(args), do: Enum.join(args, "-"))

      deflua test(a, b \\ "default") do
        "#{a} #{b}"
      end
    end

    setup do
      {:ok, lua: Lua.new()}
    end

    test "injects a global Elixir module functions into the Lua runtime", %{lua: lua} do
      lua = Lua.inject_module(lua, TestModule)
      assert {["test"], _} = Lua.eval!(lua, "return foo('test')")
    end

    test "injects a scoped Elixir module functions into the Lua runtime", %{lua: lua} do
      lua = Lua.inject_module(lua, TestModule, ["scope"])
      assert {["test"], _} = Lua.eval!(lua, "return scope.foo('test')")
    end

    test "inject a variadic function", %{lua: lua} do
      lua = Lua.inject_module(lua, TestModule, ["scope"])
      assert {["a-b-c"], _} = Lua.eval!(lua, "return scope.bar('a', 'b', 'c')")
    end

    test "injects Elixir functions that have multiple arities", %{lua: lua} do
      lua = Lua.inject_module(lua, TestModule, ["scope"])

      assert {["a default"], _} = Lua.eval!(lua, "return scope.test(\"a\")")
      assert {["a b"], _} = Lua.eval!(lua, "return scope.test(\"a\", \"b\")")
    end
  end

  describe "examples" do
    defmodule Examples do
      use Lua.API

      @moduledoc """
      These are example functions to demonstrate interaction between Lua and Elixir.

      For the Lua data types we internally use the corresponding Erlang:

      nil           - nil
      true/false   - true/false
      strings      - binaries
      numbers      - floats
      tables       - #table{} with array for keys 1..n, ordict for rest
      userdata     - #userdata{}
      function     - #function{} or {function,Fun}
      thread       - #thread{}
      """
      deflua double(x) do
        x * 2
      end

      deflua add(x, y) do
        x + y
      end

      deflua multiple_returns do
        ["hello", "world", :atom, 42, true]
      end

      deflua list do
        [1, 2, 3, 5, 8, 13, 21, 34]
      end

      # Tuples are NOT supported!
      deflua tuple do
        {:key, "value"}
      end

      deflua type_check(x) when is_integer(x) do
        IO.puts("Elixir: Got integer: #{inspect(x)}")
      end

      deflua binary() do
        binary_data = <<0::size(1 * 1024 * 8)>>
        binary_data
      end
    end

    setup do
      %{lua: Lua.new() |> Lua.inject_module(Examples, ["example"])}
    end

    test "can work with numbers", %{lua: lua} do
      assert {[10], _} = Lua.eval!(lua, "return example.double(5)")
      assert {[3], _} = Lua.eval!(lua, "return example.add(2, 1)")
    end

    test "it can return multiple values", %{lua: lua} do
      return = ["hello", "world", "atom", 42, true]
      assert {^return, _} = Lua.eval!(lua, "return example.multiple_returns()")
    end

    test "it can return lists", %{lua: lua} do
      return = [1, 2, 3, 5, 8, 13, 21, 34]
      assert {^return, _} = Lua.eval!(lua, "return example.list()")
    end

    test "it cannot return tuples from Elixir", %{lua: lua} do
      assert_raise ArgumentError, fn ->
        Lua.eval!(lua, "return example.tuple()")
      end
    end

    test "it can return binary data from Elixir", %{lua: lua} do
      return = [<<0::size(1 * 1024 * 8)>>]
      assert {^return, _} = Lua.eval!(lua, "return example.binary()")
    end
  end

  describe "require" do
    test "it can find lua code when modifying package.path" do
      lua = Lua.new()

      assert {["required file successfully"], _} =
               Lua.eval!(lua, """
               package.path = "./test/fixtures/?.lua"

               return require("test_require")
               """)
    end

    test "we can use set_lua_paths/2 to add the paths" do
      lua = Lua.new()

      lua = Lua.set_lua_paths(lua, "./test/fixtures/?.lua")

      assert {["required file successfully"], _} =
               Lua.eval!(lua, """
               return require("test_require")
               """)
    end
  end
end
