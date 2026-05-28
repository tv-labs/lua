defmodule Lua.VM.DebugGetinfoNameTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  # Pins the current (incomplete) behavior of `debug.getinfo(level, "n")`
  # — the `name` and `namewhat` fields are always nil regardless of how
  # the function was called. Lua 5.3 §6.10 requires `name` to reflect
  # the textual name resolved at the call site (PUC-Lua walks the
  # caller's bytecode); doing that needs prototype/frame metadata we
  # don't currently retain. See GitHub issue #279.

  defp eval!(code) do
    assert {:ok, ast} = Parser.parse(code)
    assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    results
  end

  test "debug.getinfo(1, 'n').name is nil for the executing closure" do
    code = """
    function F()
      local info = debug.getinfo(1, "n")
      return info.name, info.namewhat
    end

    return F()
    """

    assert [nil, nil] = eval!(code)
  end

  test "debug.getinfo(2, 'n').name is nil for the caller frame" do
    code = """
    local function inner()
      local info = debug.getinfo(2, "n")
      return info.name, info.namewhat
    end

    function caller()
      return inner()
    end

    return caller()
    """

    assert [nil, nil] = eval!(code)
  end

  @tag :skip
  test "debug.getinfo(1, 'n').name returns the global name 'F' (desired)" do
    # Pinned behavior we want once issue #279 is fixed.
    code = """
    function F()
      return debug.getinfo(1, "n").name
    end

    return F()
    """

    assert ["F"] = eval!(code)
  end
end
