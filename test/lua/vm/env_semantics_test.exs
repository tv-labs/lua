defmodule Lua.VM.EnvSemanticsTest do
  use ExUnit.Case, async: true

  # Regression tests for Lua 5.3 `_ENV` semantics (Plan A16).
  #
  # In Lua 5.3, every "global" name reference is syntactic sugar for
  # `_ENV.name`, where `_ENV` is an implicit chunk-level local. A user
  # may swap their environment with `_ENV = setmetatable({}, ...)` or
  # `local _ENV = ...`, and all subsequent free-name accesses go through
  # that table (and its metamethods).
  #
  # In our implementation, the chunk reserves register 0 for `_ENV` and
  # binds it to `_G` at startup via the `:load_env` opcode. Free names in
  # the chunk compile to `_ENV.name` (`get_field`/`set_field` against
  # register 0). Nested functions inherit `_ENV` via the standard upvalue
  # chain, allocated eagerly during scope resolution so every function
  # has access regardless of which free names it references.

  setup do
    %{lua: Lua.new(sandbox: false)}
  end

  describe "_ENV reassignment redirects global access" do
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

    test "free name read consults new _ENV's __index", %{lua: lua} do
      code = """
      _ENV = setmetatable({}, {__index = function(_, k) return "from-meta-" .. k end})
      return foo
      """

      assert {["from-meta-foo"], _} = Lua.eval!(lua, code)
    end
  end

  describe "local _ENV scoping" do
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
      assert {[true], _} = Lua.eval!(lua, "return _G == _ENV")
    end
  end

  describe "open-upvalue cells are closed when a block scope ends" do
    # A nested function declaration inside `do local _ENV = ... end` captures
    # the inner `_ENV` via the open-upvalue mechanism. When the `do` block
    # exits, the cell over that register must be detached so a subsequent
    # `do local _ENV = ... end` that reuses the same slot is not read through
    # the stale cell. Lua 5.3 §3.4.10.
    test "fresh local _ENV in a sibling block is not read through a prior cell", %{lua: lua} do
      code = """
      do local _ENV = {}
        function foo() end
      end
      do local _ENV = {assert=assert, A=20}
        assert(A == 20)
      end
      return true
      """

      assert {[true], _} = Lua.eval!(lua, code)
    end

    test "nested local _ENV redirection sees the inner table at each level", %{lua: lua} do
      code = """
      do local _ENV = {assert=assert, A=10}
        do local _ENV = {assert=assert, A=20}
          assert(A == 20)
        end
        assert(A == 10)
      end
      return true
      """

      assert {[true], _} = Lua.eval!(lua, code)
    end
  end
end
