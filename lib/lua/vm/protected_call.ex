defmodule Lua.VM.ProtectedCall do
  @moduledoc false

  # The Lua-facing error value handed back at a protected-call boundary
  # (`pcall`/`xpcall`, and `Lua.call_function/3`), per §6.1: the raised value
  # passes through verbatim.
  #
  # Clause ordering is load-bearing:
  # 1. `error()`'s §6.1-prefixed string view (`RuntimeError.lua_value`).
  # 2. Raw passthrough on KEY PRESENCE — `value: nil` (from `error()`) and
  #    `value: false` must match here so the boundary returns nil/false like
  #    PUC-Lua, never an `is_nil`-guarded fallthrough to the next clause.
  # 3. `ArgumentError` builds its message from individual fields and has no
  #    `:value` slot, so it gets its own clause that returns the raw
  #    `"bad argument #N to 'F' ..."` string — never the terminal-rendered
  #    `Exception.message/1` (ANSI + location header).
  # 4. Plain Elixir exceptions keep their message string as a last resort.
  alias Lua.VM.ArgumentError

  def error_value(%{lua_value: lv}) when not is_nil(lv), do: lv
  def error_value(%{value: value}), do: value
  def error_value(%ArgumentError{} = e), do: ArgumentError.raw_message(e)
  def error_value(e), do: Exception.message(e)
end
