defmodule Lua.VM.Stdlib.Util do
  @moduledoc false

  @doc """
  Returns the Lua type name for a value as a string.

  This is useful for error messages in standard library functions.
  """
  def typeof(nil), do: "nil"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(v) when is_number(v), do: "number"
  def typeof(v) when is_binary(v), do: "string"
  def typeof({:tref, _}), do: "table"
  def typeof({:lua_closure, _, _}), do: "function"
  def typeof({:native_func, _}), do: "function"
  def typeof(_), do: "unknown"

  @doc """
  Converts a Lua value to a string representation for formatting.
  """
  def to_lua_string(nil), do: "nil"
  def to_lua_string(val) when is_binary(val), do: val
  def to_lua_string(val) when is_boolean(val), do: to_string(val)
  def to_lua_string(val) when is_number(val), do: Lua.VM.Value.to_string(val)
  def to_lua_string(_), do: "table"
end
