defmodule Lua.RuntimeException do
  defexception [:message]

  alias Lua.Util

  @impl true
  def exception({:lua_error, error, state}) do
    message =
      case error do
        {:error_call, message} ->
          "error(#{inspect(message)})"

        {:undefined_function, nil} ->
          "undefined function"

        {:undefined_function, "sandboxed"} ->
          "sandboxed function"

        {:undefined_function, ref} ->
          "undefined function #{inspect(ref)}"

        {:undefined_method, nil, name} ->
          "undefined method #{inspect(name)}"

        {:illegal_index, nil, name} ->
          "invalid index #{inspect(name)}"
      end

    stacktrace = Luerl.New.get_stacktrace(state)

    %__MODULE__{
      message: """
      Lua runtime error: #{message}

      #{Util.format_stacktrace(stacktrace, state)}
      """
    }
  end

  def exception({:api_error, details, _state}) do
    %__MODULE__{message: "Lua API error: #{details}"}
  end

  def exception(list) when is_list(list) do
    scope = Keyword.fetch!(list, :scope)
    function = Keyword.fetch!(list, :function)
    message = Keyword.fetch!(list, :message)

    %__MODULE__{
      message: "Lua runtime error: #{format_function(scope, function)} failed, #{message}"
    }
  end

  def exception(error) when is_binary(error) do
    %__MODULE__{message: "Lua runtime error: #{String.trim(error)}"}
  end

  def exception(error) do
    %__MODULE__{message: "Lua runtime error: #{inspect(error)}"}
  end

  defp format_function([], function), do: "#{function}()"

  defp format_function(scope, function) do
    "#{Enum.join(scope, ".")}.#{function}()"
  end
end
