defmodule Lua.CompilerException do
  @moduledoc false
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

  # TODO: Re-add stacktrace formatting once the new VM has stacktrace support.
  # The old Luerl-backed implementation included stacktraces in compiler errors:
  #
  #   def message(%__MODULE__{errors: errors, state: state}) do
  #     stacktrace = :luerl.get_stacktrace(state)
  #     """
  #     Failed to compile Lua!
  #
  #     #{Enum.join(errors, "\n")}
  #
  #     #{Util.format_stacktrace(stacktrace, state)}
  #     """
  #   end
  def message(%__MODULE__{errors: errors}) do
    """
    Failed to compile Lua!

    #{Enum.join(errors, "\n")}
    """
  end
end
