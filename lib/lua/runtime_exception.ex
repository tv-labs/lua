defmodule Lua.RuntimeException do
  @moduledoc false
  alias Lua.Util

  defexception [:message, :original, :state, :line, :source, :call_stack]

  @impl true
  def exception({:lua_error, error, _state}) do
    message = Util.format_error(error)

    %__MODULE__{
      original: error,
      message: "Lua runtime error: #{message}"
    }
  end

  def exception({:api_error, details, state}) do
    %__MODULE__{original: details, state: state, message: "Lua API error: #{details}"}
  end

  def exception(list) when is_list(list) do
    scope = Keyword.fetch!(list, :scope)
    function = Keyword.fetch!(list, :function)
    message = Keyword.fetch!(list, :message)

    %__MODULE__{
      original: list,
      state: nil,
      message: "Lua runtime error: #{format_function(scope, function)} failed, #{message}"
    }
  end

  def exception(error) when is_binary(error) do
    %__MODULE__{message: "Lua runtime error: #{String.trim(error)}"}
  end

  def exception(error) do
    message =
      if is_exception(error) do
        Exception.message(error)
      else
        inspect(error)
      end

    # Copy structured fields off VM exceptions (TypeError, RuntimeError,
    # AssertionError) so consumers can pattern-match on `:line` / `:source`
    # without having to re-parse the message string.
    {line, source, call_stack} = extract_context(error)

    %__MODULE__{
      original: error,
      message: "Lua runtime error: #{message}",
      line: line,
      source: source,
      call_stack: call_stack
    }
  end

  defp extract_context(error) when is_struct(error) do
    {Map.get(error, :line), Map.get(error, :source), Map.get(error, :call_stack)}
  end

  defp extract_context(_), do: {nil, nil, nil}

  defp format_function([], function), do: "#{function}()"

  defp format_function(scope, function) do
    "#{Enum.join(scope, ".")}.#{function}()"
  end
end
