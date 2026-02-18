defmodule Lua.Language.ControlFlowTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "if false should not execute body", %{lua: lua} do
    # constructs.lua line 20: dead code with division by zero
    code = ~S"""
    if false then a = 3 // 0; a = 0 % 0 end
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "semicolons as empty statements", %{lua: lua} do
    # constructs.lua lines 13-16
    code = ~S"""
    do ;;; end
    ; do ; a = 3; assert(a == 3) end;
    ;
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "dead code not evaluated", %{lua: lua} do
    assert {[true], _} = Lua.eval!(lua, "if false then a = 3 // 0 end; return true")
  end
end
