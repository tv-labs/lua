defmodule LuaTest do
  use ExUnit.Case, async: true

  alias Lua

  doctest Lua

  require Lua.Util

  describe "inspect" do
    test "shows nothing" do
      lua = Lua.new()

      lua =
        Lua.set!(lua, [:foo], fn [value] ->
          [1 + value]
        end)

      lua = Lua.set!(lua, [:bar, :my_func], fn _, _ -> [] end)

      assert inspect(lua) == "#Lua<>"
    end
  end

  describe "load_file!/2" do
    test "loads the lua file into the state" do
      path = test_file("test_api")

      assert lua = Lua.load_file!(Lua.new(), path)

      assert {["Hi ExUnit!"], _} =
               Lua.eval!(lua, """
               return foo("ExUnit!")
               """)
    end

    test "it can load files with the .lua extension" do
      path = test_file("test_api.lua")

      assert lua = Lua.load_file!(Lua.new(), path)

      assert {["Hi ExUnit!"], _} =
               Lua.eval!(lua, """
               return foo("ExUnit!")
               """)
    end

    test "loading files with illegal tokens returns an error" do
      path = test_file("illegal_token")

      error = """
      Failed to compile Lua script!

      Failed to tokenize: illegal token on line 1: '

      """

      assert_raise Lua.CompilerException, error, fn ->
        Lua.load_file!(Lua.new(), path)
      end
    end

    test "it can load files that return" do
      path = test_file("returns_value")

      assert lua = Lua.load_file!(Lua.new(), path)

      assert {["returns value"], _} =
               Lua.eval!(lua, """
               return foo()
               """)
    end

    test "loading files with syntax errors returns an error" do
      path = test_file("syntax_error")

      error = """
      Failed to compile Lua script!

      Line 1: syntax error before: ','
      """

      assert_raise Lua.CompilerException, error, fn ->
        Lua.load_file!(Lua.new(), path)
      end
    end

    test "loading files with undefined functions returns an error" do
      path = test_file("undefined_function")

      error =
        """
        Failed to compile Lua script!

        undefined function nil

        script line 1: <unknown function>()
        """

      assert_raise Lua.CompilerException, error, fn ->
        Lua.load_file!(Lua.new(), path)
      end
    end

    test "non-existent files are not loaded" do
      assert_raise RuntimeError, "Cannot load lua file, \"bananas.lua\" does not exist", fn ->
        Lua.load_file!(Lua.new(), "bananas")
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

      assert {[], %Lua{}} = Lua.eval!(lua, "foo(5)")
      assert {[2], %Lua{}} = Lua.eval!(lua, "return foo(1)")
    end

    test "invalid functions raise" do
      lua = Lua.new()

      error = """
      Lua runtime error: undefined function nil

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

      message = "Lua runtime error: os.exit(_) is sandboxed"

      assert_raise Lua.RuntimeException, message, fn ->
        Lua.eval!(lua, """
        os.exit(1)
        """)
      end
    end
  end

  describe "call_function/3" do
    test "can call standard library functions" do
      assert {["hello robert"], %Lua{}} =
               Lua.call_function!(Lua.new(), [:string, :lower], ["HELLO ROBERT"])
    end

    test "can call user defined functions" do
      {[], lua} =
        Lua.eval!("""
        function double(val)
          return 2 * val
        end
        """)

      assert {[20], %Lua{}} = Lua.call_function!(lua, :double, [10])
    end

    test "can call references to functions" do
      {[func], lua} = Lua.eval!("return string.lower")

      assert {["it works"], %Lua{}} = Lua.call_function!(lua, func, ["IT WORKS"])
    end

    test "it plays nicely with elixir function callbacks" do
      defmodule Callback do
        use Lua.API, scope: "callback"

        deflua callme(func), state do
          Lua.call_function!(state, func, ["MAYBE"])
        end
      end

      lua = Lua.new() |> Lua.load_api(Callback)

      assert {["maybe"], %Lua{}} =
               Lua.eval!(lua, """
               return callback.callme(function(value)
                 return string.lower(value)
               end)
               """)
    end

    test "calling non-functions raises" do
      {_, lua} =
        Lua.eval!("""
        foo = "bar"
        """)

      error = """
      Lua runtime error: undefined function 'bar'


      """

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.call_function!(lua, :foo, [])
      end
    end
  end

  describe "encode!/1 and decode!/1" do
    test "it can encode values into their internal representation" do
      lua = Lua.new()

      assert {"hello", lua} = Lua.encode!(lua, "hello")
      assert "hello" = Lua.decode!(lua, "hello")
      assert {"hello", lua} = Lua.encode!(lua, :hello)
      assert {5, lua} = Lua.encode!(lua, 5)
      assert 5 = Lua.decode!(lua, 5)
      assert {{:tref, _} = ref, lua} = Lua.encode!(lua, %{a: 1, b: 2})
      assert [{"a", 1}, {"b", 2}] = Lua.decode!(lua, ref)
      assert {{:tref, _} = ref, lua} = Lua.encode!(lua, [1, 2])
      assert [{1, 1}, {2, 2}] = Lua.decode!(lua, ref)
    end

    test "it raises for values that cannot be encoded" do
      error = "Lua runtime error: Failed to encode {:foo, :bar}"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.encode!(Lua.new(), {:foo, :bar})
      end
    end

    test "it raises for values that cannot be decoded" do
      error = "Lua runtime error: Failed to decode :hello"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.decode!(Lua.new(), :hello)
      end
    end
  end

  describe "error messages" do
    test "function doesn't exist" do
      lua = Lua.new()

      error = """
      Lua runtime error: undefined function nil

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
      Failed to compile Lua script!

      Failed to tokenize: illegal token on line 1: ")

      """

      assert_raise Lua.CompilerException, error, fn ->
        Lua.eval!(lua, """
        print(yuup")
        """)
      end

      error = """
      Failed to compile Lua script!

      Failed to tokenize: illegal token on line 1: "yuup)

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
      Lua runtime error: undefined function 'a'

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
      Lua runtime error: undefined function nil

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

      lua = Lua.load_api(Lua.new(), Test)

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

    test "error/1 raises an exception" do
      error = """
      Lua runtime error: this is an error

      script line 1:error("this is an error")
      """

      assert_raise Lua.RuntimeException, error, fn ->
        lua = Lua.new(sandboxed: [])

        Lua.eval!(lua, """
        error("this is an error")
        """)
      end
    end

    test "arithmetic exceptions are handled" do
      error = """
      Lua runtime error: bad arithmetic 5 / 0


      """

      assert_raise Lua.RuntimeException, error, fn ->
        lua = Lua.new()

        Lua.eval!(lua, "return 5 / 0")
      end
    end
  end

  describe "set!/2 and get!/2" do
    test "sets and gets a simple value" do
      lua = Lua.set!(Lua.new(), [:hello], "world")
      assert "world" == Lua.get!(lua, [:hello])
    end

    test "sets and gets nested values" do
      lua = Lua.set!(Lua.new(), [:a, :b, :c], "nested")
      assert "nested" == Lua.get!(lua, [:a, :b, :c])
    end

    test "if the key already has a value, it raises" do
      error = "Lua runtime error: invalid index \"print.nope\"\n\n\n"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.set!(Lua.new(), [:_G, :print, :nope], "uh oh")
      end
    end

    test "returns nil for non-existent keys" do
      assert nil == Lua.get!(Lua.new(), [:non_existent_key])
    end

    test "if a path is nil, it raises a runtime error" do
      error = "Lua runtime error: invalid index \"one.two\"\n\n\n"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.get!(Lua.new(), [:one, :two])
      end
    end

    test "if the key is not a table, it raises" do
      error = "Lua runtime error: invalid index \"print.nope\"\n\n\n"

      assert_raise Lua.RuntimeException, error, fn ->
        Lua.get!(Lua.new(), [:print, :nope])
      end
    end
  end

  describe "load_api/2 and load_api/3" do
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
      lua = Lua.load_api(lua, TestModule)
      assert {["test"], _} = Lua.eval!(lua, "return foo('test')")
    end

    test "injects a scoped Elixir module functions into the Lua runtime", %{lua: lua} do
      lua = Lua.load_api(lua, TestModule, ["scope"])
      assert {["test"], _} = Lua.eval!(lua, "return scope.foo('test')")
    end

    test "inject a variadic function", %{lua: lua} do
      lua = Lua.load_api(lua, TestModule, ["scope"])
      assert {["a-b-c"], _} = Lua.eval!(lua, "return scope.bar('a', 'b', 'c')")
    end

    test "injects Elixir functions that have multiple arities", %{lua: lua} do
      lua = Lua.load_api(lua, TestModule, ["scope"])

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
      %{lua: Lua.new() |> Lua.load_api(Examples, ["example"])}
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
      error = "Lua runtime error: argument error"

      assert_raise Lua.RuntimeException, error, fn ->
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
      lua = Lua.new(sandboxed: [])

      assert {["required file successfully"], _} =
               Lua.eval!(lua, """
               package.path = "./test/fixtures/?.lua"

               return require("test_require")
               """)
    end

    test "we can use set_lua_paths/2 to add the paths" do
      lua = Lua.new(sandboxed: [])

      lua = Lua.set_lua_paths(lua, "./test/fixtures/?.lua")

      assert {["required file successfully"], _} =
               Lua.eval!(lua, """
               return require("test_require")
               """)
    end

    test "set_lua_paths/2 raises if package is sandboxed" do
      lua = Lua.new()

      message = """
      Lua runtime error: invalid index "package.path"


      """

      assert_raise Lua.RuntimeException, message, fn ->
        Lua.set_lua_paths(lua, "./test/fixtures/?.lua")
      end
    end
  end

  defp test_file(name) do
    Path.join(["test", "fixtures", name])
  end
end
