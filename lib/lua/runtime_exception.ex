defmodule Lua.RuntimeException do
  @moduledoc """
  Raised when a Lua program fails at runtime — bad argument types,
  arithmetic on a non-number, indexing a nil, an explicit `error()`
  call from Lua, or any other dynamic failure inside the VM.

  Fields:

    * `:message`     — formatted error string
    * `:original`    — the underlying VM error term
    * `:state`       — the internal VM state at the point of failure
    * `:line`        — line number where the error was raised
    * `:source`      — source name (filename or the default `<eval>`)
    * `:call_stack`  — list of Lua frames at failure
  """
  alias Lua.Util

  @runtime_prefix "Lua runtime error: "

  @type t :: %__MODULE__{}

  defexception [:message, :original, :state, :line, :source, :call_stack]

  @impl true
  def exception({:lua_error, error, _state}) do
    %__MODULE__{
      original: error,
      message: prefix_message(Util.format_error(error))
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
      message: prefix_message("#{format_function(scope, function)} failed, #{message}")
    }
  end

  def exception(error) when is_binary(error) do
    %__MODULE__{message: prefix_message(String.trim(error))}
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
      message: prefix_message(message),
      line: line,
      source: source,
      call_stack: call_stack
    }
  end

  defp prefix_message(@runtime_prefix <> _ = msg), do: msg
  defp prefix_message(msg), do: @runtime_prefix <> msg

  defp extract_context(error) when is_struct(error) do
    {Map.get(error, :line), Map.get(error, :source), Map.get(error, :call_stack)}
  end

  defp extract_context(_), do: {nil, nil, nil}

  defp format_function([], function), do: "#{function}()"

  defp format_function(scope, function) do
    "#{Enum.join(scope, ".")}.#{function}()"
  end
end
