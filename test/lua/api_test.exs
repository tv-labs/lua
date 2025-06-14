defmodule Lua.APITest do
  use ExUnit.Case, async: true

  alias Lua

  describe "install/3 callback" do
    test "it can modify global lua state" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule WithInstall do
                 use Lua.API

                 @impl Lua.API
                 def install(lua, _scope, _data) do
                   {[ret], lua} = Lua.call_function!(lua, [:foo], [])

                   Lua.set!(lua, [:from_install], ret)
                 end

                 deflua foo do
                   "foo"
                 end
               end
               """)

      lua = Lua.load_api(Lua.new(), module)

      assert {["foo"], _} =
               Lua.eval!(lua, """
               return from_install
               """)
    end

    test "it can return lua code directly" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule WithLua do
                 use Lua.API

                 import Lua

                 @impl Lua.API
                 def install(_lua, _scope, _data) do
                   ~LUA[whoa = "crazy"]
                 end
               end
               """)

      lua = Lua.load_api(Lua.new(), module)

      assert {["crazy"], _} =
               Lua.eval!(lua, """
               return whoa
               """)
    end

    test "it can return lua chunks directly" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule WithLuaChunk do
                 use Lua.API

                 import Lua

                 @impl Lua.API
                 def install(_lua, _scope, _data) do
                   ~LUA[whoa = "crazy"]c
                 end
               end
               """)

      lua = Lua.load_api(Lua.new(), module)

      assert {["crazy"], _} =
               Lua.eval!(lua, """
               return whoa
               """)
    end
  end

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

    test "variadic functions can have state" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule VariadicWithState do
                 use Lua.API

                 @variadic true
                 deflua foo(args), state do
                   {args, state}
                 end
               end
               """)

      assert module.foo(["a", "b", "c"], :state) == {["a", "b", "c"], :state}

      assert module.__lua_functions__() == [
               {:foo, true, true}
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

    test "deflua functions can rescue" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule Rescueable do
                 use Lua.API

                 deflua fail(a, b) do
                   a + b
                 rescue
                   _ -> "rescued"
                 end
               end
               """)

      assert module.fail(1, 2) == 3
      assert module.fail(1, "2") == "rescued"
    end

    test "deflua functions can have guards" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule WithGuards do
                 use Lua.API

                 deflua has_a_guard(a) when is_integer(a) do
                   a
                 end

                 deflua has_a_guard(a) when is_binary(a) and not is_boolean(a) do
                   a
                 end

                 deflua has_a_guard(_) do
                   "not a int"
                 end

                 deflua with_state(a) when is_integer(a), state do
                   {a, state}
                 end

                 deflua with_state(_), state do
                   {"not a int", state}
                 end
               end
               """)

      assert module.has_a_guard(1) == 1
      assert module.has_a_guard("foo") == "foo"
      assert module.has_a_guard(true) == "not a int"

      assert {1, _} = module.with_state(1, Lua.new())
      assert {"not a int", _} = module.with_state(true, Lua.new())
    end
  end

  describe "guards" do
    test "can use in functions" do
      assert [{module, _}] =
               Code.compile_string("""
               defmodule GuardCheck do
                 use Lua.API, scope: "guard"

                 deflua type(value) when is_table(value) do
                   "table"
                 end

                 deflua type(value) when is_userdata(value) do
                   "userdata"
                 end

                 deflua type(value) when is_lua_func(value) do
                   "lua function"
                 end

                 deflua type(value) when is_erl_func(value) do
                   "erl function"
                 end

                 deflua type(value) when is_mfa(value) do
                   "mfa"
                 end

                 deflua type(_value) do
                   "other"
                 end
               end
               """)

      lua =
        Lua.load_api(Lua.new(), module)
        |> Lua.set!(["foo"], {:userdata, URI.parse("https://tvlabs.ai")})

      assert {["table"], _} = Lua.eval!(lua, "return guard.type({})")
      assert {["userdata"], _} = Lua.eval!(lua, "return guard.type(foo)")

      assert {["lua function"], _} =
               Lua.eval!(lua, """
               return guard.type(function()
                 return 42
               end)
               """)

      assert {["erl function"], _} = Lua.eval!(lua, "return guard.type(guard.type)")
      assert {["mfa"], _} = Lua.eval!(lua, "return guard.type(string.lower)")
      assert {["other"], _} = Lua.eval!(lua, "return guard.type(5)")
    end
  end
end
