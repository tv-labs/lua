defmodule Lua.TestCase do
  @moduledoc """
  Test support for running Lua 5.3 test suite files.

  Thin wrapper over `Lua.SuiteRunner` that raises the underlying
  exception so an ExUnit `test` block fails the way you'd expect when
  a Lua `assert()` fires.
  """

  use ExUnit.CaseTemplate

  @doc """
  Runs a `.lua` file under the shared suite sandbox.

  Returns `:ok` on success; re-raises the underlying exception (so
  ExUnit reports it as a failure) on error.

  See `Lua.SuiteRunner.prepare/1` and `Lua.SuiteRunner.run_file/1`
  for the sandbox details — `package`/`require` are unsandboxed and
  `dostring`, `load`, `checkerr` helpers are installed.
  """
  def run_lua_file(path, _opts \\ []) do
    case Lua.SuiteRunner.run_file(path) do
      :ok -> :ok
      {:error, e} -> raise e
    end
  end
end
