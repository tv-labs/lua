defmodule Lua.APITest do
  use ExUnit.Case, async: true

  alias Lua

  describe "deflua" do
    test "can access the current lua state" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule One do
                 use Lua.API

                 deflua whoa(value), state do
                   {["Whoa, " <> Lua.get!(state, [value])], state}
                 end
               end
               """)

      lua = Lua.load_api(Lua.new(), module)

      assert {["Whoa, check this out!"], _} =
               Lua.eval!(lua, """
               some_var = "check this out!"

               return whoa("some_var")
               """)
    end

    test "can modify the current lua state" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule CurrentState do
                 use Lua.API

                 deflua foo(a, b), state do
                   value = Lua.get!(state, [:some_var])
                   lua = Lua.set!(state, [:some_var], a + b)

                   {[value], lua}
                 end
               end
               """)

      lua = Lua.load_api(Lua.new(), module)

      assert {["starting value", 111], _} =
               Lua.eval!(lua, """
               some_var = "starting value"

               return foo(22, 89), some_var
               """)
    end

    test "it compiles a function with args and state" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule Two do
                use Lua.API

                 deflua one(num), state do
                   {num + 1, state}
                 end

                 deflua two([] = _list, num), state do
                   {num + 1, state}
                 end

                 deflua three(%{} = _map, [] = _list, num), state do
                   {num + 1, state}
                 end
               end
               """)

      assert module.one(2, %{state: 5}) == {3, %{state: 5}}
      assert module.two([], 2, %{state: 5}) == {3, %{state: 5}}
      assert module.three(%{}, [], 2, %{state: 5}) == {3, %{state: 5}}

      assert module.__lua_functions__() == [
               {:one, true, false},
               {:two, true, false},
               {:three, true, false}
             ]
    end

    test "it compiles a function with only args" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule Three do
                use Lua.API

                 deflua one(num) do
                   num + 1
                 end

                 deflua two([_ | _] = list, num) do
                   [num + 1 | list]
                 end

                 deflua three(%{} = map, [_ | _] = list, num) do
                   Map.put(map, num + 1, list)
                 end
               end
               """)

      assert module.one(2) == 3
      assert module.two([2, 1], 2) == [3, 2, 1]
      assert module.three(%{a: 1}, [1, 2, 3], 2) == %{3 => [1, 2, 3], a: 1}

      assert module.__lua_functions__() == [
               {:one, false, false},
               {:two, false, false},
               {:three, false, false}
             ]
    end

    test "it can handle multiple arities" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule Four do
                use Lua.API

                 deflua foo(a) do
                   a + 1
                 end

                 deflua foo(a, b) do
                   a + b
                 end
               end
               """)

      assert module.foo(5) == 6
      assert module.foo(5, 6) == 11

      assert module.__lua_functions__() == [{:foo, false, false}]
    end

    test "it can create variadic functions" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule Variadic do
                 use Lua.API

                 deflua a(a) do
                   a + 1
                 end

                 @variadic true
                 deflua variadic(args) do
                   Enum.join(args, ", ")
                 end

                 deflua b(a, b) do
                   a + b
                 end
               end
               """)

      assert module.a(5) == 6
      assert module.variadic(["a", "b", "c"]) == "a, b, c"
      assert module.b(5, 6) == 11

      assert module.__lua_functions__() == [
               {:a, false, false},
               {:variadic, false, true},
               {:b, false, false}
             ]
    end

    test "if there is mixed usage of state for a function, it raises an error" do
      error = "Five.foo() is inconsistently using state. Please make all clauses consistent"

      assert_raise CompileError, error, fn ->
        Code.compile_string("""
        defmodule Five do
         use Lua.API

          deflua foo(a), _state do
            a + 1
          end

          deflua foo(a, b) do
            a + b
          end
        end
        """)
      end
    end
  end
end
