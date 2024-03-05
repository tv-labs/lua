defmodule Lua.CompilerException do
  defexception [:message]

  def exception(data) do
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
