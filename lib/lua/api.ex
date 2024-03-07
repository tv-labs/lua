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
          # Pull's the value of `number` out of state
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

  """

  defmacro __using__(opts) do
    scope = opts |> Keyword.get(:scope, "") |> String.split(".", trim: true)

    quote do
      @behaviour Lua.API
      Module.register_attribute(__MODULE__, :lua_function, accumulate: true)
      @before_compile Lua.API

      import Lua.API,
        only: [runtime_exception!: 1, deflua: 2, deflua: 3, validate_func!: 3]

      @impl Lua.API
      def scope do
        unquote(scope)
      end
    end
  end

  @callback scope :: list(String.t())

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
  Define a function that can be exposed in Lua
  """
  defmacro deflua(fa, state, do: block) do
    {fa, _acc} =
      Macro.prewalk(fa, false, fn
        {name, context, args}, false -> {{name, context, args ++ List.wrap(state)}, true}
        ast, true -> {ast, true}
      end)

    {name, _, _} = fa

    quote do
      @lua_function validate_func!(
                      {unquote(name), true,
                       Module.delete_attribute(__MODULE__, :variadic) || false},
                      __MODULE__,
                      @lua_function
                    )
      def unquote(fa), do: unquote(block)
    end
  end

  defmacro deflua(fa, do: block) do
    {name, _, _} = fa

    quote do
      @lua_function validate_func!(
                      {unquote(name), false,
                       Module.delete_attribute(__MODULE__, :variadic) || false},
                      __MODULE__,
                      @lua_function
                    )
      def unquote(fa), do: unquote(block)
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
