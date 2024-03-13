defmodule Lua.Util do
  @moduledoc false
  # Exposes functions for creating and accessing all of the
  # Erlang records defined in https://github.com/rvirding/luerl/blob/develop/include/luerl.hrl
  # These functions are primarily used for inspecting the state of Luerl

  require Record

  for {name, fields} <- Record.extract_all(from_lib: "luerl/include/luerl.hrl") do
    Record.defrecord(name, fields)
  end

  @doc """
  Lists all user-defined functions in the global Lua scope

      iex> lua = Lua.set!(Lua.new(), [:my_func], fn value -> value end)
      iex> user_functions(lua)
      ["my_func(_)"]

  Nested functions are nicely scoped

      iex> lua = Lua.set!(Lua.new(), [:my_func], fn value -> value end)
      iex> lua = Lua.set!(lua, [:foo, :bar], fn value, _ -> value end)
      iex> user_functions(lua)
      ["foo.bar(_, _)", "my_func(_)"]

  ## Options
  * :formatter - formats the function, defaults to &format_function/1
  """
  def user_functions(%Lua{functions: functions}, opts \\ []) do
    formatter = Keyword.get(opts, :formatter, &format_function/2)

    functions
    |> Enum.map(fn {keys, arity} -> formatter.(keys, arity) end)
    |> Enum.sort(:asc)
  end

  @doc """
  Pretty prints a stack trace
  """
  def format_stacktrace(_stack, _state, _opts \\ [])
  def format_stacktrace([], _state, _opts), do: ""

  def format_stacktrace([_ | rest] = stacktrace, state, opts) do
    script_name = Keyword.get(opts, :script_name, "script")

    stacktrace
    |> Enum.zip(rest)
    |> Enum.map_join("\n", fn
      {{func, [{:tref, _} = tref | rest], _}, {_, _, context}} ->
        # Tried to call a method on something that wasn't setup correctly
        keys = state |> Luerl.New.decode(tref) |> Enum.map_join(", ", fn {k, _} -> inspect(k) end)

        """
        #{inspect(func)} with arguments #{format_args(rest)}
        ^--- self is incorrect for object with keys #{keys}


        #{script_name} line #{context[:line]}
        """

      {{func, args, _}, {_, _, context}} ->
        name =
          case func do
            nil -> " <unknown function>#{format_args(args)}"
            "-no-name-" -> ""
            {:luerl_lib_basic, :basic_error} -> format_error(func, args)
            {:luerl_lib_basic, :basic_error, :undefined} -> format_error(func, args)
            {:luerl_lib_basic, :error_call, :undefined} -> format_error(func, args)
            func -> " #{format_function([func], args)}"
          end

        "#{script_name} line #{context[:line]}:#{name}"
    end)
  end

  @doc """
  Formats the scope as a function

      iex> format_function(["foo"], 0)
      "foo()"

  Arity is displayed

      iex> format_function(["foo"], 3)
      "foo(_, _, _)"

  Args are displayed if given

      iex> format_function(["foo"], [1, 2, 3])
      "foo(1, 2, 3)"

  Internal Lua functions are formatted nicely

      iex> format_function([:_G, :os, :exit], 1)
      "os.exit(_)"

  References to tables are displayed as <ref>

      iex> format_function([tref: 1234], [1, 2, 3])
      "<reference>(1, 2, 3)"

  Namespaced functions are correctly formatted

      iex> format_function(["namespace", "function"], 1)
      "namespace.function(_)"
  """
  def format_function([:_G | list], args), do: format_function(list, args)

  def format_function(list, args) do
    list = List.wrap(list)

    Enum.map_join(list, ".", &format_scope/1) <> format_args(args)
  end

  defp format_args(arity) when is_integer(arity) do
    underscores = List.duplicate("_", arity) |> Enum.join(", ")
    "(" <> underscores <> ")"
  end

  defp format_args(args) do
    "(" <> Enum.map_join(args, ", ", &inspect/1) <> ")"
  end

  defp format_scope({:tref, _val}), do: "<reference>"
  defp format_scope(scope), do: scope

  defp format_error({:luerl_lib_basic, :basic_error}, {:undefined, args}) do
    format_function("error", args)
  end

  defp format_error({:luerl_lib_basic, :basic_error, :undefined}, args) do
    format_function("error", args)
  end

  defp format_error({:luerl_lib_basic, :error_call, :undefined}, args) do
    format_function("error", args)
  end

  defp format_error(_, {:undefined, args}) do
    format_function("unknown_error", args)
  end
end
