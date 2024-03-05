defmodule Lua do
  @moduledoc """
  Lua aims to be the best way to integrate Luerl into an Elixir project.
  """

  defstruct [:state, functions: %{}]

  alias Luerl.New, as: Luerl

  alias Lua.Util

  defimpl Inspect do
    alias Lua.Util

    import Inspect.Algebra

    def inspect(lua, _opts) do
      concat(["#Lua<functions:", "[", Enum.join(Util.user_functions(lua), ", "), "]>"])
    end
  end

  @doc """
  Initializes a Lua VM sandbox. All library functions are stubbed out,
  so no access to the filesystem or the execution environment is exposed.
  """
  def new(_opts \\ []) do
    %__MODULE__{state: :luerl.new()}
  end

  def sandbox(_opts \\ []) do
    # TODO create an options API for this
    sandboxed = [
      [:_G, :io],
      [:_G, :file],
      [:_G, :os, :execute],
      [:_G, :os, :exit],
      [:_G, :os, :getenv],
      [:_G, :os, :remove],
      [:_G, :os, :rename],
      [:_G, :os, :tmpname],
      #       [:_G, :package],
      [:_G, :load],
      [:_G, :loadfile],
      #       [:_G, :require],
      [:_G, :dofile],
      [:_G, :load],
      [:_G, :loadfile],
      [:_G, :loadstring]
    ]

    # TODO let's implement sandbox ourselves
    %__MODULE__{state: :luerl_sandbox.new(sandboxed)}
  end

  @doc """
  Sets the path patterns that Lua will look in when requiring Lua scripts.
  """
  def set_lua_paths(%__MODULE__{state: state} = lua, paths) when is_binary(paths) do
    %{lua | state: state}
    set!(lua, ["package", "path"], paths)
  end

  @doc """
  Sets a table value in Lua. Nested keys will create
  intermediate tables

      iex> Lua.set!(Lua.new(), [:hello], "World")

  It can also set nested values

      iex> Lua.set!(Lua.new(), [:a, :b, :c], [])

  These table values are availble in lua scripts

      iex> lua = Lua.set!(Lua.new(), [:a, :b, :c], "nested!")
      iex> {result, _} = Lua.eval!(lua, "return a.b.c")
      iex> result
      ["nested!"]

  """
  def set!(%__MODULE__{state: state} = lua, keys, value) do
    new_state =
      state
      |> ensure_keys(keys)
      |> set_keys(keys, value)

    functions =
      if is_function(value) do
        info = Function.info(value)
        Map.put(lua.functions, keys, info[:arity])
      else
        lua.functions
      end

    %__MODULE__{state: new_state, functions: functions}
  end

  @doc """
  Gets a table value in Lua

      iex> state = Lua.set!(Lua.new(), [:hello], "world")
      iex> Lua.get!(state, [:hello])
      "world"

  When a value doesn't exist, it returns nil

      iex> Lua.get!(Lua.new(), [:nope])
      nil

  It can also get nested values

      iex> state = Lua.set!(Lua.new(), [:a, :b, :c], "nested")
      iex> Lua.get!(state, [:a, :b, :c])
      "nested"
  """
  def get!(%__MODULE__{state: state}, keys), do: get!(state, keys)

  def get!(state, keys) when is_tuple(state) do
    {:ok, value, _state} = Luerl.get_table_keys_dec(state, keys)
    value
  end

  @doc """
  Evalutes the script or chunk, returning the result and
  discarding side effects in the state
  """
  def eval!(state \\ new(), script)

  def eval!(%__MODULE__{state: state} = lua, script) when is_binary(script) do
    case Luerl.do_dec(state, script) do
      {:ok, result, new_state} ->
        {result, %__MODULE__{lua | state: new_state}}

      {:lua_error, _e, _state} = error ->
        raise Lua.RuntimeException, error

      {:error, reason, _stuff} ->
        raise Lua.CompilerException, reason: reason
    end
  rescue
    e in [ArgumentError, FunctionClauseError] ->
      reraise e, __STACKTRACE__

    e in [CaseClauseError, MatchError] ->
      reraise Lua.RuntimeException, "Could not match #{inspect(e.term)}", __STACKTRACE__

    e in [UndefinedFunctionError] ->
      reraise Lua.RuntimeException,
              Util.format_function([e.module, e.function], e.arity),
              __STACKTRACE__

    e in [ErlangError] ->
      reraise Lua.RuntimeException, e.original, __STACKTRACE__
  end

  # Deep-set a value within a nested Lua table structure,
  # ensuring the entire path of keys exists.
  defp ensure_keys(state, [first | rest]) do
    ensure_keys(state, [first], rest)
  end

  defp ensure_keys(state, keys, rest) do
    state =
      case Luerl.get_table_keys_dec(state, keys) do
        {:ok, nil, state} ->
          set_keys(state, keys)

        {:ok, _result, state} ->
          state
          # TODO error?
      end

    case rest do
      [] -> state
      [next | rest] -> ensure_keys(state, keys ++ [next], rest)
    end
  end

  defp set_keys(state, keys, value \\ []) do
    case Luerl.set_table_keys_dec(state, keys, value) do
      {:ok, [], state} -> state
      {:lua_error, error, _state} -> raise Lua.RuntimeException, reason: error
    end
  end

  def load_lua_file!(%__MODULE__{state: state} = lua, path) when is_binary(path) do
    case Luerl.dofile(state, String.to_charlist(path)) do
      {:ok, [], state} ->
        %__MODULE__{lua | state: state}

      :error ->
        raise "Cannot load lua file, #{inspect(path <> ".lua")} does not exist"
    end
  end

  @doc """
  Inject functions written with the `deflua` macro into the Lua
  runtime
  """
  # TODO rename to load_api
  def inject_module(lua, module, scope \\ []) do
    funcs = :functions |> module.__info__() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    module.__lua_functions__()
    |> Enum.reduce(lua, fn {name, with_state?, variadic?}, lua ->
      arities = Map.get(funcs, name)

      Lua.set!(
        lua,
        List.wrap(scope) ++ [name],
        if variadic? do
          wrap_variadic_function(module, name, with_state?)
        else
          wrap_function(module, name, arities, with_state?)
        end
      )
    end)
  end

  defp wrap_variadic_function(module, function_name, with_state?) do
    # formatted = Util.format_function(module.scope() ++ [function_name], 0)

    if with_state? do
      fn args, state ->
        apply(module, function_name, [args] ++ [state])
      end
    else
      fn args ->
        execute_function(module, function_name, [args])
      end
    end
  end

  # credo:disable-for-lines:25
  defp wrap_function(module, function_name, arities, with_state?) do
    # formatted = Util.format_function(module.scope() ++ [function_name], 0)

    if with_state? do
      fn args, state ->
        if (length(args) + 1) in arities do
          apply(module, function_name, args ++ [state])
        else
          arities = Enum.map(arities, &(&1 - 1))

          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "expected #{Enum.join(arities, " or ")} arguments, got #{length(args)}"
        end
      end
    else
      fn args ->
        if length(args) in arities do
          execute_function(module, function_name, args)
        else
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "expected #{Enum.join(arities, " or ")} arguments, got #{length(args)}"
        end
      end
    end
  end

  defp execute_function(module, function_name, args) do
    # Luerl mandates lists as return values; this function ensures all results conform.
    List.wrap(apply(module, function_name, args))
  catch
    thrown_value ->
      {:error,
       "Value thrown during function '#{function_name}' execution: #{inspect(thrown_value)}"}
  end
end
