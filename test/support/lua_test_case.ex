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
    # Suite files print() heavily. Swallow that chatter so test output stays
    # readable; capture_io re-raises after capturing, so a failing Lua
    # assert() still fails the ExUnit test with its message intact.
    ExUnit.CaptureIO.capture_io(fn ->
      case Lua.SuiteRunner.run_file(path, opts) do
        :ok -> :ok
        {:error, e} -> raise e
      end
    end)

    :ok
  end
end
