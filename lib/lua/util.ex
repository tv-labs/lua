defmodule Lua.Util do
  @moduledoc false
  # Exposes functions for creating and accessing all of the
  # Erlang records defined in https://github.com/rvirding/luerl/blob/develop/include/luerl.hrl
  # These functions are primarily used for inspecting the state of Luerl

  require Record

  for {name, fields} <- Record.extract_all(from_lib: "luerl/include/luerl.hrl") do
    Record.defrecord(name, fields)
  end

  # Check if all members of the list are encoded
  # useful for checking return values
  def list_encoded?(list) when is_list(list) do
    Enum.all?(list, &encoded?/1)
  end

  # Returns true for identity values
  # or values that hold internal Luerl representations like tref
  def encoded?(nil), do: true
  def encoded?(false), do: true
  def encoded?(true), do: true
  def encoded?(binary) when is_binary(binary), do: true
  # TODO Remove since this shouldn't be decoded
  # take out when https://github.com/rvirding/luerl/pull/213
  # is released
  def encoded?(number) when is_number(number), do: true
  def encoded?(record) when Record.is_record(record, :tref), do: true
  def encoded?(record) when Record.is_record(record, :usdref), do: true
  def encoded?(record) when Record.is_record(record, :funref), do: true
  def encoded?(record) when Record.is_record(record, :erl_func), do: true
  def encoded?(record) when Record.is_record(record, :erl_mfa), do: true

  def encoded?(_), do: false

  def format_error(error) do
    case error do
      {line, type, {:illegal, value}} ->
        type =
          case type do
            :luerl_parse -> "parse"
            :luerl_scan -> "tokenize"
          end

        "Failed to #{type}: illegal token on line #{line}: #{value}"

      {:badarith, operator, values} ->
        expression = values |> Enum.map(&to_string/1) |> Enum.join(" #{operator} ")

        "bad arithmetic #{expression}"

      {:illegal_index, _type, message} ->
        # TODO we can try to get fancy here and
        # print what the object was that they tried to access
        "invalid index \"#{message}\""

      {line, _type, {:user, message}} ->
        "Line #{line}: #{message}"

      {line, _type, message} ->
        "Line #{line}: #{message}"

      error ->
        :luerl_lib.format_error(error)
        # "unknown error #{inspect(error)}"
    end
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
        keys = tref |> :luerl.decode(state) |> Enum.map_join(", ", fn {k, _} -> inspect(k) end)

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
            {:luerl_lib_basic, :assert, :undefined} -> format_error(func, args)
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

  defp format_error({:luerl_lib_basic, :assert, :undefined}, args) do
    format_function("assert", args)
  end

  defp format_error(_, {:undefined, args}) do
    format_function("unknown_error", args)
  end
end
