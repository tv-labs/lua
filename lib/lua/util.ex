defmodule Lua.Util do
  @moduledoc false

  # Check if all members of the list are encoded
  # useful for checking return values
  def list_encoded?(list) when is_list(list) do
    Enum.all?(list, &encoded?/1)
  end

  # Returns true for identity values
  # or values that hold internal VM representations
  def encoded?(nil), do: true
  def encoded?(false), do: true
  def encoded?(true), do: true
  def encoded?(binary) when is_binary(binary), do: true
  def encoded?(number) when is_number(number), do: true
  def encoded?({:tref, _}), do: true
  def encoded?({:lua_closure, _, _}), do: true
  def encoded?({:native_func, _}), do: true
  def encoded?(_), do: false

  def format_error(error) do
    case error do
      {:badarith, operator, values} ->
        expression = values |> Enum.map(&to_string/1) |> Enum.join(" #{operator} ")
        "bad arithmetic #{expression}"

      {:illegal_index, _type, message} ->
        "invalid index \"#{message}\""

      message when is_binary(message) ->
        message

      %{message: message} when is_binary(message) ->
        message

      other ->
        inspect(other)
    end
  end

  @doc """
  Pretty prints a stack trace in Lua 5.3 format.

  ## Examples

      iex> stack = [
      ...>   %{source: "-no-source-", line: 3, name: "bar"},
      ...>   %{source: "-no-source-", line: 7, name: "foo"},
      ...>   %{source: "-no-source-", line: 10, name: nil}
      ...> ]
      iex> Lua.Util.format_stacktrace(stack, nil)
      "stack traceback:\\n    -no-source-:3: in function 'bar'\\n    -no-source-:7: in function 'foo'\\n    -no-source-:10: in main chunk"

  """
  def format_stacktrace(stack, _state, _opts \\ [])

  def format_stacktrace([], _, _), do: ""

  def format_stacktrace(stack, _, _) when is_list(stack) do
    frames =
      stack
      |> Enum.reverse()
      |> Enum.map(&format_stack_frame/1)
      |> Enum.join("\n")

    "stack traceback:\n" <> frames
  end

  defp format_stack_frame(%{source: source, line: line, name: name}) do
    location = "    #{source || "-no-source-"}:#{line}:"

    context =
      case name do
        nil -> " in main chunk"
        func_name -> " in function '#{func_name}'"
      end

    location <> context
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
end
