defmodule Lua do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  defstruct [:state]

  alias Luerl.New, as: Luerl

  alias Lua.Util

  @default_sandbox [
    [:io],
    [:file],
    [:os, :execute],
    [:os, :exit],
    [:os, :getenv],
    [:os, :remove],
    [:os, :rename],
    [:os, :tmpname],
    [:package],
    [:load],
    [:loadfile],
    [:require],
    [:dofile],
    [:load],
    [:loadfile],
    [:loadstring]
  ]

  defimpl Inspect do
    def inspect(_lua, _opts) do
      "#Lua<>"
    end
  end

  @doc """
  Initializes a Lua VM sandbox. All library functions are stubbed out,
  so no access to the filesystem or the execution environment is exposed.

  ## Options
  * `:sandboxed` - list of paths to be sandboxed, e.g. `sandboxed: [[:require], [:os, :exit]]`
  """
  def new(opts \\ []) do
    sandboxed = Keyword.get(opts, :sandboxed, @default_sandbox)

    Enum.reduce(sandboxed, %__MODULE__{state: :luerl.init()}, &sandbox(&2, &1))
  end

  @doc """
  Sandboxes the given path, swapping out the implementation with
  a function that raises when called

      iex> lua = Lua.new(sandboxed: [])
      iex> Lua.sandbox(lua, [:os, :exit])

  """
  def sandbox(lua, path) do
    set!(lua, [:_G | path], fn args ->
      raise Lua.RuntimeException,
            "#{Lua.Util.format_function(path, Enum.count(args))} is sandboxed"
    end)
  end

  @doc """
  Sets the path patterns that Lua will look in when requiring Lua scripts.
  """
  def set_lua_paths(%__MODULE__{} = lua, paths) when is_binary(paths) do
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
  def set!(%__MODULE__{state: state}, keys, value) do
    {_keys, state} =
      Enum.reduce_while(keys, {[], state}, fn key, {keys, state} ->
        keys = keys ++ [key]

        case :luerl_new.get_table_keys_dec(keys, state) do
          {:ok, nil, state} ->
            {:cont, set_keys!(state, keys)}

          {:ok, _val, state} ->
            {:halt, {keys, state}}

          {:lua_error, _err, state} ->
            raise Lua.RuntimeException, {:lua_error, illegal_index(keys), state}
        end
      end)

    case :luerl_new.set_table_keys_dec(keys, value, state) do
      {:ok, _value, state} ->
        wrap(state)

      {:lua_error, _error, state} ->
        raise Lua.RuntimeException, {:lua_error, illegal_index(keys), state}
    end
  end

  defp set_keys!(state, keys) do
    case :luerl_new.set_table_keys_dec(keys, [], state) do
      {:ok, _, state} ->
        {keys, state}

      {:lua_error, _error, state} ->
        raise Lua.RuntimeException, {:lua_error, illegal_index(keys), state}
    end
  end

  defp illegal_index([:_G | keys]), do: illegal_index(keys)

  defp illegal_index(keys) do
    {:illegal_index, nil, Enum.join(keys, ".")}
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

  # TODO remove this version
  def get!(state, keys) when is_tuple(state) do
    case :luerl_new.get_table_keys_dec(keys, state) do
      {:ok, value, _state} ->
        value

      {:lua_error, _, state} ->
        error = {:illegal_index, nil, Enum.join(keys, ".")}
        raise Lua.RuntimeException, {:lua_error, error, state}
    end
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

      {:error, [error | _], _} ->
        raise Lua.CompilerException, error
    end
  rescue
    e in [UndefinedFunctionError] ->
      reraise Lua.RuntimeException,
              Util.format_function([e.module, e.function], e.arity),
              __STACKTRACE__

    e in [Lua.RuntimeException, Lua.CompilerException] ->
      reraise e, __STACKTRACE__

    e ->
      reraise Lua.RuntimeException, e, __STACKTRACE__
  end

  @doc """
  Calls a function in Lua's state

      iex> {[ret], _lua} = Lua.call_function!(Lua.new(), [:string, :lower], ["HELLO ROBERT"])
      iex> ret
      "hello robert"

  References to functions can also be passed

      iex> {[ref], lua} = Lua.eval!("return string.lower")
      iex> {[ret], _lua} = Lua.call_function!(lua, ref, ["FUNCTION REF"])
      iex> ret
      "function ref"
  """
  def call_function!(%__MODULE__{} = lua, name, args) when is_list(args) and is_tuple(name) or is_function(name) do
    {ref, lua} = encode!(lua, name)

    case :luerl_new.call(ref, args, lua.state) do
      {:ok, value, state} -> {value, wrap(state)}
      {:lua_error, _, _} = error -> raise Lua.RuntimeException, error
    end
  end
  def call_function!(%__MODULE__{} = lua, name, args) when is_list(args) do
    keys = List.wrap(name)

    func = get!(lua, keys)

    case :luerl_new.call_function(func, args, lua.state) do
      {:ok, ret, lua} -> {ret, wrap(lua)}
      {:lua_error, _, _} = error -> raise Lua.RuntimeException, error
    end
  end

  @doc """
  Encodes a Lua value into its internal form
  """
  def encode!(%__MODULE__{} = lua, value) do
    case :luerl_new.encode(value, lua.state) do
      {encoded, state} -> {encoded, wrap(state)}
      {:lua_error, _, _} = error -> raise Lua.RuntimeException, error
    end
  end

  @doc """
  Loads a lua file into the environment. Any values returned in the globa
  scope are thrown away.

  Mimics the functionality of lua's [dofile](https://www.lua.org/manual/5.4/manual.html#pdf-dofile)
  """
  def load_file!(%__MODULE__{state: state} = lua, path) when is_binary(path) do
    case :luerl_new.dofile(String.to_charlist(path), [:return], state) do
      {:ok, _, state} ->
        %__MODULE__{lua | state: state}

      {:lua_error, _error, _lua} = error ->
        raise Lua.CompilerException, error

      {:error, [{:none, :file, :enoent} | _], _} ->
        raise "Cannot load lua file, #{inspect(path <> ".lua")} does not exist"

      {:error, [error | _], _} ->
        # We just take the first error
        raise Lua.CompilerException, error
    end
  end

  @doc """
  Inject functions written with the `deflua` macro into the Lua
  runtime
  """
  def load_api(lua, module, scope \\ nil) do
    funcs = :functions |> module.__info__() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    scope = scope || module.scope()

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
        execute_function(module, function_name, args ++ [wrap(state)])
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
          execute_function(module, function_name, args ++ [wrap(state)])
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
    case apply(module, function_name, args) do
      {ret, %Lua{state: state}} -> {ret, state}
      other -> List.wrap(other)
    end
  catch
    thrown_value ->
      {:error,
       "Value thrown during function '#{function_name}' execution: #{inspect(thrown_value)}"}
  end

  defp wrap(state), do: %__MODULE__{state: state}
end
