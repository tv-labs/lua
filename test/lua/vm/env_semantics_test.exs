defmodule Lua.VM.EnvSemanticsTest do
  use ExUnit.Case, async: true

  # Regression tests for Lua 5.3 _ENV semantics.
  #
  # In Lua 5.3, every "global" name reference is syntactic sugar for
  # `_ENV.name`, where `_ENV` is an implicit upvalue in every function. A
  # user may swap their environment with `_ENV = setmetatable({}, ...)` or
  # `local _ENV = ...`, and all subsequent free-name accesses go through
  # that table (and its metamethods).
  #
  # This implementation does not currently honour that. Free names are
  # resolved as `{:global, name}` at compile time and the VM reads/writes a
  # flat `state.globals` map directly via `:get_global` / `:set_global`
  # opcodes that bypass any user-controlled `_ENV`. `_G` is a metatable
  # proxy whose `__index`/`__newindex` route to `state.globals`; `_ENV` is
  # a one-time alias of `_G` set at stdlib install.
  #
  # These tests are tagged `:skip`. They must pass once Plan A16
  # (.agents/plans/A16-env-semantics.md) is implemented. Removing the
  # skip tags is a success criterion of A16.
  #
  # Discovered while triaging suite test events.lua (Plan A8). The first
  # failing assertion in events.lua is line 15:
  #   assert(X == 30 and _G.X == 20)
  # which depends on this behaviour.

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  describe "_ENV reassignment redirects global access" do
    @tag :skip
    test "global write after _ENV swap goes to new env, not _G", %{lua: lua} do
      code = """
      X = 20
      _ENV = setmetatable({}, {__index=_G})
      X = X + 10
      return _G.X, _ENV.X
      """

      # _G.X must remain 20 (write went to new _ENV), _ENV.X is 30
      assert {[20, 30], _} = Lua.eval!(lua, code)
    end

    @tag :skip
    test "setting key to nil in new _ENV falls through __index", %{lua: lua} do
      code = """
      B = 30
      _ENV = setmetatable({}, {__index=_G})
      B = false
      local v1 = B
      B = nil
      local v2 = B
      return v1, v2
      """

      # After B = false, _ENV.B = false (no fallthrough).
      # After B = nil, _ENV has no B key, so __index falls through to _G.B = 30.
      assert {[false, 30], _} = Lua.eval!(lua, code)
    end

    @tag :skip
    test "free name read consults new _ENV's __index", %{lua: lua} do
      code = """
      _ENV = setmetatable({}, {__index = function(_, k) return "from-meta-" .. k end})
      return foo
      """

      assert {["from-meta-foo"], _} = Lua.eval!(lua, code)
    end
  end

  describe "local _ENV scoping" do
    @tag :skip
    test "local _ENV inside a function redirects only that function", %{lua: lua} do
      code = """
      X = 1
      local function f()
        local _ENV = setmetatable({}, {__index=_G})
        X = 99
        return X
      end
      local inside = f()
      return inside, X
      """

      # Inside f, the local _ENV captures X = 99. Outer X stays 1.
      assert {[99, 1], _} = Lua.eval!(lua, code)
    end
  end

  describe "_G / _ENV identity at top level" do
    test "_G == _ENV before any user reassignment", %{lua: lua} do
      # This already passes — included to pin the contract that the A16
      # implementation must not break.
      assert {[true], _} = Lua.eval!(lua, "return _G == _ENV")
    end
  end
end
