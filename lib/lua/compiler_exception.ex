defmodule Lua.CompilerException do
  @moduledoc """
  Raised when Lua source cannot be lexed, parsed, or compiled.

  `Exception.message/1` returns a plain, ANSI-free string — the bare per-error
  messages under a `Failed to compile Lua!` header — safe to log. For the full,
  human-readable report (location, source context, pointer, suggestions, and
  ANSI color on a TTY) use `Lua.format_exception/1`, which is what
  `mix lua.eval` prints. For structured data use `to_map/1`.

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

  # Plain, ANSI-free rendering from the bare `:errors` strings — no location
  # header, source context, or color. Safe to log. The rich source-context
  # report lives in `format/1`.
  @impl true
  def message(%__MODULE__{errors: errors}) do
    """
    Failed to compile Lua!

    #{Enum.join(errors, "\n")}
    """
  end

  @doc """
  Renders the rich, human-readable report — location, source context, a pointer
  to the offending token, and suggestions — with ANSI color when
  `IO.ANSI.enabled?/0` is true. Used by `Lua.format_exception/1`.

  Compile-time errors have no runtime stack trace; the context is rendered from
  the structured `:diagnostics`. Falls back to the plain `message/1` when no
  structured diagnostics are present (lexer/compiler errors).
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{diagnostics: [_ | _] = diagnostics, source: source}) do
    rendered = Enum.map_join(diagnostics, "\n", &Error.format(&1, source))

    """
    Failed to compile Lua!

    #{rendered}
    """
  end

  def format(%__MODULE__{} = e), do: message(e)

  @doc """
  Returns a wire-safe structured representation — a list of per-error maps in
  the `Lua.Parser.Error` shape (`type`, `message`, `line`, `source_context`,
  `suggestion`, …), with no ANSI escapes. Returns `[]` for non-parser inputs
  (lexer/compiler errors) that carry no structured diagnostics; read `:errors`
  for those.
  """
  @spec to_map(t()) :: [map()]
  def to_map(%__MODULE__{diagnostics: [_ | _] = diagnostics, source: source}) do
    Enum.map(diagnostics, &Error.to_map(&1, source))
  end

  def to_map(%__MODULE__{}), do: []

  defp clean_message(%Error{message: message}) when is_binary(message), do: String.trim(message)
  defp clean_message(%Error{}), do: ""
end
