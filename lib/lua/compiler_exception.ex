defmodule Lua.CompilerException do
  @moduledoc """
  Raised when Lua source cannot be lexed, parsed, or compiled. Carries
  a list of formatted error messages in `:errors`.
  """
  alias Lua.Util

  defexception [:errors, :state]

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
  # produced by the lexer/parser before any code is executed. The rich source
  # context (line, column, pointer to the offending token) is embedded in
  # `errors` by `Lua.Parser.Error.format/2` (and the lexer's equivalent), so
  # we just join those messages under a clear "Failed to compile" header.
  def message(%__MODULE__{errors: errors}) do
    """
    Failed to compile Lua!

    #{Enum.join(errors, "\n")}
    """
  end
end
