defmodule Lua.CompilerException do
  defexception [:message]

  alias Lua.Util

  def exception({:lua_error, error, state}) do
    stacktrace = Luerl.New.get_stacktrace(state)

    message = """
    Failed to compile Lua script: #{Util.format_error(error)}

    #{Util.format_stacktrace(stacktrace, state)}
    """

    %__MODULE__{message: message}
  end

  def exception(data) when is_list(data) do
    message =
      data
      |> Keyword.fetch!(:reason)
      |> Enum.map_join("\n", fn {line, error, failure} ->
        "Line #{line}: #{format_error(error)} due to #{format_error(failure)}"
      end)

    %__MODULE__{message: "Failed to compile Lua script\n\n#{message}\n"}
  end

  defp format_error(:luerl_parse), do: "failed to parse"
  defp format_error(:luerl_scan), do: "failed to tokenize"

  defp format_error({:illegal, value}) when is_list(value),
    do: "illegal token: #{to_string(value)}"

  defp format_error({:illegal, value}), do: "illegal token: #{inspect(value)}}"
  defp format_error(value), do: inspect(value)
end
