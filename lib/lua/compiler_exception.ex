defmodule Lua.CompilerException do
  defexception [:errors, :state]

  alias Lua.Util

  def exception(formatted: errors) when is_list(errors) do
    %__MODULE__{errors: errors}
  end

  def exception(errors) when is_list(errors) do
    %__MODULE__{errors: Enum.map(errors, &Util.format_error/1)}
  end

  def exception({:lua_error, error, state}) do
    %__MODULE__{errors: [Util.format_error(error)], state: state}
  end

  def exception({_line, _type, _failure} = error) do
    %__MODULE__{errors: [Util.format_error(error)]}
  end

  def message(%__MODULE__{state: nil, errors: errors}) do
    """
    Failed to compile Lua!

    #{Enum.join(errors, "\n")}
    """
  end

  def message(%__MODULE__{errors: errors, state: state}) do
    stacktrace = Luerl.New.get_stacktrace(state)

    """
    Failed to compile Lua!

    #{Enum.join(errors, "\n")}

    #{Util.format_stacktrace(stacktrace, state)}
    """
  end
end
