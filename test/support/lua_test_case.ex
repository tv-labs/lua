defmodule Lua.TestCase do
  @moduledoc false

  # Test support for running Lua 5.3 test suite files.
  #
  # Thin wrapper over `Lua.SuiteRunner` (in `tasks/`) that raises the
  # underlying exception so an ExUnit `test` block fails the way you'd
  # expect when a Lua `assert()` fires.

  use ExUnit.CaseTemplate

  @doc false
  def run_lua_file(path, opts \\ []) do
    case Lua.SuiteRunner.run_file(path, opts) do
      :ok -> :ok
      {:error, e} -> raise e
    end
  end
end
