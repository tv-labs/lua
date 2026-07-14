defmodule Lua.CompilerException do
  @moduledoc """
  Raised when Lua source cannot be lexed, parsed, or compiled.

  Use `Exception.message/1` to render the full, human-readable report (location,
  source context, pointer, and suggestions). ANSI color is applied only when
  `IO.ANSI.enabled?/0` is true *at render time*, so the same exception logs
  cleanly to a file and renders in color on a TTY (issue #384).

  The `:errors` field carries the bare, ANSI-free error messages (no location
  header or source context) for programmatic inspection and clean logging.
  """
  alias Lua.Parser.Error
  alias Lua.Util

  @type t :: %__MODULE__{}

  # `:diagnostics` holds structured `Lua.Parser.Error` structs and `:source` the
  # original code, so `message/1` can render the rich report lazily. They stay
  # `nil` for non-parser inputs (compiler/lexer errors), which fall back to
  # joining the `:errors` strings.
  defexception errors: [], diagnostics: nil, source: nil

  # Structured parse errors — defer formatting to `message/1` so the ANSI gate
  # is evaluated when the message is written, not frozen at construction.
  def exception({:parse_errors, diagnostics, source}) when is_list(diagnostics) do
    %__MODULE__{
      diagnostics: diagnostics,
      source: source,
      errors: Enum.map(diagnostics, &clean_message/1)
    }
  end

  def exception(formatted: errors) when is_list(errors) do
    %__MODULE__{errors: errors}
  end

  def exception(errors) when is_list(errors) do
    %__MODULE__{errors: Enum.map(errors, &Util.format_error/1)}
  end

  def exception({:lua_error, error, _state}) do
    %__MODULE__{errors: [Util.format_error(error)]}
  end

  def exception({_line, _type, _failure} = error) do
    %__MODULE__{errors: [Util.format_error(error)]}
  end

  def exception(error) when is_binary(error) do
    %__MODULE__{errors: [error]}
  end

  # Compile-time errors don't have a meaningful runtime stack trace — they're
  # produced by the lexer/parser/compiler before any code is executed. The rich
  # source context (line, column, pointer to the offending token) is rendered
  # here from the structured diagnostics, so we join it under a clear
  # "Failed to compile" header.
  @impl true
  def message(%__MODULE__{diagnostics: [_ | _] = diagnostics, source: source}) do
    rendered = Enum.map_join(diagnostics, "\n", &Error.format(&1, source))

    """
    Failed to compile Lua!

    #{rendered}
    """
  end

  def message(%__MODULE__{errors: errors}) do
    """
    Failed to compile Lua!

    #{Enum.join(errors, "\n")}
    """
  end

  defp clean_message(%Error{message: message}) when is_binary(message), do: String.trim(message)
  defp clean_message(%Error{}), do: ""
end
