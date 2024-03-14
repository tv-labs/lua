defmodule Lua.CompilerException do
  defexception [:message]

  alias Lua.Util

  def exception({:lua_error, error, state}) do
    stacktrace = Luerl.New.get_stacktrace(state)

    message = """
    Failed to compile Lua script!

    #{Util.format_error(error)}

    #{Util.format_stacktrace(stacktrace, state)}
    """

    %__MODULE__{message: message}
  end

  def exception({_line, _type, _failure} = error) do
    message = """
    Failed to compile Lua script!

    #{Util.format_error(error)}
    """

    %__MODULE__{message: message}
  end
end
