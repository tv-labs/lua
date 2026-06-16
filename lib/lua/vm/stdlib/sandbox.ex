defmodule Lua.VM.Stdlib.Sandbox do
  @moduledoc """
  Shared helper for stdlib functions that are unavailable in the sandbox.

  A virtual VM has no equivalent for some host capabilities (spawning a
  subprocess, the real `io` library before it is virtualized). Those entries
  are installed as stubs that raise a consistent `"<fn>(_) is sandboxed"`
  message, matching the wording embedders and the Lua 5.3 suite already key on.
  """

  alias Lua.Util

  @doc """
  Raises the sandbox error for `path` called with `arity` arguments.
  """
  @spec sandboxed!([atom() | binary()], non_neg_integer()) :: no_return()
  def sandboxed!(path, arity) do
    raise Lua.RuntimeException, "#{Util.format_function(path, arity)} is sandboxed"
  end

  @doc """
  A `{:native_func, _}` value that raises the sandbox error for `path` on call.
  """
  @spec stub([atom() | binary()]) :: {:native_func, (list(), term() -> no_return())}
  def stub(path) do
    {:native_func, fn args, _state -> sandboxed!(path, length(args)) end}
  end
end
