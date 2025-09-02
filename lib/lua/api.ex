defmodule Lua.API do
  @moduledoc """
  Defines the Behaviour for defining a Lua API

  To create a module that exports functions to the global scope

      defmodule MyAPI do
        use Lua.API

        # Can be called via `print("hi")` in lua
        deflua print(msg), do: IO.puts msg
      end

  Optionally, you can provide a scope

      defmodule SpecificAPI do
        use Lua.API, scope: "namespace.domain"

        # Can be called via `namespace.domain.foo(5)` in lua
        deflua foo(v), do: v
      end

  You can access Lua state

      defmodule State do
        use Lua.API

        deflua bar(name), state do
          # Pulls the value of `number` out of state
          val = Lua.get!(state, [:number])

          2 * val
        end
      end

  Regular functions are not exported

      defmodule SpecificAPI do
        use Lua.API

        # Won't be exposed
        def baz(v), do: v
      end

  ## Installing an API

  A `Lua.API` can provide an optional `install/3` callback, which
  can run arbitrary Lua code or change the `Lua` state in any way.

  An `install/3` callback takes a `t:Lua.t/0` and should either return a
  Lua script to be evaluated, a `t:Lua.Chunk.t/0`, or return a new `t:Lua.t/0`

      defmodule WithInstall do
        use Lua.API, scope: "install"

        @impl Lua.API
        def install(lua, _scope, _data) do
          Lua.set!(lua, [:foo], "bar")
        end
      end

  If you don't need to write Elixir, but want to execute some Lua
  to setup global variables, modify state, or expose some additonal
  APIs, you can simply return a Lua chunk directly using the `c` modifier
  on `Lua.sigil_LUA/2`

      defmodule WithLua do
        use Lua.API, scope: "whoa"

        import Lua

        @impl Lua.API
        def install(_lua, _scope, _data) do
          ~LUA[print("Hello at install time!")]c
        end
      end

  ## Guards

  When doing `use Lua.API`, we also import the guards documented in this API.
  This can be useful for having different function heads that match on encoded
  values. E.g.

      deflua say_type(value) when is_table(value), do: "table"
      deflua say_type(value) when is_userdata(value), do: "userdata"

  Keep in mind that if you want to work with values passed to `deflua` functions,
  they still need to be decoded first.
  """

  require Record

  defmacro __using__(opts) do
    scope = opts |> Keyword.get(:scope, "") |> String.split(".", trim: true)

    quote do
      @behaviour Lua.API
      Module.register_attribute(__MODULE__, :lua_function, accumulate: true)
      @before_compile Lua.API

      import Lua.API,
        only: [
          runtime_exception!: 1,
          deflua: 2,
          deflua: 3,
          validate_func!: 3,
          is_table: 1,
          is_userdata: 1,
          is_lua_func: 1,
          is_erl_func: 1,
          is_mfa: 1
        ]

      @impl Lua.API
      def scope do
        unquote(scope)
      end
    end
  end

  @type scope_def :: list(String.t())

  @callback scope :: scope_def()
  @callback install(Lua.t(), scope_def(), any()) :: Lua.t() | Lua.Chunk.t() | String.t()
  @optional_callbacks [install: 3]

  @doc """
  Is the value a reference to a Lua table?

  """
  defguard is_table(record) when Record.is_record(record, :tref)

  @doc """
  Is the value a reference to userdata?
  """
  defguard is_userdata(record) when Record.is_record(record, :usdref)

  @doc """
  Is the value a reference to a Lua function?
  """
  defguard is_lua_func(record) when Record.is_record(record, :funref)

  @doc """
  Is the value a reference to an Erlang / Elixir function?
  """
  defguard is_erl_func(record) when Record.is_record(record, :erl_func)

  @doc """
  Is the value a reference to an Erlang / Elixir mfa?
  """
  defguard is_mfa(record) when Record.is_record(record, :erl_mfa)

  @doc """
  Raises a runtime exception inside an API function, displaying contextual
  information about where the exception was raised.
  """
  defmacro runtime_exception!(message) do
    quote do
      unless function_exported?(__MODULE__, :scope, 0) do
        raise "runtime_exception!/1 can only be called on modules implementing Lua.API"
      end

      {function, _arity} = __ENV__.function

      raise Lua.RuntimeException,
        scope: scope(),
        function: function,
        message: unquote(message)
    end
  end

  @doc """
  Defines a function that can be exposed in Lua through `Lua.load_api/3`

      deflua add_two(number) when is_number(number) do
        number + 2
      end

  ## Accessing state

  Sometimes, you may want to access or modify the Lua environment in a `deflua`. This
  can be done by using the following syntax

      deflua get_value(key), state do
        # Access the Lua environment
        Lua.get!(lua, [key])
      end

  To modify and return new state, return a tuple

      deflua set_value(key, value), state do
        # Return nothing but modify the state
        {[], Lua.set!(lua, [key])}
      end

  ## Using guards

  Since `deflua` uses non-conventional syntax to receive the current state, make sure
  you specifiy the `when` clause and guards first, e.g.

      deflua set_int(key, value) when is_integer(value), state do
        # Return nothing but modify the state
        {[], Lua.set!(lua, [key])}
      end

  Specifyiing the `when` clause and guards last will result in a confusing error message.

  ## Variadic functions

  Technically, all Lua functions are variadic, which means they can receive
  a variable number of arguments. As a convenience, `Lua` applies your arguments to
  `deflua` functions so that they can be written in idiomatic Elixir.

  If you need to handle variadic arguments, annotate the function with the `@variadic`
  module attribute.

      @variadic true
      deflua print(args) do
        IO.puts(Enum.join(args, " "))
      end

  > #### @variadic behavior {: .neutal}
  > When using the `@variadic` attribute, note that it is per-function. `Lua` will
  > reset this attribute after every function definition, so there is no need to
  > manually reset it yourself

  """
  defmacro deflua(fa, state, rest) do
    name =
      case fa do
        {:when, _, [{name, _, _} | _]} -> name
        {name, _, _} -> name
      end

    {fa, _acc} =
      Macro.prewalk(fa, :ok, fn
        {^name, context, args}, acc ->
          {{name, context, args ++ List.wrap(state)}, acc}

        ast, acc ->
          {ast, acc}
      end)

    quote do
      @lua_function validate_func!(
                      {unquote(name), true,
                       Module.delete_attribute(__MODULE__, :variadic) || false},
                      __MODULE__,
                      @lua_function
                    )
      def unquote(fa), unquote(rest)
    end
  end

  @doc """
  See `deflua/3`
  """
  defmacro deflua(fa, rest) do
    {name, _, _} = fa

    quote do
      @lua_function validate_func!(
                      {unquote(name), false,
                       Module.delete_attribute(__MODULE__, :variadic) || false},
                      __MODULE__,
                      @lua_function
                    )
      def unquote(fa), unquote(rest)
    end
  end

  @doc false
  def install(lua, module, scope, data) do
    if function_exported?(module, :install, 3) do
      case module.install(lua, scope, data) do
        %Lua{} = lua ->
          lua

        code when is_binary(code) or is_struct(code, Lua.Chunk) ->
          {_, lua} = Lua.eval!(lua, code)
          lua

        other ->
          raise Lua.RuntimeException,
                "Lua.API.install/1 must return %Lua{}, %Lua.Chunk{}, or Lua literal, got #{inspect(other)}"
      end
    else
      lua
    end
  end

  defmacro __before_compile__(env) do
    attributes =
      env.module
      |> Module.get_attribute(:lua_function)
      |> Enum.uniq()
      |> Enum.reverse()

    quote do
      def __lua_functions__ do
        unquote(Macro.escape(attributes))
      end
    end
  end

  @doc false
  def validate_func!({name, state, variadic}, module, values) do
    issue =
      Enum.find(values, fn
        {^name, new_state, _variadic} -> new_state != state
        _ -> false
      end)

    if issue do
      raise CompileError,
        description:
          "#{Exception.format_mfa(module, name, [])} is inconsistently using state. Please make all clauses consistent"
    end

    {name, state, variadic}
  end
end
